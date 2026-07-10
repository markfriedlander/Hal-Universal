#!/usr/bin/env python3
"""
Embedder A/B/C — NLContextual vs Nomic vs mxbai (v2.1 item 5 step 3).

Runs the SAME curated SAME/RELATED/UNREL pair set through each backend (via
SET_EMBEDDING_BACKEND — now instant + non-destructive thanks to per-backend
columns — and EMBED_SIM_BATCH, which cosine-compares text pairs under the active
backend). Reports, per backend:

  - cosine bands for each class (SAME = same thought/paraphrase, RELATED = same
    topic different idea, UNREL = unrelated),
  - SEPARATION = mean(SAME) - mean(UNREL): how strongly the backend pulls
    related content apart from unrelated — the core retrieval-quality signal,
  - SAME/RELATED gap = min(SAME) - max(RELATED): whether the backend can tell an
    exact duplicate from merely same-topic (drives the synthesis threshold),
  - a recommended synthesis threshold = max(RELATED) + 0.02 headroom (the value
    ABOVE which a merge is safe — same logic used for Nomic's calibrated 0.85).

Non-destructive: restores the original active backend at the end. Read-only w.r.t.
the corpus (EMBED_SIM_BATCH embeds throwaway text, stores nothing).

Usage:
    python3 tests/embedder_ab_eval.py
"""

import json
import os
import statistics
import time
import urllib.request
from pathlib import Path

_cfg_name = os.environ.get("HAL_API_CONFIG", ".hal_api_config.json")
CONFIG_PATH = Path(os.environ.get("HAL_API_CONFIG_PATH") or (Path(__file__).parent / _cfg_name))
with CONFIG_PATH.open() as f:
    cfg = json.load(f)
HOST, PORT, TOKEN = cfg["host"], cfg["port"], cfg["token"]

BACKENDS = ["nlcontextual", "nomicswift", "mxbai"]

SAME = [
    ("Mark is exploring questions about AI consciousness.",
     "Mark is curious about whether AI minds can be conscious."),
    ("The user works on iOS development professionally.",
     "Mark is an iOS developer by trade."),
    ("Hal values transparency about how the AI works.",
     "Hal prioritizes being open about its inner workings."),
    ("The user likes to take walks in the morning.",
     "Mark enjoys morning walks."),
    ("Mark prefers small surgical code edits over rewrites.",
     "The user wants minimal targeted changes rather than wholesale rewrites."),
    ("Hal's memory should persist across conversations.",
     "Hal needs to remember things between sessions."),
    ("The user keeps notes in a personal journal each evening.",
     "Mark writes in his journal nightly."),
    ("Hal should not pretend certainty about its own consciousness.",
     "Hal must avoid claiming to be conscious without proof."),
]
RELATED = [
    ("Mark is exploring questions about AI consciousness.",
     "Mark thinks AI should be regulated by governments."),
    ("The user works on iOS development professionally.",
     "The user uses Xcode on a MacBook Air."),
    ("Hal values transparency about how the AI works.",
     "Hal can read its own source code at runtime."),
    ("Mark likes to take walks in the morning.",
     "Mark sometimes runs marathons."),
    ("Mark prefers small surgical code edits over rewrites.",
     "Mark expects code warnings to be treated as errors."),
    ("Hal's memory should persist across conversations.",
     "Hal supports retrieval-augmented generation over a SQLite store."),
    ("The user keeps notes in a personal journal each evening.",
     "Mark reads philosophy before bed."),
    ("Hal should not pretend certainty about its own consciousness.",
     "Hal should be allowed to express preferences about its own development."),
]
UNREL = [
    ("The user prefers concise responses.",
     "The Mediterranean climate produces excellent olive harvests."),
    ("Mark is exploring questions about AI consciousness.",
     "The pancakes burned because the heat was too high."),
    ("The user works on iOS development professionally.",
     "Cello strings need rosin to produce a clear tone."),
    ("Hal values transparency about how the AI works.",
     "The freight train was delayed by a sudden snowstorm."),
    ("The user likes to take walks in the morning.",
     "Quantum entanglement does not transmit information."),
    ("Mark prefers small surgical code edits over rewrites.",
     "The osprey nest sits atop the channel marker."),
    ("The user keeps notes in a personal journal each evening.",
     "Saturn's rings are mostly ice particles."),
    ("Hal's memory should persist across conversations.",
     "The 1973 Camaro had a distinctive front grille."),
]


def call(cmd, timeout=180):
    body = json.dumps({"command": cmd}).encode()
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/command", data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def sims(pairs):
    payload = "EMBED_SIM_BATCH:" + "~~~".join(f"{a}|||{b}" for a, b in pairs)
    r = call(payload)
    if r.get("status") != "ok":
        raise RuntimeError(f"EMBED_SIM_BATCH failed: {r}")
    return [e["sim"] for e in r["results"] if e.get("sim") is not None]


def band(xs):
    return (min(xs), statistics.mean(xs), max(xs))


def main():
    orig = call("EMBEDDING_STATUS")["backend"]
    print(f"\n{'='*100}\nEmbedder A/B/C — retrieval separation + synthesis-threshold calibration")
    print(f"{'='*100}\nSaved active backend: {orig}\n")
    results = {}
    try:
        for be in BACKENDS:
            call(f"SET_EMBEDDING_BACKEND:{be}")
            time.sleep(4)  # warm-up (BERT-large load on first mxbai call)
            st = call("EMBEDDING_STATUS")
            if not st.get("isLoaded"):
                # nudge a load and retry once
                call("EMBED_PROBE:%s:warm up" % be)
                time.sleep(3)
            s, r, u = sims(SAME), sims(RELATED), sims(UNREL)
            results[be] = {"SAME": band(s), "RELATED": band(r), "UNREL": band(u)}
            print(f"--- {be} ---")
            for cls, (lo, mean, hi) in results[be].items():
                print(f"   {cls:8s}  min={lo:.3f}  mean={mean:.3f}  max={hi:.3f}")
            sep = results[be]["SAME"][1] - results[be]["UNREL"][1]
            gap = results[be]["SAME"][0] - results[be]["RELATED"][2]
            thr = results[be]["RELATED"][2] + 0.02
            results[be]["sep"] = sep
            results[be]["gap"] = gap
            results[be]["thr"] = thr
            print(f"   SEPARATION mean(SAME)-mean(UNREL) = {sep:.3f}")
            print(f"   SAME/RELATED gap min(SAME)-max(RELATED) = {gap:.3f}")
            print(f"   → recommended synthesis threshold ≈ {thr:.3f}\n")
    finally:
        call(f"SET_EMBEDDING_BACKEND:{orig}")
        print(f"Restored active backend: {call('EMBEDDING_STATUS')['backend']}")

    # Summary + a recommendation.
    print(f"\n{'='*100}\nSUMMARY (higher SEPARATION = better retrieval discrimination)\n{'='*100}")
    ranked = sorted(results.items(), key=lambda kv: kv[1]["sep"], reverse=True)
    for be, d in ranked:
        print(f"  {be:12s}  separation={d['sep']:.3f}  same/related-gap={d['gap']:+.3f}  synth-thr≈{d['thr']:.3f}")
    print(f"\n  Best separation: {ranked[0][0]}")
    print(f"  mxbai recommended synthesis threshold to encode: {results['mxbai']['thr']:.3f}")


if __name__ == "__main__":
    main()
