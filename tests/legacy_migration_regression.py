#!/usr/bin/env python3
"""
Legacy → shared-store migration regression test — guards v2.1 item 4 increment #2.

WHAT THIS GUARDS: v2.0 stored MLX models + the Nomic asset in the per-app
`Caches/huggingface/models/<org>/<name>/`. v2.1 reads from the App-Group
shared store, so a v2.0 user who upgrades would find the shared store empty
and appear to have lost every download — a multi-GB re-fetch. The launch-time
migration (`MaintenanceTasks.migrateLegacyCachesModelsToSharedStore`) moves
their existing models into the shared store so they carry forward.

THE BRANCHES THIS EXERCISES (via the test-only LEGACY_MIGRATION API verb, since
the dev device never used the legacy location so real migration is a no-op):

  A. MOVE — a model only in legacy Caches is moved into the shared store,
     claimed for Hal, and the legacy copy is gone.
  B. RECONCILE — a model already present in the shared store (e.g. Posey put
     it there) has its redundant legacy duplicate removed, shared copy kept.
  C. RETIRED SKIP — a retired backend (EmbeddingGemma) found in legacy is
     deleted, not migrated.

NON-DESTRUCTIVE: everything runs against fake model ids that can't collide
with a real model, and a finally block removes them from both locations. Real
models are asserted untouched at the end.

Usage:
    python3 tests/legacy_migration_regression.py                 # device
    HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/legacy_migration_regression.py   # sim
"""

import json
import os
import urllib.request
from pathlib import Path

_cfg_name = os.environ.get("HAL_API_CONFIG", ".hal_api_config.json")
CONFIG_PATH = Path(os.environ.get("HAL_API_CONFIG_PATH") or (Path(__file__).parent / _cfg_name))
with CONFIG_PATH.open() as f:
    cfg = json.load(f)
HOST, PORT, TOKEN = cfg["host"], cfg["port"], cfg["token"]

MOVE = "test-org/legacy-move-fake"
RECON = "test-org/legacy-reconcile-fake"
RETIRED = "mlx-community/embeddinggemma-300m-4bit"  # in removedEmbeddingBackendModelIDs
HAL = "com.MarkFriedlander.Hal-Universal"


def call(command):
    body = json.dumps({"command": command}).encode("utf-8")
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command", data=body,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def state(repo):
    return call(f"LEGACY_MIGRATION QUERY:{repo}")["state"]


def main():
    print(f"\n{'=' * 100}\nLegacy → shared-store migration regression (v2.1 item 4 increment #2)\n{'=' * 100}\n")
    failures = []
    try:
        # Clean slate for all fakes.
        for r in (MOVE, RECON, RETIRED):
            call(f"LEGACY_MIGRATION CLEANUP:{r}")

        # --- A: MOVE ---
        call(f"LEGACY_MIGRATION PLANT:{MOVE}")
        s = state(MOVE)
        if not (s["legacyPresent"] and not s["sharedPresent"]):
            failures.append(f"A-setup: expected legacy-only before move, got {s}")
        call("LEGACY_MIGRATION RUN")
        s = state(MOVE)
        if not (not s["legacyPresent"] and s["sharedPresent"] and HAL in s["claimants"]):
            failures.append(f"A: expected moved→shared + Hal claim, got {s}")

        # --- B: RECONCILE (shared already has it) ---
        call(f"LEGACY_MIGRATION PLANT:{RECON}")
        call("LEGACY_MIGRATION RUN")            # first move into shared
        call(f"LEGACY_MIGRATION PLANT:{RECON}")  # re-plant a legacy duplicate
        s = state(RECON)
        if not (s["legacyPresent"] and s["sharedPresent"]):
            failures.append(f"B-setup: expected legacy dup + shared present, got {s}")
        call("LEGACY_MIGRATION RUN")
        s = state(RECON)
        if not (not s["legacyPresent"] and s["sharedPresent"]):
            failures.append(f"B: expected legacy dup removed, shared kept, got {s}")

        # --- C: RETIRED SKIP ---
        call(f"LEGACY_MIGRATION PLANT:{RETIRED}")
        call("LEGACY_MIGRATION RUN")
        s = state(RETIRED)
        if not (not s["legacyPresent"] and not s["sharedPresent"]):
            failures.append(f"C: retired backend should be removed, not migrated, got {s}")

    finally:
        for r in (MOVE, RECON, RETIRED):
            call(f"LEGACY_MIGRATION CLEANUP:{r}")

    # Real models untouched.
    present = {m["id"] for m in call("SHARED_MODELS")["present"]}
    for fake in (MOVE, RECON):
        if fake in present:
            failures.append(f"cleanup: fake {fake} still present in shared store")

    print()
    if failures:
        print("FAIL:")
        for f in failures:
            print(f"  - {f}")
        raise SystemExit(1)
    print("PASS — legacy migration intact:")
    print("  A. move: legacy-only model → shared store + Hal claim")
    print("  B. reconcile: legacy duplicate removed when shared copy exists")
    print("  C. retired backend removed, not migrated")


if __name__ == "__main__":
    main()
