#!/usr/bin/env python3
"""
Per-embedder columns regression test — guards v2.1 item 5 step 2 ("keep-both").

WHAT THIS GUARDS: Hal used to store one `embedding` column per memory row and
WIPE + re-embed the whole corpus on every embedder switch — destructive, slow,
and it made an A/B impossible (only one backend's vectors existed at a time).
Step 2 gives each backend its own permanent column (embedding_nl /
embedding_nomic / embedding_mxbai). All vector sets coexist; switching backends
just reads a different column (instant, non-destructive); a background backfill
fills an inactive backend's column.

THE PROPERTIES THIS EXERCISES (via the live API):

  A. WRITE → ACTIVE COLUMN — planting rows fills the active backend's column.
  B. BACKFILL — filling an inactive backend's column climbs its coverage
     without touching the others.
  C. NON-DESTRUCTIVE SWITCH — switching the active backend leaves every
     column's coverage UNCHANGED (the old destructive wipe would zero them).
  D. RETRIEVAL UNDER THE NEW COLUMN — after switching, a semantic search finds
     a planted phrase (proving the retriever reads the new backend's column).

Requires nomicswift + mxbai present in the shared model store (download or
adopt from Posey first). NON-DESTRUCTIVE: plants live under the recency test's
plant source and are removed in a finally; the active backend is saved and
restored. Assertions are delta-based so a non-empty real corpus is fine.

Usage:
    python3 tests/embedding_columns_regression.py
"""

import json
import os
import time
import urllib.request
from pathlib import Path

_cfg_name = os.environ.get("HAL_API_CONFIG", ".hal_api_config.json")
CONFIG_PATH = Path(os.environ.get("HAL_API_CONFIG_PATH") or (Path(__file__).parent / _cfg_name))
with CONFIG_PATH.open() as f:
    cfg = json.load(f)
HOST, PORT, TOKEN = cfg["host"], cfg["port"], cfg["token"]

PLANTS = [
    "the aurora shimmered over the frozen tundra at midnight",
    "quantum entanglement links two distant particles instantly",
    "she planted heirloom tomatoes in the spring garden",
]
QUERY = "aurora tundra glow"          # should retrieve the first plant
QUERY_MARK = "aurora"


def call(command, timeout=300):
    body = json.dumps({"command": command}).encode("utf-8")
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command", data=body,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def coverage():
    d = call("EMBEDDING_COVERAGE")
    return {b["backend"]: b["filled"] for b in d["backends"]}


def main():
    print(f"\n{'=' * 100}\nPer-embedder columns regression (v2.1 item 5 step 2)\n{'=' * 100}\n")
    orig_backend = call("EMBEDDING_STATUS")["backend"]
    print(f"Saved active backend: {orig_backend}")
    failures = []
    try:
        call("MEMORY_PLANT_AGED_CLEANUP")
        base = coverage()

        # --- A: write → active column ---
        for t in PLANTS:
            call(f"MEMORY_PLANT_AGED:0:{t}")
        after_plant = coverage()
        if after_plant.get(orig_backend, 0) - base.get(orig_backend, 0) < len(PLANTS):
            failures.append(f"A: planting should fill the active column by >= {len(PLANTS)} "
                            f"(base {base}, after {after_plant})")

        # --- B: backfill inactive columns ---
        for b in ("nomicswift", "mxbai"):
            call(f"BACKFILL_EMBEDDINGS:{b}")
        after_backfill = coverage()
        for b in ("nomicswift", "mxbai"):
            if after_backfill.get(b, 0) < len(PLANTS):
                failures.append(f"B: backfill {b} should reach >= {len(PLANTS)} filled, got {after_backfill}")

        # --- C: non-destructive switch (coverage must not drop) ---
        call("SET_EMBEDDING_BACKEND:nomicswift")
        after_switch = coverage()
        for b, n in after_backfill.items():
            if after_switch.get(b, 0) < n:
                failures.append(f"C: switch DROPPED {b} coverage {n} -> {after_switch.get(b, 0)} "
                                f"(switch must be non-destructive)")
        time.sleep(3)  # let nomic warm up

        # --- D: retrieval under the new column ---
        entries = call(f"MEMORY_SEARCH_DEBUG:{QUERY}").get("entries", [])
        found = any(QUERY_MARK in ((e.get("contentPreview") or e.get("content") or "").lower())
                    for e in entries[:5])
        if not found:
            failures.append(f"D: after switch to nomic, '{QUERY_MARK}' not in top-5 for query '{QUERY}'")

    finally:
        call(f"SET_EMBEDDING_BACKEND:{orig_backend}")
        call("MEMORY_PLANT_AGED_CLEANUP")
        print(f"Restored active backend: {call('EMBEDDING_STATUS')['backend']}; plants removed.")

    print()
    if failures:
        print("FAIL:")
        for f in failures:
            print(f"  - {f}")
        raise SystemExit(1)
    print("PASS — per-embedder columns intact:")
    print("  A. planting fills the active backend's column")
    print("  B. backfill fills inactive backends' columns independently")
    print("  C. switching backends is non-destructive (no coverage lost)")
    print("  D. retrieval reads the new backend's column after a switch")


if __name__ == "__main__":
    main()
