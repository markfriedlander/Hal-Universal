#!/usr/bin/env python3
"""
Recency-ranking regression test — guards against Bug 4 (orphaned recency).

THE BUG THIS GUARDS: for a stretch, Hal's recency / half-life decay was
*orphaned* — `calculateRecencyScore()` existed and was correct, but no
retrieval path called it. The RRF fusion ranked by semantic + BM25 rank
only, so the `recencyWeight` / `recencyHalfLifeDays` / `recencyFloor`
settings were inert: moving the sliders changed nothing about what got
retrieved. A pure unit test of the decay function would NOT have caught
this (the function was fine; it just wasn't wired in). So this test
exercises the LIVE retrieval path (searchUnifiedContent via
MEMORY_SEARCH_DEBUG) and asserts that changing recencyWeight actually
changes the blended relevance score and the resulting order.

HOW IT WORKS: plants two conversation rows with identical query-relevant
tokens but very different ages (one ~365 days old, one fresh) using the
test-only MEMORY_PLANT_AGED verb, then queries them at recencyWeight=0
(recency inert) and at recencyWeight=0.95 (recency dominant), and checks:

  A. Both plants are retrieved in both passes.
  B. PRIMARY GUARD — turning recency ON decays the OLD row's blended
     score well below its recency-OFF score. On an UNFIXED (orphaned)
     build these scores are identical → this assertion fails. This is
     the assertion that would have caught the original disconnect.
  C. ORDER — with recency ON, the FRESH row ranks above the OLD row.

NON-DESTRUCTIVE: plants live under source_id "recency-regression-test"
and are removed via MEMORY_PLANT_AGED_CLEANUP in a finally block; the
test also saves and restores your real recencyWeight / recencyHalfLife
settings so it leaves the app exactly as it found it. Safe to run
against the real on-device corpus — the query terms are nonsense that
won't collide with organic memories.

Usage:
    python3 tests/recency_regression.py                 # device
    HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/recency_regression.py   # sim
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

# Distinctive nonsense tokens so the plants dominate retrieval for this
# query without colliding with anything organic in the real corpus.
QUERY = "zorblaxian sigil"
OLD_CONTENT = "The zorblaxian sigil marker alpha endures."   # backdated
NEW_CONTENT = "The zorblaxian sigil marker bravo endures."   # fresh
OLD_MARK = "marker alpha"
NEW_MARK = "marker bravo"

OLD_AGE_DAYS = 365
TEST_HALFLIFE_DAYS = 30      # short so a 365-day row decays to the floor
HIGH_WEIGHT = 0.95


def call(command):
    body = json.dumps({"command": command}).encode("utf-8")
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command",
        data=body,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def find_entry(entries, mark):
    """Return (rank, entry) for the plant whose content contains `mark`."""
    for rank, e in enumerate(entries, start=1):
        content = e.get("contentPreview", "") or e.get("content", "")
        if mark.lower() in content.lower():
            return rank, e
    return None, None


def search():
    return call(f"MEMORY_SEARCH_DEBUG:{QUERY}").get("entries", [])


def main():
    print(f"\n{'=' * 100}")
    print("Recency-ranking regression test (Bug 4 guard)")
    print(f"{'=' * 100}\n")

    # Save the real settings so we can restore them no matter what.
    state = call("GET_STATE")
    orig_weight = float(state.get("recencyWeight", 0.3))
    orig_halflife = float(state.get("recencyHalfLifeDays", 90.0))
    print(f"Saved current settings: recencyWeight={orig_weight}, recencyHalfLifeDays={orig_halflife}")

    failures = []
    try:
        # Clean slate for our own plants, then plant the age gap.
        call("MEMORY_PLANT_AGED_CLEANUP")
        call(f"MEMORY_PLANT_AGED:{OLD_AGE_DAYS}:{OLD_CONTENT}")
        call(f"MEMORY_PLANT_AGED:0:{NEW_CONTENT}")
        call(f"SET_RECENCY_HALFLIFE:{TEST_HALFLIFE_DAYS}")

        # Pass 1 — recency OFF (pure rank fusion).
        call("SET_RECENCY_WEIGHT:0.0")
        e0 = search()
        old_rank0, old0 = find_entry(e0, OLD_MARK)
        new_rank0, new0 = find_entry(e0, NEW_MARK)

        # Pass 2 — recency ON (dominant).
        call(f"SET_RECENCY_WEIGHT:{HIGH_WEIGHT}")
        e1 = search()
        old_rank1, old1 = find_entry(e1, OLD_MARK)
        new_rank1, new1 = find_entry(e1, NEW_MARK)

        # --- Assertion A: both plants retrieved in both passes ---
        if not (old0 and new0 and old1 and new1):
            failures.append(
                "A: plants not retrieved in both passes "
                f"(w0 old={old_rank0} new={new_rank0}; w{HIGH_WEIGHT} old={old_rank1} new={new_rank1})"
            )
            # Can't evaluate B/C without the entries.
            raise AssertionError("plants missing from retrieval")

        old_score0 = float(old0["relevanceScore"])
        old_score1 = float(old1["relevanceScore"])
        new_score0 = float(new0["relevanceScore"])
        new_score1 = float(new1["relevanceScore"])

        print(f"\nOLD row (age {OLD_AGE_DAYS}d):  score w0={old_score0:.4f} (rank {old_rank0})  "
              f"->  w{HIGH_WEIGHT}={old_score1:.4f} (rank {old_rank1})")
        print(f"NEW row (fresh):      score w0={new_score0:.4f} (rank {new_rank0})  "
              f"->  w{HIGH_WEIGHT}={new_score1:.4f} (rank {new_rank1})")

        # --- Assertion B (PRIMARY GUARD): recency ON decays the OLD score ---
        # With halfLife=30d a 365-day row hits the recency floor, so its
        # blended score should drop far below the recency-OFF score. On an
        # orphaned build the two scores are identical.
        if not (old_score1 < old_score0 * 0.9):
            failures.append(
                f"B: OLD score did not decay when recency turned on "
                f"(w0={old_score0:.4f}, w{HIGH_WEIGHT}={old_score1:.4f}) — "
                f"recency appears ORPHANED (Bug 4 regressed)."
            )
        else:
            print(f"\n[PASS] B: OLD score decayed {old_score0:.4f} -> {old_score1:.4f} "
                  f"({old_score1 / old_score0:.2%} of original) when recency turned on.")

        # --- Assertion C: with recency ON, the FRESH row ranks above OLD ---
        if not (new_rank1 < old_rank1):
            failures.append(
                f"C: with recency ON, fresh row did not rank above old row "
                f"(new rank {new_rank1}, old rank {old_rank1})."
            )
        else:
            print(f"[PASS] C: fresh row ranks above old row with recency ON "
                  f"(new rank {new_rank1} < old rank {old_rank1}).")

    finally:
        # Always restore: remove our plants and put the user's settings back.
        call("MEMORY_PLANT_AGED_CLEANUP")
        call(f"SET_RECENCY_WEIGHT:{orig_weight}")
        call(f"SET_RECENCY_HALFLIFE:{orig_halflife}")
        print(f"\nRestored settings: recencyWeight={orig_weight}, recencyHalfLifeDays={orig_halflife}")
        print("Removed test plants.")

    print(f"\n{'=' * 100}")
    if failures:
        print(f"RESULT: FAIL ({len(failures)} assertion(s))")
        for f in failures:
            print(f"  - {f}")
        print(f"{'=' * 100}\n")
        raise SystemExit(1)
    print("RESULT: PASS — recency is wired into live retrieval ranking.")
    print(f"{'=' * 100}\n")


if __name__ == "__main__":
    main()
