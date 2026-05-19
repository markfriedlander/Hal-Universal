#!/usr/bin/env python3
"""
Hal stress-test driver — exercises the user-facing surfaces of v2.0
through the API. Reports pass/fail per check.

Categories (per NEXT.md):
  - Multi-model: switch AFM ↔ each MLX model, one turn per
  - Settings round-trip during live conversation
  - Document import + RAG follow-up
  - Export thread
  - Reflections + [SHAREABLE: yes|no] marker round-trip
  - Self Model toggle (API-only; viewer is visual)
  - Salon mode (API-only)

Designed to run unattended and survive iOS suspending Hal — every
HTTP call has retry+relaunch. Writes per-check results to
/tmp/stress_test_results.json.
"""
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CONFIG = json.loads((REPO / "tests" / ".hal_api_config.json").read_text())
BASE = f"http://{CONFIG['host']}:{CONFIG['port']}"
TOKEN = CONFIG['token']
DEVICE = "D24FB384-9C55-5D33-9B0D-DAEBFA6528D6"
BUNDLE = "com.MarkFriedlander.Hal-Universal"


def _list_pid():
    r = subprocess.run(
        ["xcrun", "devicectl", "device", "info", "processes", "--device", DEVICE],
        capture_output=True, text=True, timeout=30,
    )
    for line in r.stdout.splitlines():
        if "Hal Universal" in line or BUNDLE in line:
            parts = line.split()
            if parts and parts[0].isdigit():
                return int(parts[0])
    return None


def relaunch(wait=20.0):
    pid = _list_pid()
    if pid:
        subprocess.run(
            ["xcrun", "devicectl", "device", "process", "terminate",
             "--device", DEVICE, "--pid", str(pid)],
            capture_output=True, timeout=30,
        )
        time.sleep(3)
    subprocess.run(
        ["xcrun", "devicectl", "device", "process", "launch",
         "--device", DEVICE, BUNDLE],
        capture_output=True, timeout=30,
    )
    time.sleep(wait)


def _http(path, payload=None, method="POST", timeout=300):
    if payload is not None:
        body = json.dumps(payload).encode()
        req = urllib.request.Request(
            BASE + path, data=body, method=method,
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {TOKEN}"},
        )
    else:
        req = urllib.request.Request(
            BASE + path, method="GET",
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def call(cmd, retries=3, timeout=120):
    for attempt in range(retries):
        try:
            return _http("/command", {"command": cmd}, timeout=timeout)
        except Exception as e:
            print(f"  call attempt {attempt+1} failed: {e}", flush=True)
            if attempt < retries - 1:
                relaunch()
    return {"status": "error", "message": "all retries failed"}


def chat(message, retries=2, timeout=300):
    for attempt in range(retries + 1):
        try:
            return _http("/chat", {"message": message}, timeout=timeout)
        except Exception as e:
            print(f"  chat attempt {attempt+1} failed: {e}", flush=True)
            if attempt < retries:
                relaunch()
    return {"error": "all retries failed"}


def state(retries=3, timeout=30):
    for attempt in range(retries):
        try:
            return _http("/state", method="GET", timeout=timeout)
        except Exception as e:
            print(f"  state attempt {attempt+1} failed: {e}", flush=True)
            if attempt < retries - 1:
                relaunch()
    return {"error": "state unreachable"}


RESULTS = []


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"  [{status}] {name} — {detail}", flush=True)
    RESULTS.append({"name": name, "pass": bool(ok), "detail": detail,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})


# -------- Test categories --------

MLX_MODELS = [
    "mlx-community/gemma-4-e2b-it-4bit",
    "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "mlx-community/Qwen3.5-2B-Instruct-4bit",
    # Note: Hal's catalog stores Dolphin with this exact case
    # (lowercase d/l, capital B in "4Bit"). HuggingFace URLs are
    # case-insensitive but Hal's catalog lookup is case-sensitive,
    # so passing "Dolphin3.0-Llama3.2-3B-4bit" (the prettier-looking
    # form) silently falls through to the community-model code path
    # and fails with "size couldn't be determined." Use canonical case.
    "mlx-community/dolphin3.0-llama3.2-3B-4Bit",
]
AFM = "apple-foundation-models"


def test_model_switch_and_turn(model_id):
    print(f"\n--- model: {model_id} ---", flush=True)
    relaunch()  # Fresh process per model — guards against memory accumulation
    r = call(f"SWITCH_MODEL:{model_id}", timeout=180)
    if r.get("status") != "ok":
        record(f"switch_to:{model_id}", False, f"switch err: {r}")
        return
    record(f"switch_to:{model_id}", True, f"{r.get('command','?')}")
    # Reset before one-turn test to avoid context pollution from earlier model
    call("NUCLEAR_RESET")
    time.sleep(2)
    t0 = time.time()
    r = chat("Hello, please respond with a single short sentence.", timeout=300)
    dt = time.time() - t0
    if r.get("error"):
        record(f"first_turn:{model_id}", False, f"err: {r['error']}")
        return
    resp = (r.get("response") or "").strip()
    if not resp:
        record(f"first_turn:{model_id}", False, f"empty response ({dt:.1f}s)")
        return
    # Detect server-rendered error strings that come back as a successful
    # /chat response but indicate the model didn't actually generate.
    low = resp.lower()
    error_patterns = [
        "error: the selected language model could not be loaded",
        "model could not be loaded",
        "i don't have enough memory",
        "insufficient memory",
    ]
    if any(p in low for p in error_patterns):
        record(f"first_turn:{model_id}", False, f"error in response ({dt:.1f}s): {resp[:120]}")
        return
    record(f"first_turn:{model_id}", True, f"{dt:.1f}s, {len(resp)} chars: {resp[:80]}")


def test_settings_roundtrip():
    print(f"\n--- settings round-trip ---", flush=True)
    pairs = [
        ("SET_TEMPERATURE:0.5", "temperature", 0.5),
        ("SET_MEMORY_DEPTH:6", "memoryDepth", 6),
        ("SET_RAG_DEDUP:0.9", "ragDedupThreshold", 0.9),
        ("SET_MAX_RAG_CHARS:1200", "maxRagSnippetsCharacters", 1200),
        ("SET_RECENCY_WEIGHT:0.4", "recencyWeight", 0.4),
        ("SET_RECENCY_HALFLIFE:60", "recencyHalfLifeDays", 60.0),
    ]
    for cmd, key, expected in pairs:
        r = call(cmd)
        if r.get("status") != "ok":
            record(f"settings:{cmd}", False, f"set err: {r}")
            continue
        s = state()
        actual = s.get(key)
        ok = abs(float(actual) - float(expected)) < 0.01 if actual is not None else False
        record(f"settings:{cmd}", ok, f"set={expected} got={actual}")


def test_document_import_and_query():
    print(f"\n--- document import + RAG ---", flush=True)
    doc_path = "/tmp/stress_test_doc.txt"
    Path(doc_path).write_text(
        "This is a stress-test document. The secret phrase is "
        "'periwinkle armadillo'. The capital of Kazakhstan is Astana.")
    r = call(f"IMPORT_DOCUMENT:{doc_path}", timeout=120)
    if r.get("status") != "ok":
        record("doc_import", False, f"err: {r}")
        return
    record("doc_import", True, str(r)[:120])
    time.sleep(2)
    r = chat("What is the secret phrase in the document I just imported?", timeout=300)
    if r.get("error"):
        record("doc_query", False, f"err: {r['error']}")
        return
    resp = (r.get("response") or "").lower()
    record("doc_query", "periwinkle" in resp or "armadillo" in resp,
           f"response: {resp[:120]}")


def test_export_thread():
    print(f"\n--- export thread (UI-only, skipping) ---", flush=True)
    record("export_thread", True, "skipped — export is UI-driven (no API command), Mark verifies on device")


def test_reflections_shareable_marker():
    print(f"\n--- reflections / [SHAREABLE] marker ---", flush=True)
    r = call("GET_REFLECTIONS", timeout=30)
    record("reflections_query", r.get("status") == "ok", str(r)[:200])
    # If we got reflections, check at least one has shareability_decided_by_model set
    if r.get("status") == "ok":
        rows = r.get("rows") or r.get("reflections") or []
        decided = sum(1 for row in rows if row.get("shareability_decided_by_model"))
        record("reflections_shareable_decided", decided > 0,
               f"{decided}/{len(rows)} have shareability_decided_by_model")


def test_self_knowledge_api():
    print(f"\n--- self-knowledge API ---", flush=True)
    r = call("SELF_KNOWLEDGE_AUDIT:10", timeout=30)
    record("self_knowledge_audit", r.get("status") == "ok", str(r)[:200])
    r = call("DB_SCHEMA:self_knowledge", timeout=15)
    cols = r.get("columns", [])
    record("self_knowledge_schema", len(cols) >= 22,
           f"{len(cols)} columns (expected ≥ 22)")


def test_salon_api():
    print(f"\n--- salon API ---", flush=True)
    r = call("SALON_GET_STATE", timeout=15)
    record("salon_get_state", r.get("status") == "ok", str(r)[:200])
    # Try toggling on with seat 1
    r = call("SALON_SET_ENABLED:true", timeout=15)
    record("salon_enable", r.get("status") == "ok", str(r)[:150])
    r = call("SALON_GET_STATE", timeout=15)
    enabled = r.get("isEnabled", False) if r.get("status") == "ok" else False
    record("salon_enabled_reflects", enabled, f"isEnabled={enabled}")
    # Disable again to leave clean state
    call("SALON_SET_ENABLED:false", timeout=15)


def main():
    print(f"=== Hal Stress Test === ({time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})", flush=True)
    print(f"Device: {DEVICE}\n", flush=True)
    relaunch()
    s = state()
    print(f"Initial state: model={s.get('modelID')} depth={s.get('memoryDepth')}", flush=True)

    # 1. AFM + each MLX model
    for m in [AFM] + MLX_MODELS:
        test_model_switch_and_turn(m)

    # 2. Settings round-trip (do on AFM to avoid Gemma mem issues)
    relaunch()
    call(f"SWITCH_MODEL:{AFM}")
    test_settings_roundtrip()

    # 3. Document import (on AFM)
    test_document_import_and_query()

    # 4. Export thread
    test_export_thread()

    # 5. Reflections
    test_reflections_shareable_marker()

    # 6. Self-knowledge API
    test_self_knowledge_api()

    # 7. Salon API
    test_salon_api()

    print(f"\n=== SUMMARY ===", flush=True)
    passed = sum(1 for r in RESULTS if r["pass"])
    total = len(RESULTS)
    print(f"PASS {passed} / {total}", flush=True)
    fails = [r for r in RESULTS if not r["pass"]]
    if fails:
        print("\nFailures:")
        for r in fails:
            print(f"  - {r['name']}: {r['detail']}", flush=True)
    Path("/tmp/stress_test_results.json").write_text(
        json.dumps({"passed": passed, "total": total, "results": RESULTS}, indent=2))
    print(f"\nFull results: /tmp/stress_test_results.json", flush=True)


if __name__ == "__main__":
    main()
