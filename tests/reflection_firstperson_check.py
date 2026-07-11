#!/usr/bin/env python3
"""
Reflection first-person harness.

For each curated MLX model: switch to it, wait for it to load, force a
reflection on the CURRENT thread, and report whether the generated text is
first person ("I"/"my", and does NOT refer to itself as "Hal" / "the
assistant"). Prints the full text for a human eyeball too.

Why: the reflection prompt was rewritten (2026-07-11) from third person
("I notice that Hal tends to...") to first person. A prompt change can land
differently per model, so we validate all five.

PRECONDITION: the current thread must already hold a few conversation turns
for the reflection to analyze (set one up first, e.g. `hal_test.py turn ...`).

Usage:
    python3 tests/reflection_firstperson_check.py           # Type 1 (practical)
    python3 tests/reflection_firstperson_check.py 2         # Type 2 (existential)
"""
import json
import os
import sys
import time
import urllib.request

CONFIG_PATH = os.path.join(os.path.dirname(__file__), ".hal_api_config.json")

# The five curated MLX models (AFM is excluded — it does not write reflections).
MODELS = [
    ("Gemma 4 E2B",       "mlx-community/gemma-4-e2b-it-4bit"),
    ("Qwen 3.5 2B",       "mlx-community/Qwen3.5-2B-MLX-4bit"),
    ("Llama 3.2 3B",      "mlx-community/Llama-3.2-3B-Instruct-4bit"),
    ("Dolphin 3.0",       "mlx-community/dolphin3.0-llama3.2-3B-4Bit"),
    ("Ternary Bonsai 8B", "prism-ml/Ternary-Bonsai-8B-mlx-2bit"),
]


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def _req(path, config, data=None, timeout=600):
    url = f"http://{config['host']}:{config['port']}{path}"
    headers = {"Authorization": f"Bearer {config['token']}"}
    body = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()
        method = "POST"
    else:
        method = "GET"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:  # noqa: BLE001 - report any transport error verbatim
        return {"error": str(e)}


def cmd(c, config, timeout=600):
    return _req("/command", config, {"command": c}, timeout)


def state(config):
    return _req("/state", config, None, 30)


def wait_for_model(model_id, config, timeout=120):
    start = time.time()
    while time.time() - start < timeout:
        st = state(config)
        if st.get("modelID") == model_id:
            return True
        time.sleep(2)
    return False


def check_first_person(text):
    """Return (verdict, issues[]). First person = uses I/my, never names itself."""
    t = text.strip()
    padded = f" {t.lower()} "
    issues = []
    if "hal " in padded or "hal's" in padded or t.lower().startswith("hal"):
        issues.append('refers to itself in the third person as "Hal"')
    if "the assistant" in padded:
        issues.append('refers to itself as "the assistant"')
    has_first = (" i " in padded) or (" i'" in padded) or (" my " in padded) or t.lower().startswith("i ")
    if not has_first:
        issues.append('no first-person "I"/"my"')
    return ("PASS" if not issues else "FAIL"), issues


def main():
    rtype = sys.argv[1] if len(sys.argv) > 1 else "1"
    config = load_config()
    if not config:
        print("No API config found."); sys.exit(1)

    st = state(config)
    if "error" in st:
        print(f"Device unreachable: {st['error']}"); sys.exit(1)
    if st.get("activeThreadMessages", 0) < 2:
        print("WARNING: current thread has < 2 messages; reflections need conversation content.\n")

    results = []
    for name, mid in MODELS:
        print(f"\n=== {name} ===")
        r = cmd(f"SWITCH_MODEL:{mid}", config)
        if "error" in r:
            print(f"  switch error: {r['error']}")
            results.append((name, "ERROR")); continue
        if not wait_for_model(mid, config):
            print("  model did not become active in time")
            results.append((name, "ERROR")); continue
        time.sleep(3)  # settle after load
        rr = cmd(f"FORCE_REFLECTION:{rtype}", config, timeout=600)
        if rr.get("status") != "ok":
            print(f"  reflection error: {rr}")
            results.append((name, "ERROR")); continue
        text = (rr.get("text") or "").strip()
        if not text:
            print("  (empty reflection — verification may have rejected it)")
            results.append((name, "EMPTY")); continue
        verdict, issues = check_first_person(text)
        print(f"  [{verdict}] {text}")
        if issues:
            print(f"  -> {'; '.join(issues)}")
        results.append((name, verdict))

    print("\n\n===== SUMMARY (Type " + rtype + ") =====")
    for name, verdict in results:
        print(f"  {verdict:6} {name}")


if __name__ == "__main__":
    main()
