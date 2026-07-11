#!/usr/bin/env python3
"""validate_lego.py — Guard the LEGO block scheme against silent rot.

Hal reads his own bundled source (Hal_Source.txt) as self-knowledge, so the
block markers and the master index at the top of Hal.swift must describe the
code truthfully. This script is the check that keeps them honest.

It verifies, across every source file in the order sync_hal_source.sh
concatenates them:

  (a) every `// ==== LEGO START: N Name ====` has a matching
      `// ==== LEGO END: N Name ====` (same number, same name), properly
      closed before the next block opens (flat, non-nested);
  (b) the block numbers, read in concatenation order, are a clean 1..N with
      no gaps and no duplicates;
  (c) the MASTER LEGO INDEX in Hal.swift's header lists exactly those blocks —
      same file grouping, same numbers, same names, same order.

Exit code 0 = clean, 1 = a problem was found (printed to stderr).
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYNC_SCRIPT = os.path.join(REPO_ROOT, "scripts", "sync_hal_source.sh")
HAL_SWIFT = os.path.join(REPO_ROOT, "Hal Universal", "Hal.swift")

START_RE = re.compile(r"^\s*// ==== LEGO START: (\d+) (.+?) ====\s*$")
END_RE = re.compile(r"^\s*// ==== LEGO END: (\d+) (.+?) ====\s*$")


def read_file_order():
    """Parse the FILES=( ... ) array from sync_hal_source.sh, in order."""
    with open(SYNC_SCRIPT, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"FILES=\((.*?)\)", text, re.DOTALL)
    if not m:
        fail("could not find FILES=( ... ) in sync_hal_source.sh")
    files = re.findall(r'"([^"]+)"', m.group(1))
    if not files:
        fail("FILES array in sync_hal_source.sh is empty")
    return files


def fail(msg):
    print(f"validate_lego: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def scan_blocks(files):
    """Return the flat, ordered list of (num, name, file) blocks and validate
    START/END pairing along the way."""
    blocks = []
    for rel in files:
        path = os.path.join(REPO_ROOT, rel)
        if not os.path.isfile(path):
            fail(f"missing source file listed in sync script: {rel}")
        open_block = None  # (num, name, lineno)
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                sm = START_RE.match(line)
                em = END_RE.match(line)
                if sm:
                    if open_block is not None:
                        fail(f"{rel}:{lineno} nested/unclosed START {sm.group(1)} "
                             f"(block {open_block[0]} still open from line {open_block[2]})")
                    open_block = (int(sm.group(1)), sm.group(2).strip(), lineno)
                elif em:
                    if open_block is None:
                        fail(f"{rel}:{lineno} END {em.group(1)} with no open START")
                    num, name = int(em.group(1)), em.group(2).strip()
                    if num != open_block[0] or name != open_block[1]:
                        fail(f"{rel}:{lineno} END '{num} {name}' does not match "
                             f"START '{open_block[0]} {open_block[1]}' (line {open_block[2]})")
                    blocks.append((num, name, rel))
                    open_block = None
        if open_block is not None:
            fail(f"{rel}: START {open_block[0]} at line {open_block[2]} never closed")
    return blocks


def check_sequence(blocks):
    nums = [b[0] for b in blocks]
    expected = list(range(1, len(nums) + 1))
    if nums != expected:
        # Find first divergence for a helpful message.
        for i, (got, exp) in enumerate(zip(nums, expected)):
            if got != exp:
                fail(f"numbering breaks at block #{i+1}: expected {exp}, got {got} "
                     f"({blocks[i][2]} — '{blocks[i][1]}')")
        fail(f"numbering length mismatch: {len(nums)} blocks, expected 1..{len(nums)}")


def parse_master_index():
    """Parse the MASTER LEGO INDEX from Hal.swift's header.

    Expected shape (inside the leading comment block):
        //  Hal.swift
        //    1  Imports & App Entry & Environment Wiring
        //    2  ...
        //  EmbeddingBackend.swift
        //   30  ...
    Returns an ordered list of (num, name, file)."""
    entries = []
    current_file = None
    in_index = False
    file_hdr = re.compile(r"^//\s{1,4}([A-Za-z][\w]*\.swift)\s*$")
    entry_re = re.compile(r"^//\s+(\d+)\s{1,3}(.+?)\s*$")
    with open(HAL_SWIFT, encoding="utf-8") as f:
        for line in f:
            if "MASTER LEGO INDEX" in line:
                in_index = True
                continue
            if not in_index:
                continue
            # The index ends at the first import or the block's blank sentinel.
            if line.startswith("import ") or line.startswith("// ==== LEGO END"):
                break
            fh = file_hdr.match(line)
            if fh:
                current_file = fh.group(1)
                continue
            em = entry_re.match(line)
            if em and current_file:
                entries.append((int(em.group(1)), em.group(2).strip(), current_file))
    if not entries:
        fail("could not parse a MASTER LEGO INDEX from Hal.swift header")
    return entries


def check_index_matches(blocks, index):
    real = [(n, name, os.path.basename(f)) for (n, name, f) in blocks]
    idx = [(n, name, f) for (n, name, f) in index]
    if real == idx:
        return
    # Pinpoint the first mismatch.
    for i in range(max(len(real), len(idx))):
        r = real[i] if i < len(real) else None
        x = idx[i] if i < len(idx) else None
        if r != x:
            fail(f"master index diverges from real markers at position {i+1}:\n"
                 f"    real : {r}\n    index: {x}")


def main():
    files = read_file_order()
    blocks = scan_blocks(files)
    check_sequence(blocks)
    index = parse_master_index()
    check_index_matches(blocks, index)
    print(f"validate_lego: OK — {len(blocks)} blocks, clean 1..{len(blocks)}, "
          f"index matches across {len(files)} files")


if __name__ == "__main__":
    main()
