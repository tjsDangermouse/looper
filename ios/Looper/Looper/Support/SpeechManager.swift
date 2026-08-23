import AVFoundation

/// Turn-by-turn voice guidance. Configured for background playback so
/// announcements keep firing while the phone is locked — the PWA limitation
/// this native app exists to fix.
final class SpeechManager: NSObject {
    private nonisolated(unsafe) let synthesizer = AVSpeechSynthesizer()
    private let selectedVoiceKey = "selectedVoiceIdentifier"

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Only voices already available on the device appear here. iOS manages
    /// downloads of enhanced and premium voice packs in Settings.
    var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
            .sorted {
                if $0.language != $1.language { return $0.language < $1.language }
                if qualityRank($0) != qualityRank($1) { return qualityRank($0) > qualityRank($1) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// British English remains the app's natural default. Within every locale,
    /// prefer premium, then enhanced, before accepting the standard voice.
    var selectedVoice: AVSpeechSynthesisVoice? {
        if let identifier = UserDefaults.standard.string(forKey: selectedVoiceKey),
           let saved = AVSpeechSynthesisVoice(identifier: identifier) {
            return saved
        }
        return preferredVoice(in: englishVoices.filter { $0.language == "en-GB" })
            ?? preferredVoice(in: englishVoices)
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    var selectedVoiceIdentifier: String? { selectedVoice?.identifier }

    var hasPremiumEnglishVoice: Bool {
        englishVoices.contains { $0.quality == .premium }
    }

    func selectVoice(identifier: String) {
        UserDefaults.standard.set(identifier, forKey: selectedVoiceKey)
    }

    func prime() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = selectedVoice
        prime()
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivate()
    }

    /// Other apps' audio only needs to duck for the duration of an
    /// announcement — release the session once it's finished speaking so
    /// music/podcasts return to full volume instead of staying ducked for
    /// the rest of the walk.
    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func qualityName(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    private func preferredVoice(in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        voices.max { qualityRank($0) < qualityRank($1) }
    }

    private func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deactivate()
    }
}
