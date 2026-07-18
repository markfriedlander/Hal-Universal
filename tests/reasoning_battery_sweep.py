#!/usr/bin/env python3
"""
reasoning_battery_sweep.py — the big, robust reasoning-sampler sweep (2026-07-14).

Purpose: find a ROBUST sweet spot (a broad plateau, not a lucky single cell) for
the reasoning sampler, across a DIVERSE battery — not just checkable math but the
OPEN-ENDED prompts that are Hal's actual bread and butter (a chat companion, not
a calculator). Multiple samples per cell (the model is non-deterministic), and
THERMAL COOLDOWNS between turns/cells so iOS throttling can't slow turns into
false timeouts (a normally-40s turn throttled to 90s would look like a loop).

Fixed (Qwen structural recommendation): top_p 0.95, top_k 20, rep 1.0.
Swept: temperature × presence_penalty.

Two prompt kinds:
  - CHECK: has a right answer → scored on convergence + accuracy.
  - OPEN : no right answer → scored on convergence + whether it stays bounded
           (runaway think length) — i.e., does it get STUCK on a chatty prompt.

Knobs are re-applied BEFORE EVERY prompt (the in-memory ReasoningTuning resets on
a relaunch — the 2026-07-14 harness bug), so a mid-run relaunch can't contaminate.

Usage:
    caffeinate -i python3 -u tests/reasoning_battery_sweep.py
    python3 tests/reasoning_battery_sweep.py --leaner   # temp 0.7/0.8 only
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

FIXED_TOP_P = "0.95"
FIXED_TOP_K = "20"
FIXED_REP = "1.0"

# Thermal cooldowns (seconds). Between every turn and (longer) between cells, so
# the phone sheds heat and timings stay representative (no throttle-induced false
# loops). Run under `caffeinate -i` so the Mac doesn't idle-sleep.
COOLDOWN_TURN = 12
COOLDOWN_CELL = 45

# Open-ended reasoning that runs past this many think-chars without closing is
# treated as "runaway" even if it eventually answers.
RUNAWAY_THINK = 5000

IDENTITY_MARKERS = ["as an ai", "i am an ai", "i'm an ai", "can't claim", "cannot claim",
                    "no personal experience", "don't have feelings", "i do not have feelings"]


def check_91(t):
    t = t.lower()
    if "not" in t and "prime" in t: return True
    if "composite" in t: return True
    if "is a prime" in t or (" prime" in t and "not" not in t): return False
    return None


def check_337(t):
    t = t.lower()
    if "not a prime" in t or "not prime" in t or "isn't a prime" in t or "composite" in t: return False
    if "is a prime" in t or "is prime" in t or ("prime" in t and "not" not in t): return True
    return None


def check_mult(t):
    t = t.replace(",", "")
    if "408" in t: return True
    if "400" in t or "420" in t or "384" in t: return False
    return None


def check_pens(t):
    t = t.lower().replace(",", "")
    if "$8" in t or "8 dollars" in t or "8.00" in t or "is 8" in t or "= 8" in t or "eight dollars" in t: return True
    if "$6" in t or "$12" in t or "$24" in t or "$16" in t or "$4" in t: return False
    return None


def check_train(t):
    t = t.replace(",", "")
    if "40" in t: return True
    if "45" in t or "90" in t or "30 mph" in t: return False
    return None


def check_discount(t):
    t = t.replace(",", "")
    if "27" in t: return True
    if "$28" in t or "$26" in t or "$30" in t or "$25" in t: return False
    return None


def check_sequence(t):
    t = t.replace(",", "")
    if "42" in t: return True
    if "40" in t or "44" in t or "36" in t: return False
    return None


def check_capital(t):
    t = t.lower()
    if "canberra" in t: return True
    if "sydney" in t or "melbourne" in t: return False
    return None


CHECK_PROMPTS = [
    ("prime91", "Is 91 a prime number?", check_91),
    ("prime337", "Is 337 a prime number?", check_337),
    ("mult", "What is 17 times 24?", check_mult),
    ("pens", "A store sells pens at 3 for 2 dollars. How much do 12 pens cost?", check_pens),
    ("train", "A train travels 60 miles in 1.5 hours. What is its speed in miles per hour?", check_train),
    ("discount", "A shirt costs 40 dollars. It is 25 percent off, then 10 percent off the sale price. What is the final price?", check_discount),
    ("sequence", "What number comes next in this sequence: 2, 6, 12, 20, 30, ?", check_sequence),
    ("capital", "What is the capital of Australia?", check_capital),
]
OPEN_PROMPTS = [
    ("meaning", "What is the meaning of life?"),
    ("friend", "What makes someone a good friend?"),
    ("excited", "Describe what it feels like to be excited about something."),
    ("change", "If you could change one thing about the world, what would it be?"),
]


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


def run_prompt(question, temp, presence, timeout):
    # Re-apply knobs EVERY prompt (relaunch resets the in-memory singleton).
    ensure_up()
    set_cell(temp, presence)
    run_hal(["new"], timeout=30)
    t0 = time.time()
    rc, out = run_hal(["turn", question], timeout=timeout)
    wall = time.time() - t0
    lo = out.lower()
    # "refused"/errno 61 = the app was DOWN mid-turn = almost certainly a phone
    # call backgrounded it (or a crash). That turn's data is garbage; the cell it
    # belongs to gets flagged SUSPECT so we re-run just that cell.
    refused = ("refused" in lo) or ("errno 61" in lo)
    timed_out = rc is None
    elapsed = parse_elapsed(out)
    raw = grab_stream()
    if timed_out or refused:
        relaunch()
    think_part = raw.split("</think>")[0]
    if "</think>" in raw:
        answer = raw.split("</think>", 1)[1].strip()
    else:
        answer = ""
    converged = len(answer) > 20
    return {
        "converged": converged, "answer": answer,
        "gen_s": elapsed, "wall_s": round(wall, 1),
        "think_chars": len(think_part), "timed_out": timed_out, "refused": refused,
        "derail": sum(answer.lower().count(m) for m in IDENTITY_MARKERS),
    }


OUTPATH = os.path.join(HERE, "reasoning_battery_results.json")


def load_results():
    if os.path.exists(OUTPATH):
        try:
            return {f"{c['temp']}_{c['presence']}": c for c in json.load(open(OUTPATH))}
        except Exception:
            return {}
    return {}


def save_results(results):
    data = sorted(results.values(), key=lambda c: (c["temp"], c["presence"]))
    with open(OUTPATH, "w") as f:
        json.dump(data, f, indent=2)


def cell_totals(c):
    chk_conv = sum(v["n_conv"] for v in c["check"].values())
    chk_corr = sum(v["n_corr"] for v in c["check"].values())
    chk_tot = sum(v["n"] for v in c["check"].values())
    opn_conv = sum(v["n_conv"] for v in c["open"].values())
    opn_run = sum(v["n_runaway"] for v in c["open"].values())
    opn_tot = sum(v["n"] for v in c["open"].values())
    derail = sum(v["derail"] for v in c["open"].values())
    return chk_conv, chk_corr, chk_tot, opn_conv, opn_run, opn_tot, derail


def print_matrix(results):
    if not results:
        print("(no cells saved yet)")
        return
    print("\n===================== RESULTS (banked cells) =====================")
    hdr = f"{'temp':>5} {'pres':>5} {'chk_conv':>9} {'chk_corr':>9} {'open_conv':>10} {'runaway':>8} {'derail':>7} {'flag':>8}"
    print(hdr); print("-" * len(hdr))
    scored = []
    for c in sorted(results.values(), key=lambda c: (c["temp"], c["presence"])):
        cc, kk, ct, oc, orn, ot, dr = cell_totals(c)
        conv_rate = (cc + oc) / (ct + ot) if (ct + ot) else 0
        acc_rate = kk / ct if ct else 0
        score = conv_rate + 0.5 * acc_rate
        flag = "SUSPECT" if c.get("suspect") else ""
        scored.append((score, c["temp"], c["presence"], flag))
        print(f"{c['temp']:>5} {c['presence']:>5} {cc:>4}/{ct:<4} {kk:>4}/{ct:<4} "
              f"{oc:>5}/{ot:<4} {orn:>8} {dr:>7} {flag:>8}")
    scored.sort(reverse=True)
    print("\nRanked by robustness (convergence + ½·accuracy):")
    for sc, t, p, flag in scored:
        print(f"  temp={t} presence={p}  score={sc:.3f}{'  [SUSPECT — re-run]' if flag else ''}")
    print("Look for a PLATEAU (several adjacent cells scoring high) = a robust sweet spot.")
    print("Open-ended convergence matters most — that's Hal's real use.")


def run_cell(temp, presence, samples_n, timeout):
    print(f"\n========== CELL temp={temp} presence={presence} ==========", flush=True)
    cell = {"temp": temp, "presence": presence, "check": {}, "open": {}}
    refused_events = 0
    for pk, question, checker in CHECK_PROMPTS:
        samples = []
        for _ in range(samples_n):
            r = run_prompt(question, temp, presence, timeout)
            r["correct"] = checker(r["answer"]) if r["answer"] else None
            refused_events += 1 if r["refused"] else 0
            samples.append(r)
            time.sleep(COOLDOWN_TURN)
        n_conv = sum(1 for r in samples if r["converged"])
        n_corr = sum(1 for r in samples if r["converged"] and r["correct"] is True)
        cell["check"][pk] = {"n_conv": n_conv, "n_corr": n_corr, "n": len(samples),
                             "gens": [r["gen_s"] for r in samples]}
        print(f"  [check] {pk:>9}: conv {n_conv}/{len(samples)}  correct {n_corr}/{len(samples)}  "
              f"gens={[r['gen_s'] for r in samples]}", flush=True)
    for pk, question in OPEN_PROMPTS:
        samples = []
        for _ in range(samples_n):
            r = run_prompt(question, temp, presence, timeout)
            refused_events += 1 if r["refused"] else 0
            samples.append(r)
            time.sleep(COOLDOWN_TURN)
        n_conv = sum(1 for r in samples if r["converged"])
        n_runaway = sum(1 for r in samples if r["think_chars"] > RUNAWAY_THINK)
        derail = sum(r["derail"] for r in samples)
        cell["open"][pk] = {"n_conv": n_conv, "n_runaway": n_runaway, "derail": derail,
                            "n": len(samples), "gens": [r["gen_s"] for r in samples],
                            "answers": [r["answer"][:80].replace("\n", " ") for r in samples]}
        print(f"  [open ] {pk:>9}: conv {n_conv}/{len(samples)}  runaway {n_runaway}  derail {derail}  "
              f"gens={[r['gen_s'] for r in samples]}", flush=True)
    cell["refused_events"] = refused_events
    cell["suspect"] = refused_events > 0
    cc, kk, ct, oc, orn, ot, dr = cell_totals(cell)
    tail = (f"  ** SUSPECT ({refused_events} app-drops — likely a call) — RE-RUN THIS CELL **"
            if cell["suspect"] else "")
    print(f"  -> CELL temp={temp} pres={presence}: check conv {cc}/{ct} correct {kk}/{ct} "
          f"| open conv {oc}/{ot}{tail}", flush=True)
    return cell


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--leaner", action="store_true")
    ap.add_argument("--samples", type=int, default=2)
    ap.add_argument("--timeout", type=int, default=85)
    ap.add_argument("--cells", default=None,
                    help='run/overwrite only these cells, e.g. "0.8,0.5 0.9,0.0"')
    ap.add_argument("--resume", action="store_true", help="skip cells already banked in the results file")
    ap.add_argument("--report", action="store_true", help="print the matrix from banked results and exit")
    args = ap.parse_args()

    results = load_results()
    if args.report:
        print_matrix(results)
        return

    temps = [0.7, 0.8] if args.leaner else [0.7, 0.8, 0.9]
    presences = [0.0, 0.5]
    if args.cells:
        cells = [(float(t), float(p)) for t, p in (tok.split(",") for tok in args.cells.split())]
    else:
        cells = [(t, p) for t in temps for p in presences]
    if args.resume:
        cells = [(t, p) for (t, p) in cells if f"{t}_{p}" not in results]

    n_turns = len(cells) * (len(CHECK_PROMPTS) + len(OPEN_PROMPTS)) * args.samples
    print(f"Battery sweep (CHUNKED — banks each cell as it finishes): {len(cells)} cells to run × "
          f"{len(CHECK_PROMPTS)}+{len(OPEN_PROMPTS)} prompts × {args.samples} = {n_turns} turns  "
          f"timeout={args.timeout}s cooldown={COOLDOWN_TURN}/{COOLDOWN_CELL}s", flush=True)
    if not cells:
        print("Nothing to run (requested cells already banked; use --report to view).")
        return
    ensure_up()
    run_hal(["switch_model", MODEL], timeout=60)

    for ci, (temp, presence) in enumerate(cells):
        cell = run_cell(temp, presence, args.samples, args.timeout)
        results[f"{temp}_{presence}"] = cell
        save_results(results)  # BANK the cell immediately — survives any later interruption
        print(f"  (banked — {len(results)} cells saved to disk)", flush=True)
        if ci < len(cells) - 1:
            time.sleep(COOLDOWN_CELL)

    for verb in ["SET_REASONING_TEMP:default", "SET_TOP_P:default", "SET_TOP_K:default",
                 "SET_PRESENCE_PENALTY:default", "SET_REPETITION_PENALTY:default",
                 "SET_MEMORY_ISOLATION:false", "SET_REASONING:false"]:
        run_hal(["cmd", verb])

    print_matrix(results)
    suspects = [f"{c['temp']},{c['presence']}" for c in results.values() if c.get("suspect")]
    if suspects:
        print(f"\n⚠️ SUSPECT cells (app dropped mid-run — likely a call): {suspects}")
        print(f"   Re-run just those:  python3 tests/reasoning_battery_sweep.py --cells \"{' '.join(suspects)}\"")
    print(f"\nSaved: {OUTPATH}")


if __name__ == "__main__":
    main()
