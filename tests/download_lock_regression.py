#!/usr/bin/env python3
"""
Cross-app download-lock regression test — guards v2.1 item 4 increment #3.

WHAT THIS GUARDS: Hal and Posey share one on-disk model store (App Group
`group.com.MarkFriedlander.aifamily`). Without a lock, both apps can fetch
the same multi-GB repo at once — wasteful and confusing (two progress
bars). The fix is a per-model lock in the shared store
(`SharedModelStore` BLOCK SMS.4): before downloading, an app claims the
slot; a second app that sees a fresh foreign lock WAITS and adopts the
finished copy instead of duplicating it, and takes over only if the
holder's lock goes stale (crash / force-quit).

THE DECISION LOGIC THIS EXERCISES (the risky, branchy part):

  A. A model with a FRESH foreign lock cannot be acquired (granted:false)
     — this is what makes the second app wait instead of duplicating.
  B. A model with a STALE foreign lock (older than staleSeconds) CAN be
     acquired (granted:true) and ownership transfers to us — this is the
     take-over-after-crash backstop.
  C. Release removes our lock cleanly.
  D. A free slot is immediately acquirable (granted:true).

This drives the same code path production uses, via the read-only /
test-only `DOWNLOAD_LOCK` API verb (QUERY / PLANT / ACQUIRE / RELEASE /
CLEAR). It does NOT run a real multi-GB download — the full
wait→adopt→take-over orchestration around this logic
(`awaitSharedDownloadThenAdopt`) needs an absent model plus a real or
simulated concurrent download and is spot-checked with the two real apps.
This test locks in the decision logic those branches hinge on.

NON-DESTRUCTIVE: plants live under a nonexistent test model id so they
can never collide with a real model or a real in-flight download, and a
finally block clears them. Safe to run against the device.

Usage:
    python3 tests/download_lock_regression.py                 # device
    HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/download_lock_regression.py   # sim
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

# A model id that does NOT exist in the catalog or on disk, so planting a
# lock on it can never interfere with a real model or a real download.
TEST_MODEL = "test-org/download-lock-regression-fake"
POSEY = "com.MarkFriedlander.Posey"


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


def lock_holder(model):
    """Return the holder bundle id currently recorded for `model`, or None."""
    q = call("DOWNLOAD_LOCK QUERY")
    for lk in q.get("locks", []):
        if lk.get("modelID") == model:
            return lk.get("holder")
    return None


def main():
    print(f"\n{'=' * 100}")
    print("Cross-app download-lock regression test (v2.1 item 4 increment #3)")
    print(f"{'=' * 100}\n")

    stale = int(call("DOWNLOAD_LOCK QUERY").get("staleSeconds", 600))
    print(f"Reported staleSeconds = {stale}")
    over_stale = stale + 100

    failures = []
    try:
        # Make sure our fake model starts with no lock.
        call(f"DOWNLOAD_LOCK RELEASE:{TEST_MODEL}")

        # --- D: a free slot is acquirable ---
        r = call(f"DOWNLOAD_LOCK ACQUIRE:{TEST_MODEL}")
        if r.get("granted") is not True:
            failures.append(f"D: free slot should be acquirable, got granted={r.get('granted')}")
        # release it again for the rest of the test
        call(f"DOWNLOAD_LOCK RELEASE:{TEST_MODEL}")

        # --- A: fresh foreign lock blocks acquire (→ the app waits) ---
        call(f"DOWNLOAD_LOCK PLANT:{TEST_MODEL}:{POSEY}")  # age 0 = fresh
        r = call(f"DOWNLOAD_LOCK ACQUIRE:{TEST_MODEL}")
        if r.get("granted") is not False:
            failures.append(f"A: fresh foreign lock must block acquire, got granted={r.get('granted')}")
        if lock_holder(TEST_MODEL) != POSEY:
            failures.append(f"A: holder should still be Posey after a blocked acquire, got {lock_holder(TEST_MODEL)}")

        # --- B: stale foreign lock is takeable (→ take-over backstop) ---
        call(f"DOWNLOAD_LOCK PLANT:{TEST_MODEL}:{POSEY}:{over_stale}")
        r = call(f"DOWNLOAD_LOCK ACQUIRE:{TEST_MODEL}")
        if r.get("granted") is not True:
            failures.append(f"B: stale foreign lock must be takeable, got granted={r.get('granted')}")
        holder = lock_holder(TEST_MODEL)
        if holder != "com.MarkFriedlander.Hal-Universal":
            failures.append(f"B: ownership should transfer to Hal after take-over, got holder={holder}")

        # --- C: release clears our lock ---
        call(f"DOWNLOAD_LOCK RELEASE:{TEST_MODEL}")
        if lock_holder(TEST_MODEL) is not None:
            failures.append(f"C: release must clear the lock, holder still {lock_holder(TEST_MODEL)}")

    finally:
        # Leave no trace of the fake model's lock.
        call(f"DOWNLOAD_LOCK RELEASE:{TEST_MODEL}")

    print()
    if failures:
        print("FAIL:")
        for f in failures:
            print(f"  - {f}")
        raise SystemExit(1)
    print("PASS — download-lock decision logic intact:")
    print("  A. fresh foreign lock blocks acquire (second app waits, no duplicate)")
    print("  B. stale foreign lock is takeable (crash take-over backstop)")
    print("  C. release clears the lock")
    print("  D. free slot is immediately acquirable")


if __name__ == "__main__":
    main()
