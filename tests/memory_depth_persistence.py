#!/usr/bin/env python3
"""
Per-model settings persistence regression test — guards Bug 1.

THE BUG THIS GUARDS: changing a per-model setting (memory depth, temperature,
recency, RAG limits) wrote the live value but did NOT persist a per-model
override unless the user later switched models. So a set-then-quit with no
model switch was clobbered on relaunch: at launch `applyEffectiveSettings`
re-derived each managed key from defaults+overrides, found no override, and
wrote the model's curated default back over the user's value.

THE FIX: `ModelSettingsStore.persistCurrentOverrides(for:)` records the edit
(as a delta from the curated default) at the moment it happens — from every
API setter, the settings-sheet dismiss, and app backgrounding — so the value
survives a restart. This test proves that on the LIVE path by actually
terminating and relaunching the app on the device.

WHAT IT CHECKS
  P (persistence, the fix): set memory depth to a value, hard-restart the app,
    assert it survived. Done TWICE with two different depths so the assertion
    is decisive without needing to know the curated default — an unfixed build
    reverts BOTH restarts to the same default, so the two results collapse to
    one value; a fixed build preserves each distinct value.
  G (global settings unaffected): toggle the GLOBAL Self-Knowledge setting,
    restart, assert it survived — confirming the global settings (which never
    had this bug) still persist and weren't disturbed by the fix.
  R (escape hatch): RESET_MODEL_SETTINGS returns depth to the curated default,
    and that reset persists across a restart.
  C (clamp): an over-max depth is clamped to the model's max, never stored raw.

NON-DESTRUCTIVE: saves all six managed values + the Self-Knowledge flag up
front and restores them in a finally block (the escape-hatch check clears the
active model's overrides, so full restore matters). Safe on the real corpus.

REQUIRES the device + the beta toolchain (it drives devicectl to restart the
app). Override via env vars if your setup differs:
    HAL_DEVICE_UDID, HAL_BUNDLE_ID, DEVELOPER_DIR

Usage:
    python3 tests/memory_depth_persistence.py
"""

import json
import os
import subprocess
import time
import urllib.request
from pathlib import Path

_cfg_name = os.environ.get("HAL_API_CONFIG", ".hal_api_config.json")
CONFIG_PATH = Path(os.environ.get("HAL_API_CONFIG_PATH") or (Path(__file__).parent / _cfg_name))
with CONFIG_PATH.open() as f:
    cfg = json.load(f)
HOST = cfg["host"]
PORT = cfg["port"]
TOKEN = cfg["token"]

DEVICE_UDID = os.environ.get("HAL_DEVICE_UDID", "D24FB384-9C55-5D33-9B0D-DAEBFA6528D6")
BUNDLE_ID = os.environ.get("HAL_BUNDLE_ID", "com.MarkFriedlander.Hal-Universal")
DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode-beta.app/Contents/Developer")

# The six managed per-model settings, keyed by their GET_STATE field, with the
# API verb that sets each — used for save/restore.
MANAGED = [
    ("memoryDepth", "SET_MEMORY_DEPTH"),
    ("temperature", "SET_TEMPERATURE"),
    ("recencyWeight", "SET_RECENCY_WEIGHT"),
    ("recencyHalfLifeDays", "SET_RECENCY_HALFLIFE"),
    ("maxRagSnippetsCharacters", "SET_MAX_RAG_CHARS"),
    ("ragDedupThreshold", "SET_RAG_DEDUP"),
]


def call(command, timeout=30):
    body = json.dumps({"command": command}).encode("utf-8")
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command",
        data=body,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_state():
    return call("GET_STATE")


def restart_app_and_wait():
    """Hard-terminate and cold-relaunch the app, then wait for the API antenna.

    devicectl's launch can transiently fail (exit 1) when it races the app —
    e.g. terminating while a multi-GB MLX model is mid-load — so retry a few
    times and surface stderr if it never succeeds."""
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    last_err = None
    for _ in range(4):
        try:
            subprocess.run(
                ["xcrun", "devicectl", "device", "process", "launch",
                 "--terminate-existing", "--device", DEVICE_UDID, BUNDLE_ID],
                env=env, check=True, capture_output=True, text=True,
            )
            break
        except subprocess.CalledProcessError as e:
            last_err = (e.stderr or e.stdout or str(e)).strip()
            time.sleep(3)
    else:
        raise RuntimeError(f"devicectl launch failed after retries: {last_err}")
    # Poll GET_STATE until the freshly-launched app's API is reachable. Give it
    # generous time — with an MLX model active the app does more at launch.
    for _ in range(25):
        time.sleep(2)
        try:
            s = get_state()
            if "memoryDepth" in s:
                return s
        except Exception:
            pass
    raise RuntimeError("app did not come back up after restart")


def main():
    print(f"\n{'=' * 100}")
    print("Per-model settings persistence regression test (Bug 1 guard)")
    print(f"{'=' * 100}\n")

    s0 = get_state()
    max_depth = int(s0["maxMemoryDepth"])
    orig = {field: s0[field] for field, _ in MANAGED}
    orig_selfknow = bool(s0["selfKnowledgeEnabled"])
    print(f"Model: {s0['modelID']}  |  maxMemoryDepth={max_depth}")
    print(f"Saved settings: {orig}  selfKnowledgeEnabled={orig_selfknow}")

    if max_depth < 2:
        print("maxMemoryDepth < 2 — cannot vary depth on this model; skipping.")
        return

    failures = []
    a1, a2 = 1, max_depth          # two distinct valid depths
    target_selfknow = not orig_selfknow
    try:
        # --- P + G: cycle 1 (depth a1, and flip the global Self-Knowledge flag) ---
        call(f"SET_MEMORY_DEPTH:{a1}")
        call(f"SET_SELF_KNOWLEDGE:{'true' if target_selfknow else 'false'}")
        print(f"\nCycle 1: set depth={a1}, selfKnowledge={target_selfknow}; restarting app…")
        s1 = restart_app_and_wait()
        r1_depth = int(s1["memoryDepth"])
        r1_selfknow = bool(s1["selfKnowledgeEnabled"])

        # --- P: cycle 2 (depth a2) ---
        call(f"SET_MEMORY_DEPTH:{a2}")
        print(f"Cycle 2: set depth={a2}; restarting app…")
        s2 = restart_app_and_wait()
        r2_depth = int(s2["memoryDepth"])

        print(f"\nAfter restart 1: depth={r1_depth} (set {a1}), selfKnowledge={r1_selfknow} (set {target_selfknow})")
        print(f"After restart 2: depth={r2_depth} (set {a2})")

        # P: each set depth survived its restart, and the two are distinct
        # (an unfixed build collapses both to the curated default).
        if r1_depth != a1:
            failures.append(f"P1: depth {a1} did not survive restart (got {r1_depth}) — Bug 1 regressed.")
        if r2_depth != a2:
            failures.append(f"P2: depth {a2} did not survive restart (got {r2_depth}) — Bug 1 regressed.")
        if r1_depth == r2_depth:
            failures.append(f"P3: both restarts returned {r1_depth} — depth is reverting to a constant "
                            f"(curated default), i.e. the override is NOT persisting.")
        if not failures:
            print(f"[PASS] P: both custom depths survived restart ({a1}→{r1_depth}, {a2}→{r2_depth}).")

        # G: the global Self-Knowledge flag survived restart too.
        if r1_selfknow != target_selfknow:
            failures.append(f"G: global Self-Knowledge flag did not survive restart "
                            f"(set {target_selfknow}, got {r1_selfknow}).")
        else:
            print(f"[PASS] G: global Self-Knowledge flag survived restart ({target_selfknow}).")

        # --- R: escape hatch — a custom value resets back to the curated default ---
        # Learn the curated default by resetting first (reset clears overrides, so
        # depth == the curated default), then set a value KNOWN to differ from it
        # and confirm reset brings it back and that the reset persists across a
        # restart. Choosing the probe value relative to the observed default keeps
        # this robust on models where the default equals the max (e.g. AFM = 3).
        call("RESET_MODEL_SETTINGS")
        d_default = int(get_state()["memoryDepth"])
        v = 1 if d_default != 1 else min(2, max_depth)
        if v != d_default:
            call(f"SET_MEMORY_DEPTH:{v}")       # custom value, persisted as an override
            call("RESET_MODEL_SETTINGS")        # escape hatch → back to curated default
            d_after = int(get_state()["memoryDepth"])
            s3 = restart_app_and_wait()
            d_after_restart = int(s3["memoryDepth"])
            if d_after != d_default:
                failures.append(f"R: reset did not return depth to curated default "
                                f"(custom {v} → {d_after}, expected {d_default}).")
            elif d_after_restart != d_default:
                failures.append(f"R: reset-to-default did not persist across restart "
                                f"({d_default} → {d_after_restart}).")
            else:
                print(f"[PASS] R: custom depth {v} reset to curated default {d_default}, persisted across restart.")
        else:
            print("[SKIP] R: model exposes only one valid depth; escape-hatch check not applicable.")

        # --- C: clamp — over-max is clamped, never stored raw ---
        call("SET_MEMORY_DEPTH:9999")
        d_clamped = int(get_state()["memoryDepth"])
        if d_clamped != max_depth:
            failures.append(f"C: over-max depth was not clamped (set 9999, got {d_clamped}, max {max_depth}).")
        else:
            print(f"[PASS] C: over-max depth clamped to model max ({d_clamped}).")

    finally:
        # Restore every managed value + the global flag, then a final restart so
        # applyEffectiveSettings re-derives cleanly from the restored overrides.
        for field, verb in MANAGED:
            call(f"{verb}:{orig[field]}")
        call(f"SET_SELF_KNOWLEDGE:{'true' if orig_selfknow else 'false'}")
        try:
            restart_app_and_wait()
        except Exception as e:
            print(f"(warning: final restart failed: {e})")
        print(f"\nRestored settings: {orig}  selfKnowledgeEnabled={orig_selfknow}")

    print(f"\n{'=' * 100}")
    if failures:
        print(f"RESULT: FAIL ({len(failures)} assertion(s))")
        for f in failures:
            print(f"  - {f}")
        print(f"{'=' * 100}\n")
        raise SystemExit(1)
    print("RESULT: PASS — per-model settings persist across restart, clamp holds, reset works.")
    print(f"{'=' * 100}\n")


if __name__ == "__main__":
    main()
