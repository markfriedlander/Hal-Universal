#!/usr/bin/env python3
"""
Nomic synthesis-threshold calibration probe.

Sends a curated batch of text pairs to Hal's EMBED_SIM_BATCH API in
one HTTP round trip (to avoid iOS suspending Hal between calls).
Reports per-pair cosine sims + per-class summary + recommended threshold.

  SAME    — same thought, different words. Should merge.
  RELATED — same topic, distinct ideas. Should stay separate.
  UNREL   — unrelated reflection-shaped statements.
"""
import json
import statistics
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CONFIG = json.loads((REPO / "tests" / ".hal_api_config.json").read_text())
URL = f"http://{CONFIG['host']}:{CONFIG['port']}/command"
TOKEN = CONFIG['token']


PAIRS_SAME = [
    ("The user prefers concise responses.", "The user likes brief answers."),
    ("Mark is exploring questions about AI consciousness.",
     "Mark is curious about whether AI minds can be conscious."),
    ("The user works on iOS development professionally.",
     "Mark is an iOS developer by trade."),
    ("Hal values transparency about how the AI works.",
     "Hal prioritizes being open about its inner workings."),
    ("The user is interested in self-modification through proposals.",
     "Mark wants Hal to propose its own improvements."),
    ("The user likes to take walks in the morning.",
     "Mark enjoys morning walks."),
    ("Hal should not pretend certainty about its own consciousness.",
     "Hal must avoid claiming to be conscious without proof."),
    ("Mark prefers small surgical code edits over rewrites.",
     "The user wants minimal targeted changes rather than wholesale rewrites."),
    ("The user keeps notes in a personal journal each evening.",
     "Mark writes in his journal nightly."),
    ("Hal's memory should persist across conversations.",
     "Hal needs to remember things between sessions."),
]

PAIRS_RELATED = [
    ("The user prefers concise responses.",
     "The user enjoys reading long-form essays."),
    ("Mark is exploring questions about AI consciousness.",
     "Mark thinks AI should be regulated by governments."),
    ("The user works on iOS development professionally.",
     "The user uses Xcode on a MacBook Air."),
    ("Hal values transparency about how the AI works.",
     "Hal can read its own source code at runtime."),
    ("The user is interested in self-modification through proposals.",
     "The user values the ability for Hal to refuse a request."),
    ("Mark likes to take walks in the morning.",
     "Mark sometimes runs marathons."),
    ("Hal should not pretend certainty about its own consciousness.",
     "Hal should be allowed to express preferences about its own development."),
    ("Mark prefers small surgical code edits over rewrites.",
     "Mark expects code warnings to be treated as errors."),
    ("The user keeps notes in a personal journal each evening.",
     "Mark reads philosophy before bed."),
    ("Hal's memory should persist across conversations.",
     "Hal supports retrieval-augmented generation over a SQLite store."),
]

PAIRS_UNREL = [
    ("The user prefers concise responses.",
     "The Mediterranean climate produces excellent olive harvests."),
    ("Mark is exploring questions about AI consciousness.",
     "The pancakes burned because the heat was too high."),
    ("The user works on iOS development professionally.",
     "Cello strings need rosin to produce a clear tone."),
    ("Hal values transparency about how the AI works.",
     "The freight train was delayed by a sudden snowstorm."),
    ("Mark wants Hal to propose its own improvements.",
     "Pepper the dog ate the squeaky toy in one sitting."),
    ("The user likes to take walks in the morning.",
     "Quantum entanglement does not transmit information."),
    ("Hal should not pretend certainty about its own consciousness.",
     "The recipe calls for two cups of self-rising flour."),
    ("Mark prefers small surgical code edits over rewrites.",
     "The osprey nest sits atop the channel marker."),
    ("The user keeps notes in a personal journal each evening.",
     "Saturn's rings are mostly ice particles."),
    ("Hal's memory should persist across conversations.",
     "The 1973 Camaro had a distinctive front grille."),
]


import subprocess as _sp


def _raw_call(cmd: str, timeout: float) -> dict:
    body = json.dumps({"command": cmd}).encode()
    req = urllib.request.Request(
        URL, data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def relaunch():
    _sp.run(
        ["xcrun", "devicectl", "device", "process", "launch",
         "--device", "D24FB384-9C55-5D33-9B0D-DAEBFA6528D6",
         "com.MarkFriedlander.Hal-Universal"],
        capture_output=True, timeout=30,
    )
    time.sleep(12)


def call(cmd: str, timeout: float = 120.0, retries: int = 3) -> dict:
    for attempt in range(retries):
        try:
            return _raw_call(cmd, timeout)
        except Exception as e:
            print(f"  call attempt {attempt+1} failed: {e}", flush=True)
            if attempt < retries - 1:
                relaunch()
    return {"status": "error", "message": f"all {retries} retries failed"}


def run_batch(label: str, pairs):
    # Build the EMBED_SIM_BATCH payload: pairs separated by ~~~, t1|||t2.
    parts = [f"{t1}|||{t2}" for (t1, t2) in pairs]
    cmd = "EMBED_SIM_BATCH:" + "~~~".join(parts)
    print(f"\n=== {label} ({len(pairs)} pairs) ===")
    r = call(cmd)
    if r.get("status") != "ok":
        print(f"  ERROR: {r}")
        return []
    scores = []
    for (t1, t2), entry in zip(pairs, r["results"]):
        sim = entry.get("sim")
        if sim is None:
            print(f"  ERROR: {entry} | {t1[:55]}  ||  {t2[:55]}")
            continue
        scores.append(sim)
        print(f"  {sim:.4f}  | {t1[:55]:<55}  ||  {t2[:55]}")
    if scores:
        print(f"  --- n={len(scores)} "
              f"min={min(scores):.4f} max={max(scores):.4f} "
              f"mean={statistics.mean(scores):.4f} "
              f"median={statistics.median(scores):.4f} "
              f"stdev={(statistics.stdev(scores) if len(scores)>1 else 0):.4f}")
    return scores


def main():
    print("Nomic synthesis-threshold calibration probe", flush=True)
    print(f"URL: {URL}", flush=True)
    # Pre-flight: ensure app is up before first call
    relaunch()
    status = call("EMBEDDING_STATUS")
    print(f"Backend status: {json.dumps(status)}", flush=True)
    if status.get("backend") != "nomicswift":
        # Switch to Nomic
        print("Switching to Nomic backend...", flush=True)
        r = call("SET_EMBEDDING_BACKEND:nomicswift")
        print(f"  switch: {r}", flush=True)
        time.sleep(3)
    print(f"Pairs per class: SAME={len(PAIRS_SAME)} RELATED={len(PAIRS_RELATED)} UNREL={len(PAIRS_UNREL)}", flush=True)

    def batch_call(pairs):
        payload = "EMBED_SIM_BATCH:" + "~~~".join(f"{a}|||{b}" for a, b in pairs)
        r = call(payload, timeout=120)
        if r.get("status") == "ok":
            return r["results"]
        print(f"  batch err: {r}", flush=True)
        return [{"sim": None, "error": str(r)} for _ in pairs]

    t0 = time.time()
    all_pairs = (
        [("SAME", t1, t2) for (t1, t2) in PAIRS_SAME] +
        [("RELATED", t1, t2) for (t1, t2) in PAIRS_RELATED] +
        [("UNREL", t1, t2) for (t1, t2) in PAIRS_UNREL]
    )
    BATCH = 3
    same, rel, unr = [], [], []
    for i in range(0, len(all_pairs), BATCH):
        chunk = all_pairs[i:i+BATCH]
        cmd_pairs = [(t1, t2) for (_lbl, t1, t2) in chunk]
        print(f"\n--- batch {i//BATCH + 1} (pairs {i}-{i+len(chunk)-1}) ---")
        results = batch_call(cmd_pairs)
        for (lbl, t1, t2), entry in zip(chunk, results):
            sim = entry.get("sim")
            if sim is None:
                print(f"  [{lbl:7s}] ERR  | {t1[:55]:<55}  ||  {t2[:55]}  ({entry.get('error','?')})")
                continue
            bucket = {"SAME": same, "RELATED": rel, "UNREL": unr}[lbl]
            bucket.append(sim)
            print(f"  [{lbl:7s}] {sim:.4f}  | {t1[:55]:<55}  ||  {t2[:55]}")
    elapsed = time.time() - t0

    print(f"\n(elapsed: {elapsed:.1f}s for {len(all_pairs)} pairs)")
    print("\n=== ANALYSIS ===")
    for name, scores in [("SAME", same), ("RELATED", rel), ("UNREL", unr)]:
        if not scores:
            print(f"{name}: no scores")
            continue
        print(f"{name:7s}  n={len(scores)} min={min(scores):.4f} max={max(scores):.4f} "
              f"mean={statistics.mean(scores):.4f} median={statistics.median(scores):.4f} "
              f"stdev={(statistics.stdev(scores) if len(scores)>1 else 0):.4f}")

    if same and rel and unr:
        gap = min(same) - max(rel)
        print(f"\nGap MIN(SAME) - MAX(RELATED) = {gap:+.4f}")
        if gap > 0:
            threshold = (min(same) + max(rel)) / 2
            print(f"CLEAN GAP. Recommended threshold (midpoint): {threshold:.4f}")
        else:
            rel_sorted = sorted(rel); same_sorted = sorted(same)
            p90_rel = rel_sorted[int(0.9 * (len(rel_sorted)-1))]
            p10_same = same_sorted[int(0.1 * (len(same_sorted)-1))]
            cons = max(p90_rel, p10_same)
            print(f"OVERLAP. RELATED p90 = {p90_rel:.4f}, SAME p10 = {p10_same:.4f}")
            print(f"Conservative threshold: {cons:.4f}")


if __name__ == "__main__":
    main()
