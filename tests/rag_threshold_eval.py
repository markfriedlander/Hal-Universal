#!/usr/bin/env python3
"""
RAG threshold evaluation against a realistic 70-row corpus.

Assumes the device has been NUCLEAR_RESET'd and INJECT_REALISTIC_TEST_CORPUS'd.
The corpus is defined in `MemoryStore.injectRealisticTestCorpus` (Hal.swift).
The first 10 (user, assistant) pairs are PLANTED facts; the next 50 entries
are general background content.

For each of 10 recall queries (worded naturally, NOT echoing the plant), this
script calls MEMORY_SIMILARITY_DEBUG and analyzes:
  - the plant's similarity score for that query (and rank in sorted results)
  - the highest non-plant score (worst false positive)
  - at each threshold (0.25 / 0.35 / 0.45 / 0.50), whether the plant survives
    and how many noise rows also survive
"""

import json
import sys
import urllib.request
from pathlib import Path

CONFIG_PATH = Path(__file__).parent / ".hal_api_config.json"
with CONFIG_PATH.open() as f:
    cfg = json.load(f)
HOST = cfg["host"]
PORT = cfg["port"]
TOKEN = cfg["token"]

# Ground truth: (recall_query, expected_plant_substring)
# The substring must appear in either the user plant turn OR the assistant
# restatement — whichever scores higher is what we care about.
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

THRESHOLDS = [0.25, 0.35, 0.45, 0.50]


def call_similarity_debug(query):
    body = json.dumps({"command": f"MEMORY_SIMILARITY_DEBUG:{query}"}).encode("utf-8")
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command",
        data=body,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def find_plant(entries, plant_substr):
    """Return (rank, score, content) for the highest-scoring row containing the substring.
    Rank is 1-based among ALL rows sorted by score desc (which entries already is)."""
    for rank, e in enumerate(entries, start=1):
        if plant_substr.lower() in e["contentPreview"].lower():
            return rank, e["score"], e["contentPreview"]
    return None, None, None


def main():
    print(f"\n{'=' * 100}")
    print(f"RAG threshold evaluation — 70-row corpus, 10 ground-truth queries")
    print(f"Thresholds tested: {', '.join(str(t) for t in THRESHOLDS)}")
    print(f"{'=' * 100}\n")

    per_query_results = []

    for query, plant_substr in GROUND_TRUTH:
        result = call_similarity_debug(query)
        entries = result.get("entries", [])
        plant_rank, plant_score, plant_content = find_plant(entries, plant_substr)

        # Highest non-plant score (worst false positive)
        non_plant_top = None
        for e in entries:
            if plant_substr.lower() not in e["contentPreview"].lower():
                non_plant_top = (e["score"], e["contentPreview"])
                break

        # At each threshold: count rows >= threshold, count noise (non-plant) >= threshold
        threshold_results = {}
        for t in THRESHOLDS:
            passing = [e for e in entries if e["score"] >= t]
            noise_passing = [e for e in passing if plant_substr.lower() not in e["contentPreview"].lower()]
            plant_passes = plant_score is not None and plant_score >= t
            threshold_results[t] = {
                "plant_passes": plant_passes,
                "total_passing": len(passing),
                "noise_passing": len(noise_passing),
                "noise_in_top_10": sum(1 for e in passing[:10] if plant_substr.lower() not in e["contentPreview"].lower()),
            }

        per_query_results.append({
            "query": query,
            "plant_substr": plant_substr,
            "plant_rank": plant_rank,
            "plant_score": plant_score,
            "plant_content": plant_content,
            "non_plant_top": non_plant_top,
            "thresholds": threshold_results,
        })

        # Per-query summary
        print(f"Q: \"{query}\"")
        print(f"   Plant: rank {plant_rank}, score {plant_score:.4f}, content: '{plant_content[:80] if plant_content else 'NOT FOUND'}'")
        if non_plant_top:
            print(f"   Top non-plant noise: score {non_plant_top[0]:.4f}, content: '{non_plant_top[1][:80]}'")
        for t in THRESHOLDS:
            r = threshold_results[t]
            print(f"   @{t:.2f}: plant {'PASS' if r['plant_passes'] else 'FAIL'} | {r['total_passing']} rows pass ({r['noise_passing']} noise) | top-10 noise: {r['noise_in_top_10']}")
        print()

    # Aggregate
    print(f"\n{'=' * 100}")
    print(f"AGGREGATE — across {len(GROUND_TRUTH)} queries")
    print(f"{'=' * 100}\n")

    print(f"{'Threshold':>10} | {'Plant recall':>14} | {'Avg noise passing':>18} | {'Avg top-10 noise':>18}")
    print(f"{'-' * 10} | {'-' * 14} | {'-' * 18} | {'-' * 18}")
    for t in THRESHOLDS:
        plant_pass_count = sum(1 for r in per_query_results if r["thresholds"][t]["plant_passes"])
        avg_noise = sum(r["thresholds"][t]["noise_passing"] for r in per_query_results) / len(per_query_results)
        avg_top10_noise = sum(r["thresholds"][t]["noise_in_top_10"] for r in per_query_results) / len(per_query_results)
        print(f"{t:>10.2f} | {plant_pass_count}/{len(GROUND_TRUTH):>2} {'':>9} | {avg_noise:>18.2f} | {avg_top10_noise:>18.2f}")

    print()
    print("Plant scores summary:")
    plant_scores = [r["plant_score"] for r in per_query_results if r["plant_score"] is not None]
    if plant_scores:
        print(f"  Min: {min(plant_scores):.4f}")
        print(f"  Max: {max(plant_scores):.4f}")
        print(f"  Mean: {sum(plant_scores) / len(plant_scores):.4f}")
        plant_scores_sorted = sorted(plant_scores)
        print(f"  All (sorted): {[f'{s:.3f}' for s in plant_scores_sorted]}")

    non_plant_tops = [r["non_plant_top"][0] for r in per_query_results if r["non_plant_top"] is not None]
    if non_plant_tops:
        print("\nTop non-plant scores per query (worst false positives):")
        print(f"  Min: {min(non_plant_tops):.4f}")
        print(f"  Max: {max(non_plant_tops):.4f}")
        print(f"  Mean: {sum(non_plant_tops) / len(non_plant_tops):.4f}")
        non_plant_tops_sorted = sorted(non_plant_tops, reverse=True)
        print(f"  All (sorted desc): {[f'{s:.3f}' for s in non_plant_tops_sorted]}")


if __name__ == "__main__":
    main()
