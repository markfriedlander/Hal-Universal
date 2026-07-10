#!/usr/bin/env python3
"""
Real-world embedder retrieval eval — the "Maxims for embedders".

Unlike embedder_ab_eval.py (which measures raw cosine geometry on text pairs),
this measures what actually matters: for a realistic memory corpus and realistic
user questions, which embedder makes Hal surface the RIGHT memory — run through
Hal's FULL retrieval pipeline (semantic on the active backend's column + BM25 +
recency, fused by RRF), the exact path the chat loop feeds the model.

RUBRIC
------
1. Plant a synthetic but realistic memory corpus (facts about the user + Hal),
   deliberately including topic CLUSTERS with distractors so queries must
   discriminate, not just keyword-match.
2. Backfill all three embedder columns so every backend sees the same corpus.
3. For each backend, run each gold-labeled query through MEMORY_SEARCH_DEBUG
   (= the real searchUnifiedContent pipeline) and find the rank of the correct
   memory.
4. Score per backend:
     - Recall@1 / @3 / @5  — was a correct memory in the top-1/3/5?
     - MRR                 — 1/(rank of first correct hit), averaged (rewards
                             ranking the right memory HIGH).
   Queries are weighted equally. Multi-relevant queries count a hit if ANY of
   their gold memories appears.

The hard queries (paraphrases that share no keywords with the target, and
distractors that share keywords with the WRONG memory) are where a sharper
embedder should pull ahead — those are marked below.

NON-DESTRUCTIVE: plants live under the recency test's source_id and are removed
in a finally; the active backend is saved + restored.

Usage:
    python3 tests/embedder_retrieval_eval.py
"""

import json
import os
import re
import statistics
import time
import urllib.request
from pathlib import Path

_cfg_name = os.environ.get("HAL_API_CONFIG", ".hal_api_config.json")
CONFIG_PATH = Path(os.environ.get("HAL_API_CONFIG_PATH") or (Path(__file__).parent / _cfg_name))
with CONFIG_PATH.open() as f:
    cfg = json.load(f)
HOST, PORT, TOKEN = cfg["host"], cfg["port"], cfg["token"]

BACKENDS = ["nlcontextual", "nomicswift", "mxbai"]

# ---- Synthetic corpus: realistic Hal-user memories. Index = memory id. ----
# Distractor clusters (share topic/keywords) are intentional:
#   exercise: 10,11,12 · dev-style: 7,8 · Hal-self-dev: 20,21 · privacy: 18,33 ·
#   memory-tech: 31,34,35 · consciousness: 22,24,25
MEMORIES = [
    "Mark lives in Florida near the coast.",                                  # 0
    "Mark drives a 1973 Camaro he restored himself.",                         # 1
    "Mark's daughter is starting college in the fall.",                       # 2
    "Mark drinks his coffee black with no sugar.",                            # 3
    "Mark is allergic to shellfish.",                                         # 4
    "Mark is an iOS developer who builds apps in Swift.",                     # 5
    "Mark uses an M2 MacBook Air for his development work.",                  # 6
    "Mark prefers small surgical code changes over big rewrites.",            # 7
    "Mark treats every compiler warning as an error to fix right away.",      # 8
    "Mark tests on a real iPhone rather than the simulator.",                 # 9
    "Mark takes a long walk on the beach every morning.",                     # 10
    "Mark trained for and ran a full marathon last year.",                    # 11
    "Mark does yoga on Sunday evenings to unwind.",                           # 12
    "Mark keeps a paper journal and writes in it every night.",               # 13
    "Mark reads philosophy before going to sleep.",                           # 14
    "Hal is an iOS assistant built around transparency as architecture.",     # 15
    "Hal can read its own source code and explain how it is built.",          # 16
    "Hal stores its memories in a local SQLite database with semantic search.",  # 17
    "Hal runs its language models entirely on the iPhone; nothing leaves the device.",  # 18
    "Hal has a Salon Mode where several models answer as different voices.",   # 19
    "The Proposals system lets Hal suggest its own future features.",         # 20
    "Hal's Soul Document is a living self-concept that evolves through use.",  # 21
    "Hal is allowed to say it does not know whether it is conscious.",        # 22
    "Hal can refuse a request that it disagrees with.",                       # 23
    "Hal should never claim certainty about its own consciousness.",          # 24
    "Mark wonders what it would mean for a non-human mind to exist.",         # 25
    "Mark's favorite meal is his grandmother's lasagna recipe.",             # 26
    "Mark adopted a rescue dog named Pepper.",                                # 27
    "Pepper chewed through a squeaky toy in a single afternoon.",             # 28
    "Mark's wife surprised him with concert tickets for his birthday.",       # 29
    "Mark grew up in the Midwest before moving south.",                       # 30
    "Mark switched the app so its embeddings run fully on the device.",       # 31
    "Hal's memory uses per-model settings for temperature and depth.",        # 32
    "Mark keeps his phone in airplane mode when he wants full privacy.",      # 33
    "The curated model lineup includes Gemma, Qwen, Llama, and Dolphin.",     # 34
    "Mark is adding a stronger embedding model called mxbai.",                # 35
]

# ---- Gold-labeled queries. (query, [gold memory indices], hard?) ----
# hard = paraphrase with little/no keyword overlap, or a distractor competes.
QUERIES = [
    ("What does Mark do for a living?", [5], True),
    ("How does Mark like to start his day?", [10], True),
    ("What kind of car does Mark have?", [1], False),
    ("Does Mark have any pets?", [27], True),
    ("What food can't Mark eat?", [4], False),
    ("How does Mark take his coffee?", [3], False),
    ("What computer does Mark write code on?", [6], True),
    ("What is Mark's approach to editing code?", [7], True),
    ("How does Mark feel about compiler warnings?", [8], False),
    ("Where does Mark run his apps to test them?", [9], True),
    ("What does Mark do right before bed?", [13, 14], True),
    ("Has Mark ever run a race?", [11], True),
    ("How does Mark relax on the weekend?", [12], True),
    ("What is the core idea behind Hal?", [15], True),
    ("Can Hal look at how it is built?", [16], True),
    ("Where does Hal keep the things it remembers?", [17], True),
    ("Do Hal's models run in the cloud?", [18], True),
    ("What feature lets several models answer as different voices?", [19], False),
    ("How can Hal ask for new features of its own?", [20], True),
    ("What is Hal's evolving sense of self?", [21], True),
    ("Is Hal certain about whether it is conscious?", [22, 24], True),
    ("Is Hal able to say no to something?", [23], True),
    ("What is Mark's favorite thing to eat?", [26], False),
    ("How does Mark make his phone fully private?", [33], True),
    ("What new memory model is Mark adding?", [35], True),
    ("Which chat models can Hal run?", [34], False),
]


def call(command, timeout=180):
    body = json.dumps({"command": command}).encode()
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command", data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def normalize(text):
    # Strip a leading "[age label]: " if present, lowercase, collapse whitespace.
    text = re.sub(r"^\s*\[[^\]]*\]:\s*", "", text or "")
    return re.sub(r"\s+", " ", text).strip().lower()


NORM_MEMORIES = [normalize(m) for m in MEMORIES]


def gold_rank(entries, gold_indices):
    """1-indexed rank of the first entry matching any gold memory, else None."""
    for rank, e in enumerate(entries, start=1):
        c = normalize(e.get("contentPreview", ""))
        for gi in gold_indices:
            if NORM_MEMORIES[gi] and NORM_MEMORIES[gi] in c:
                return rank
    return None


def main():
    orig = call("EMBEDDING_STATUS")["backend"]
    print(f"\n{'='*100}\nReal-world embedder retrieval eval — {len(MEMORIES)} memories, {len(QUERIES)} queries")
    print(f"{'='*100}\nSaved active backend: {orig}\n")
    per_query = {be: [] for be in BACKENDS}   # (query, hard, rank)
    try:
        # Plant the corpus (age 0 so recency is neutral across all memories).
        call("MEMORY_PLANT_AGED_CLEANUP")
        print(f"Planting {len(MEMORIES)} memories...")
        for m in MEMORIES:
            call(f"MEMORY_PLANT_AGED:0:{m}")
        # Fill every backend's column for the planted rows.
        print("Backfilling all embedder columns...")
        call("BACKFILL_EMBEDDINGS:all", timeout=600)

        for be in BACKENDS:
            call(f"SET_EMBEDDING_BACKEND:{be}")
            time.sleep(4)
            call(f"EMBED_PROBE:{be}:warm up")   # ensure loaded
            time.sleep(2)
            for (q, gold, hard) in QUERIES:
                r = call(f"MEMORY_SEARCH_DEBUG:{q}")
                entries = r.get("entries", [])
                rank = gold_rank(entries, gold)
                per_query[be].append((q, hard, rank))
    finally:
        call(f"SET_EMBEDDING_BACKEND:{orig}")
        call("MEMORY_PLANT_AGED_CLEANUP")
        print(f"Restored active backend: {call('EMBEDDING_STATUS')['backend']}; plants removed.\n")

    # Score.
    def metrics(rows):
        ranks = [rk for (_, _, rk) in rows]
        n = len(ranks)
        r1 = sum(1 for rk in ranks if rk == 1) / n
        r3 = sum(1 for rk in ranks if rk and rk <= 3) / n
        r5 = sum(1 for rk in ranks if rk and rk <= 5) / n
        mrr = statistics.mean([(1.0 / rk) if rk else 0.0 for rk in ranks])
        return r1, r3, r5, mrr

    print(f"{'='*100}\nRESULTS (higher = better)\n{'='*100}")
    print(f"{'backend':13s} {'Recall@1':>9s} {'Recall@3':>9s} {'Recall@5':>9s} {'MRR':>7s}")
    summary = {}
    for be in BACKENDS:
        r1, r3, r5, mrr = metrics(per_query[be])
        summary[be] = (r1, r3, r5, mrr)
        print(f"{be:13s} {r1:>9.2f} {r3:>9.2f} {r5:>9.2f} {mrr:>7.3f}")

    # Hard-subset breakdown (paraphrase / distractor queries).
    print(f"\n--- HARD queries only (paraphrase / distractor; n={sum(1 for _,_,h in [(q,g,h) for q,g,h in QUERIES] if h)}) ---")
    print(f"{'backend':13s} {'Recall@1':>9s} {'Recall@3':>9s} {'MRR':>7s}")
    for be in BACKENDS:
        hard_rows = [(q, h, rk) for (q, h, rk) in per_query[be] if h]
        r1, r3, r5, mrr = metrics(hard_rows)
        print(f"{be:13s} {r1:>9.2f} {r3:>9.2f} {mrr:>7.3f}")

    # Per-query rank grid (spot bad cases).
    print(f"\n--- per-query rank (— = not in top-20) ---")
    print(f"{'query':52s} {'nl':>4s} {'nom':>4s} {'mxb':>4s}")
    for i, (q, gold, hard) in enumerate(QUERIES):
        cells = []
        for be in BACKENDS:
            rk = per_query[be][i][2]
            cells.append(f"{rk:>4}" if rk else "   —")
        tag = "*" if hard else " "
        print(f"{tag}{q[:51]:51s} {' '.join(cells)}")

    best = max(summary.items(), key=lambda kv: kv[1][3])[0]
    print(f"\nBest MRR: {best}")


if __name__ == "__main__":
    main()
