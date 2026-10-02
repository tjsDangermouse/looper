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

    func configure(_ narration: NarrationSettings?) {
        voiceIdentifier = narration?.voiceIdentifier
    }

    /// Claims the audio session for speech that ducks other audio, as the
    /// phone does. Safe to call again.
    func prime() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            onDiagnostic?("speech.audioSessionFailed", ["error": error.localizedDescription])
        }
    }

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
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
