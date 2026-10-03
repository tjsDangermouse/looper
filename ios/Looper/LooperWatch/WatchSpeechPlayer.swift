import AVFoundation
import Foundation
import LooperKit

/// Speaks the phone's script. It is handed finished sentences and does nothing
/// but say them — what to say, and when, was decided on the phone.
///
/// Watch audio reaches the wearer through connected headphones or a speaker;
/// the Start screen says so rather than letting a silent walk look like a bug.
@MainActor
final class WatchSpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var voiceIdentifier: String?
    private var completions: [ObjectIdentifier: () -> Void] = [:]
    var onDiagnostic: ((String, [String: String]) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private var voice: AVSpeechSynthesisVoice?
    private var resolvedVoiceIdentifier: String??

    func configure(_ narration: NarrationSettings?) {
        voiceIdentifier = narration?.voiceIdentifier
    }

    /// Looked up once, not per sentence: the lookup is a round trip to the
    /// system's speech service.
    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let resolvedVoiceIdentifier, resolvedVoiceIdentifier == voiceIdentifier { return voice }
        resolvedVoiceIdentifier = .some(voiceIdentifier)
        voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? bestInstalledVoice()
            ?? AVSpeechSynthesisVoice(language: "en-GB")
        return voice
    }

    /// The phone's chosen voice is often not on the Watch. Take the best
    /// English voice that is — British first, premium before enhanced.
    private func bestInstalledVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix("en") }
        let british = english.filter { $0.language == "en-GB" }
        let rank: (AVSpeechSynthesisVoice) -> Int = { voice in
            switch voice.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }
        return (british.isEmpty ? english : british).max { rank($0) < rank($1) }
    }

    /// Sets the audio session up for speech that ducks other audio, as the
    /// phone does. Safe to call again. The session is only active while
    /// something is being said: an active ducking session keeps the wearer's
    /// music turned down for as long as it stays active.
    func prime() {
        reportVoicesOnce()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        } catch {
            onDiagnostic?("speech.audioSessionFailed", ["error": error.localizedDescription])
        }
    }

    /// Utterances queued and not yet finished or cancelled.
    private var pending = 0
    private var releaseTask: Task<Void, Never>?

    var isSpeaking: Bool { pending > 0 }

    private func activateSession() {
        releaseTask?.cancel()
        releaseTask = nil
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            onDiagnostic?("speech.audioSessionFailed", ["error": error.localizedDescription])
        }
    }

    /// Gives the audio back once the queue has drained, so other apps return
    /// to full volume. A short wait first, so back-to-back sentences don't
    /// pump the music up and down between them.
    private func releaseSessionWhenIdle() {
        guard pending == 0 else { return }
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.pending == 0, !self.synthesizer.isSpeaking else { return }
            self.releaseTask = nil
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                self.onDiagnostic?("speech.audioReleaseFailed", ["error": error.localizedDescription])
            }
        }
    }

    private var reportedVoices = false

    /// Which English voices this Watch actually has, and which one is used —
    /// the phone's premium voice is not among them unless watchOS offers it.
    private func reportVoicesOnce() {
        guard !reportedVoices else { return }
        reportedVoices = true
        let quality: (AVSpeechSynthesisVoice) -> String = { voice in
            switch voice.quality {
            case .premium: return "premium"
            case .enhanced: return "enhanced"
            default: return "default"
            }
        }
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix("en") }
        onDiagnostic?("speech.voices", [
            "english": english.map { "\($0.name) \($0.language) \(quality($0))" }.joined(separator: "; "),
            "requested": voiceIdentifier ?? "none",
            "chosen": resolveVoice().map { "\($0.name) \(quality($0)) \($0.identifier)" } ?? "none"
        ])
    }

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_NO_SPEECH"] == "1" {
            onDiagnostic?("speech.skipped", ["text": text])
            completion?()
            return
        }
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice()
        if let completion { completions[ObjectIdentifier(utterance)] = completion }
        onDiagnostic?("speech.queued", ["text": text])
        activateSession()
        pending += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        completions.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        pending = max(0, pending - 1)
        completions.removeValue(forKey: id)?()
        releaseSessionWhenIdle()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
