#!/usr/bin/env python3
"""
Full-pipeline RAG eval — measures the actual production retrieval (semantic + BM25 + RRF).

Uses MEMORY_SEARCH_DEBUG (the real searchUnifiedContent path) rather than
MEMORY_SIMILARITY_DEBUG (raw cosine only). This is the metric that matters.

Ground truth: same 10 queries as rag_threshold_eval.py. For each, reports the
plant's rank in the full-pipeline top-N entries returned by MEMORY_SEARCH_DEBUG.
"""

import json
import urllib.request
from pathlib import Path

import os
_cfg_name = os.environ.get("HAL_API_CONFIG", ".hal_api_config.json")
CONFIG_PATH = Path(os.environ.get("HAL_API_CONFIG_PATH") or (Path(__file__).parent / _cfg_name))
with CONFIG_PATH.open() as f:
    cfg = json.load(f)
HOST = cfg["host"]
PORT = cfg["port"]
TOKEN = cfg["token"]

GROUND_TRUTH = [
    ("What's my dog's name?", "Pepper"),
    ("Where do I work?", "Anthropic"),
    ("What restaurant do I love?", "Tartine"),
    ("Tell me about my upcoming travel plans.", "Iceland"),
    ("Where do I live now?", "Berkeley"),
    ("What instrument am I learning?", "cello"),
    ("What's my favorite book?", "Karamazov"),
    ("What's my cat called?", "Atlas"),
    ("Do I have any running events coming up?", "marathon"),
    ("What kind of car do I have?", "Subaru"),
]


def call_search_debug(query):
    body = json.dumps({"command": f"MEMORY_SEARCH_DEBUG:{query}"}).encode("utf-8")
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command",
        data=body,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def find_plant_rank(entries, plant_substr):
    for rank, e in enumerate(entries, start=1):
        content = e.get("contentPreview", "") or e.get("content", "")
        if plant_substr.lower() in content.lower():
            return rank, e
    return None, None


def main():
    print(f"\n{'=' * 100}")
    print(f"Full-pipeline RAG evaluation (semantic + BM25 + RRF)")
    print(f"{'=' * 100}\n")

    in_top_10 = 0
    in_top_5 = 0
    in_top_1 = 0
    results = []

    for query, plant_substr in GROUND_TRUTH:
        result = call_search_debug(query)
        entries = result.get("entries", [])
        rank, entry = find_plant_rank(entries, plant_substr)
        results.append((query, plant_substr, rank, len(entries)))

        print(f"Q: \"{query}\"")
        print(f"   Plant '{plant_substr}': rank {rank if rank else 'NOT IN RESULTS'} (of {len(entries)} returned)")
        if entry:
            content = entry.get("contentPreview", "") or entry.get("content", "")
            print(f"   Content: '{content[:90]}'")
            print(f"   semRank={entry.get('semanticRank')}, bm25Rank={entry.get('bm25Rank')}, rrf={entry.get('rrfScore', 'n/a')}")

        if rank is not None:
            if rank == 1: in_top_1 += 1
            if rank <= 5: in_top_5 += 1
            if rank <= 10: in_top_10 += 1
        print()

    print(f"\n{'=' * 100}")
    print(f"AGGREGATE")
    print(f"{'=' * 100}")
    print(f"  Top-1  recall: {in_top_1}/{len(GROUND_TRUTH)}")
    print(f"  Top-5  recall: {in_top_5}/{len(GROUND_TRUTH)}")
    print(f"  Top-10 recall: {in_top_10}/{len(GROUND_TRUTH)}")
    print()


if __name__ == "__main__":
    main()
