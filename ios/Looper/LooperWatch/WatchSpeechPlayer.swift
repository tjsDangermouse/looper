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

    /// Claims the audio session for speech that ducks other audio, as the
    /// phone does. Safe to call again.
    func prime() {
        reportVoicesOnce()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            onDiagnostic?("speech.audioSessionFailed", ["error": error.localizedDescription])
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
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        completions.removeAll()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.completions.removeValue(forKey: id)?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.completions.removeValue(forKey: id)?() }
    }
}
