# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-17 evening entry).

---

## What the next session should do first

1. **Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-17
   post-compaction entry of `HISTORY.md`.** Item 4 (PromptDetailView),
   Item 5 (BGDL long-lock test — passed §7), and two Item-5 follow-ups
   (progress-bar-on-recovery bug + model card UI consistency) all
   landed this session.
2. **Verify the live state:**
   ```bash
   python3 tests/hal_test.py state                       # responds
   python3 tests/hal_test.py cmd "SALON_GET_STATE"       # seat1 filled
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"      # backend loaded
   ```
3. **Pick up where this session paused: Item 6 (below).**

---

## Open work — in order

### Item 6 (resume here) — UI consistency sweep

Mark caught a real one in the Model Library: LLM rows and embedding
rows had different action-row styles (plain icon+text vs bordered-
prominent pills) and different spacing. The Model Library was fixed
this session by making the embedding side match the LLM plain style
— see `EmbedderBackendRow.actionRow` in
`Hal Universal/EmbedderMigrationCoordinator.swift`.

The broader work is a sweep of the rest of the app for similar
mismatches. Concrete places to check:

  - **Settings sheet**: action buttons (Export Thread, Upload
    Document, etc.) vs. inline toggles vs. nav links — are they
    visually consistent?
  - **Salon panel**: seat picker buttons, model selection chrome.
    Different style from Model Library?
  - **Reflections viewer** (if one exists in Settings → Power User):
    list row treatment.
  - **System prompt editor** sheet: button placement, save/cancel
    affordance.
  - **Document import flow**: progress indicators, success/error
    states.
  - **Compression-explanation popover** (the badge in the chat
    bubble footer): visual weight relative to other in-chat
    affordances.
  - **NUCLEAR_RESET confirmation**: matches other destructive
    confirmations?

Approach: take screenshots of each surface, list mismatches, propose
unified targets (probably matching the plain-icon-+-text-+-color
style the Model Library now uses), get Mark's sign-off per surface,
implement surgically.

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
