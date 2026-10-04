import Foundation
import LooperKit
import WatchConnectivity

/// The WatchConnectivity half of the Watch/iPhone link, shared by both apps.
///
/// The mirrored workout session's own data channel is the fast path while a
/// workout is running, but it only exists once a workout exists — and it goes
/// away the moment the session ends or the devices lose each other. This is
/// everything around that: preloading the prepared loop, a Watch asking to
/// start one, and a way for state to keep flowing when the live channel is
/// down. It is deliberately unaware of HealthKit.
final class WatchLinkSession: NSObject {
    /// How much a message is willing to pay for delivery.
    enum Delivery {
        /// Now or never — a live figure that a newer one will replace in a
        /// second anyway. Dropped silently when the counterpart is asleep.
        case live
        /// Must arrive, even if the counterpart is asleep or out of range.
        /// Queued by the system and delivered whenever it can be.
        case durable
        /// The single most recent picture of the world. Overwrites whatever
        /// was queued before it, so a Watch that reconnects after ten minutes
        /// gets today's state rather than ten minutes of history.
        case latest
        /// A big payload, queued and delivered whenever the counterpart next
        /// runs. Only the most recent of each `kind` is kept in flight, so a
        /// Watch that was away for a week doesn't take delivery of seven
        /// out-of-date saved-route lists.
        case queued(kind: String)
    }

    /// What the link can do right now, in the terms the UI has to explain.
    struct Reach: Equatable {
        var supported = false
        var activated = false
        /// iPhone: a Watch is paired and has the Looper app. Watch: the phone
        /// app is installed.
        var counterpartInstalled = false
        /// The other app is awake and can answer immediately.
        var reachable = false

        var canPreload: Bool { supported && activated && counterpartInstalled }
    }

    /// Called on the main actor for every decoded message.
    var onMessage: ((WatchMessage) -> Void)?
    /// Called on the main actor whenever the picture above changes.
    var onReachChange: ((Reach) -> Void)?
    /// Called on the main actor when a message arrives that this build can't
    /// read — one device updated, the other not.
    var onVersionMismatch: ((Int) -> Void)?

    /// Called on the main actor for every file that arrives, with the
    /// details sent alongside it. The file is this app's to move or delete.
    var onFile: ((URL, [String: Any]) -> Void)?

    private(set) var reach = Reach()
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else {
            publishReach(Reach(supported: false))
            return
        }
        session.delegate = self
        if session.activationState != .activated { session.activate() }
        refreshReach()
    }

    /// Sends one message. `live` traffic that can't be delivered immediately
    /// is simply dropped — a stale distance is worse than none — while
    /// anything durable falls back to the queued transfer.
    func send(_ message: WatchMessage, delivery: Delivery) {
        guard let session, session.activationState == .activated else { return }
        guard let payload = try? WatchLinkCodec.dictionary(for: message) else { return }

        switch delivery {
        case .live:
            guard session.isReachable else { return }
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Nothing to do: a newer update is already on its way.
            }
        case .durable:
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { _ in
                    // Reachability can lapse between the check and the send;
                    // the queued transfer is the guarantee that matters.
                    session.transferUserInfo(payload)
                }
            } else {
                session.transferUserInfo(payload)
            }
        case .latest:
            // Application context is the one channel that survives both apps
            // being asleep and still hands over the *current* state on wake.
            try? session.updateApplicationContext(payload)
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { _ in }
            }
        case .queued(let kind):
            for transfer in session.outstandingUserInfoTransfers where transfer.userInfo["kind"] as? String == kind {
                transfer.cancel()
            }
            var info = payload
            info["kind"] = kind
            session.transferUserInfo(info)
        }
    }

    /// Queues a file for the counterpart. The system delivers it whenever it
    /// can, in order, and the file is deleted here once it has gone.
    func sendFile(_ url: URL, details: [String: Any]) {
        guard let session, session.activationState == .activated else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        session.transferFile(url, metadata: details)
    }

    /// The details of every file still waiting to go.
    var filesInFlight: [[String: Any]] {
        guard let session, session.activationState == .activated else { return [] }
        return session.outstandingFileTransfers.filter(\.isTransferring).compactMap { $0.file.metadata }
    }

    /// Withdraws queued files the counterpart no longer wants.
    func cancelFiles(where unwanted: ([String: Any]) -> Bool) {
        guard let session, session.activationState == .activated else { return }
        for transfer in session.outstandingFileTransfers where unwanted(transfer.file.metadata ?? [:]) {
            transfer.cancel()
            try? FileManager.default.removeItem(at: transfer.file.fileURL)
        }
    }

    private func refreshReach() {
        guard let session else { return publishReach(Reach(supported: false)) }
        var next = Reach()
        next.supported = true
        next.activated = session.activationState == .activated
        next.reachable = session.isReachable
        #if os(iOS)
        next.counterpartInstalled = session.isPaired && session.isWatchAppInstalled
        #else
        next.counterpartInstalled = session.isCompanionAppInstalled
        #endif
        publishReach(next)
    }

    private func publishReach(_ next: Reach) {
        guard next != reach else { return }
        reach = next
        Task { @MainActor [onReachChange] in onReachChange?(next) }
    }

    private func handle(_ payload: [String: Any]) {
        do {
            let message = try WatchLinkCodec.message(from: payload)
            Task { @MainActor [onMessage] in onMessage?(message) }
        } catch WatchLinkError.unsupportedVersion(let version) {
            Task { @MainActor [onVersionMismatch] in onVersionMismatch?(version) }
        } catch {
            // A payload we can't read at all is dropped; the next state
            // update replaces it in a second or two either way.
        }
    }
}

extension WatchLinkSession: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        refreshReach()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system deletes the file when this returns, so it is moved first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard (try? FileManager.default.moveItem(at: file.fileURL, to: kept)) != nil else { return }
        let details = file.metadata ?? [:]
        Task { @MainActor [onFile] in
            if let onFile { onFile(kept, details) } else { try? FileManager.default.removeItem(at: kept) }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refreshReach()
    }

    #if os(iOS)
    func sessionWatchStateDidChange(_ session: WCSession) {
        refreshReach()
    }

    /// A phone can be unpaired from one Watch and paired to another without
    /// the app being relaunched; both of these hand the session back so it
    /// can be activated again for the new Watch.
    func sessionDidBecomeInactive(_ session: WCSession) {
        refreshReach()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif
}
