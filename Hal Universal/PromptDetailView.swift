// PromptDetailView.swift
// Hal Universal
//
// Created 2026-05-17 (per Mark's directive: "color-coded segments so
// users can visually distinguish system prompt, self-knowledge, RAG
// snippets, conversation history, and user message. Collapsible
// sections for dense content. This is an educational surface and it
// should feel like one.").
//
// The PromptDetailView shows the full prompt that produced a given
// assistant turn, broken into structurally-meaningful, color-coded
// sections that the user can expand and collapse independently.
// Sections map to how Hal actually assembles his prompts in
// buildChatMessages (system persona → temporal context → conversation
// summary → self-awareness → self-knowledge → RAG snippets → watch
// delivery → conversation history → current user input).
//
// Refactor-as-you-go: lives in its own file rather than nested inside
// the iOSChatView struct (which is where the previous unused
// PromptDetailView was defined).

import SwiftUI

// MARK: - Segment classification

/// Logical sections of an assembled prompt. Each one gets its own
/// color, icon, and short header label so the user can see at a
/// glance what's in the prompt and how it's organized.
enum PromptDetailSegmentKind: Sendable {
    case systemPrompt          // Layer 1 + Layer 2 (persona/framing)
    case temporal              // Date/time/device/uptime
    case summary               // Compressed conversation summary
    case selfAwareness         // Runtime stats (turn count, etc.)
    case selfKnowledge         // Persistent traits / reflections
    case ragRetrieval          // Long-term memory snippets
    case conversationHistory   // Recent turn pairs
    case userMessage           // The user input that triggered this turn
    case other                 // Unclassified context

    /// Display label for the section header.
    var displayName: String {
        switch self {
        case .systemPrompt:        return "System Prompt"
        case .temporal:            return "Temporal Context"
        case .summary:             return "Conversation Summary"
        case .selfAwareness:       return "Self-Awareness"
        case .selfKnowledge:       return "Self-Knowledge"
        case .ragRetrieval:        return "Memory Snippets (RAG)"
        case .conversationHistory: return "Conversation History"
        case .userMessage:         return "User Message"
        case .other:               return "Context"
        }
    }

    /// SF Symbol icon for the row.
    var icon: String {
        switch self {
        case .systemPrompt:        return "scroll"
        case .temporal:            return "clock"
        case .summary:             return "doc.append"
        case .selfAwareness:       return "gauge"
        case .selfKnowledge:       return "brain"
        case .ragRetrieval:        return "magnifyingglass"
        case .conversationHistory: return "bubble.left.and.bubble.right"
        case .userMessage:         return "person.circle"
        case .other:               return "ellipsis.circle"
        }
    }

    /// Section color. Picked for distinguishability on both light and
    /// dark mode; the rendered tint sits at moderate saturation so
    /// section headers read clearly without overpowering the body
    /// text. Order matches the assembly order in buildChatMessages
    /// so the palette tells a story when scanned top-to-bottom.
    var color: Color {
        switch self {
        case .systemPrompt:        return .purple
        case .temporal:            return .orange
        case .summary:             return .yellow
        case .selfAwareness:       return .teal
        case .selfKnowledge:       return .pink
        case .ragRetrieval:        return .green
        case .conversationHistory: return .blue
        case .userMessage:         return .gray
        case .other:               return .secondary
        }
    }

    /// Short text label used by the export (text-only) variant so a
    /// copy-and-paste transcript still color-codes via prefixed
    /// emoji + label. Matches the SF Symbol's spirit without needing
    /// rendered SwiftUI.
    ///
    /// Stable integer rank for each case, used by the nonisolated
    /// `parsePromptSegments` to compare kinds without going through
    /// the enum's synthesized Equatable (which the project-level
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes
    /// @MainActor-isolated and therefore unusable from nonisolated
    /// contexts). Pure value-type derivation, safe from any context.
    nonisolated var kindRank: Int {
        switch self {
        case .systemPrompt:        return 0
        case .temporal:            return 1
        case .summary:             return 2
        case .selfAwareness:       return 3
        case .selfKnowledge:       return 4
        case .ragRetrieval:        return 5
        case .conversationHistory: return 6
        case .userMessage:         return 7
        case .other:               return 8
        }
    }

    /// Marked `nonisolated` so the nonisolated `buildPromptDetailExportText`
    /// can reference it without a @MainActor hop. The rest of the enum's
    /// view-side extension members (displayName/icon/color) are read
    /// only from SwiftUI bodies which are already main-actor-isolated.
    nonisolated var exportTag: String {
        switch self {
        case .systemPrompt:        return "📜 SYSTEM PROMPT"
        case .temporal:            return "🕒 TEMPORAL CONTEXT"
        case .summary:             return "📄 CONVERSATION SUMMARY"
        case .selfAwareness:       return "📊 SELF-AWARENESS"
        case .selfKnowledge:       return "🧠 SELF-KNOWLEDGE"
        case .ragRetrieval:        return "🔍 MEMORY SNIPPETS (RAG)"
        case .conversationHistory: return "💬 CONVERSATION HISTORY"
        case .userMessage:         return "👤 USER MESSAGE"
        case .other:               return "• CONTEXT"
        }
    }
}

/// One parsed segment of a prompt — its classification plus the
/// verbatim body text. Conformance to Identifiable so SwiftUI can
/// render a stable ForEach.
struct PromptDetailSegment: Identifiable, Sendable {
    // Stable, deterministic ID derived from position + content so
    // ForEach identity survives `body` recomputes. The previous
    // `let id = UUID()` minted a fresh UUID each time the parent's
    // computed `segments` ran, which made ForEach re-create every
    // card and reset their local @State (e.g. DisclosureGroup
    // expansion). Including content in the hash means the rare case
    // where two segments of the same kind have the same body still
    // collide gracefully; we tack on the index to disambiguate.
    let id: String
    let kind: PromptDetailSegmentKind
    let content: String

    // Marked nonisolated so parsePromptSegments (also nonisolated)
    // can call this without a @MainActor hop. The interpolation
    // `\(kind)` would otherwise pull in PromptDetailSegmentKind's
    // @MainActor-isolated extension surface (displayName/icon/etc.);
    // using kind.rawHashValue keeps the id derivation pure.
    nonisolated init(kind: PromptDetailSegmentKind, content: String, index: Int = 0) {
        self.kind = kind
        self.content = content
        self.id = "seg-\(index)-\(content.hashValue)"
    }
}

// MARK: - Parser

/// Classify a context-block section by its opening line. The
/// patterns mirror the literal section starters used in
/// buildChatMessages (e.g. "Summary of earlier conversation:",
/// "Relevant past context:"). Anything that
/// doesn't match a known marker falls back to .other so the user
/// still sees the content — better to display unclassified than to
/// drop it.
nonisolated func classifyPromptContextSection(_ section: String) -> PromptDetailSegmentKind {
    let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()

    // Explicit prefix markers (set deterministically by buildChatMessages
    // — these are unambiguous matches).
    if lower.hasPrefix("summary of earlier conversation:") { return .summary }
    if lower.hasPrefix("relevant past context:") { return .ragRetrieval }

    // Self-Awareness body is produced by buildSelfAwarenessContext and
    // opens with the "You are Hal" framing followed by a structured
    // "Your history and capabilities:" block. Match any of the
    // distinctive markers we actually emit. Phase 4-era bodies include
    // "Conversation threads:", "Current session duration:", "App uptime:"
    // and (when reflection is due) "It has been N turns since your last
    // self-reflection." Audit pass 2026-05-18.
    if lower.hasPrefix("you are hal") ||
       lower.contains("your history and capabilities:") ||
       lower.contains("conversation threads:") ||
       lower.contains("current session duration:") ||
       lower.contains("app uptime:") ||
       lower.contains("since your last self-reflection") ||
       lower.contains("turn count") ||
       lower.contains("conversation uptime") ||
       lower.contains("messages so far") {
        return .selfAwareness
    }

    // Self-Knowledge body is produced by buildSelfKnowledgeContext and
    // opens with "Persistent knowledge (survives conversation deletion):"
    // followed by category headers like "Core Values:", "Proven
    // Capabilities:", "User Preferences:", "Learned User Traits:",
    // "Interaction Patterns:", "Identity Milestones:", "Ways of Thinking:".
    // Match the opener and a sampling of the category headers so the
    // segment classifies whether or not all categories are populated.
    if lower.hasPrefix("persistent knowledge") ||
       lower.contains("core values:") ||
       lower.contains("proven capabilities:") ||
       lower.contains("user preferences:") ||
       lower.contains("learned user traits:") ||
       lower.contains("interaction patterns:") ||
       lower.contains("identity milestones:") ||
       lower.contains("ways of thinking:") ||
       lower.contains("persistent trait") ||
       lower.contains("self-knowledge:") {
        return .selfKnowledge
    }

    // Temporal context body opens with "Current date and time:" /
    // "Day of week:" / "Time of day:" (buildTemporalContext) plus the
    // optional timing signals ("Device:", "This thread:", "Resuming
    // after Xh gap", etc.). Match the deterministic openers.
    if lower.hasPrefix("today is") ||
       lower.contains("it is now") ||
       lower.contains("current date and time:") ||
       lower.contains("day of week:") ||
       lower.contains("time of day:") {
        return .temporal
    }

    return .other
}

/// Parse a `fullPromptUsed` string into a list of segments.
///
/// The system message that Hal sends to the LLM has the shape:
///
///     <persona>
///
///     CURRENT CONTEXT:
///     <section1>
///
///     <section2>
///     ...
///
/// We split on the literal "\n\nCURRENT CONTEXT:\n" boundary; the
/// first half becomes the .systemPrompt segment. The remainder is
/// split into context sections on "\n\n" and each section is
/// classified by `classifyPromptContextSection`.
///
/// The caller can optionally append .conversationHistory and
/// .userMessage segments before/after by inspecting the chat
/// message context — those don't live inside `fullPromptUsed` (the
/// LLM receives them as separate chat-message turns) but the user
/// reads the prompt as a unified whole, so we render them as
/// adjacent segments.
nonisolated func parsePromptSegments(fullPrompt: String) -> [PromptDetailSegment] {
    var segments: [PromptDetailSegment] = []

    let parts = fullPrompt.components(separatedBy: "\n\nCURRENT CONTEXT:\n")
    let personaText = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !personaText.isEmpty {
        segments.append(PromptDetailSegment(kind: .systemPrompt, content: personaText))
    }

    guard parts.count > 1 else { return segments }

    // The context body's sub-sections (Temporal, Summary, Self-Awareness,
    // Self-Knowledge, RAG, Watch-Delivery) are joined with "\n\n" by
    // buildChatMessages — BUT each sub-section internally also uses
    // "\n\n" for paragraph breaks. A naive split on "\n\n" therefore
    // shatters Self-Awareness into 4+ chunks and Self-Knowledge into
    // 6-8 category chunks, each becoming its own viewer row. That's
    // the "wall of Context rows" bug Mark called out 2026-05-18.
    //
    // Fix: walk paragraphs in order, classify each, and merge adjacent
    // paragraphs that belong to the same logical section. A paragraph
    // is treated as a continuation of the previous logical section when
    // either (a) it classifies to the same kind as the previous
    // classified paragraph, or (b) it classifies to .other and the
    // previous classified paragraph had a known kind. The result is
    // one viewer row per logical section, with all its paragraphs intact.
    let contextBody = parts.dropFirst().joined(separator: "\n\nCURRENT CONTEXT:\n")
    let paragraphs = contextBody.components(separatedBy: "\n\n")

    // We avoid Optional<PromptDetailSegmentKind> for `currentKind` and
    // direct `==` comparisons on the enum because the project-level
    // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes the enum's
    // synthesized Equatable conformance @MainActor-isolated, which
    // can't be used from this nonisolated function. Instead we encode
    // the kind via its `kindRank` Int (a pure-value comparison that
    // doesn't go through Equatable), with -1 meaning "no current
    // section yet". Same pattern as the existing nonisolated
    // `PromptDetailSegment(kind:content:index:)` init which uses
    // `\(kind)` printable form to derive the id.
    var currentKindRank: Int = -1
    var currentKind: PromptDetailSegmentKind = .other  // placeholder, ignored while rank == -1
    var currentChunks: [String] = []
    var segmentIndex = 0

    func flush() {
        guard currentKindRank >= 0, !currentChunks.isEmpty else { return }
        let body = currentChunks.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            segments.append(PromptDetailSegment(kind: currentKind, content: body, index: segmentIndex))
            segmentIndex += 1
        }
        currentChunks = []
    }

    for paragraph in paragraphs {
        let body = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { continue }
        let kind = classifyPromptContextSection(body)
        let rank = kind.kindRank

        if currentKindRank < 0 {
            // First paragraph: start a new section.
            currentKind = kind
            currentKindRank = rank
            currentChunks = [body]
            continue
        }

        if rank == currentKindRank {
            // Same kind continuing — append to current section.
            currentChunks.append(body)
        } else if rank == PromptDetailSegmentKind.other.kindRank {
            // Unclassified continuation paragraph (e.g. the trailing
            // "You can reference this history naturally when relevant…"
            // sentence in Self-Awareness). Attach to the running
            // section rather than emitting a bare "Context" row.
            currentChunks.append(body)
        } else {
            // New, distinguishable section begins. Flush the previous
            // group and start fresh.
            flush()
            currentKind = kind
            currentKindRank = rank
            currentChunks = [body]
        }
    }
    flush()

    return segments
}

// MARK: - View

/// Color-coded, collapsible prompt detail view. Replaces the
/// previous flat text-blob PromptDetailView (which was defined but
/// never wired into the UI). Wired in by the chat bubble's "View
/// Prompt Details" context menu entry.
struct PromptDetailView: View {
    let message: ChatMessage
    let precedingUserContent: String?  // The user input that triggered this assistant turn
    let recentHistory: [ChatMessage]   // A few prior turns for context, optional

    @Environment(\.dismiss) var dismiss
    // NOTE (2026-05-17, post-Item-4-wire): previously kept a Set<UUID>
    // of expanded segment IDs here, but `segments` below is computed
    // and PromptDetailSegment.id = UUID() regenerates on every body
    // pass. The Set stored stale IDs, so cards collapsed on the next
    // redraw. Now each card owns its own @State; this view doesn't
    // need to track expansion at all.

    private var segments: [PromptDetailSegment] {
        var result: [PromptDetailSegment] = []
        if let prompt = message.fullPromptUsed, !prompt.isEmpty {
            result.append(contentsOf: parsePromptSegments(fullPrompt: prompt))
        }
        // Append conversation-history and user-message segments so the
        // viewer presents the WHOLE input to the LLM as one ordered
        // narrative, even though the chat layer split it across
        // multiple .system / .user / .assistant messages.
        if !recentHistory.isEmpty {
            let body = recentHistory.map { m in
                let speaker = m.isFromUser ? "User" : "Hal"
                return "[\(speaker)] \(m.content)"
            }.joined(separator: "\n\n")
            result.append(PromptDetailSegment(kind: .conversationHistory, content: body))
        }
        if let userMsg = precedingUserContent, !userMsg.isEmpty {
            result.append(PromptDetailSegment(kind: .userMessage, content: userMsg))
        }
        return result
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Top legend so the color language is self-explanatory.
                    PromptDetailLegend()
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    ForEach(segments) { segment in
                        PromptDetailSegmentCard(segment: segment)
                            .padding(.horizontal, 16)
                    }

                    // Token breakdown summary — shows actual numbers
                    // tagged to the colors above so users can read
                    // the budget in the same visual language as the
                    // segments.
                    if let breakdown = message.tokenBreakdown {
                        TokenBudgetSummary(breakdown: breakdown)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Prompt Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Copy as Text") {
                        UIPasteboard.general.string = buildPromptDetailExportText(
                            message: message,
                            precedingUserContent: precedingUserContent,
                            recentHistory: recentHistory
                        )
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Sub-views

private struct PromptDetailLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How this prompt is built")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text("Each colored section below is one piece of the prompt Hal sent to the model. Tap a section to expand it. The colors match the legend below the breakdown.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
}

private struct PromptDetailSegmentCard: View {
    let segment: PromptDetailSegment
    // Each card owns its own expansion state. We can't use a parent-
    // tracked Set<UUID> because PromptDetailSegment IDs are freshly
    // minted UUIDs on each body recompute (the parent's `segments`
    // is a computed property). Local @State survives card-level
    // redraws as long as the card's identity in the ForEach is stable
    // — which it is, because the ForEach keys by segment.id and the
    // segment list order/contents don't change for a given message.
    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(segment.content)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(segment.kind.color.opacity(0.08))
                .cornerRadius(6)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: segment.kind.icon)
                    .foregroundColor(segment.kind.color)
                    .imageScale(.medium)
                Text(segment.kind.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(segment.kind.color)
                Spacer()
                Text("\(segment.content.count) chars")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(segment.kind.color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(segment.kind.color.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct TokenBudgetSummary: View {
    let breakdown: TokenBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.indigo)
                Text("Token Budget")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 4) {
                tokenRow(label: "System Prompt", value: breakdown.systemTokens, color: .purple)
                tokenRow(label: "Conversation Summary", value: breakdown.summaryTokens, color: .yellow)
                tokenRow(label: "Memory Snippets (RAG)", value: breakdown.ragTokens, color: .green)
                tokenRow(label: "Short-Term History", value: breakdown.shortTermTokens, color: .blue)
                tokenRow(label: "User Input", value: breakdown.userInputTokens, color: .gray)
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Prompt (in)").font(.footnote).fontWeight(.semibold)
                Spacer()
                Text(formatTokens(breakdown.totalPromptTokens)).font(.footnote).fontWeight(.semibold).monospacedDigit()
            }
            HStack {
                Text("Completion (out)").font(.footnote).fontWeight(.semibold)
                Spacer()
                Text(formatTokens(breakdown.completionTokens)).font(.footnote).fontWeight(.semibold).monospacedDigit()
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Total").font(.footnote).fontWeight(.bold)
                Spacer()
                Text("\(formatTokens(breakdown.totalTokens)) / \(formatTokens(breakdown.contextWindowSize))")
                    .font(.footnote).fontWeight(.bold).monospacedDigit()
            }
            HStack {
                Text("Window Usage").font(.footnote).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", breakdown.percentageUsed))
                    .font(.footnote).foregroundColor(.secondary).monospacedDigit()
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.05))
        .cornerRadius(8)
    }

    private func tokenRow(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
            Spacer()
            Text(formatTokens(value)).font(.caption).monospacedDigit().foregroundColor(.secondary)
        }
    }

    private func formatTokens(_ count: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Text export

/// Text-only export of a prompt, structured the same way as the
/// in-app view — each segment gets a tagged header (📜 SYSTEM PROMPT,
/// 🧠 SELF-KNOWLEDGE, etc.) followed by the verbatim body. The
/// emoji + label combination color-codes the export visually even
/// when pasted into plain-text destinations like email or notes.
nonisolated func buildPromptDetailExportText(
    message: ChatMessage,
    precedingUserContent: String?,
    recentHistory: [ChatMessage]
) -> String {
    var lines: [String] = []
    lines.append("# Hal — Prompt Details")
    lines.append("Turn \(message.turnNumber) — \(message.recordedByModel)")
    lines.append("")

    if let prompt = message.fullPromptUsed, !prompt.isEmpty {
        for segment in parsePromptSegments(fullPrompt: prompt) {
            lines.append("━━ \(segment.kind.exportTag) ━━")
            lines.append(segment.content)
            lines.append("")
        }
    }
    if !recentHistory.isEmpty {
        lines.append("━━ \(PromptDetailSegmentKind.conversationHistory.exportTag) ━━")
        for m in recentHistory {
            let speaker = m.isFromUser ? "User" : "Hal"
            lines.append("[\(speaker)] \(m.content)")
            lines.append("")
        }
    }
    if let userMsg = precedingUserContent, !userMsg.isEmpty {
        lines.append("━━ \(PromptDetailSegmentKind.userMessage.exportTag) ━━")
        lines.append(userMsg)
        lines.append("")
    }
    if let breakdown = message.tokenBreakdown {
        lines.append("━━ 📊 TOKEN BUDGET ━━")
        lines.append("System Prompt:      \(breakdown.systemTokens)")
        lines.append("Conv. Summary:      \(breakdown.summaryTokens)")
        lines.append("Memory (RAG):       \(breakdown.ragTokens)")
        lines.append("Short-Term History: \(breakdown.shortTermTokens)")
        lines.append("User Input:         \(breakdown.userInputTokens)")
        lines.append("Prompt (in):        \(breakdown.totalPromptTokens)")
        lines.append("Completion (out):   \(breakdown.completionTokens)")
        lines.append("Total:              \(breakdown.totalTokens) / \(breakdown.contextWindowSize)")
        lines.append(String(format: "Window Usage:       %.1f%%", breakdown.percentageUsed))
    }
    return lines.joined(separator: "\n")
}
