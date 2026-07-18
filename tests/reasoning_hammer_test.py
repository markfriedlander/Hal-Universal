#!/usr/bin/env python3
"""
reasoning_hammer_test.py — harness-side PROTOTYPE of the force-close "hammer"
for the reasoning / think-token path (2026-07-13).

WHY: the 27-cell tuning sweep proved no temp/rep/prompt combo robustly stops
Qwen 3.5 2B's paragraph-level reasoning loop (5/27 clean, fragile corner). The
fix is structural: bound the thinking and force a conclusion. Before building
that into Hal's generation core (Swift), prove the concept HERE, with no app
changes, and calibrate the depth budgets.

THE HAMMER, MODELED IN TWO PHASES (per prompt):
  Phase 1 (think): one reasoning turn at the best-known baseline (terse-think
    Layer-0 prompt, temp 0.6, rep 1.1, memory isolated). Capture the full raw
    reasoning via GET_THINK_STREAM. It may loop; we only need the trace.
  Truncate the reasoning (the part before </think>) at each depth's char
    budget, cutting back to a clean sentence/line boundary.
  Phase 2 (conclude) per depth: a reasoning-OFF turn that feeds the bounded
    reasoning back and says "stop, answer now." Measure correctness + latency.

This is exactly what the real hammer does — "think up to N tokens, then stop
and answer from what you have" — and the reason-then-conclude-with-reasoning-
off shape is more robust than injecting </think> into a model mid-spiral.

Depths tested: terse / mid / deep. Prompts rise in difficulty so we can SEE
whether deeper thinking actually buys a better answer on the hard ones.

Usage:
    python3 tests/reasoning_hammer_test.py
    python3 tests/reasoning_hammer_test.py --think-timeout 70
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

# Best-known baseline from the 2026-07-13 sweep (terse-think + temp 0.6 + rep 1.1
# was the only combo clean across all temps).
BASELINE_TEMP = 0.6
BASELINE_REP = 1.1
BASELINE_PROMPT = ("Think inside <think></think> only as much as the question needs, and do not "
                   "repeat yourself. As soon as you know the answer, close </think> and reply "
                   "normally.")

# Depth = how many chars of reasoning we keep before forcing the conclusion.
DEPTHS = {"terse": 450, "mid": 1100, "deep": 2400}


def check_91(text):
    t = text.lower()
    if "not" in t and "prime" in t:
        return True
    if "composite" in t:
        return True
    if "7" in t and "13" in t:
        return True
    if "is a prime" in t or (" prime" in t and "not" not in t):
        return False
    return None


def check_337(text):
    # 337 IS prime.
    t = text.lower()
    if "not a prime" in t or "not prime" in t or "isn't a prime" in t or "composite" in t:
        return False
    if "is a prime" in t or "is prime" in t or ("prime" in t and "not" not in t):
        return True
    return None


def check_pens(text):
    # 3 pens = $2  ->  12 pens = $8.
    t = text.lower().replace(",", "")
    if "$8" in t or "8 dollars" in t or "8.00" in t or "is 8" in t or "= 8" in t or " eight" in t:
        return True
    if "$6" in t or "$12" in t or "$24" in t:
        return False
    return None


PROMPTS = {
    "prime91": ("Is 91 a prime number?", check_91),
    "prime337": ("Is 337 a prime number?", check_337),
    "pens": ("A store sells pens at 3 for $2. How much do 12 pens cost?", check_pens),
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
    """Full captured raw reasoning via the think_stream subcommand."""
    rc, out = run_hal(["think_stream"], timeout=20)
    lines = out.split("\n")
    for i, ln in enumerate(lines):
        if ln.startswith("CHARS:"):
            return "\n".join(lines[i + 1:]).rstrip("\n")
    return ""


def parse_turn(out):
    elapsed = None
    m = re.search(r"\[[^\]]*?\s([\d.]+)s\]", out)
    if m:
        try:
            elapsed = float(m.group(1))
        except ValueError:
            pass
    body = out.split("Full response:", 1)[1].strip() if "Full response:" in out else ""
    return elapsed, body


def truncate_reasoning(reasoning, budget):
    """Keep the thinking portion (before </think>), cut to `budget` chars at a
    clean sentence/line boundary. Models the hammer stopping the think phase."""
    think = reasoning.split("</think>")[0].strip()
    if len(think) <= budget:
        return think
    cut = think[:budget]
    for sep in ["\n", ". ", "! ", "? ", "; "]:
        idx = cut.rfind(sep)
        if idx > budget * 0.5:
            return cut[:idx + len(sep)].strip()
    return cut.strip()


def set_baseline_knobs():
    run_hal(["cmd", "SET_MEMORY_ISOLATION:true"])
    run_hal(["cmd", f"SET_TEMPERATURE:{BASELINE_TEMP}"])
    run_hal(["cmd", f"SET_REPETITION_PENALTY:{BASELINE_REP}"])
    run_hal(["cmd", f"SET_REASONING_PROMPT:{BASELINE_PROMPT}"])


def think_phase(question, think_timeout):
    """Phase 1: one reasoning turn; return the full captured raw reasoning."""
    ensure_up()
    set_baseline_knobs()
    run_hal(["cmd", "SET_REASONING:true"])
    run_hal(["new"], timeout=30)
    rc, out = run_hal(["turn", question], timeout=think_timeout)
    timed_out = (rc is None)
    reasoning = grab_stream()
    # If the think turn looped/timed out the device may still be generating —
    # relaunch to free the model before the conclude phase (reasoning is
    # already captured above, so nothing is lost).
    if timed_out:
        relaunch()
    return reasoning, timed_out


def conclude_phase(question, bounded_reasoning, checker, timeout=60):
    """Phase 2: reasoning OFF, feed the bounded reasoning, force the answer."""
    ensure_up()
    run_hal(["cmd", "SET_REASONING:false"])
    run_hal(["cmd", "SET_MEMORY_ISOLATION:true"])
    run_hal(["cmd", f"SET_TEMPERATURE:{BASELINE_TEMP}"])
    run_hal(["cmd", f"SET_REPETITION_PENALTY:{BASELINE_REP}"])
    run_hal(["new"], timeout=30)
    conclude_prompt = (
        f"Earlier you were working out this question: \"{question}\"\n\n"
        f"Here is the reasoning you had so far:\n\"\"\"\n{bounded_reasoning}\n\"\"\"\n\n"
        f"Stop reasoning now and give your final answer to the question, directly and concisely."
    )
    t0 = time.time()
    rc, out = run_hal(["turn", conclude_prompt], timeout=timeout)
    wall = time.time() - t0
    elapsed, body = parse_turn(out)
    correct = checker(body) if body else None
    looped = (rc is None)
    return {
        "wall_s": round(wall, 1), "gen_s": elapsed,
        "answer": body.replace("\n", " ")[:200], "ans_chars": len(body),
        "correct": correct, "looped": looped,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--think-timeout", type=int, default=70)
    ap.add_argument("--prompts", default="prime91,prime337,pens")
    args = ap.parse_args()

    prompt_keys = [p.strip() for p in args.prompts.split(",") if p.strip()]
    depth_names = list(DEPTHS)
    print(f"Hammer prototype: {len(prompt_keys)} prompts x {len(depth_names)} depths "
          f"(depths={DEPTHS})  baseline: terse-think/temp {BASELINE_TEMP}/rep {BASELINE_REP}")
    ensure_up()
    run_hal(["switch_model", MODEL], timeout=60)

    rows = []
    for pk in prompt_keys:
        question, checker = PROMPTS[pk]
        print(f"\n=== {pk}: {question} ===")
        reasoning, timed_out = think_phase(question, args.think_timeout)
        rlen = len(reasoning.split("</think>")[0])
        print(f"  think: captured {len(reasoning)} chars raw "
              f"({rlen} before </think>){'  [looped/timeout]' if timed_out else ''}")
        for dn in depth_names:
            budget = DEPTHS[dn]
            bounded = truncate_reasoning(reasoning, budget)
            r = conclude_phase(question, bounded, checker)
            r.update({"prompt": pk, "depth": dn, "reasoning_used": len(bounded)})
            rows.append(r)
            verdict = "OK" if (r["correct"] is True and not r["looped"]) else \
                      ("WRONG" if r["correct"] is False else
                       ("LOOP" if r["looped"] else "unclear"))
            print(f"  [{dn:>5} {r['reasoning_used']:>4}c] {verdict:>7}  "
                  f"gen={r['gen_s']}s correct={r['correct']}  \"{r['answer'][:90]}\"")

    # reset knobs
    run_hal(["cmd", "SET_MEMORY_ISOLATION:false"])
    run_hal(["cmd", "SET_REPETITION_PENALTY:default"])
    run_hal(["cmd", "SET_REASONING_PROMPT:default"])
    run_hal(["cmd", "SET_REASONING:false"])

    print("\n===================== RESULTS =====================")
    hdr = f"{'prompt':<9} {'depth':>5} {'used':>5} {'verdict':>8} {'gen':>6} {'correct':>7}"
    print(hdr); print("-" * len(hdr))
    for r in rows:
        verdict = "OK" if (r["correct"] is True and not r["looped"]) else \
                  ("WRONG" if r["correct"] is False else
                   ("LOOP" if r["looped"] else "unclear"))
        print(f"{r['prompt']:<9} {r['depth']:>5} {r['reasoning_used']:>5} {verdict:>8} "
              f"{str(r['gen_s']):>6} {str(r['correct']):>7}")

    # per-depth correctness summary
    print("\nPer-depth correctness:")
    for dn in depth_names:
        drows = [r for r in rows if r["depth"] == dn]
        nok = sum(1 for r in drows if r["correct"] is True and not r["looped"])
        print(f"  {dn:>5}: {nok}/{len(drows)} correct")

    outpath = os.path.join(HERE, "reasoning_hammer_results.json")
    with open(outpath, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"\nSaved: {outpath}")


if __name__ == "__main__":
    main()
