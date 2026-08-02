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
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // System default voice for the current locale; a picker can come later.
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
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
