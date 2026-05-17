# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-17 entry).

---

## What the next session should do first

1. **Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-17 entry of `HISTORY.md`.**
   That's the full context for the RAG work and the three proposals below.
2. **Verify the live state on the iPhone is what the docs claim:**
   ```bash
   python3 tests/hal_test.py state                         # should respond
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"        # isLoaded: true, dim: 512
   python3 tests/hal_test.py cmd "SALON_GET_STATE"         # should be disabled
   ```
   If anything fails, the phone may be asleep/off WiFi — Mark should wake it.
3. **Run the eval to establish baseline before any new work:**
   ```bash
   python3 tests/hal_test.py reset
   python3 tests/hal_test.py cmd "INJECT_REALISTIC_TEST_CORPUS"
   python3 tests/rag_threshold_eval.py
   ```
   Expected: plant scores mean ~0.83, top-noise mean ~0.88, plants reachable
   via semantic but rank-buried under question-shape rows.
4. **Start with Proposal B** (cheapest, sharpens our measurement before any
   architectural change).

---

## RAG work — three proposals in order

These came out of the 2026-05-17 investigation. SC and Mark received the
proposals; no implementation decision was made before context ran low.
Recommended order is **B → A → C** — establishes a fair baseline first,
then tries the bigger embedding, then layers entity-aware expansion if
still needed.

### Proposal B — Fix eval methodology (do this first)

**Why first.** Our current eval corpus has empty `entity_keywords` for all
70 rows because `INJECT_REALISTIC_TEST_CORPUS` calls
`storeUnifiedContentWithEntities` with `entityKeywords: ""`. Real chat data
goes through `storeTurn` → `extractNamedEntities` (Hal.swift:1597) and
DOES populate entity_keywords. So today's eval understates BM25's real-
world contribution. Without a fair baseline we can't tell whether
Proposal A or C actually helps.

**What to do.** Modify `injectRealisticTestCorpus` (in MemoryStore around
the new diagnostic section) so that each row's `entityKeywords` is
populated via `extractNamedEntities(from: text)` (mirroring the real
chat-store flow at Hal.swift:1597). Then re-run
`tests/rag_threshold_eval.py` and the full-pipeline check via
`MEMORY_SEARCH_DEBUG` on the 10 ground-truth queries.

**What this should reveal.** Likely that BM25-via-entity_keywords lifts
recall on queries that share entity-shape but not surface words. May or
may not bridge the 3 specific misses (Berkeley / Subaru / cello) — those
queries contain none of the entities NLTagger would extract from the
plants. Measurement will tell.

### Proposal A — Try EmbeddingGemma as alternative embedding backend

**Context.** NLContextualEmbedding compresses cosine scores into a narrow
band (0.69–0.91 across all short-text pairs) which limits discrimination.
EmbeddingGemma is 308M parameters (vs ~50M for NLContextualEmbedding),
trained explicitly for retrieval/semantic similarity, state-of-the-art on
MTEB Multilingual v2 for open models under 500M. Should produce wider
dynamic range. Already shipping in our deps via
`mlx-swift-lm 3.31.3 → MLXEmbedders`.

**What to do.**
1. Register a curated EmbeddingGemma model in the catalog (e.g.,
   `mlx-community/embeddinggemma-300m-4bit` if available, else research
   the right HuggingFace ID). May need a separate "embedding model"
   category vs the LLM model catalog.
2. Add a runtime selector — could be `@AppStorage("embeddingBackend")` with
   values `"nlcontextual"` / `"embeddinggemma"`, or just compile-time
   choice for the A/B run.
3. Modify `EmbeddingProvider.embed(_:)` to dispatch to the chosen backend.
   EmbeddingGemma path loads via `MLXEmbedders` and returns its vector
   (likely 768-dim default, or smaller via Matryoshka).
4. Wipe + re-embed all stored rows when backend changes (the existing
   `wipeStaleEmbeddingsIfNeeded` pattern, version bumped). Or use a
   separate UserDefaults flag per backend.
5. Re-run `tests/rag_threshold_eval.py` with each backend. Compare:
   plant scores, top-noise scores, plant ranks. If EmbeddingGemma
   meaningfully separates signal from noise, make it the default.

**Open question for Mark.** EmbeddingGemma adds ~200MB to model storage.
Worth the trade for better RAG quality? Probably yes — Hal already ships
multi-GB MLX models — but flag for explicit approval before adding it
to the curated catalog.

### Proposal C — Entity-aware query expansion (if A doesn't close the gap)

**Why this is here.** Bridges the specific failure mode the other two
don't directly address: queries with zero surface-term overlap to the
plant ("What kind of car?" → "Subaru Outback"). Independent of A and B —
could land alongside either.

**What to do.**
1. At query time, run NLTagger over the recall query to extract entity-
   type intent. "What kind of car?" → infer concept `vehicle`.
2. Expand the FTS5 query to include common synonyms for that concept
   (mini synonym dictionary, hand-curated for common categories: car/
   vehicle/auto/drive, instrument/cello/guitar/piano, live/home/house/
   reside, etc.).
3. BM25 then matches the plant via the expanded terms (Subaru is a car,
   cello is an instrument, Berkeley is a place where someone lives).

**Trade-off.** Synonym dictionaries are brittle and English-specific. An
LLM-based query rewriter would be more flexible but adds latency. Start
with a small hand-curated dictionary for the categories the eval queries
exercise; expand based on real-world miss patterns.

---

## Other work queued (deferred to make room for RAG)

These were paused when the RAG question came up on May 16. Still relevant.

- **Cluster B remaining (visual)**: Salon UI Pickers, System prompt counter,
  Model Library UI, App icon — visual verification on device or simulator.
- **Cluster B remaining (long duration)**: Background downloads long-lock test
  — delete Gemma (3.6 GB), start fresh download, lock phone face-down 10+
  minutes, verify BGDL coordinator handles iOS suspension.
- **Cluster C from May 16** (orthogonal to the RAG proposals above):
  - Structured-trait synthesis (Mark's decision: implement, design for
    inspectability so it can surface in a future Evolutionary Salon)
  - Scroll behavior (Mark's decision: requirement — search SwiftUI examples
    on the web first, find a working pattern, adapt it)

## On deck

- Screenshots × 6 for App Store
- ASC metadata fills using `Docs/ASC_v2.0_Paste_Ready.md`
- One-off `Docs/` consolidation (many per-session recovery/finding docs)
