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

### Item 11 — Gemma jetsam crash investigation

During the Phase 2 live test (2026-05-18), switching to Gemma 4 E2B with the prior salon's heavy context jetsam-killed Hal during model load. Workaround was switching to Qwen 3.5 2B, but that's not acceptable for real users.

Investigation plan:
  - Reproduce on device (load Gemma after a heavy chat context).
  - Measure memory pressure at swap points (Xcode → Debug Navigator → Memory, or log via `os_proc_available_memory()`).
  - Check whether `MLXWrapper.unloadModel` fires before the new model loads. Commit `750f487` added a background-lifecycle unloader; verify the model-swap path runs the equivalent.
  - Consider: eager release of inactive chat history before swap? Per-model context budgeting aware of pending swap?
  - If structural fix isn't tractable: surface a "won't fit" error to the user rather than letting iOS kill the process.

Real user issue. Needs to land before ship.

### Memory Depth display mismatch

The Memory Depth setting display doesn't match the actual stored value (observed by Mark). Reproduce, identify whether it's a read-side (display) or write-side (storage) discrepancy, fix.

### Apple Intelligence appearing twice in Salon picker

In the Salon seat-assignment picker, "Apple Intelligence" shows up as two separate options. Probably a duplicate-source bug in the picker's data assembly — `[ModelConfiguration.appleFoundation] + downloadedModels` accidentally including AFM in `downloadedModels` too. Audit the salon picker construction.

### Salon toggle scroll/flash behavior

When toggling Salon mode on/off, the chat surface scrolls or flashes in a distracting way. Trace whether `ChatViewModel.salonConfig.isEnabled` change triggers an unintended layout pass or scroll event.

### Salon mode should show model names not just "4 voices"

Current display: "Salon Mode: 4 voices". Should show the actual model names (Gemma, Llama, Qwen, Dolphin) so the user knows which models are in the active configuration without opening Settings.

### Dolphin display name in pickers

The Dolphin display name in model pickers is awkward (likely too long, or shows the underlying llama base in a confusing way). Cleanup pass on `ModelConfiguration.displayName` for `mlx-community/dolphin3.0-llama3.2-3B-4Bit`.

### Prompt detail viewer segment labels

In `PromptDetailView`, several segments render with the generic "Context" label (seen in Phase 4 screenshots — multiple "Context" entries). Should be more descriptive (e.g. "Self-Knowledge", "Memory Snippets", "Summary"). Audit the segment-kind classification in `PromptDetailView.swift`'s parser and add explicit cases where they currently fall to the generic bucket.

### Settings audit after RAG and embedding changes

Walk through every Settings panel control and verify it still works correctly given the RAG/embedding architectural changes since v1.6:
  - Temperature
  - Memory depth
  - RAG dedup threshold
  - RAG snippet character budget
  - Recency weight / half-life
  - Self-knowledge toggle
  - Embedding backend selection
  - System prompt editor
Each should reflect actual current state on read and persist correctly on write.

### selfKnowledge log labels — budget vs actual used

The `HALDEBUG-BUDGET` log line includes `selfKnowledge=44493` which is the *allocation ceiling*, not actual usage. This caused confusion during the salon (interpreted as "44K of self-knowledge being injected"). Fix: clarify the log labels — `selfKnowledgeBudget=X` for the ceiling, plus an `selfKnowledgeUsed=Y` line after `resolveSegment` for what actually got injected. Lives in `buildChatMessages` around the HALDEBUG-BUDGET log.

### Prompt detail viewer wiring — confirm whether done or not

Item 4 from 2026-05-17 was the PromptDetailView wiring. Committed at `97c8a7a` with `View Prompt Details` added to ChatBubbleView's assistant-side contextMenu. Visual verification on sim confirmed it opens, the legend renders, segments expand. Confirm one more time on phone with real conversation content that everything works end-to-end and the segments classify correctly.

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
