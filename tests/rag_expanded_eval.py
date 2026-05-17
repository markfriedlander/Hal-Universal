#!/usr/bin/env python3
"""
Full-pipeline RAG eval WITH LLM-driven query expansion (2026-05-17).

Uses MEMORY_SEARCH_EXPANDED, which runs the two-pass chat search path:
  1. First pass without expansion.
  2. If top-1 RRF < 0.020 AND !isEntityMatch, ask the active LLM for
     related terms (cached in SQLite by query hash).
  3. Second pass with those terms ORed into BM25.
  4. Whichever pass produced the higher top-1 RRF wins.

Reports per-query plant rank, whether expansion fired, what terms came
back, and whether the expanded pass improved over the original. Prints
side-by-side rank-only table at the end.
"""

import json
import os
import urllib.request
from pathlib import Path

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


def post(command, timeout=120):
    body = json.dumps({"command": command}).encode("utf-8")
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command",
        data=body,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def find_plant_rank(entries, plant_substr):
    for rank, e in enumerate(entries, start=1):
        content = e.get("contentPreview", "") or e.get("content", "")
        if plant_substr.lower() in content.lower():
            return rank
    return None


def main():
    print(f"\n{'=' * 100}")
    print("Full-pipeline RAG eval — Nomic + LLM-driven query expansion")
    print(f"{'=' * 100}\n")

    in_top_10 = 0
    in_top_5 = 0
    in_top_1 = 0
    rows = []

    for query, plant_substr in GROUND_TRUTH:
        r = post(f"MEMORY_SEARCH_EXPANDED:{query}")
        entries = r.get("entries", [])
        expansion = r.get("expansion", {})
        rank = find_plant_rank(entries, plant_substr)
        triggered = expansion.get("triggered", False)
        improved = expansion.get("improved", False)
        terms = expansion.get("terms", [])

        print(f"Q: \"{query}\"")
        print(f"   Plant '{plant_substr}': rank {rank if rank else 'NOT IN RESULTS'} (of {len(entries)} returned)")
        if triggered:
            sample_terms = ", ".join(terms[:8]) if terms else "(none)"
            print(f"   Expansion triggered. terms=[{sample_terms}]  improved={improved}")
        else:
            print("   Expansion NOT triggered (initial retrieval was strong enough)")
        print()

        if rank is not None:
            if rank == 1: in_top_1 += 1
            if rank <= 5: in_top_5 += 1
            if rank <= 10: in_top_10 += 1
        rows.append((query, plant_substr, rank, triggered, improved, terms))

    print(f"\n{'=' * 100}")
    print("AGGREGATE")
    print(f"{'=' * 100}")
    print(f"  Top-1  recall: {in_top_1}/{len(GROUND_TRUTH)}")
    print(f"  Top-5  recall: {in_top_5}/{len(GROUND_TRUTH)}")
    print(f"  Top-10 recall: {in_top_10}/{len(GROUND_TRUTH)}")
    print()
    print("Expansion stats:")
    triggered_count = sum(1 for r in rows if r[3])
    improved_count = sum(1 for r in rows if r[4])
    print(f"  Triggered: {triggered_count}/{len(rows)}")
    print(f"  Improved:  {improved_count}/{len(rows)}")
    print()


if __name__ == "__main__":
    main()
