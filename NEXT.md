# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-17 morning entry).

---

## What the next session should do first

1. **Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-17 morning
   entry of `HISTORY.md`.** That's the full context for the embedder
   upgrade work and what's still untested.
2. **Verify the live state on the iPhone is what the docs claim:**
   ```bash
   python3 tests/hal_test.py state                          # should respond
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"         # backend=nlcontextual, isLoaded:true
   python3 tests/hal_test.py cmd "EMBEDDING_DOWNLOAD_STATUS"  # isDownloaded:false initially
   ```
3. **Verify Proposal A on actual device** (sim is documented as not
   supported for MLXEmbedders/Gemma load). The sim doesn't get past the
   libc++ Hardening string-nullptr crash in the load path; the device
   may. We need real measurement.

---

## On-device test plan for EmbeddingGemma (Proposal A)

The full upgrade flow is wired through the Model Library UI. Test order:

1. **Boot Hal on the phone fresh, confirm baseline.**
   ```bash
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"
   # Expect: backend=nlcontextual, isLoaded=true, dim=512
   ```

2. **Open Model Library, scroll to the new "Embedding (Memory)" section.**
   - Apple NLContextual row should show "Active".
   - EmbeddingGemma 300M row should offer "Download EmbeddingGemma".
3. **Tap Download. Wait for the progress bar to complete (~210 MB).**
   The download uses the same BGDL coordinator the LLM downloads use, so
   it survives backgrounding. Verify on-device files end up at
   `.cachesDirectory/huggingface/models/mlx-community/embeddinggemma-300m-4bit/`.
4. **Inject the eval corpus, baseline the full pipeline against the new
   backend NOT loaded yet:**
   ```bash
   python3 tests/hal_test.py reset
   python3 tests/hal_test.py cmd "INJECT_REALISTIC_TEST_CORPUS"
   python3 tests/rag_pipeline_eval.py
   # Expect: same 7/10 top-10 baseline (NLContextual still active)
   ```
5. **In the Model Library, tap "Switch to EmbeddingGemma" on the
   downloaded backend row. Confirm the migration dialog.**
   The flow:
   - wipes existing embeddings
   - warms up the new backend (this is where the load happens — if the
     libc++ crash reproduces on device, capture the log lines from
     `python3 tests/hal_test.py logs`)
   - re-embeds the corpus rows via Gemma (~1s/row at ~50ms per embed)
   - reports updated/skipped/failed counts inline
6. **Re-run both evals against the Gemma-embedded corpus:**
   ```bash
   python3 tests/rag_threshold_eval.py    # raw cosine
   python3 tests/rag_pipeline_eval.py     # full RRF
   ```
   Compare to the previous baseline. Key questions:
   - Do plant scores rise relative to noise scores? (NLContextual's
     0.69–0.91 band was the problem.)
   - Do the 3 misses (Berkeley/Subaru/cello) close to top-10?
   - Does top-1 recall improve?
7. **Switch back to Apple NLContextual via the Model Library** to
   verify the downgrade path also re-embeds correctly (proves the
   two-way migration story).

---

## What happens if EmbeddingGemma improves recall

Per Mark's directive: ship with NLContextual as default, expose
EmbeddingGemma as an opt-in upgrade. The Model Library UI is already
built. The remaining work is:
  - Confirm download UX on device (BGDL backgrounding, locked-phone
    survival — already field-tested for LLMs, should generalize)
  - Capture migration timing on a realistic corpus (a 500-row chat
    history at ~50ms/row is ~25s — UI may want a more detailed progress
    indicator if real-world numbers run higher)
  - Decide what happens on first launch if a user opens settings before
    NLContextual finishes loading (current UX: section renders with
    NLContextual showing Active but isLoaded would be false — likely
    fine, but worth a check)

## What happens if EmbeddingGemma does NOT improve recall on device

Proposal C is still on deck:
  - NLTagger over the recall query at query time
  - Hand-curated synonym dictionary (vehicle: car/drive/Subaru/Honda/…)
  - Expand the FTS5 query with the synonyms before BM25 ranks

Pairs naturally with the Proposal B groundwork (entity_keywords now
populated on stored rows). Independent of Proposal A — could land
alongside either or both.

---

## Cluster B remaining (visual + long-duration)

These were paused when the RAG question came up on May 16. Still relevant.

- **Salon UI Pickers**: visual verification on device or simulator.
- **System prompt counter**: visual verification.
- **Model Library UI**: visual verification of new embedder section (test
  plan above covers it).
- **App icon**: visual verification.
- **Background downloads long-lock test**: delete Gemma (3.6 GB), start
  fresh download, lock phone face-down 10+ minutes, verify BGDL coordinator
  handles iOS suspension. The same flow now covers the EmbeddingGemma
  download — both use BGDL.

## Cluster C from May 16 (orthogonal to the RAG proposals)

- Structured-trait synthesis (Mark's decision: implement, design for
  inspectability so it can surface in a future Evolutionary Salon)
- Scroll behavior (Mark's decision: requirement — search SwiftUI examples
  on the web first, find a working pattern, adapt it)

## On deck

- Screenshots × 6 for App Store
- ASC metadata fills using `Docs/ASC_v2.0_Paste_Ready.md`
- One-off `Docs/` consolidation (many per-session recovery/finding docs)
