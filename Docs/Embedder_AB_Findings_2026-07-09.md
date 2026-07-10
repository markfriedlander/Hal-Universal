# Embedder A/B/C findings — NLContextual vs Nomic vs mxbai

**Date:** 2026-07-09 · **Device:** iPhone 16 Plus · **Tool:** `tests/embedder_ab_eval.py`
**Context:** v2.1 item 5 step 3. Now that all three embedders coexist in the
database (per-backend columns), we can compare them directly.

## Method

The same curated pair set (8 pairs per class) run through each backend via
`SET_EMBEDDING_BACKEND` (instant + non-destructive) + `EMBED_SIM_BATCH` (cosine
between two texts under the active backend):

- **SAME** — the same thought in different words (should score high)
- **RELATED** — same topic, different idea (should score medium)
- **UNREL** — unrelated (should score low)

The headline metric is **SEPARATION = mean(SAME) − mean(UNREL)**: how strongly a
backend pulls related content apart from unrelated content. Higher = better
retrieval discrimination (the model can actually tell your relevant memories
from noise).

## Results

| Backend | SAME (mean) | RELATED (mean) | UNREL (mean) | **Separation** |
|---|---|---|---|---|
| **mxbai** | 0.84 | 0.67 | 0.36 | **0.480** |
| Nomic | 0.85 | 0.77 | 0.55 | 0.303 |
| NLContextual | 0.92 | 0.89 | 0.82 | 0.101 |

**Ranking (retrieval discrimination): mxbai ≫ Nomic ≫ NLContextual.**

The story is in the UNREL column. NLContextual rates *unrelated* text at 0.82 —
nearly as high as same-thought pairs — so it barely separates signal from noise;
its vectors carry a lot of generic English-structure similarity. Nomic is much
better (UNREL 0.55). mxbai is best by a wide margin (UNREL 0.36), giving the
cleanest signal-vs-noise gap.

## Synthesis-threshold calibration

The reflection-synthesis merge threshold must sit just above each backend's
RELATED tail (merging is destructive, so bias conservative). SAME and RELATED
overlap at the bottom for all three, so the threshold captures the clearer
duplicates only.

| Backend | RELATED max | Encoded synthesis threshold |
|---|---|---|
| NLContextual | 0.915 | 0.85 (unchanged; high in its 0.79–0.95 range) |
| Nomic | 0.831 | 0.85 (unchanged; calibrated 2026-05-18) |
| **mxbai** | 0.794 | **0.82** (new — was a 0.85 placeholder) |

mxbai contradiction threshold set to **0.5** (distribution-informed: RELATED ~0.67,
UNREL ~0.36 → ~0.5 is a sensible aligned-vs-in-tension boundary). Still soft —
refine from real trait-evolution events.

## Product decision

**Keep all three; let the user choose (model cards in the picker).** Not
one-size-fits-all:

- **NLContextual** — the **default / always-available** (built-in, no download,
  fastest, lightest). Hal must work on first launch with no download, so this
  stays the out-of-box embedder. Weakest discrimination.
- **Nomic** — balanced middle (~522 MB, moderate speed, clearly better than
  built-in).
- **mxbai** — **recommended for quality** (`isRecommended = true`). Sharpest
  retrieval; heaviest (~670 MB) and slowest to embed. Opt-in download.

## Caveats

- 8 pairs/class — directionally strong (the gaps are large and consistent) but a
  small sample; the bands, not any single pair, are what matter.
- `EMBED_SIM_BATCH` is symmetric (both sides embedded the same way). Correct for
  the synthesis-threshold question (comparing two stored reflections). A future
  pass could measure asymmetric query→document retrieval directly.
- Speed/size are qualitative here; mxbai ≈ 0.66 s/encode (Posey 2026-06-19) vs
  Nomic/NLContextual faster. The backfill cost scales with corpus size.
