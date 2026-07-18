#!/usr/bin/env python3
"""
reasoning_tuning_matrix.py — empirical tuning harness for the reasoning /
think-token path (2026-07).

Goal: find whether a (Layer-0 prompt x temperature x repetition-penalty) sweet
spot makes a reasoning model (Qwen 3.5 2B today) reason WITHOUT looping, close
</think>, and land a clean answer quickly -- or prove there isn't one.

Per matrix cell:
  1. Ensure the app is up (relaunch + wait if it crashed or timed out last cell).
  2. Set a clean footprint + the cell's knobs via API verbs:
       SET_MEMORY_ISOLATION:true, SET_REASONING:true, SET_TEMPERATURE:<t>,
       SET_REPETITION_PENALTY:<r>, SET_REASONING_PROMPT:<variant | default>.
     (These live on the in-memory ReasoningTuning singleton, so they are re-set
      every cell -- surviving any relaunch.)
  3. Fresh thread, run one prompt with a hard per-cell timeout.
  4. Measure: completed / timed-out(looped) / crashed, wall time, answer length,
     correctness, a crude repetition score, and a peek at the RAW reasoning
     (pulled from the HALDEBUG-THINK-RAW log the app now emits).
  5. Print a results matrix and save JSON.

Usage:
    python3 tests/reasoning_tuning_matrix.py                 # small sweep
    python3 tests/reasoning_tuning_matrix.py --full          # 3x3 + variants
    python3 tests/reasoning_tuning_matrix.py --timeout 90
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

PROMPT_VARIANTS = {
    # Baseline: the built-in Layer-0 reasoning directive (prod default).
    "default": "default",
    # Hypothesis (2026-07-13): the model loops because it *narrates our
    # instructions* (tags, "maintain voice", formatting) instead of reasoning
    # about the question. This variant names NO mechanics at all -- no tags,
    # no format, no voice-talk -- just "reason, once, then answer".
    "no-meta": ("Think through the problem step by step before you answer. Work through it "
                "once, and do not repeat yourself or re-litigate a step you have already "
                "settled. Then give your answer."),
    # Control: names the tags but asks for brevity.
    "terse-think": ("Think inside <think></think> only as much as the question needs, and do not "
                    "repeat yourself. As soon as you know the answer, close </think> and reply "
                    "normally."),
    # Control: names the tags, step-structured.
    "stepwise": ("Reason step by step inside <think></think>. Do each step once and move on; "
                 "never restate a step you have already done. When you reach a conclusion, close "
                 "</think> and answer in your normal voice."),
}


def check_91(text):
    t = text.lower()
    if "not" in t and "prime" in t:
        return True
    if "7" in t and "13" in t:
        return True
    if "is a prime" in t or ("prime" in t and "not" not in t and "isn" not in t):
        return False
    return None


PROMPTS = {"prime91": ("Is 91 a prime number?", check_91)}


def run_hal(args, timeout=None):
    """Run hal_test.py; return (returncode|None, combined output)."""
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
    for _ in range(15):
        if api_up():
            return True
        time.sleep(4)
    return False


def ensure_up():
    if not api_up():
        relaunch()


def set_knobs(temp, rep, prompt_text):
    run_hal(["cmd", "SET_MEMORY_ISOLATION:true"])
    run_hal(["cmd", "SET_REASONING:true"])
    run_hal(["cmd", f"SET_TEMPERATURE:{temp}"])
    run_hal(["cmd", f"SET_REPETITION_PENALTY:{rep}"])
    run_hal(["cmd", f"SET_REASONING_PROMPT:{prompt_text}"])


def repetition_score(text):
    if len(text) < 120:
        return 1
    best, step, seen = 1, 40, {}
    for i in range(0, len(text) - step, 10):
        w = text[i:i + step]
        seen[w] = seen.get(w, 0) + 1
        best = max(best, seen[w])
    return best


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


def grab_stream():
    """Pull the COMPLETE raw reasoning for the last (or in-flight) turn via
    the `think_stream` subcommand (which hits GET_THINK_STREAM directly and
    prints the FULL buffer untruncated -- the plain `cmd` path caps output at
    300 chars). Returns the whole string, even when the turn LOOPED and never
    finished (the generator appends it per-chunk)."""
    rc, out = run_hal(["think_stream"], timeout=20)
    lines = out.split("\n")
    for i, ln in enumerate(lines):
        if ln.startswith("CHARS:"):
            return "\n".join(lines[i + 1:]).rstrip("\n")
    return ""


def run_cell(prompt_text, checker, timeout):
    ensure_up()
    run_hal(["new"], timeout=30)
    t0 = time.time()
    rc, out = run_hal(["turn", prompt_text], timeout=timeout)
    wall = time.time() - t0
    lo = out.lower()
    crashed = ("refused" in lo) or ("errno 61" in lo)
    timed_out = (rc is None) or ("timed out" in lo)
    elapsed, body = parse_turn(out)
    ans_chars = len(body)
    rep_score = repetition_score(body) if body else 0
    correct = checker(body) if (checker and body) else None
    ok = (not timed_out) and (not crashed) and (0 < ans_chars < 4000) and (rep_score < 3)
    thinking = grab_stream() if not crashed else ""
    return {
        "crashed": crashed, "timed_out": timed_out, "wall_s": round(wall, 1),
        "gen_s": elapsed, "ans_chars": ans_chars, "rep_score": rep_score,
        "correct": correct, "ok": ok,
        "answer_head": body[:120].replace("\n", " "),
        "think_chars": len(thinking),
        "thinking_head": thinking[:400].replace("\n", " "),
        "thinking_full": thinking,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--micro", action="store_true",
                    help="2-cell smoke test: default prompt, temp 0.6, rep 1.1 + 1.3 "
                         "(validates OK path, crash-fix, and recovery before a long run).")
    ap.add_argument("--timeout", type=int, default=100)
    ap.add_argument("--prompt", default="prime91")
    args = ap.parse_args()

    if args.micro:
        temps, reps, variants = [0.6], [1.1, 1.3], ["default"]
    elif args.full:
        # rep 1.3 dropped (confirmed loser: reliably loops to the timeout).
        # Sweep the useful zone instead, across the baseline + the no-meta
        # hypothesis + the tag-naming control. 3 x 3 x 3 = 27 informative cells.
        temps, reps, variants = [0.6, 0.7, 0.8], [1.1, 1.15, 1.2], ["default", "no-meta", "terse-think"]
    else:
        temps, reps, variants = [0.6, 0.7, 0.8], [1.1, 1.3], ["default"]

    prompt_text, checker = PROMPTS[args.prompt]
    cells = [(v, t, r) for v in variants for t in temps for r in reps]
    print(f"Matrix: {len(cells)} cells  variants={variants} temps={temps} reps={reps}  "
          f"timeout={args.timeout}s  prompt='{prompt_text}'")
    ensure_up()
    run_hal(["switch_model", MODEL], timeout=60)

    rows = []
    for idx, (v, t, r) in enumerate(cells, 1):
        ensure_up()
        set_knobs(t, r, PROMPT_VARIANTS[v])
        print(f"[{idx}/{len(cells)}] variant={v} temp={t} rep={r} ... ", end="", flush=True)
        m = run_cell(prompt_text, checker, args.timeout)
        m.update({"variant": v, "temp": t, "rep_pen": r})
        rows.append(m)
        verdict = "OK" if m["ok"] else ("CRASH" if m["crashed"] else ("LOOP/TIMEOUT" if m["timed_out"] else "fail"))
        print(f"{verdict}  wall={m['wall_s']}s gen={m['gen_s']} chars={m['ans_chars']} "
              f"think={m['think_chars']} rep#={m['rep_score']} correct={m['correct']}")
        if m["thinking_head"]:
            print(f"      think: {m['thinking_head'][:160]}")

    run_hal(["cmd", "SET_MEMORY_ISOLATION:false"])
    run_hal(["cmd", "SET_REPETITION_PENALTY:default"])
    run_hal(["cmd", "SET_REASONING_PROMPT:default"])

    print("\n===================== RESULTS =====================")
    hdr = f"{'variant':<12} {'temp':>4} {'rep':>4} {'verdict':>13} {'wall':>6} {'gen':>6} {'chars':>6} {'rep#':>4} {'correct':>7}"
    print(hdr); print("-" * len(hdr))
    for m in rows:
        verdict = "OK" if m["ok"] else ("CRASH" if m["crashed"] else ("LOOP" if m["timed_out"] else "fail"))
        print(f"{m['variant']:<12} {m['temp']:>4} {m['rep_pen']:>4} {verdict:>13} "
              f"{str(m['wall_s']):>6} {str(m['gen_s']):>6} {m['ans_chars']:>6} {m['rep_score']:>4} {str(m['correct']):>7}")
    wins = [m for m in rows if m["ok"] and m["correct"] is True]
    print(f"\n{len([m for m in rows if m['ok']])}/{len(rows)} cells clean.  Correct sweet spots:")
    for m in wins:
        print(f"  variant={m['variant']} temp={m['temp']} rep={m['rep_pen']}  gen={m['gen_s']}s  '{m['answer_head']}'")

    outpath = os.path.join(HERE, "reasoning_tuning_results.json")
    with open(outpath, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"\nSaved: {outpath}")


if __name__ == "__main__":
    main()
