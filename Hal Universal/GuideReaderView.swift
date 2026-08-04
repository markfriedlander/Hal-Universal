import SwiftUI
import Combine

// ==== LEGO START: 66 GuideReaderView (In-App Guide Reader) ====
//
// The in-app reader for HAL_GUIDE.md — the same public guide that is bundled with
// the app and ingested into Hal's self-knowledge. Reached as the LAST item on the
// Help (life-ring) menu, and by the antenna via SET_UI_STATE:guidereader.
//
// Rendering reuses MarkdownView (headings, prose, lists, code, tables, rules), so
// there is no second renderer to keep in step. Search is keyword find-in-page, the
// literal half of Posey's document-search design (its SearchBarView is the model for
// GuideSearchBar here): the guide is a small, tightly structured reference whose
// terms — command/feature/signal names — appear verbatim, so a literal find lands
// almost every query. The semantic "search by meaning" fallback Posey adds for large
// prose documents is intentionally out of scope here (the guide is 80-odd chunks); if
// the keyword reader ever proves too blunt, the fallback slots in without rework.

/// Keyword find-in-page bar pinned to the top of the reader. Pure bindings and
/// callbacks, no search logic (that lives in GuideReaderView), mirroring Posey's
/// SearchBarView. Dismissal of the whole reader is the navigation bar's Done, so this
/// bar carries only the query, the match readout, and next/prev.
private struct GuideSearchBar: View {
    @Binding var query: String
    let matchCount: Int
    /// 0-based position within the matches, nil when there is no query / no match.
    let currentMatchPosition: Int?
    let onPrevious: () -> Void
    let onNext: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var matchLabel: String {
        guard hasQuery else { return "" }
        if matchCount == 0 { return "No matches" }
        let ordinal = (currentMatchPosition ?? 0) + 1
        return "\(ordinal) of \(matchCount)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Find in the guide", text: $query)
                .focused($isFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { isFieldFocused = false }

            if hasQuery {
                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()

                if matchCount > 0 {
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Previous match")

                    Button(action: onNext) {
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Next match")
                }

                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

struct GuideReaderView: View {
    @Environment(\.dismiss) private var dismiss
    // Query lives on the VM so the antenna (SET_GUIDE_QUERY) can drive find-in-page
    // for headless verification, not just a human typing. Reset on close.
    @EnvironmentObject private var chatViewModel: ChatViewModel
    /// 0-based index INTO `matchIndices` (which chunk of the matching set we are on).
    @State private var currentMatch: Int? = nil

    // The guide split once into heading-delimited chunks. Each chunk is a scroll
    // target (its index is its `.id`) and the unit of a keyword match, the same
    // container-level model Posey uses (it matches whole segments, not occurrences).
    private let chunks: [String]
    /// GitHub-style anchor slug -> chunk index, so an internal cross-reference like
    /// "[Safe and Advanced](#safe-and-advanced)" scrolls to that section on tap.
    private let anchorToChunk: [String: Int]

    init() {
        let loaded = Self.loadChunks()
        chunks = loaded
        anchorToChunk = Self.buildAnchorMap(loaded)
    }

    private var trimmedQuery: String { chatViewModel.guideReaderQuery.trimmingCharacters(in: .whitespaces) }

    /// Indices of the chunks that contain the query (case-insensitive). Cheap to
    /// recompute for ~80 chunks; kept as a computed value so it always tracks `query`.
    private var matchIndices: [Int] {
        guard !trimmedQuery.isEmpty else { return [] }
        return chunks.indices.filter { chunks[$0].localizedCaseInsensitiveContains(trimmedQuery) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chunks.indices, id: \.self) { i in
                            MarkdownView(text: chunks[i], bodyPointSize: 17, lineSpacing: 5, highlight: trimmedQuery)
                                .id(i)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    GuideSearchBar(
                        query: $chatViewModel.guideReaderQuery,
                        matchCount: matchIndices.count,
                        currentMatchPosition: currentMatch,
                        onPrevious: { step(-1, proxy: proxy) },
                        onNext: { step(1, proxy: proxy) }
                    )
                }
                .onChange(of: chatViewModel.guideReaderQuery) { _, _ in
                    let matches = matchIndices
                    if let first = matches.first {
                        currentMatch = 0
                        scroll(to: first, proxy: proxy)
                    } else {
                        currentMatch = nil
                    }
                }
                .onDisappear {
                    chatViewModel.guideReaderQuery = ""
                    currentMatch = nil
                }
                // Intercept taps on markdown links. An internal cross-reference
                // ("#section") scrolls to that chunk; external URLs (http/https/mailto)
                // open normally; anything else relative is swallowed so a stray link
                // can't open garbage.
                .environment(\.openURL, OpenURLAction { url in
                    let raw = url.fragment ?? (url.absoluteString.hasPrefix("#") ? String(url.absoluteString.dropFirst()) : "")
                    let anchor = raw.lowercased()
                    if !anchor.isEmpty, let idx = anchorToChunk[anchor] {
                        scroll(to: idx, proxy: proxy)
                        return .handled
                    }
                    return url.scheme == nil ? .handled : .systemAction
                })
            }
            .navigationTitle("The Hal Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Advance the current match by `direction` (+1 next, -1 previous), wrapping, and
    /// scroll its chunk into view. No-op when there are no matches.
    private func step(_ direction: Int, proxy: ScrollViewProxy) {
        let matches = matchIndices
        guard !matches.isEmpty else { return }
        let base = currentMatch ?? (direction > 0 ? -1 : 0)
        let next = ((base + direction) % matches.count + matches.count) % matches.count
        currentMatch = next
        scroll(to: matches[next], proxy: proxy)
    }

    private func scroll(to chunkIndex: Int, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(chunkIndex, anchor: .top)
        }
    }

    /// GitHub-style heading slug: lowercased, non-alphanumerics dropped, runs of
    /// spaces/hyphens collapsed to a single hyphen, trimmed. "Safe and Advanced"
    /// becomes "safe-and-advanced", matching the anchors written in the guide.
    private static func slug(_ heading: String) -> String {
        var out = ""
        for ch in heading.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Map each chunk's first heading's anchor -> its index. First writer wins, so a
    /// repeated heading resolves to its first occurrence (as a browser would).
    private static func buildAnchorMap(_ chunks: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, chunk) in chunks.enumerated() {
            guard let headingLine = chunk.split(separator: "\n").first(where: { $0.hasPrefix("#") }) else { continue }
            var text = String(headingLine)
            while text.first == "#" { text.removeFirst() }
            let anchor = slug(text.trimmingCharacters(in: .whitespaces))
            if !anchor.isEmpty, map[anchor] == nil { map[anchor] = i }
        }
        return map
    }

    /// Load the bundled guide and split it into heading-delimited chunks: every line
    /// that is a heading of level >= 2 ("## " ... "###### ") starts a new chunk, and
    /// the title + intro before the first such heading is the opening chunk. Blank /
    /// whitespace-only chunks are dropped. Fenced code is respected so a "###" inside
    /// a code block never splits a chunk.
    private static func loadChunks() -> [String] {
        guard let path = Bundle.main.path(forResource: "HAL_GUIDE", ofType: "md"),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ["# The Hal Guide\n\nThe guide could not be loaded on this build."]
        }
        func isHeading(_ line: String) -> Bool {
            var h = 0
            for c in line { if c == "#" { h += 1 } else { break } }
            return h >= 2 && line.dropFirst(h).first == " "
        }
        var chunks: [String] = []
        var current: [String] = []
        var inFence = false
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, isHeading(line), !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// ==== LEGO END: 66 GuideReaderView (In-App Guide Reader) ====
