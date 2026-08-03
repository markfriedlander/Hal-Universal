// ==== LEGO START: 64 SpeechService (Text-to-Speech Read-Aloud) ====
// SpeechService.swift
// Hal Universal
//
// A small text-to-speech read-aloud service: tap a speaker, hear the last response.
// Deliberately minimal next to Posey's SpeechPlaybackService (a full reading-teleprompter
// engine with per-word tracking and a voice picker) — Hal's need is just
// speak(one response) / stop / an isSpeaking flag. The audio-session configuration and the
// "clean the display text before speaking" idea are adapted from Posey; a voice picker is a
// later nicety (see NEXT).

import Foundation
import AVFoundation
import Combine

@MainActor
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    /// True while an utterance is being spoken. Drives the speaker icon's active state.
    @Published private(set) var isSpeaking = false
    /// The message id currently being spoken, so a specific bubble can show its speaker as
    /// active (and so tapping the same speaker again toggles stop). Empty when idle.
    @Published private(set) var speakingMessageID: String?

    private let synth = AVSpeechSynthesizer()

    // Persisted read-aloud preferences. Stored in UserDefaults so the Settings UI can bind to
    // the SAME keys via @AppStorage while this service reads them at speak() time — no extra
    // plumbing. An empty voice id means "Automatic (best available)", the prior behavior.
    static let voiceIDKey = "ttsVoiceIdentifier"
    static let rateKey = "ttsSpeechRate"
    /// When true, Hal speaks each completed response automatically (read on finish).
    static let autoReadKey = "ttsAutoRead"

    /// Whether auto-read is on. Read at the completion of a turn to decide whether to speak.
    var autoReadEnabled: Bool { UserDefaults.standard.bool(forKey: Self.autoReadKey) }

    /// The voice to speak with: the user's explicit pick if set and still installed, else the
    /// best-quality voice for the language (the original automatic behavior).
    private var preferredVoice: AVSpeechSynthesisVoice? {
        let id = UserDefaults.standard.string(forKey: Self.voiceIDKey) ?? ""
        if !id.isEmpty, let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == id }) {
            return v
        }
        return Self.bestVoice()
    }

    /// The speaking rate: the user's chosen speed, else the system default.
    private var preferredRate: Float {
        if let r = UserDefaults.standard.object(forKey: Self.rateKey) as? Double { return Float(r) }
        return AVSpeechUtteranceDefaultSpeechRate
    }

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak `text` aloud, cleaning markdown/code first so the synthesizer reads prose, not
    /// asterisks and backticks. Speaking while already speaking replaces the current utterance
    /// (stop-then-speak), so tapping a different message just switches to it.
    func speak(_ text: String, messageID: String? = nil) {
        let clean = Self.spokenText(from: text)
        guard !clean.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        configureAudioSession()
        let utterance = AVSpeechUtterance(string: clean)
        utterance.rate = preferredRate
        // The user's chosen voice (Settings › Read-Aloud › Voice), or the best-quality voice
        // available for the language when set to Automatic. Premium/enhanced are the natural
        // "Siri-quality" voices, present only if the user has downloaded them.
        utterance.voice = preferredVoice
        speakingMessageID = messageID
        isSpeaking = true
        synth.speak(utterance)
    }

    /// One control that both starts and stops: if this exact message is already speaking, stop;
    /// otherwise speak it. The speaker icon calls this.
    func toggle(_ text: String, messageID: String) {
        if isSpeaking && speakingMessageID == messageID {
            stop()
        } else {
            speak(text, messageID: messageID)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingMessageID = nil
    }

    // MARK: - Text cleaning

    /// Strip the markdown Hal renders (fenced/inline code, links, headings, blockquotes, list
    /// bullets, emphasis markers) so TTS reads the prose instead of the punctuation. A
    /// display-only transform — it never touches stored content.
    static func spokenText(from source: String) -> String {
        var s = source
        func sub(_ pattern: String, _ replacement: String) {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        sub(#"(?s)```.*?```"#, " ")            // fenced code blocks: drop (reading code aloud is noise)
        sub(#"`([^`]*)`"#, "$1")               // inline code: keep the text
        sub(#"!?\[([^\]]*)\]\([^)]*\)"#, "$1")  // links/images: keep the label
        sub(#"(?m)^\s{0,3}(?:#{1,6}|>)\s*"#, "") // headings / blockquote markers at line start
        sub(#"(?m)^\s*(?:[-*+]|\d+\.)\s+"#, "")  // list bullets at line start
        sub(#"(\*\*|\*|__|_|~~)"#, "")          // bold / italic / strikethrough markers
        sub(#"[ \t]+"#, " ")                    // collapse runs of spaces
        sub(#"\n{2,}"#, "\n")                   // collapse blank lines
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio session

    /// `.playback` + `.spokenAudio` so read-aloud plays even with the ringer switched off, and
    /// `.mixWithOthers`/`.duckOthers` so we duck rather than kill the user's music/podcast.
    /// Adapted from Posey's SpeechPlaybackService. Best-effort — a failure just means quieter.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
    }

    // MARK: - Voice selection

    /// The best-quality voice for the current language: premium first, then enhanced, then the
    /// default compact voice. Premium/enhanced are the natural "Siri-quality" voices — present
    /// only if the user has downloaded them (Settings › Accessibility › Spoken Content › Voices).
    /// Falls back gracefully so speech always works. Approach adapted from Posey's voice picker;
    /// a manual picker (choose a specific voice) is the next step.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let all = AVSpeechSynthesisVoice.speechVoices()
        // Prefer exact-language matches; else the same base language (e.g. "en"); else anything.
        let exact = all.filter { $0.language == lang }
        let base = String(lang.prefix(2))
        let pool = !exact.isEmpty ? exact : all.filter { $0.language.hasPrefix(base) }
        let candidates = pool.isEmpty ? all : pool
        return candidates.max { qualityRank($0.quality) < qualityRank($1.quality) }
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    private static func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium:  return 3
        case .enhanced: return 2
        default:        return 1   // .default (compact)
        }
    }

    /// Speak a short sample in the CURRENT voice + speed selection — the picker's live preview
    /// and the speed slider's on-release preview both call this. (The voice list + grouping for
    /// the picker live in VoicePickerView, adapted from Posey.)
    func speakSample() {
        speak("Hi, I'm Hal. This is how I sound.")
    }

    /// Diagnostic: the voice `speak()` would use right now, plus how many premium/enhanced voices
    /// are installed. Lets the antenna confirm the "Siri-quality" pick without needing an ear.
    func voiceReport() -> (name: String, quality: String, premiumInstalled: Int, enhancedInstalled: Int) {
        let v = Self.bestVoice()
        let all = AVSpeechSynthesisVoice.speechVoices()
        let quality: String
        switch v?.quality {
        case .premium:  quality = "premium"
        case .enhanced: quality = "enhanced"
        case .some:     quality = "default"
        case .none:     quality = "none"
        @unknown default: quality = "unknown"
        }
        return (v?.name ?? "none", quality,
                all.filter { $0.quality == .premium }.count,
                all.filter { $0.quality == .enhanced }.count)
    }

    // MARK: - Preferences (Settings UI + antenna share these)

    // The Settings › Read-Aloud controls bind these same UserDefaults keys via @AppStorage, so
    // setting them here updates the UI live (@AppStorage observes UserDefaults change notices).
    // These setters exist so the key names live in exactly one place and the antenna can drive
    // the prefs for verification without needing on-screen taps (the picker is a NavigationLink).

    /// Turn auto-read on/off (read every completed response aloud).
    func setAutoRead(_ on: Bool) { UserDefaults.standard.set(on, forKey: Self.autoReadKey) }

    /// Choose the speaking voice by identifier; empty string means Automatic (best available).
    func setPreferredVoiceID(_ id: String) { UserDefaults.standard.set(id, forKey: Self.voiceIDKey) }

    /// Set the speaking rate (AVSpeechUtterance rate space, ~0.0…1.0; default is 0.5).
    func setPreferredRate(_ rate: Double) { UserDefaults.standard.set(rate, forKey: Self.rateKey) }

    /// The current read-aloud preferences AND the voice/rate `speak()` would actually use right
    /// now. "stored" is what's persisted (voice id may be "" for Automatic); "effective" resolves
    /// that to the real voice — the user's pick if still installed, else the automatic best.
    /// Lets the antenna verify a chosen voice/rate is applied without needing an ear.
    func prefsReport() -> (autoRead: Bool, storedVoiceID: String, storedRate: Double,
                           effectiveVoiceName: String, effectiveVoiceID: String,
                           effectiveQuality: String, effectiveRate: Float) {
        let storedID = UserDefaults.standard.string(forKey: Self.voiceIDKey) ?? ""
        let storedRate = UserDefaults.standard.object(forKey: Self.rateKey) as? Double
            ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        let v = preferredVoice
        let quality: String
        switch v?.quality {
        case .premium:  quality = "premium"
        case .enhanced: quality = "enhanced"
        case .some:     quality = "default"
        case .none:     quality = "none"
        @unknown default: quality = "unknown"
        }
        return (autoReadEnabled, storedID, storedRate,
                v?.name ?? "none", v?.identifier ?? "", quality, preferredRate)
    }

    /// Installed voices for the current base language as (name, identifier, quality, language).
    /// Lets the antenna pick a real identifier to set when verifying the voice-picker path.
    func installedVoices() -> [(name: String, identifier: String, quality: String, language: String)] {
        let base = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(base) }
            .sorted { Self.qualityRank($0.quality) > Self.qualityRank($1.quality) }
            .map { v in
                let q: String
                switch v.quality {
                case .premium:  q = "premium"
                case .enhanced: q = "enhanced"
                default:        q = "default"
                }
                return (v.name, v.identifier, q, v.language)
            }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            speakingMessageID = nil
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            speakingMessageID = nil
        }
    }
}
// ==== LEGO END: 64 SpeechService (Text-to-Speech Read-Aloud) ====
