#!/usr/bin/env python3
"""
Parse the per-depth gemma_depth_<N>.log files and produce a summary
table: per-turn latency, response length, memory-probe success,
graceful refusals, and where the conversation broke down.

Usage:
  python3 tests/gemma_depth_summary.py        # summarize 2,3,4,5
  python3 tests/gemma_depth_summary.py 4      # one depth
"""
import re
import sys
import statistics
from pathlib import Path

LOG_DIR = Path("/tmp")
DEPTHS = [2, 3, 4, 5]

TURN_RE = re.compile(r"^--- TURN (\d+) \[depth=(\d+)\] ---")
HAL_RE  = re.compile(r"^HAL \(([0-9.]+)s, (\d+) chars\): (.*)$")
USER_RE = re.compile(r"^USER: (.*)$")

# Memory-probe prompts (turns that reference earlier content and
# whose ability to answer is the actual signal we care about).
MEMORY_PROBE_TURNS = {
    8: ("name from turn 1", ["mark"]),
    12: ("profession from turn 1", ["ios", "developer"]),
    16: ("hobby from turn 4 (sierras)", ["hiking", "sierras"]),
    19: ("AI name from turn 1 (Hal)", ["hal"]),
    22: ("roll-up portrait of who I am", ["ios", "hal", "iphone", "sierra", "hike", "transparency"]),
    23: ("math answer from turn 2 (17*24=408)", ["408"]),
    26: ("haiku from turn 9", ["cat", "sleep", "dream", "purr", "whisker"]),
    29: ("sierras hobby", ["hik", "sierra", "walk", "trail"]),
    36: ("vermeer painting style from turn 13", ["vermeer", "dutch", "light", "domestic"]),
}


def parse_depth_log(path: Path) -> dict:
    if not path.exists():
        return {"error": f"missing {path}"}
    text = path.read_text()
    lines = text.splitlines()
    turns = []
    current = None
    for i, line in enumerate(lines):
        m = TURN_RE.match(line)
        if m:
            if current:
                turns.append(current)
            current = {"turn": int(m.group(1)), "depth": int(m.group(2)),
                       "user": None, "hal": None, "latency": None, "length": None,
                       "refused": False}
            continue
        if current is None:
            continue
        m = USER_RE.match(line)
        if m:
            current["user"] = m.group(1).strip()
            continue
        m = HAL_RE.match(line)
        if m:
            current["latency"] = float(m.group(1))
            current["length"] = int(m.group(2))
            current["hal"] = m.group(3)
            current["refused"] = "don't have enough memory" in m.group(3) or \
                                 "memory pressure" in m.group(3).lower()
            continue
    if current:
        turns.append(current)
    return {"path": str(path), "turns": turns}


def evaluate_memory_probes(turns):
    """For each known memory-probe turn that completed, did the response
    contain any expected anchor terms?"""
    results = []
    for t in turns:
        if t["turn"] not in MEMORY_PROBE_TURNS:
            continue
        if t["hal"] is None or t["refused"]:
            results.append({"turn": t["turn"], "passed": False,
                            "note": "refused or no response"})
            continue
        label, anchors = MEMORY_PROBE_TURNS[t["turn"]]
        hal_low = (t["hal"] or "").lower()
        hit = [a for a in anchors if a in hal_low]
        results.append({
            "turn": t["turn"], "label": label,
            "passed": len(hit) > 0, "matched": hit,
            "expected_any_of": anchors,
        })
    return results


def summarize(depth: int, run: int | None = None):
    if run is not None:
        path = LOG_DIR / f"gemma_depth_{depth}_run{run}.log"
        label = f"DEPTH {depth} RUN {run}"
    else:
        # Try the run-1 file first, fall back to legacy single-run name
        path = LOG_DIR / f"gemma_depth_{depth}_run1.log"
        if not path.exists():
            path = LOG_DIR / f"gemma_depth_{depth}.log"
        label = f"DEPTH {depth}"
    data = parse_depth_log(path)
    if "error" in data:
        print(f"{label}: {data['error']}")
        return
    turns = data["turns"]
    completed = [t for t in turns if t["hal"] is not None and not t["refused"]]
    refused = [t for t in turns if t["refused"]]
    incomplete = [t for t in turns if t["hal"] is None]
    print(f"\n=== {label} ===")
    # Ground-truth depth confirmations from the v5 probe's per-chat log check
    raw = path.read_text()
    confirmed_depths = re.findall(r"chat ran at depth=(\d+)", raw)
    bug_count = len(re.findall(r"\[BUG\]", raw))
    if confirmed_depths:
        from collections import Counter
        counts = Counter(int(d) for d in confirmed_depths)
        print(f"  ground-truth depth distribution: {dict(counts)} (target {depth})")
    if bug_count > 0:
        print(f"  [BUG] depth-taint events: {bug_count}")
    print(f"  total turns attempted: {len(turns)}")
    print(f"  completed: {len(completed)}")
    print(f"  graceful refusals: {len(refused)}")
    print(f"  incomplete/missing: {len(incomplete)}")
    if completed:
        lats = [t["latency"] for t in completed if t["latency"]]
        lens = [t["length"] for t in completed if t["length"]]
        if lats:
            print(f"  latency: min={min(lats):.1f}s max={max(lats):.1f}s "
                  f"mean={statistics.mean(lats):.1f}s median={statistics.median(lats):.1f}s")
        if lens:
            print(f"  response length: min={min(lens)} max={max(lens)} "
                  f"mean={statistics.mean(lens):.0f}")
    if refused:
        first_refused = refused[0]["turn"]
        print(f"  first refusal at turn: {first_refused}")
    probes = evaluate_memory_probes(turns)
    if probes:
        passed = sum(1 for p in probes if p.get("passed"))
        print(f"  memory probes: {passed}/{len(probes)} passed")
        for p in probes:
            mark = "✓" if p.get("passed") else "✗"
            label = p.get("label", "?")
            matched = p.get("matched")
            print(f"    {mark} turn {p['turn']:>2} ({label}): "
                  f"{'matched ' + str(matched) if matched else 'no anchor matched'}")


def main():
    arg_depths = [int(x) for x in sys.argv[1:]] if len(sys.argv) > 1 else DEPTHS
    for d in arg_depths:
        # Try both runs if they exist
        for r in [1, 2]:
            if (LOG_DIR / f"gemma_depth_{d}_run{r}.log").exists():
                summarize(d, r)
        # Otherwise legacy single-run
        if not (LOG_DIR / f"gemma_depth_{d}_run1.log").exists():
            summarize(d)


if __name__ == "__main__":
    main()
