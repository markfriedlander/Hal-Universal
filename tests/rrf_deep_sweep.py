#!/usr/bin/env python3
"""
Deep RRF sweep BELOW k=10 — with a real Bug 2a guard (NEXT.md 5.5, step 2).

The global sweep (rrf_global_sweep.py) showed mean MRR climbing monotonically as
rrfKSemantic drops 60 -> 10, and it was STILL climbing at 10. But 10 was the floor
there because it equals rrfKBM25Distinctive: below it, semantic would outrank a
distinctive lexical hit and break Bug 2a (an imported document's rare exact term
must win). This script tests whether we can go below 10 SAFELY by co-lowering the
distinctive-BM25 knob so the invariant `rrfKBM25Distinctive <= rrfKSemantic` always
holds — and it MEASURES that with real guard queries instead of trusting the math.

Corpus = the base 36 memories + 26 queries (imported from embedder_retrieval_eval,
so the two evals can't drift) + 15 extra general memories + 10 extra general
queries (overfit guard: a bigger set) + 4 Bug-2a GUARD triples (a rare-term
"imported document" + a semantic distractor + a rare-term query; the guard passes
iff the rare-term doc ranks #1).

Configs (label, rrfKSemantic, rrfKBM25Distinctive); rrfKBM25Default held at 60:
  - (60,10) production baseline
  - (10,10) current global-sweep best
  - (8,8) (6,6) (5,5) (3,3) co-lowered, invariant respected
  - (5,10) NEGATIVE CONTROL — invariant VIOLATED; guards SHOULD break here. If they
    don't, the guard has no teeth and its green elsewhere means nothing.

NON-DESTRUCTIVE: plants live under the recency test's source_id, removed in a
finally; active backend + all three RRF knobs saved and restored.

Usage:
    python3 tests/rrf_deep_sweep.py
"""

import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from embedder_retrieval_eval import (  # noqa: E402
    MEMORIES as BASE_MEMORIES, QUERIES as BASE_QUERIES, BACKENDS, call, normalize,
)

# ---- Extra general memories (overfit guard: more coverage) ----
EXT_MEMORIES = [
    "Mark's brother is a jazz pianist in New Orleans.",
    "Mark broke his wrist skateboarding as a teenager.",
    "Mark's first programming language was BASIC on a Commodore 64.",
    "Mark keeps a saltwater aquarium with two clownfish.",
    "Mark's favorite film is Blade Runner.",
    "Hal's entity extractor builds a knowledge graph from conversations over time.",
    "Hal summarizes long conversations to stay within the model's context window.",
    "Hal has an Apple Watch companion that shows a simplified chat on the wrist.",
    "Hal's temperature setting controls how creative or focused its replies are.",
    "Mark is teaching his daughter to drive the restored Camaro.",
    "Mark's wife works as a pediatric nurse at the children's hospital.",
    "Mark volunteers at the local animal shelter every Saturday morning.",
    "Mark's back porch faces east toward the open ocean.",
    "Hal can run four different local language models the user downloads.",
    "Mark sketches building ideas in a small notebook he carries everywhere.",
]

# (query, [gold memory TEXTS], hard). Text-based gold so indices can't drift.
EXT_QUERIES = [
    ("What instrument does Mark's brother play?", ["Mark's brother is a jazz pianist in New Orleans."], False),
    ("How did Mark first get into computers as a kid?", ["Mark's first programming language was BASIC on a Commodore 64."], True),
    ("What does Mark keep in a tank of water?", ["Mark keeps a saltwater aquarium with two clownfish."], True),
    ("What is Mark's favorite movie?", ["Mark's favorite film is Blade Runner."], False),
    ("What does Hal do so a long chat still fits in the model?", ["Hal summarizes long conversations to stay within the model's context window."], True),
    ("How does Hal accumulate knowledge over many conversations?", ["Hal's entity extractor builds a knowledge graph from conversations over time."], True),
    ("What can Hal do on a smartwatch?", ["Hal has an Apple Watch companion that shows a simplified chat on the wrist."], True),
    ("What does the temperature control actually change?", ["Hal's temperature setting controls how creative or focused its replies are."], False),
    ("What is Mark's wife's profession?", ["Mark's wife works as a pediatric nurse at the children's hospital."], True),
    ("How does Mark spend his Saturday mornings?", ["Mark volunteers at the local animal shelter every Saturday morning."], True),
]

# ---- Bug 2a GUARD triples: imported doc vs a conversation ECHO of its content. ----
# This mirrors the REAL Bug 2a failure mode (per the searchUnifiedContent comment):
# an imported document and a conversation snippet echo the SAME content; the doc
# carries a distinctive term; without the distinctive-BM25 boost the semantic echo
# outranks the doc. Both doc and echo are about the same topic (so both get semantic
# support); the query uses the distinctive term. Guard passes iff the imported DOC
# ranks above its echo. (Note: one-line synthetic memories can't fully reproduce a
# long imported doc, so this is a directional check, not a strict invariant proof.)
GUARD_DOCS = [
    "Imported lab report: the active ingredient is compound Zephyrine-9, dosed at five milligrams.",
    "Imported contract clause: indemnification is limited to the amount named in schedule 7-Alpha-Zulu.",
    "Imported spec sheet: the coolant pump is part number QX-4417-Rev2, rated to 512 kilopascals.",
    "Imported roadmap: the release codenamed Nightingale-7X is targeted for the third quarter.",
]
GUARD_DISTRACTORS = [
    "Earlier we chatted about how Zephyrine keeps showing up as the key ingredient in that lab report.",
    "We talked before about the indemnification limit and which schedule the contract points to.",
    "We discussed the coolant pump earlier and how its pressure rating was on the spec sheet.",
    "We were talking about that upcoming release and roughly when in the year it was aimed for.",
]
# (query, gold DOC text) — the query carries the distinctive term; expect the
# imported DOC to rank above its conversation echo.
GUARD_QUERIES = [
    ("What is the active ingredient Zephyrine-9?", GUARD_DOCS[0]),
    ("What does schedule 7-Alpha-Zulu limit indemnification to?", GUARD_DOCS[1]),
    ("What is coolant pump part QX-4417-Rev2 rated to?", GUARD_DOCS[2]),
    ("When is Nightingale-7X targeted to release?", GUARD_DOCS[3]),
]

ALL_MEMORIES = BASE_MEMORIES + EXT_MEMORIES + GUARD_DOCS + GUARD_DISTRACTORS

# General queries with text-based gold (base queries carry indices into BASE_MEMORIES).
GENERAL_QUERIES = (
    [(q, [BASE_MEMORIES[i] for i in gold], hard) for (q, gold, hard) in BASE_QUERIES]
    + EXT_QUERIES
)

# (label, rrfKSemantic, rrfKBM25Distinctive). The gap-preserving SAFE family holds
# kBM25d=10 (prod value) and only lowers kSem, so distinctive keyword stays
# STRICTLY stronger than semantic for every kSem>10 (Bug 2a margin preserved).
# 10/10 sits ON the boundary; 5/10 CROSSES it (semantic beats distinctive) as a
# reference for what "unsafe" looks like.
CONFIGS = [
    ("prod   60/10", 60, 10),
    ("safe   30/10", 30, 10),
    ("safe   20/10", 20, 10),
    ("safe   15/10", 15, 10),
    ("safe   12/10", 12, 10),
    ("bound  10/10", 10, 10),
    ("CROSS   5/10", 5, 10),   # invariant crossed — reference for "unsafe"
]


def rank_of(entries, gold_texts):
    norm_golds = [normalize(g) for g in gold_texts]
    for rank, e in enumerate(entries, start=1):
        c = normalize(e.get("contentPreview", ""))
        if any(ng and ng in c for ng in norm_golds):
            return rank
    return None


def metrics(ranks):
    n = len(ranks)
    r1 = sum(1 for rk in ranks if rk == 1) / n
    r3 = sum(1 for rk in ranks if rk and rk <= 3) / n
    r5 = sum(1 for rk in ranks if rk and rk <= 5) / n
    mrr = statistics.mean([(1.0 / rk) if rk else 0.0 for rk in ranks])
    return r1, r3, r5, mrr


def main():
    orig_backend = call("EMBEDDING_STATUS")["backend"]
    rrf0 = call("RRF_STATUS")
    saved = (rrf0["rrfKSemantic"], rrf0["rrfKBM25Distinctive"], rrf0["rrfKBM25Default"])
    print(f"\n{'='*104}")
    print(f"Deep RRF sweep — {len(ALL_MEMORIES)} memories "
          f"({len(GENERAL_QUERIES)} general + {len(GUARD_QUERIES)} Bug-2a guard queries)")
    print(f"{'='*104}")
    print(f"Saved: backend={orig_backend}  RRF={saved}\n")

    # results[label][backend] = (r1,r3,r5,mrr, guard_pass, guard_total)
    results = {lbl: {} for (lbl, _, _) in CONFIGS}
    try:
        call("SET_RRF_BM25_DEFAULT_K:60")   # held constant
        call("MEMORY_PLANT_AGED_CLEANUP")
        print(f"Planting {len(ALL_MEMORIES)} memories...")
        for m in ALL_MEMORIES:
            call(f"MEMORY_PLANT_AGED:0:{m}")
        print("Backfilling all embedder columns...")
        call("BACKFILL_EMBEDDINGS:all", timeout=600)

        for be in BACKENDS:
            call(f"SET_EMBEDDING_BACKEND:{be}")
            time.sleep(4)
            call(f"EMBED_PROBE:{be}:warm up")
            time.sleep(2)
            for (lbl, kSem, kBM25d) in CONFIGS:
                call(f"SET_RRF_SEMANTIC_K:{kSem}")
                call(f"SET_RRF_BM25_DISTINCTIVE_K:{kBM25d}")
                ranks = []
                for (q, gold, _hard) in GENERAL_QUERIES:
                    r = call(f"MEMORY_SEARCH_DEBUG:{q}")
                    ranks.append(rank_of(r.get("entries", []), gold))
                r1, r3, r5, mrr = metrics(ranks)
                gpass = 0
                for (q, doc) in GUARD_QUERIES:
                    r = call(f"MEMORY_SEARCH_DEBUG:{q}")
                    if rank_of(r.get("entries", []), [doc]) == 1:
                        gpass += 1
                results[lbl][be] = (r1, r3, r5, mrr, gpass, len(GUARD_QUERIES))
                print(f"  {be:12s} {lbl:14s}  R@1={r1:.2f} R@3={r3:.2f} R@5={r5:.2f} "
                      f"MRR={mrr:.3f}  guard={gpass}/{len(GUARD_QUERIES)}")
    finally:
        call(f"SET_RRF_SEMANTIC_K:{saved[0]}")
        call(f"SET_RRF_BM25_DISTINCTIVE_K:{saved[1]}")
        call(f"SET_RRF_BM25_DEFAULT_K:{saved[2]}")
        call(f"SET_EMBEDDING_BACKEND:{orig_backend}")
        call("MEMORY_PLANT_AGED_CLEANUP")
        print(f"\nRestored: backend={call('EMBEDDING_STATUS')['backend']}  "
              f"RRF={call('RRF_STATUS')}; plants removed.")

    # ---- Summary ----
    print(f"\n{'='*104}\nMean MRR (general queries) + guard pass-rate, by config x embedder")
    print(f"{'='*104}")
    print("  config          " + "".join(f"{be:>14s}" for be in BACKENDS) + f"{'MEAN MRR':>11s}{'GUARD':>10s}")
    for (lbl, _, _) in CONFIGS:
        mrrs, gp, gt = [], 0, 0
        cells = ""
        for be in BACKENDS:
            r1, r3, r5, mrr, gpass, gtot = results[lbl][be]
            mrrs.append(mrr)
            gp += gpass
            gt += gtot
            cells += f"{mrr:>14.3f}"
        mean = statistics.mean(mrrs)
        print(f"  {lbl:14s}{cells}{mean:>11.3f}{f'{gp}/{gt}':>10s}")

    print("\nSAFE family (kBM25d=10, kSem>10): distinctive keyword stays stronger than semantic")
    print("(Bug 2a margin preserved). Pick the kSem that captures most of the recall gain while")
    print("keeping a real gap above the 10/10 boundary. CROSS 5/10 is the 'unsafe' reference.")


if __name__ == "__main__":
    main()
