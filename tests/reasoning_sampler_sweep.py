#!/usr/bin/env python3
"""
reasoning_sampler_sweep.py — sweep the reasoning sampler LIVE (2026-07-14).

Now that ModelSettings/GenerateParameters carry the full sampler and
ReasoningTuning exposes live override knobs (SET_REASONING_TEMP / SET_TOP_P /
SET_TOP_K / SET_PRESENCE_PENALTY / SET_REPETITION_PENALTY), we can sweep the
reasoning recipe WITHOUT a rebuild-per-config.

Context: wiring Qwen's published thinking-TEXT recipe (temp 1.0, top_p 0.95,
top_k 20, presence 1.5) fixed the pens word-problem but 91/337 (deterministic
math) still looped — temp 1.0 is too hot for math on this 4-bit quant. Qwen's
own card uses a COLDER line (temp 0.6) for coding/deterministic tasks. This
sweep finds the temp × presence sweet spot that converges on BOTH math and
word problems (or proves we need task-dependent recipes).

Fixed per Qwen's structural recommendation: top_p 0.95, top_k 20, rep 1.0.
Swept: temperature × presence_penalty.

Convergence = the model actually closed </think> and produced a real answer
(read from the raw capture buffer via GET_THINK_STREAM), not a timeout/loop.

Usage:
    python3 tests/reasoning_sampler_sweep.py            # 2x2 quick
    python3 tests/reasoning_sampler_sweep.py --full     # 3x4
    python3 tests/reasoning_sampler_sweep.py --timeout 90
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HAL_TEST = os.path.join(HERE, "hal_test.py")
DEVICE = "D24FB384-9C55-5D33-9B0D-DAEBFA6528D6"
BUNDLE = "com.MarkFriedlander.Hal-Universal"
DEVELOPER_DIR = "/Applications/Xcode-beta.app/Contents/Developer"
MODEL = "mlx-community/Qwen3.5-2B-MLX-4bit"

# Fixed structural params (Qwen recommends these across all reasoning modes).
FIXED_TOP_P = "0.95"
FIXED_TOP_K = "20"
FIXED_REP = "1.0"


def check_91(text):
    t = text.lower()
    if "not" in t and "prime" in t: return True
    if "composite" in t: return True
    if "7" in t and "13" in t: return True
    if "is a prime" in t or (" prime" in t and "not" not in t): return False
    return None


def check_337(text):
    t = text.lower()
    if "not a prime" in t or "not prime" in t or "isn't a prime" in t or "composite" in t: return False
    if "is a prime" in t or "is prime" in t or ("prime" in t and "not" not in t): return True
    return None


def check_pens(text):
    t = text.lower().replace(",", "")
    if "$8" in t or "8 dollars" in t or "8.00" in t or "is 8" in t or "= 8" in t or "eight dollars" in t: return True
    if "$6" in t or "$12" in t or "$24" in t or "$16" in t: return False
    return None


PROMPTS = {
    "prime91": ("Is 91 a prime number?", check_91),
    "prime337": ("Is 337 a prime number?", check_337),
    "pens": ("A store sells pens at 3 for 2 dollars. How much do 12 pens cost?", check_pens),
}


def run_hal(args, timeout=None):
    try:
        p = subprocess.run([sys.executable, HAL_TEST] + args,
                           capture_output=True, text=True, timeout=timeout, cwd=ROOT)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired as e:
        so = e.stdout if isinstance(e.stdout, str) else (e.stdout.decode() if e.stdout else "")
        return None, so


def api_up():
    rc, out = run_hal(["current_model"], timeout=20)
    return "modelID" in out and "refused" not in out.lower()


def relaunch():
    subprocess.run(["pkill", "-f", "hal_test.py"], capture_output=True)
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    subprocess.run(["xcrun", "devicectl", "device", "process", "launch",
                    "--device", DEVICE, "--terminate-existing", BUNDLE],
                   capture_output=True, text=True, env=env, timeout=90)
    for _ in range(20):
        if api_up():
            return True
        time.sleep(4)
    return False


def ensure_up():
    if not api_up():
        relaunch()


def grab_stream():
    rc, out = run_hal(["think_stream"], timeout=20)
    lines = out.split("\n")
    for i, ln in enumerate(lines):
        if ln.startswith("CHARS:"):
            return "\n".join(lines[i + 1:]).rstrip("\n")
    return ""


def parse_elapsed(out):
    m = re.search(r"\[[^\]]*?\s([\d.]+)s\]", out)
    if m:
        try:
            return float(m.group(1))
        except ValueError:
            pass
    return None


def set_cell(temp, presence):
    run_hal(["cmd", "SET_MEMORY_ISOLATION:true"])
    run_hal(["cmd", "SET_REASONING:true"])
    run_hal(["cmd", "SET_REASONING_PROMPT:default"])
    run_hal(["cmd", f"SET_TOP_P:{FIXED_TOP_P}"])
    run_hal(["cmd", f"SET_TOP_K:{FIXED_TOP_K}"])
    run_hal(["cmd", f"SET_REPETITION_PENALTY:{FIXED_REP}"])
    run_hal(["cmd", f"SET_REASONING_TEMP:{temp}"])
    run_hal(["cmd", f"SET_PRESENCE_PENALTY:{presence}"])


def run_prompt(question, checker, temp, presence, timeout):
    # Re-apply the knobs on EVERY prompt, not once per cell. The knobs +
    # isolation flag live in the app's in-memory ReasoningTuning singleton, so a
    # relaunch (triggered when a prior prompt loops) RESETS them to defaults.
    # Setting them per-cell meant any prompt after a mid-cell relaunch ran
    # un-isolated at the default temperature — silently contaminating results.
    # (Found 2026-07-14 via a memory-bleed sighting on the device.)
    ensure_up()
    set_cell(temp, presence)
    run_hal(["new"], timeout=30)
    t0 = time.time()
    rc, out = run_hal(["turn", question], timeout=timeout)
    wall = time.time() - t0
    timed_out = rc is None
    elapsed = parse_elapsed(out)
    raw = grab_stream()
    if timed_out:
        relaunch()  # free the device from a runaway before the next prompt
    # Converged = the model closed </think> and produced a real answer.
    if "</think>" in raw:
        answer = raw.split("</think>", 1)[1].strip()
    else:
        answer = ""
    converged = len(answer) > 20
    correct = checker(answer) if answer else None
    think_chars = len(raw.split("</think>")[0])
    return {
        "converged": converged, "correct": correct,
        "gen_s": elapsed, "wall_s": round(wall, 1),
        "think_chars": think_chars, "timed_out": timed_out,
        "answer": answer[:100].replace("\n", " "),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--timeout", type=int, default=75)
    args = ap.parse_args()

    if args.full:
        temps, presences = [0.6, 0.8, 1.0], [0.0, 0.5, 1.0, 1.5]
    else:
        temps, presences = [0.6, 0.8], [0.5, 1.5]

    prompt_keys = list(PROMPTS)
    cells = [(t, p) for t in temps for p in presences]
    print(f"Sampler sweep: {len(cells)} cells (temp × presence)  fixed top_p={FIXED_TOP_P} "
          f"top_k={FIXED_TOP_K} rep={FIXED_REP}  prompts={prompt_keys}  timeout={args.timeout}s")
    ensure_up()
    run_hal(["switch_model", MODEL], timeout=60)

    rows = []
    for (temp, presence) in cells:
        print(f"\n=== temp={temp} presence={presence} ===")
        cell = {"temp": temp, "presence": presence, "prompts": {}}
        for pk in prompt_keys:
            question, checker = PROMPTS[pk]
            r = run_prompt(question, checker, temp, presence, args.timeout)
            cell["prompts"][pk] = r
            verdict = "OK" if (r["converged"] and r["correct"] is True) else \
                      ("WRONG" if (r["converged"] and r["correct"] is False) else "LOOP")
            print(f"  {pk:>9}: {verdict:>5}  gen={r['gen_s']}s think={r['think_chars']}c  "
                  f"correct={r['correct']}  \"{r['answer'][:70]}\"")
        n_ok = sum(1 for pk in prompt_keys
                   if cell["prompts"][pk]["converged"] and cell["prompts"][pk]["correct"] is True)
        cell["n_ok"] = n_ok
        rows.append(cell)
        print(f"  -> {n_ok}/{len(prompt_keys)} converged+correct")

    # reset knobs
    for verb in ["SET_REASONING_TEMP:default", "SET_TOP_P:default", "SET_TOP_K:default",
                 "SET_PRESENCE_PENALTY:default", "SET_REPETITION_PENALTY:default",
                 "SET_MEMORY_ISOLATION:false", "SET_REASONING:false"]:
        run_hal(["cmd", verb])

    print("\n===================== RESULTS (converged+correct per cell) =====================")
    hdr = f"{'temp':>5} {'presence':>9} " + " ".join(f"{pk:>9}" for pk in prompt_keys) + f" {'n_ok':>5}"
    print(hdr); print("-" * len(hdr))
    for c in rows:
        marks = []
        for pk in prompt_keys:
            r = c["prompts"][pk]
            marks.append("OK" if (r["converged"] and r["correct"] is True) else
                         ("WRONG" if r["converged"] else "LOOP"))
        print(f"{c['temp']:>5} {c['presence']:>9} " + " ".join(f"{m:>9}" for m in marks) + f" {c['n_ok']:>5}")

    best = max(rows, key=lambda c: c["n_ok"]) if rows else None
    if best:
        print(f"\nBest: temp={best['temp']} presence={best['presence']} -> {best['n_ok']}/{len(prompt_keys)}")
        if best["n_ok"] < len(prompt_keys):
            print("No universal cell hit all prompts — likely task-dependent (heuristic/classifier territory).")

    outpath = os.path.join(HERE, "reasoning_sampler_results.json")
    with open(outpath, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"\nSaved: {outpath}")


if __name__ == "__main__":
    main()
