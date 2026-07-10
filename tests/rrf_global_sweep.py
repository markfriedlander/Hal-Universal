#!/usr/bin/env python3
"""
Global RRF-fusion sweep — step 2 of the retrieval rebalance (NEXT.md 5.5).

The 2026-07-09 retrieval eval (embedder_retrieval_eval.py) found the embedder
barely affects what Hal actually retrieves: full-pipeline recall is ~identical
across all three backends even though mxbai's PURE-semantic recall is far better.
Root cause: RRF weights the top semantic hit (k=60 → 1/61) ~5.5x weaker than a
distinctive BM25 keyword hit (k=10 → 1/11), so keyword matching dominates and the
embedder only breaks ties.

This sweeps the primary lever — rrfKSemantic — DOWN from 60 toward 10, holding
rrfKBM25Distinctive=10 and rrfKBM25Default=60, and measures recall/MRR for ALL
THREE embedders at each setting. We hold the distinctive-BM25 k at 10 on purpose:
a genuinely distinctive lexical hit (the Bug 2a imported-document case) must still
win, and this corpus has no such queries to protect it — so keeping
rrfKSemantic >= rrfKBM25Distinctive preserves "distinctive BM25 >= semantic" by
construction while still letting semantic beat GENERIC keyword matches (default
BM25 k=60).

What to look for:
  1. Overall recall/MRR should RISE as k drops (semantic finally competes).
  2. The three embedders should DIVERGE (mxbai > nomic > nl) — that divergence is
     the proof the semantic signal now matters end-to-end.
  3. A smooth plateau (not a lone spike) across a range of k = robust, not overfit.

Reuses the EXACT corpus + queries + scoring from embedder_retrieval_eval.py so the
sweep and the headline eval can never drift apart.

NON-DESTRUCTIVE: plants live under the recency test's source_id and are removed in
a finally; the active backend AND the three RRF knobs are saved + restored.

Usage:
    python3 tests/rrf_global_sweep.py
"""

import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from embedder_retrieval_eval import (  # noqa: E402
    MEMORIES, QUERIES, BACKENDS, call, gold_rank,
)

# rrfKSemantic grid, high (current default) → low. Floor at 10 = rrfKBM25Distinctive
# so a distinctive lexical hit never loses to semantic (protects Bug 2a).
SEMANTIC_K_GRID = [60, 45, 35, 25, 20, 15, 10]


def metrics(ranks):
    n = len(ranks)
    r1 = sum(1 for rk in ranks if rk == 1) / n
    r3 = sum(1 for rk in ranks if rk and rk <= 3) / n
    r5 = sum(1 for rk in ranks if rk and rk <= 5) / n
    mrr = statistics.mean([(1.0 / rk) if rk else 0.0 for rk in ranks])
    return r1, r3, r5, mrr


def run_queries():
    """Run all gold queries through the full pipeline; return (ranks, hard_ranks)."""
    ranks, hard_ranks = [], []
    for (q, gold, hard) in QUERIES:
        r = call(f"MEMORY_SEARCH_DEBUG:{q}")
        rk = gold_rank(r.get("entries", []), gold)
        ranks.append(rk)
        if hard:
            hard_ranks.append(rk)
    return ranks, hard_ranks


def main():
    orig_backend = call("EMBEDDING_STATUS")["backend"]
    rrf0 = call("RRF_STATUS")
    saved = (rrf0["rrfKSemantic"], rrf0["rrfKBM25Distinctive"], rrf0["rrfKBM25Default"])
    print(f"\n{'='*100}")
    print(f"Global RRF sweep — {len(MEMORIES)} memories, {len(QUERIES)} queries, "
          f"rrfKSemantic in {SEMANTIC_K_GRID}")
    print(f"{'='*100}")
    print(f"Saved: backend={orig_backend}  RRF(sem/bm25d/bm25)={saved}\n")

    # results[backend][k] = (r1, r3, r5, mrr, hard_mrr)
    results = {be: {} for be in BACKENDS}
    try:
        # Hold BM25 knobs at their defaults for the whole sweep.
        call("SET_RRF_BM25_DISTINCTIVE_K:10")
        call("SET_RRF_BM25_DEFAULT_K:60")

        # Plant corpus once (age 0 → recency neutral); fill every backend column once.
        call("MEMORY_PLANT_AGED_CLEANUP")
        print(f"Planting {len(MEMORIES)} memories...")
        for m in MEMORIES:
            call(f"MEMORY_PLANT_AGED:0:{m}")
        print("Backfilling all embedder columns...")
        call("BACKFILL_EMBEDDINGS:all", timeout=600)

        # Backend-outer so we only switch embedders 3x total.
        for be in BACKENDS:
            call(f"SET_EMBEDDING_BACKEND:{be}")
            time.sleep(4)
            call(f"EMBED_PROBE:{be}:warm up")
            time.sleep(2)
            for k in SEMANTIC_K_GRID:
                call(f"SET_RRF_SEMANTIC_K:{k}")
                ranks, hard_ranks = run_queries()
                r1, r3, r5, mrr = metrics(ranks)
                _, _, _, hard_mrr = metrics(hard_ranks)
                results[be][k] = (r1, r3, r5, mrr, hard_mrr)
                print(f"  {be:12s} k={k:<3d}  R@1={r1:.2f} R@3={r3:.2f} "
                      f"R@5={r5:.2f} MRR={mrr:.3f} hardMRR={hard_mrr:.3f}")
    finally:
        call(f"SET_RRF_SEMANTIC_K:{saved[0]}")
        call(f"SET_RRF_BM25_DISTINCTIVE_K:{saved[1]}")
        call(f"SET_RRF_BM25_DEFAULT_K:{saved[2]}")
        call(f"SET_EMBEDDING_BACKEND:{orig_backend}")
        call("MEMORY_PLANT_AGED_CLEANUP")
        print(f"\nRestored: backend={call('EMBEDDING_STATUS')['backend']}  "
              f"RRF={call('RRF_STATUS')}; plants removed.")

    # ---- Summary grids ----
    print(f"\n{'='*100}\nMRR by rrfKSemantic (rows) x embedder (cols) — higher = better")
    print(f"{'='*100}")
    header = "  k    " + "".join(f"{be:>13s}" for be in BACKENDS) + f"{'MEAN':>9s}"
    print(header)
    combined = {}
    for k in SEMANTIC_K_GRID:
        cells = ""
        mrrs = []
        for be in BACKENDS:
            mrr = results[be][k][3]
            mrrs.append(mrr)
            cells += f"{mrr:>13.3f}"
        mean = statistics.mean(mrrs)
        combined[k] = mean
        star = "  <- default" if k == 60 else ""
        print(f"  {k:<4d}{cells}{mean:>9.3f}{star}")

    print(f"\nRecall@3 by rrfKSemantic (rows) x embedder (cols)")
    print("  k    " + "".join(f"{be:>13s}" for be in BACKENDS))
    for k in SEMANTIC_K_GRID:
        cells = "".join(f"{results[be][k][1]:>13.2f}" for be in BACKENDS)
        print(f"  {k:<4d}{cells}")

    best_k = max(combined, key=combined.get)
    base = combined[60]
    print(f"\n{'='*100}")
    print(f"Best mean MRR: k={best_k} ({combined[best_k]:.3f})   "
          f"vs default k=60 ({base:.3f})   delta={combined[best_k]-base:+.3f}")
    print("Divergence check (mxbai MRR - nl MRR) at each k:")
    for k in SEMANTIC_K_GRID:
        div = results["mxbai"][k][3] - results["nlcontextual"][k][3]
        print(f"  k={k:<3d}  {div:+.3f}")
    print("\nRead the CURVE, not just the argmax: a smooth plateau = robust; a lone spike = suspect.")


if __name__ == "__main__":
    main()
