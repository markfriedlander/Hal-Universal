# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-17 evening entry).

---

## What the next session should do first

1. **Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-17
   post-compaction entry of `HISTORY.md`.** That's the chronicle of
   how Item 4 wiring landed (including the collapse-bug fix) and
   what's queued.
2. **Verify the live state:**
   ```bash
   python3 tests/hal_test.py state                       # responds
   python3 tests/hal_test.py cmd "SALON_GET_STATE"       # seat1 filled
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"      # backend loaded
   ```
3. **Pick up where this session paused: Item 5 (below).**

---

## Open work — in order

### Item 5 (resume here) — Background download long-lock test (coordinate with Mark)

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
