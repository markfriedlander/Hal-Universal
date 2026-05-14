#!/usr/bin/env python3
"""
Performance Benchmark Suite — Strategic §1.

For each model in the curated tier (plus AFM), runs:
  - A short-context probe (~50-token prompt)
  - A long-context probe (~1500-token prompt preamble + question)

Captures from log lines emitted by the chat path:
  - prompt token count
  - prefill time → prefill tok/s
  - time to first token (TTFT)
  - generation tokens
  - generation tok/s
  - total wall time

For AFM (which doesn't go through MLXWrapper), only wall time + response
length are recorded — AFM's stream doesn't surface tok/s.

Emits a Markdown report to stdout.

Usage:
    python3 tests/perf_benchmark.py [--models <id1>,<id2>,...]

If --models is omitted, runs against AFM + all four curated MLX models.
"""

import argparse
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / ".hal_api_config.json").read_text())
BASE = f"http://{CONFIG['host']}:{CONFIG['port']}"
HEADERS = {
    "Authorization": f"Bearer {CONFIG['token']}",
    "Content-Type": "application/json",
}

# A neutral ~1500-word passage. Designed to be off-topic from anything Hal
# has in its self-knowledge or RAG, so we measure pure prefill cost and not
# RAG retrieval cost.
LONG_PREAMBLE = """The cell, often considered the basic structural and functional unit of life,
exhibits a remarkable degree of internal organization. Within the eukaryotic cell, membrane-bound
organelles segregate biochemical functions: the nucleus houses the genome, mitochondria generate
ATP through oxidative phosphorylation, the endoplasmic reticulum synthesizes proteins and lipids
destined for membranes or secretion, and the Golgi apparatus modifies and routes those products.
Each compartment maintains a distinct chemical environment — distinct pH, ionic composition,
and protein complement — through selective transport across its bounding membranes.

Mitosis is the process by which a eukaryotic cell divides its nucleus and chromosomes into two
genetically identical daughter nuclei. It proceeds through five canonical stages: prophase,
prometaphase, metaphase, anaphase, and telophase, followed by cytokinesis. During prophase,
chromatin condenses into discrete, visible chromosomes, the nuclear envelope begins to break
down, and centrosomes migrate to opposite poles, organizing microtubules into the mitotic
spindle. In prometaphase, the nuclear envelope completes its disassembly and kinetochore
microtubules attach to the kinetochores at each chromosome's centromere. By metaphase, the
chromosomes align along the cell's equator — the metaphase plate — under tension from balanced
microtubule pulling forces from both poles. Anaphase begins when sister chromatids are
suddenly separated, pulled by depolymerizing kinetochore microtubules toward opposite poles
while astral microtubules and the actomyosin cortex elongate the cell. Telophase reverses many
of the early events: a nuclear envelope reforms around each set of chromosomes, the chromosomes
decondense, and the mitotic spindle disassembles. Cytokinesis — the physical division of the
cytoplasm — follows, leaving two daughter cells each with a full diploid complement of
chromosomes identical to the parent.

Meiosis serves a fundamentally different purpose. Rather than producing two identical daughter
cells, it generates four genetically diverse gametes from a single diploid precursor. This
requires two sequential divisions — meiosis I and meiosis II — separated by no intervening
DNA replication. The defining events occur in prophase I: homologous chromosomes pair along
their length (a process called synapsis, mediated by the synaptonemal complex), and reciprocal
genetic exchange (crossing over) occurs at chiasmata. This recombination, combined with the
independent assortment of homologous pairs at metaphase I, generates enormous combinatorial
diversity among gametes. Meiosis I separates homologs (reductional division), reducing the
chromosome number from diploid to haploid; meiosis II then separates the sister chromatids
of each chromosome (equational division), much like a mitotic division but starting from a
haploid cell. The result, in animals, is four haploid gametes — sperm or egg precursors —
each genetically distinct from one another and from the parent cell.

The biochemistry that drives both processes is highly conserved across eukaryotes. Cyclin-
dependent kinase (CDK) complexes, activated and inactivated by oscillating cyclin levels and
post-translational modifications, license the major transitions: entry into S phase (where
DNA replication occurs), entry into mitosis, exit from mitosis. The anaphase-promoting
complex (APC/C), an E3 ubiquitin ligase, triggers chromatid separation at the metaphase-to-
anaphase transition by polyubiquitinating securin, releasing separase to cleave the cohesin
rings that hold sisters together. In meiosis, an additional layer of regulation maintains
cohesion at centromeres through meiosis I — preventing premature separation of sisters —
while permitting arm cohesion to be cleaved so homologs can separate.

Errors in either process have severe consequences. Mis-segregation in mitosis produces
aneuploid daughter cells, a hallmark of many cancers. Mis-segregation in meiosis produces
aneuploid gametes; if such a gamete participates in fertilization, the resulting embryo is
aneuploid — a condition that, depending on the chromosomes involved, may be lethal early in
development or may produce viable but profoundly affected individuals (Down syndrome, for
instance, is trisomy 21 — the presence of three copies of chromosome 21 rather than two).
The checkpoints that monitor chromosome attachment, DNA damage, and cell size before
permitting cell-cycle progression are accordingly under intense surveillance, with multiple
redundant pathways converging to delay or arrest division when problems are detected.

Beyond the textbook account, recent decades have revealed unexpected complexity. Many cell
types — neurons, cardiomyocytes — exit the cell cycle entirely and never divide again in
the adult organism. Others, like hepatocytes, divide only rarely but retain the capacity to
re-enter the cycle in response to tissue damage. Stem cells divide asymmetrically, producing
one differentiated daughter and one stem cell daughter to maintain tissue homeostasis. Cancer
cells, in contrast, escape the normal regulatory constraints — through mutations in tumor
suppressors like p53, oncogenes like RAS or MYC, or DNA repair genes — and divide when they
shouldn't, where they shouldn't, with chromosomes they shouldn't have. The molecular logic of
the cell cycle is thus both elegant in its conservation and devastating when it breaks."""


def post(path, payload, timeout=300):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers=HEADERS,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def cmd(c, timeout=60):
    return post("/command", {"command": c}, timeout=timeout)


def chat(msg, timeout=300):
    return post("/chat", {"message": msg}, timeout=timeout)


def wait_for_load(model_id, timeout_s=30):
    """Switch then wait until current_model matches AND ready."""
    cmd(f"SWITCH_MODEL:{model_id}", timeout=60)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(2)
        st = cmd("CURRENT_MODEL", timeout=10)
        if st.get("modelID") == model_id:
            time.sleep(3)  # let the load finish
            return True
    return False


def pull_logs():
    r = cmd("GET_LOGS:300", timeout=10)
    return r.get("logs", [])


def parse_mlx_metrics(logs, since_ts):
    """Extract prefill/gen metrics from MLX log lines emitted after since_ts."""
    metrics = {
        "promptTokens": None,
        "prefillTime": None,
        "ttftMs": None,
        "genTokens": None,
        "genTokPerSec": None,
    }
    for line in logs:
        # Skip lines before our test started
        if since_ts and len(line) >= 14 and line[1:13] < since_ts:
            continue
        m = re.search(r"Input prepared in ([\d.]+)s; prompt tokens: (\d+)", line)
        if m:
            metrics["prefillTime"] = float(m.group(1))
            metrics["promptTokens"] = int(m.group(2))
        m = re.search(r"First token at ([\d.]+)ms", line)
        if m:
            metrics["ttftMs"] = float(m.group(1))
        m = re.search(r"Generation complete: (\d+) tokens at ([\d.]+) tok/s", line)
        if m:
            metrics["genTokens"] = int(m.group(1))
            metrics["genTokPerSec"] = float(m.group(2))
    if metrics["prefillTime"] and metrics["promptTokens"]:
        metrics["prefillTokPerSec"] = metrics["promptTokens"] / metrics["prefillTime"]
    else:
        metrics["prefillTokPerSec"] = None
    return metrics


def run_probe(model_id, label, prompt):
    """Reset → send prompt → capture log-derived metrics + wall time + response."""
    cmd("NUCLEAR_RESET", timeout=30)
    time.sleep(2)
    t0_str = time.strftime("[%H:%M:%S")
    t_start = time.time()
    r = chat(prompt, timeout=600)
    elapsed = time.time() - t_start
    resp = r.get("response", "")
    err = r.get("error")
    # Pull logs for the last ~60s window
    logs = pull_logs()
    metrics = parse_mlx_metrics(logs, t0_str[1:9])  # "HH:MM:SS"
    return {
        "label": label,
        "wallSeconds": elapsed,
        "responseChars": len(resp),
        "responsePreview": resp[:200],
        "error": err,
        **metrics,
    }


def fmt_metric(v, suffix=""):
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.1f}{suffix}"
    return f"{v}{suffix}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--models", default="",
        help="Comma-separated model IDs (default: AFM + 4 curated MLX)"
    )
    args = ap.parse_args()

    if args.models:
        models = args.models.split(",")
    else:
        models = [
            "apple-foundation-models",
            "mlx-community/gemma-4-e2b-it-4bit",
            "mlx-community/Qwen3.5-2B-MLX-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/dolphin3.0-llama3.2-3B-4Bit",
        ]

    short_prompt = "Briefly explain how mitosis differs from meiosis."
    long_prompt = (
        "Here is a passage I'd like you to consider before answering:\n\n"
        f"{LONG_PREAMBLE}\n\n"
        "Now: briefly explain how mitosis differs from meiosis."
    )

    print(f"# Performance Benchmark — Strategic §1\n")
    print(f"**Date:** {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    print(f"**Short prompt length:** {len(short_prompt)} chars (~50 tokens)")
    print(f"**Long prompt length:** {len(long_prompt)} chars (~1500-2000 tokens)\n")

    all_results = []
    for model_id in models:
        print(f"\n## `{model_id}`\n")
        print(f"Switching + loading...", flush=True)
        wait_for_load(model_id)

        for label, prompt in [("short", short_prompt), ("long", long_prompt)]:
            print(f"  running {label}...", flush=True)
            try:
                r = run_probe(model_id, label, prompt)
            except Exception as e:
                r = {"label": label, "error": str(e), "wallSeconds": 0, "responseChars": 0}
            r["modelID"] = model_id
            all_results.append(r)
            if r.get("error"):
                print(f"    ERROR: {r['error']}")
            else:
                print(f"    wall={r['wallSeconds']:.1f}s, chars={r['responseChars']}, "
                      f"prefill={fmt_metric(r.get('prefillTokPerSec'), ' tok/s')}, "
                      f"gen={fmt_metric(r.get('genTokPerSec'), ' tok/s')}")

    # Final table
    print(f"\n---\n\n## Summary table\n")
    print("| Model | Context | Wall (s) | Prompt tok | Prefill tok/s | TTFT (ms) | Gen tok | Gen tok/s | Chars |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in all_results:
        mid = r["modelID"].split("/")[-1]
        print(
            f"| {mid} | {r['label']} | "
            f"{r['wallSeconds']:.1f} | "
            f"{fmt_metric(r.get('promptTokens'))} | "
            f"{fmt_metric(r.get('prefillTokPerSec'))} | "
            f"{fmt_metric(r.get('ttftMs'))} | "
            f"{fmt_metric(r.get('genTokens'))} | "
            f"{fmt_metric(r.get('genTokPerSec'))} | "
            f"{r['responseChars']} |"
        )

    # Response previews
    print(f"\n## Response previews (first 200 chars)\n")
    for r in all_results:
        mid = r["modelID"].split("/")[-1]
        print(f"\n### `{mid}` ({r['label']})\n")
        print(f"> {r.get('responsePreview', '<empty>')[:200]}")

    print(f"\n---\n*Benchmark complete.*\n")


if __name__ == "__main__":
    main()
