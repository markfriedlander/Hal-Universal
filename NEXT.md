# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md`.

---

## Just landed (May 17)

RAG architectural rebuild complete — three commits (A: NLContextualEmbedding,
B: FTS5 BM25, C: RRF fusion). Detail in HISTORY.md 2026-05-17 entry. Plant
recall on natural-language queries: 7/10 in top-10 (vs effectively 0 before
on paraphrased queries). Architecture matches industry standard.

---

## Active queue

### 1. Push to origin

Local `main` is **6 commits ahead of `origin/main`** (RAG rebuild A/B/C, plus
the Cluster A + Salon + SPM fixes from May 16). Push pending.

### 2. Cluster B verification — remaining items

The non-RAG Cluster B verification items from May 16 still apply. RAG itself
is now verified separately via `tests/rag_threshold_eval.py`. Remaining:

- **Visual checks**: Salon UI Pickers, System prompt counter, Model Library UI,
  App icon — visual verification on device or simulator.
- **Background downloads long-lock test** — delete Gemma (3.6 GB), start fresh
  download, lock phone face-down 10+ minutes, verify BGDL coordinator handles
  iOS suspension correctly.

### 3. Cluster C — implementation (from May 16, was paused for RAG question)

- **Structured-trait synthesis** (Mark's decision: implement, design for
  inspectability so it can surface in a future Evolutionary Salon)
  - Add semantic similarity check to `storeSelfKnowledge` for
    `structured_trait` format. New entry's embedding compared against
    existing entries in the same category. Above threshold (start at 0.85
    to match reflections), synthesize into existing.
- **Scroll behavior** (Mark's decision: requirement — search SwiftUI examples
  on the web first, find a working pattern, adapt it)
  - User's message scrolls off the top, Hal's response follows immediately
    below, user is in complete control. No automatic repositioning.

## On deck (post-clusters)

- **Screenshots × 6** for App Store
- **ASC metadata fills** using `Docs/ASC_v2.0_Paste_Ready.md`
- **One-off Docs/ consolidation** — many per-session recovery and finding
  docs in `Docs/` should be consolidated. Queued for a dedicated pass.

## Open RAG follow-ups (lower priority than active queue)

These are the 3 missed ground-truth queries from the RAG eval. They reflect
genuine model-strength limits on short text, not architectural problems.
Worth investigating after the active queue clears:

- **"Where do I live now?" → "house in Berkeley"** — pure-semantic + BM25
  can't bridge "live" → "Berkeley" reliably. Would benefit from entity-
  aware indexing (extract Berkeley, San Francisco, Iceland, etc. at write
  time and store as searchable entities separate from raw content).
- **"What kind of car?" → "Subaru Outback"** — same root cause; "car"
  doesn't appear in plant content.
- **"What instrument am I learning?" → "cello"** — same; "instrument"
  doesn't appear in plant.

Three options if/when this surfaces as a real problem:
- (a) Entity extraction at write time (NLTagger names → entity_keywords)
- (b) Synonym dictionary at query time ("car" → "vehicle, drive, auto,
  Honda, Subaru, ...")
- (c) Wait for a stronger on-device embedding model (e.g., EmbeddingGemma
  when it's available via Swift bindings)
