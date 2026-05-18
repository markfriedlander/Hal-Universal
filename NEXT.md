# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-17 evening entry).

---

## What the next session should do first

1. **Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-17
   evening entry of `HISTORY.md`.** That's the state of the 5-item
   sequence Mark queued, where each item landed, and what's still open.
2. **Verify the live state:**
   ```bash
   python3 tests/hal_test.py state                       # responds
   python3 tests/hal_test.py cmd "SALON_GET_STATE"       # seat1 filled
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"      # backend loaded
   ```
3. **Pick up where the previous session paused: Item 4 wiring (below).**

---

## Open work — in order

### Item 4 (resume here) — Wire the new PromptDetailView into the UI

`Hal Universal/PromptDetailView.swift` is built and compiles clean
(commit `61f8240`). It has color-coded segments, collapsible
DisclosureGroups, a token budget card, and a "Copy as Text" export.
But it's **not yet reachable** from the UI. Users can't open it yet.

Wiring checklist:

  1. In `ChatBubbleView` (Hal.swift around line 11689 — the
     assistant-side branch of the `else` block), add an
     `@State private var showingPromptDetail = false` at the top of
     the struct.
  2. Add a button to the assistant-side contextMenu (around
     Hal.swift:11742, right next to the existing "View Details"
     toggle):
     ```swift
     Button {
         showingPromptDetail = true
     } label: {
         Label("View Prompt Details", systemImage: "doc.text.magnifyingglass")
     }
     ```
  3. Add a `.sheet(isPresented: $showingPromptDetail)` modifier on
     the bubble that presents `PromptDetailView`. It takes three
     arguments:
     ```swift
     PromptDetailView(
         message: message,
         precedingUserContent: precedingUserContent,
         recentHistory: recentHistory
     )
     ```
  4. Compute `precedingUserContent` and `recentHistory`:
     ```swift
     private var precedingUserContent: String? {
         // The user message whose turn number is the same as this
         // assistant message (turns are paired). Walk backwards in
         // chatViewModel.messages from this message's index.
         guard let idx = chatViewModel.messages.firstIndex(where: { $0.id == message.id }) else { return nil }
         for i in stride(from: idx - 1, through: 0, by: -1) {
             let m = chatViewModel.messages[i]
             if m.isFromUser && m.turnNumber == message.turnNumber { return m.content }
         }
         return nil
     }
     private var recentHistory: [ChatMessage] {
         // The N prior turn pairs before this one, capped at ~4 turns
         // to keep the detail-view scrollable.
         guard let idx = chatViewModel.messages.firstIndex(where: { $0.id == message.id }) else { return [] }
         let start = max(0, idx - 8)  // ~4 turn pairs
         return Array(chatViewModel.messages[start..<idx])
     }
     ```
  5. Once exercised end-to-end, delete `_LegacyPromptDetailView_Unused`
     from Hal.swift (the renamed dead view in LEGO 14).

Visual verification after wiring: open chat with a few turns, long-
press a Hal bubble → "View Prompt Details" → confirm segments render
with colors, collapsible behavior works, token budget card matches
the breakdown numbers.

### Item 5 — Background download long-lock test (coordinate with Mark)

Delete a model, trigger a fresh download, then Mark locks the phone
face down for 10 minutes. Verify the filesystem state before and
after. The new commands available for this:
  - `DOWNLOAD_EMBEDDING_MODEL:nomicswift` is a clean 522 MB candidate
  - `EMBEDDING_DOWNLOAD_STATUS:nomicswift` polls progress
  - `MLXModelDownloader.shared.startDownload(...)` for any LLM via API

Mark coordinates the lock-and-wait; CC monitors filesystem and logs.

---

## Workstreams from earlier sessions still ready to pick up

### A. Default-on Nomic for new installs (product decision, pending Mark)

Question raised after the gate landed: should Nomic be the default
embedder for new installs, or stay opt-in via Model Library? Per
Mark's earlier directive ("default stays as NLContextual. Nomic
remains opt-in via the Model Library. The 522 MB makes it unreasonable
as a forced default for new users") this is settled — Nomic stays
opt-in. Mark may revisit later.

### B. Re-enable EmbeddingGemma when MLX-swift ships a fix

Track [mlx-swift issues](https://github.com/ml-explore/mlx-swift/issues)
for the iOS Metal device init nullptr crash. When fixed: bump mlx-swift,
flip `HAL_ENABLE_EMBEDDING_GEMMA` into Release config, verify on device.

### C. Cluster C from May 16 (orthogonal to RAG)

- Structured-trait synthesis (implement with inspectability for the
  Evolutionary Salon)
- Scroll behavior refinement based on real-world usage of the new
  send-start-only rule

### D. On deck

- Screenshots × 6 for App Store
- ASC metadata fills using `Docs/ASC_v2.0_Paste_Ready.md`
- `Docs/` consolidation (many per-session recovery/finding docs)
