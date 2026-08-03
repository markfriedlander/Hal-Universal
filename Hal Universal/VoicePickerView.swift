// ==== LEGO START: 65 VoicePickerView (Read-Aloud Voice Selection) ====
// VoicePickerView.swift
// Hal Universal
//
// The voice selection list for read-aloud, adapted from Posey's VoicePickerView (its reader
// is TTS-first, so its picker is the mature reference). Kept nearly verbatim: the VoiceOption
// model, the VoiceList grouping (by language, English first; quality tier within; device locale
// on top), the "Show all languages" expansion, the empty state, and the quality color-coding.
//
// Two Hal-specific adaptations:
//   1. An "Automatic (best available)" row at the top — Hal's default (empty identifier), which
//      SpeechService resolves to the highest-quality installed voice for the language.
//   2. Preview-on-tap: selecting a voice speaks a short sample in it (and stays on the picker)
//      so the user can audition several, rather than Posey's select-and-dismiss.

import AVFoundation
import SwiftUI

/// A single voice available on the device, with display-ready labels.
struct VoiceOption: Identifiable {
    let voice: AVSpeechSynthesisVoice
    var id: String { voice.identifier }
    var name: String { voice.name }
    var language: String { voice.language }

    var qualityLabel: String {
        switch voice.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Standard"
        }
    }
    /// Sort index: lower = higher quality (Premium first).
    var qualitySortIndex: Int {
        switch voice.quality {
        case .premium:  return 0
        case .enhanced: return 1
        default:        return 2
        }
    }
    /// BCP-47 language code, e.g. "en" from "en-US".
    var languageCode: String { String(voice.language.split(separator: "-").first ?? "en") }
    /// Human-readable language name using the current locale.
    var languageDisplayName: String {
        Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode.uppercased()
    }
}

/// Groups and sorts all voices available on the device: language (alphabetical, English first) →
/// quality tier (Premium → Enhanced → Standard) → locale variant (device locale first).
struct VoiceList {
    struct Group: Identifiable {
        var id: String { languageCode }
        let languageCode: String
        let languageDisplayName: String
        let voices: [VoiceOption]
    }
    let groups: [Group]

    init() {
        let allVoices = AVSpeechSynthesisVoice.speechVoices().map { VoiceOption(voice: $0) }
        let grouped = Dictionary(grouping: allVoices, by: \.languageCode)
        let preferredLocale = Locale.preferredLanguages.first ?? "en-US"

        var built: [Group] = grouped.map { code, voices in
            let sorted = voices.sorted {
                if $0.qualitySortIndex != $1.qualitySortIndex { return $0.qualitySortIndex < $1.qualitySortIndex }
                if $0.language == preferredLocale { return true }
                if $1.language == preferredLocale { return false }
                return $0.language < $1.language
            }
            let displayName = sorted.first?.languageDisplayName ?? code.uppercased()
            return Group(languageCode: code, languageDisplayName: displayName, voices: sorted)
        }
        built.sort {
            if $0.languageCode == "en" { return true }
            if $1.languageCode == "en" { return false }
            return $0.languageDisplayName < $1.languageDisplayName
        }
        groups = built
    }
}

/// Voice selection list, grouped by language then quality tier. Defaults to the device's current
/// language; "Show all languages" expands the full list. A NavigationLink destination from the
/// Read-Aloud settings section. Binds to the persisted voice identifier ("" = Automatic).
struct VoicePickerView: View {
    @Binding var selectedIdentifier: String
    @State private var showAllLanguages = false

    private let voiceList = VoiceList()

    private var currentLanguageCode: String {
        String(AVSpeechSynthesisVoice.currentLanguageCode().split(separator: "-").first ?? "en")
    }

    private var visibleGroups: [VoiceList.Group] {
        guard !showAllLanguages else { return voiceList.groups }
        return voiceList.groups.filter { $0.languageCode == currentLanguageCode }
    }

    var body: some View {
        List {
            // Automatic (Hal's default): highest-quality installed voice for the language.
            Section {
                Button {
                    selectedIdentifier = ""
                    SpeechService.shared.speakSample()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic").foregroundStyle(.primary)
                            Text("Best available voice for your language")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedIdentifier.isEmpty {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Tap a voice to hear a sample. Only voices downloaded to your device are listed; add more in the device's Settings, under Accessibility, Spoken Content, Voices.")
            }

            if visibleGroups.isEmpty {
                Section {
                    Text("No voices for your current language are downloaded. Tap \"Show all languages\" below, or add voices in the device's Settings, under Accessibility, Spoken Content, Voices.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            ForEach(visibleGroups) { group in
                Section(group.languageDisplayName) {
                    ForEach(group.voices) { option in
                        voiceRow(option)
                    }
                }
            }

            if !showAllLanguages {
                Section {
                    Button("Show all languages") { showAllLanguages = true }
                }
            }
        }
        .navigationTitle("Hal's Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func voiceRow(_ option: VoiceOption) -> some View {
        Button {
            selectedIdentifier = option.id
            SpeechService.shared.speakSample()   // preview the newly selected voice (stay on the picker)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(option.qualityLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(qualityColor(for: option.voice.quality))
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(option.language).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if option.id == selectedIdentifier {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func qualityColor(for quality: AVSpeechSynthesisVoiceQuality) -> Color {
        switch quality {
        case .premium:  return Color.accentColor
        case .enhanced: return Color.secondary
        default:        return Color.secondary.opacity(0.6)
        }
    }
}
// ==== LEGO END: 65 VoicePickerView (Read-Aloud Voice Selection) ====
