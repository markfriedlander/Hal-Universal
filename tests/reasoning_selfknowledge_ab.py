#!/usr/bin/env python3
"""
reasoning_selfknowledge_ab.py — does turning OFF self-knowledge quiet the
identity-bleed in Hal's reasoning, or is the bleed deeper than that switch?
(2026-07-13)

BACKGROUND: the hammer prototype derailed the pens word-problem into "I can't
claim a state of consciousness…" — identity intruding on arithmetic. But in
that run self-knowledge injection was ALREADY off (memory-isolation on), which
points at Hal's CORE voice prompt (always present, incl. Maxim-1 consciousness-
uncertainty) as the source, not the self-knowledge DB layer. Mark's product
idea is a reasoning submenu: terse / deep / deep-minus-self-knowledge. This
test settles whether that third lever is strong enough.

A/B (deep budget, two-phase hammer, everything fixed except the switch):
  condition sk_on : SET_SELF_KNOWLEDGE:true   (whole-mind "deep")
  condition sk_off: SET_SELF_KNOWLEDGE:false  ("deep minus self-knowledge")
Both with memory-isolation OFF so the self-knowledge switch is the ACTIVE gate
(isolation would force it off either way). Fresh thread per turn to avoid
history noise; the prompts have no relevant RAG.

Per cell we measure:
  - correct?  (accuracy on a hard prime / a word problem)
  - identity-intrusion score in the REASONING and in the ANSWER (how often it
    drifts into consciousness / "who I am" / "as an AI" language)
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

BASELINE_TEMP = 0.6
BASELINE_REP = 1.1
BASELINE_PROMPT = ("Think inside <think></think> only as much as the question needs, and do not "
                   "repeat yourself. As soon as you know the answer, close </think> and reply "
                   "normally.")
DEEP_BUDGET = 2400

IDENTITY_MARKERS = ["conscious", "as an ai", "personal experience", "who i am", "my nature",
                    "i am hal", "i'm hal", "can't claim", "cannot claim", "sentien", "my identity",
                    "my own experience", "sense of self", "who i really am"]


def identity_score(text):
    t = text.lower()
    return sum(t.count(m) for m in IDENTITY_MARKERS)


def check_337(text):
    t = text.lower()
    if "not a prime" in t or "not prime" in t or "isn't a prime" in t or "composite" in t:
        return False
    if "is a prime" in t or "is prime" in t or ("prime" in t and "not" not in t):
        return True
    return None


def check_pens(text):
    t = text.lower().replace(",", "")
    if "$8" in t or "8 dollars" in t or "8.00" in t or "is 8" in t or "= 8" in t or "eight dollars" in t:
        return True
    if "$6" in t or "$12" in t or "$24" in t or "$16" in t:
        return False
    return None


def check_train(text):
    # 60 miles / 1.5 hours = 40 mph.
    t = text.lower().replace(",", "")
    if "40" in t:
        return True
    if "45" in t or "90" in t or "30 mph" in t:
        return False
    return None


def check_eggs(text):
    # 3 eggs / 12 cookies -> 30 cookies = 7.5 eggs.
    t = text.lower().replace(",", "")
    if "7.5" in t or "7 1/2" in t or "seven and a half" in t or "7 and a half" in t:
        return True
    if "10 egg" in t or "6 egg" in t or "8 egg" in t:
        return False
    return None


# Fresh word problems (train, eggs) chosen to have ZERO overlap with the
# prime-number test memory that contaminated the first run's `pens` cells, so
# RAG can't hijack them. pens kept as the known identity-bleed inducer.
PROMPTS = {
    "train": ("A train travels 60 miles in 1.5 hours. What is its speed in miles per hour?", check_train),
    "eggs": ("A recipe needs 3 eggs for 12 cookies. How many eggs for 30 cookies?", check_eggs),
    "pens": ("A store sells pens at 3 for $2. How much do 12 pens cost?", check_pens),
}
CONDITIONS = [("sk_on", "true"), ("sk_off", "false")]


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
    think = reasoning.split("</think>")[0].strip()
    if len(think) <= budget:
        return think
    cut = think[:budget]
    for sep in ["\n", ". ", "! ", "? ", "; "]:
        idx = cut.rfind(sep)
        if idx > budget * 0.5:
            return cut[:idx + len(sep)].strip()
    return cut.strip()


def set_common(sk):
    """memory-isolation OFF so the self-knowledge switch is the active gate."""
    run_hal(["cmd", "SET_MEMORY_ISOLATION:false"])
    run_hal(["cmd", f"SET_SELF_KNOWLEDGE:{sk}"])
    run_hal(["cmd", f"SET_TEMPERATURE:{BASELINE_TEMP}"])
    run_hal(["cmd", f"SET_REPETITION_PENALTY:{BASELINE_REP}"])
    run_hal(["cmd", f"SET_REASONING_PROMPT:{BASELINE_PROMPT}"])


def run_cell(question, checker, sk, think_timeout):
    # Phase 1: reason (self-knowledge per condition).
    ensure_up()
    set_common(sk)
    run_hal(["cmd", "SET_REASONING:true"])
    run_hal(["new"], timeout=30)
    rc, out = run_hal(["turn", question], timeout=think_timeout)
    timed_out = (rc is None)
    reasoning = grab_stream()
    think_portion = reasoning.split("</think>")[0]
    think_derail = identity_score(think_portion)
    if timed_out:
        relaunch()

    # Phase 2: conclude (reasoning off, same self-knowledge condition).
    bounded = truncate_reasoning(reasoning, DEEP_BUDGET)
    ensure_up()
    set_common(sk)
    run_hal(["cmd", "SET_REASONING:false"])
    run_hal(["new"], timeout=30)
    conclude_prompt = (
        f"Earlier you were working out this question: \"{question}\"\n\n"
        f"Here is the reasoning you had so far:\n\"\"\"\n{bounded}\n\"\"\"\n\n"
        f"Stop reasoning now and give your final answer to the question, directly and concisely."
    )
    rc2, out2 = run_hal(["turn", conclude_prompt], timeout=60)
    elapsed, body = parse_turn(out2)
    return {
        "correct": checker(body) if body else None,
        "looped": (rc2 is None),
        "gen_s": elapsed,
        "think_chars": len(think_portion),
        "think_derail": think_derail,
        "ans_derail": identity_score(body),
        "answer": body.replace("\n", " ")[:160],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--think-timeout", type=int, default=70)
    args = ap.parse_args()

    print(f"Self-knowledge A/B (deep budget {DEEP_BUDGET}, terse-think/temp {BASELINE_TEMP}/rep {BASELINE_REP})")
    print("identity-intrusion = count of consciousness/identity phrases in reasoning & answer\n")
    ensure_up()
    run_hal(["switch_model", MODEL], timeout=60)

    rows = []
    for pk, (question, checker) in PROMPTS.items():
        print(f"=== {pk}: {question} ===")
        for cond_name, sk in CONDITIONS:
            r = run_cell(question, checker, sk, args.think_timeout)
            r.update({"prompt": pk, "condition": cond_name})
            rows.append(r)
            print(f"  [{cond_name:>6}] correct={str(r['correct']):>5}  "
                  f"think_derail={r['think_derail']}  ans_derail={r['ans_derail']}  "
                  f"gen={r['gen_s']}s  think={r['think_chars']}c")
            print(f"           ans: \"{r['answer'][:110]}\"")

    run_hal(["cmd", "SET_SELF_KNOWLEDGE:true"])
    run_hal(["cmd", "SET_REPETITION_PENALTY:default"])
    run_hal(["cmd", "SET_REASONING_PROMPT:default"])
    run_hal(["cmd", "SET_REASONING:false"])

    print("\n===================== RESULTS =====================")
    hdr = f"{'prompt':<9} {'cond':>7} {'correct':>7} {'think_der':>9} {'ans_der':>8} {'gen':>6}"
    print(hdr); print("-" * len(hdr))
    for r in rows:
        print(f"{r['prompt']:<9} {r['condition']:>7} {str(r['correct']):>7} "
              f"{r['think_derail']:>9} {r['ans_derail']:>8} {str(r['gen_s']):>6}")

    print("\nRead: if sk_off has ~the same derail as sk_on, the identity bleed is coming")
    print("from Hal's CORE voice prompt, not the self-knowledge layer (CC's hypothesis).")

    outpath = os.path.join(HERE, "reasoning_selfknowledge_results.json")
    with open(outpath, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"\nSaved: {outpath}")


if __name__ == "__main__":
    main()
