# Hal Universal — Next

Forward-looking work, organized by category. As items are resolved, they move out of NEXT.md and the completion lands in HISTORY.md.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-18 late-afternoon entry for Phase 4).
For the v1 self-knowledge spec: `Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md`.

---

## What the next session should do first

1. **Read this file**, then `HANDOFF_BRIEF.md`, then the most recent `HISTORY.md` entry, then `CLAUDE.md` for standing rules.
2. **Verify the live state:**
   ```bash
   python3 tests/hal_test.py state                       # responds
   python3 tests/hal_test.py cmd "SALON_GET_STATE"       # seat1 filled
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"      # backend loaded
   curl ... DB_SCHEMA:self_knowledge                     # 22 columns
   curl ... SELF_KNOWLEDGE_AUDIT:30                      # corpus snapshot
   ```
3. **Pick up the next item below** — bugs first, then stress test, then App Store ship prep.

---

## Bugs to fix before ship

### Item 11 — Gemma jetsam crash investigation ✓ RESOLVED (2026-05-18 post-compaction)

Diagnosed and fixed. New `Hal Universal/ProcessMemoryGuard.swift`
exposes `os_proc_available_memory()` as `processAvailableMemoryMB()`
and `requiredMemoryMBForLoad(_:)` (0.75× disk size + 250 MB margin,
empirically calibrated from Qwen's 0.56 ratio). Three coordinated
changes:

1. MLX→MLX swap path replaced the fixed 500 ms settle with
   `waitForMemoryHeadroom(...)` — polls every ~150 ms for up to 3 s,
   logs the reclamation curve.
2. `MLXWrapper.loadModel` runs a pre-flight `availableMB >= requiredMB`
   check before the dangerous mmap call. On refusal, sets `mlxError`
   to a friendly user-facing message and returns.
3. `ChatViewModel.switchToModel` now stores the load Task and awaits
   it via `LLMService.awaitPendingMLXLoad()`. On failure: revert to
   the previous model (not AFM), post a clean explanation in chat,
   replace the misleading "Hal, are the [OLD] files missing?" prompt
   with the neutral "Hal, can you switch to [NEW]?".

Verified on iPhone 16 Plus: cold-launch Gemma (3333 available vs 2999
required) succeeds; Gemma → Qwen swap completes cleanly; first refusal
test (pre-recalibration, 3271 < 4149) showed Hal logging
"REFUSED — insufficient memory" instead of crashing. Build clean,
zero new warnings, Hal_Source.txt synced. See HISTORY 2026-05-18
post-compaction entry for the full chronicle.

Follow-up monitoring: if a future stress-test load exceeds our 0.75×
estimate and still crashes despite passing pre-flight, tighten the
multiplier or introduce a per-model override (e.g. Gemma 4 E2B's
QAT layout may have a different effective footprint).

### Memory Depth display mismatch ✓ RESOLVED (2026-05-18, commit 7f274a4)

Reproduced via:
  `SET_MEMORY_DEPTH:100` on Qwen (max 209)
  `SWITCH_MODEL:apple-foundation-models` (max 3)
  → state: memoryDepth=100, maxMemoryDepth=3 — slider shows "100 turns"
    with thumb pinned at 3.

Three coordinated fixes:
1. AFM's `defaultSettings.effectiveMemoryDepth` was off-by-one: set to 4
   while AFM's runtime max is 3 (4096 × 12% / 150 = 3.27 → 3). Now 3.
2. The API-side `switchToModel` was missing the clamping that the UI
   path already has. Added an unconditional defense-in-depth clamp at
   the apply site.
3. The Settings sheet's Memory Depth slider binding now displays
   `effectiveMemoryDepth` (clamped) so the number and thumb always
   agree; storage gets corrected to the displayed value on first
   user slider interaction.

### Apple Intelligence appearing twice in Salon picker ✓ RESOLVED (2026-05-18, commit ab1df36)

`ChatViewModel.downloadedModels` filtered `isDownloaded == true`, which
included AFM (the catalog seed marks AFM as downloaded). Then
`usableModels` prepended AFM, producing two entries. Fixed by
restricting `downloadedModels` to `$0.source == .mlx && $0.isDownloaded`.

### Salon toggle scroll/flash behavior — needs visual repro

Investigated. The salon picker uses `setSalonEnabled` which mutates
`@Published var salonConfig`, triggering ChatViewModel.objectWillChange
and re-rendering all observers. ChatBubbleView reads
`salonConfig.activeSeats.count` for the per-message footer seat text
(line ~10152), so every bubble re-evaluates body on salon toggle.
Whether that explains the "scroll/flash" depends on what Mark sees —
in code review nothing obviously shifts layout. Recommend Mark
captures a video or describes the exact visual artifact (sliding
animation? text reflow? scroll position change? brief opacity
flicker?) on next try, then we can target precisely.

Defensive option if it recurs: cache the salon seat-count value at
the chat-view body level and pass into ChatBubbleView as a value
parameter instead of having each bubble observe the VM directly —
breaks the @Published chain for non-salon changes, but doesn't help
the case where salon itself toggles.

### Salon mode should show model names not just "4 voices" ✓ RESOLVED (2026-05-18, commit ab1df36)

New `ChatViewModel.salonSeatSummary` computed property joins active
seat displayNames with " · ". Settings sheet's Salon Mode row now
shows "Qwen 3.5 2B · Gemma 4 E2B" instead of "2 voices". Truncates
to single line with tail-elision if names get long.

### Dolphin display name in pickers ✓ RESOLVED (2026-05-18, commit ab1df36)

`ModelConfiguration.dolphin3Llama32_3B4bit.displayName` was
"Dolphin 3.0 (Llama 3.2 3B)" — the only catalog entry with a
parenthetical base model. Shortened to "Dolphin 3.0"; the full
lineage stays visible in the Model Library card description.

### Prompt detail viewer segment labels ✓ RESOLVED (2026-05-18, commits 100168a + e8ce4f4)

First cut (100168a) fixed the classifier — the keyword set hadn't
matched what `buildSelfAwarenessContext` / `buildSelfKnowledgeContext` /
`buildTemporalContext` actually emit after wrapper-marker stripping
("You are Hal", "Persistent knowledge", "Current date and time:",
etc.). Updated classifier to recognize the real openers plus a
sampling of category headers.

But Mark's screenshot still showed ~13 generic "Context" rows. Root
cause was deeper: the parser was splitting the context body on
"\n\n" and classifying each fragment independently. The bodies
themselves contain "\n\n" between their internal paragraphs
(Self-Awareness has 4 paragraphs, Self-Knowledge has 6-8 category
sections). Even with correct classification, each fragment became
its own viewer row.

Second cut (`e8ce4f4`) rewrote `parsePromptSegments` to walk
paragraphs in order and merge adjacent paragraphs of the same kind
plus unclassified continuations into one logical section. Result:
~6 sections instead of ~13 (System Prompt, Temporal, Summary,
Self-Awareness, Self-Knowledge, RAG, ± Watch Delivery / User
Message).

Verified locally with a representative prompt structure: 11
paragraphs collapse to 6 logical sections, each preserving its
internal "\n\n" paragraph breaks inside the collapsible card.

Also (in 100168a) cleaned up the seven pre-existing MainActor
warnings that HANDOFF_BRIEF noted as a follow-up — `exportTag` and
the four `TokenBreakdown` derived properties are now `nonisolated`.
Golden Rule #7 back in green.

### Settings audit after RAG and embedding changes ✓ RESOLVED (2026-05-18 — verified via API, no commit needed)

Walked through every Settings control via API:
  - `SET_TEMPERATURE:0.9` → state shows temperature=0.9 ✓
  - `SET_MEMORY_DEPTH:6` → state shows memoryDepth=6 ✓
  - `SET_RAG_DEDUP:0.92` → state shows ragDedupThreshold=0.92 ✓
  - `SET_MAX_RAG_CHARS:1800` → state shows maxRagSnippetsCharacters=1800 ✓
  - `SET_RECENCY_WEIGHT:0.45` → state shows recencyWeight=0.45 ✓
  - `SET_RECENCY_HALFLIFE:120` → state shows recencyHalfLifeDays=120 ✓
  - `SET_SELF_KNOWLEDGE:false` then `:true` → state toggles cleanly ✓
  - `EMBEDDING_STATUS` returns active backend ✓
  - System prompt set/get works via `SET_SYSTEM_PROMPT` ✓

All controls reflect actual state on read and persist correctly on
write. No regressions from the RAG/embedding architectural changes.

### selfKnowledge log labels — budget vs actual used ✓ RESOLVED (2026-05-18, commit ab1df36)

`HALDEBUG-BUDGET` line now uses `selfKnowledgeBudget=` (the
allocation ceiling) instead of the ambiguous `selfKnowledge=`, and
a new `HALDEBUG-SELF-KNOWLEDGE` line fires immediately after
`resolveSegment` reporting `selfKnowledgeUsed=N tokens (M chars) of
selfKnowledgeBudget=K`. Verified on Qwen turn: budget=91392,
used=277 (1109 chars) — confirms the corpus is lean. Also relabeled
`summary=`/`RAG=` → `summaryBudget=`/`RAGBudget=` in the same line
for consistency.

### Prompt detail viewer wiring — Mark to confirm on phone

Code-side is healthy: contextMenu hook in ChatBubbleView calls
PromptDetailView with the fixed-id segments + collapsible cards
(commit `97c8a7a`), and segment classification now covers
Self-Awareness / Self-Knowledge / Temporal correctly (commit
`100168a`). Awaiting Mark's visual confirmation on real-device
conversation content that the segments classify and color-code as
expected.

---

## Stress test — full unscripted walkthrough

Real-use end-to-end test, NOT scripted API batches. Coverage:

  - **Long conversations across multiple models** — AFM ↔ MLX switches, multiple MLX-to-MLX swaps (this also covers Item 11 verification once that's fixed).
  - **Salon mode** with the four-seat setup (Gemma, Llama, Qwen, Dolphin).
  - **Settings changes** (temperature, memory depth, RAG threshold, embedding backend) during a live conversation.
  - **Document import** + a follow-up conversation that uses the imported content via RAG.
  - **Export thread** — verify the format reads cleanly.
  - **Self Model viewer** — once there's organic content, exercise the privacy toggle with real private/public reflections.
  - **`[SHAREABLE: yes|no]` marker round-trip** — sustained MLX conversation should generate reflections that include the marker; verify the parser handles all four MLX models' output correctly.
  - **General feature tour** — see if anything obvious is broken.

Goal: signal on how everything holds together with all the recent changes in place. Bugs found during the stress test get filed and prioritized vs ship-blockers.

---

## App Store ship items

These are mechanical / process work, not architectural.

### Screenshots — 6 iPhone screenshots

Required: 6.7" display screenshots (iPhone 16 Plus or 17 Pro). Subjects per the existing draft:
  - Main chat with AFM
  - Main chat with an MLX model
  - Self Model viewer
  - Model Library
  - Settings (Power User)
  - Salon mode (or PromptDetailView)

`Docs/SC_Release_Materials/` may already have placeholders. Verify what's there.

### ASC metadata

Description, keywords, what's-new, support URL, privacy URL, category, age rating. Draft is in `Docs/ASC_v2.0_Paste_Ready.md`. Apply mechanically once the v2.0 draft exists in App Store Connect. CC can do this via Chrome MCP if needed.

### README, privacy.html, support.html

`README.md` got a v1.6 rewrite (commit `9db3a32` from May 15) and was later locked in for v2.0. Verify it's current with the Phase 1-4 v1-crystallization work. `privacy.html` and `support.html` need to live on a public URL (likely GitHub Pages) that the ASC submission references.

### GitHub Pages verified

The `privacy.html` and `support.html` URLs in the ASC submission must resolve publicly. Confirm GitHub Pages is enabled on the repo, the files are at the expected paths, and the URLs return 200.

### Version bump, fresh archive, upload, submit

Mechanical sequence:
  1. Bump `CFBundleShortVersionString` to 2.0 and `CFBundleVersion` to 5 (or next) in `project.pbxproj`.
  2. Build clean for Release configuration.
  3. Archive in Xcode.
  4. Upload to ASC.
  5. Apply metadata to the v2.0 draft.
  6. Submit for review.

Do NOT do this until: Item 11 is resolved AND stress test passes AND screenshots are captured AND ASC metadata is staged.

---

## Side work (earlier-session items, not blocking)

### Item 6 — UI consistency sweep

Mark caught the Model Library mismatch (LLM rows vs embedding rows — fixed in `Item 5 follow-up B`, commit `1849f72`). Broader sweep of the rest of the app for similar mismatches:

  - Settings sheet action buttons vs toggles vs nav links
  - Salon panel chrome
  - Reflections viewer list row treatment
  - System prompt editor button placement
  - Document import progress indicators
  - Compression-explanation popover visual weight
  - NUCLEAR_RESET confirmation styling

Approach: screenshot each surface, list mismatches, propose unified targets matching the plain-icon-+-text-+-color style now in Model Library, get sign-off per surface, implement surgically.

### Item 9 — Serial download queue indicator

When multiple downloads are tapped in succession, no UI indicator that the additional taps registered. Looks broken. Add a queue-position indicator or "queued" pill on rows where `isDownloading` is false but the model is in the queue.

### Item 10 — Self-knowledge corpus visibility discrepancy ✓ RESOLVED

Audited via the new `SELF_KNOWLEDGE_AUDIT` command. The "44K vs empty UI" mystery was not a bug — `selfKnowledge=44493` in the budget log is the allocation ceiling, not actual content; the UI was correctly filtering on `shareable=1`. Follow-up "selfKnowledge log labels" is in the bug list above and addresses the source of the confusion.

### A. Default-on Nomic for new installs ✓ SETTLED

Mark's directive: "default stays as NLContextual. Nomic remains opt-in via the Model Library. The 522 MB makes it unreasonable as a forced default for new users." May revisit later.

### B. Re-enable EmbeddingGemma when MLX-swift ships fix

Track [mlx-swift issues](https://github.com/ml-explore/mlx-swift/issues) for the iOS Metal device init nullptr crash. When fixed: bump mlx-swift, flip `HAL_ENABLE_EMBEDDING_GEMMA` into Release config, verify on device.

### C. Cluster C from May 16 — partially done

  - ~~Structured-trait synthesis~~ ✓ DONE via v1 crystallization (Phases 1-4).
  - **Scroll behavior refinement** based on real-world usage of the new send-start-only rule — still open as feedback accumulates.

### D. Docs/ consolidation

Many per-session recovery / finding docs accumulated under `Docs/`. Worth a pass to consolidate or move historical recovery docs into an archive subfolder, leaving the current architectural docs (build spec, salon archive, ASC paste-ready) at the top level.

---

## Notes on shape of the remaining work

- **Most of the bug list is small or medium surgical work** — none are architectural rewrites. A focused session could close 3-5 of them.
- **Item 11 is the only one with real diagnostic uncertainty.** The rest are "find the code, fix it, verify." Item 11 might be a one-line fix (model unload not firing on swap) or a deeper memory-management change.
- **The stress test is the gating event** between bug-fix work and App Store prep. Bugs found in the stress test get added to the list and prioritized.
- **App Store ship items are mechanical** once the bugs are clean and screenshots are captured.
