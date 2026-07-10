# Real-world embedder retrieval eval — the "Maxims for embedders"

**Date:** 2026-07-09 · **Device:** iPhone 16 Plus · **Tool:** `tests/embedder_retrieval_eval.py`
**Context:** v2.1 item 5. Mark asked for a test "close enough to what Hal has to
do in the real world" — not raw cosine geometry (that's `embedder_ab_eval.py`),
but the full retrieval pipeline the chat loop actually uses.

## Rubric

1. Plant a synthetic-but-realistic memory corpus (36 memories: facts about the
   user + Hal), deliberately including topic clusters with **distractors** so
   queries must discriminate, not just keyword-match.
2. Backfill all three embedder columns so every backend sees the same corpus.
3. For each backend, run 26 gold-labeled queries through the FULL pipeline
   (`MEMORY_SEARCH_DEBUG` → `searchUnifiedContent`: semantic on the active
   column + BM25 + recency, fused by RRF) and record the rank of the correct
   memory.
4. Score per backend: Recall@1/@3/@5 and MRR. Hard queries (paraphrases with no
   keyword overlap, or distractors that share keywords with the WRONG memory)
   are called out separately — those are where a sharper embedder *should* win.

Corpus + queries are inlined in the script for review/editing (realism is the
whole game; the numbers are only as good as the data).

## Headline result — the embedder barely matters in the current pipeline

| Backend | Recall@1 | Recall@3 | Recall@5 | MRR |
|---|---|---|---|---|
| NLContextual | 0.38 | 0.50 | 0.65 | 0.499 |
| Nomic | 0.38 | 0.50 | 0.65 | 0.499 |
| mxbai | 0.38 | 0.54 | 0.65 | 0.502 |

**All three are nearly identical.** Choosing the "best" embedder (mxbai) over the
built-in one changes almost nothing about what Hal actually retrieves. This is
the *opposite* of what the cosine A/B implied (mxbai 0.48 vs 0.10 separation).

## Why — confirmed, not guessed

Ran each hard query through BOTH the pure-semantic path
(`MEMORY_SIMILARITY_DEBUG`, embedder only) and the full pipeline:

| | Pure semantic (embedder only) | Full pipeline |
|---|---|---|
| NLContextual | Recall@3 = 0.63 | 0.47 |
| **mxbai** | Recall@3 = **0.84** | **0.47** |

**mxbai's semantics are far better (0.84 vs 0.63) — the pipeline discards the
gain (both collapse to 0.47).** Example: "What computer does Mark write code on?"
→ mxbai semantics rank the answer **#1**; the full pipeline buries it at **#20**.

**Root cause — the RRF fusion is keyword-dominated.** In `searchUnifiedContent`:

```
rrfKSemantic = 60.0
rrfKBM25     = bm25Distinctive ? 10.0 : 60.0
rrf += 1/(rrfKSemantic + semanticRank) + 1/(rrfKBM25 + bm25Rank)
```

A distinctive BM25 (keyword) hit at rank 1 contributes `1/11 ≈ 0.091`; the top
semantic hit contributes `1/61 ≈ 0.016` — **~5.5× weaker**, and identical no
matter which embedder produced it. So keyword matching drives retrieval; the
embedder only breaks ties, weakly. On paraphrase queries (no keyword overlap)
BM25 fails AND the strong semantic signal is weighted too low to rescue the rank.

## Implications

1. **Today, downloading a better embedder gives little real-world benefit.** The
   value is real at the vector level but the pipeline doesn't deliver it. The
   model-card wording ("most reliably surfaces exactly the right one" for mxbai)
   overstates the *end-to-end* benefit as things stand — worth revisiting.
2. **The real lever is the fusion, not the embedder.** To let a better embedder
   actually help, rebalance RRF toward semantic — e.g. lower `rrfKSemantic`, or
   make the semantic weight scale with the embedder's confidence/quality, or add
   a semantic-only rescue for queries where BM25 finds nothing distinctive. That
   is a retrieval-behavior change affecting ALL users, so it needs a deliberate
   decision + its own before/after eval (this harness is exactly that).
3. **This eval harness is the instrument for that work** — re-run it after any
   fusion change to measure the before/after on the same corpus + queries.

## Caveats

- 36 memories / 26 queries — a small, hand-authored set; directionally strong
  (the pure-vs-full gap is large and consistent) but not a large benchmark.
- All memories planted at the same age, so recency is uniform (not a confound;
  it's identical across backends anyway).
- Content matching is by substring on the 200-char preview; memories are short
  and unique, so matches are unambiguous.
