#!/usr/bin/env python3
"""Generate the Command Reference section of the Hal guide FROM the code.

The three Lab doors — the Developer API, RoboRunner, and the hal CLI — all drive
ONE command interpreter whose single source of truth is `CommandCatalog.all` in
`Hal Universal/RoboRunner.swift`. This script parses that catalog and emits the
reference as Markdown so the document can never drift from the code: a verb added,
renamed, or re-argued in Swift shows up here on the next sync, exactly like
`sync_hal_source.sh` keeps `Hal_Source.txt` matched to the source.

Only VISIBLE verbs are emitted — `debugOnly` descriptors are filtered out, matching
the shipped app's HELP (`CommandCatalog.visible`), so users never read about verbs
their build doesn't have. Destructive verbs are flagged; they need Advanced safety
mode plus a trailing confirm marker.

Usage:
    gen_command_reference.py            # print the reference to stdout
    gen_command_reference.py --check    # exit 1 if the parse looks wrong (CI guard)

Grouped by category in the catalog's own order, alphabetical within a category to
match `CommandCatalog.helpText`. Pure stdlib; no build required.
"""
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_SWIFT = os.path.join(REPO_ROOT, "Hal Universal", "RoboRunner.swift")

# One descriptor per line. Summary allows escaped quotes; destructive is always
# present, debugOnly is optional (defaults false).
DESCRIPTOR_RE = re.compile(
    r'CommandDescriptor\(\s*'
    r'verb:\s*"(?P<verb>[^"]+)"\s*,\s*'
    r'args:\s*(?P<args>nil|"(?:[^"\\]|\\.)*")\s*,\s*'
    r'summary:\s*"(?P<summary>(?:[^"\\]|\\.)*)"\s*,\s*'
    r'category:\s*\.(?P<cat>\w+)\s*,\s*'
    r'destructive:\s*(?P<dest>true|false)'
    r'(?:\s*,\s*debugOnly:\s*(?P<dbg>true|false))?'
)
CATEGORY_RE = re.compile(r'case\s+(\w+)\s*=\s*"([^"]+)"')


def unescape(s):
    return s.replace('\\"', '"').replace('\\\\', '\\')


def parse():
    src = open(CATALOG_SWIFT, encoding="utf-8").read()

    # Category display names, in declaration order (== catalog grouping order).
    cat_block = re.search(r'enum CommandCategory[^{]*\{(.*?)\}', src, re.DOTALL)
    if not cat_block:
        sys.exit("ERROR: could not find `enum CommandCategory` in RoboRunner.swift")
    cat_order = []
    cat_name = {}
    for case, name in CATEGORY_RE.findall(cat_block.group(1)):
        cat_order.append(case)
        cat_name[case] = name

    # Only parse inside `static let all: [CommandDescriptor] = [ ... ]` so a stray
    # CommandDescriptor mention elsewhere can't leak in.
    all_block = re.search(r'static let all:\s*\[CommandDescriptor\]\s*=\s*\[(.*?)\n\s*\]',
                          src, re.DOTALL)
    if not all_block:
        sys.exit("ERROR: could not find `CommandCatalog.all` array in RoboRunner.swift")

    verbs = []
    for m in DESCRIPTOR_RE.finditer(all_block.group(1)):
        args = None if m.group("args") == "nil" else unescape(m.group("args")[1:-1])
        verbs.append({
            "verb": m.group("verb"),
            "args": args,
            "summary": unescape(m.group("summary")),
            "cat": m.group("cat"),
            "destructive": m.group("dest") == "true",
            "debugOnly": (m.group("dbg") == "true"),
        })
    return cat_order, cat_name, verbs


def usage(v):
    return f"{v['verb']}:{v['args']}" if v["args"] else v["verb"]


def render(cat_order, cat_name, verbs):
    visible = [v for v in verbs if not v["debugOnly"]]
    hidden = len(verbs) - len(visible)
    lines = []
    lines.append("<!-- BEGIN GENERATED COMMAND REFERENCE. Do not edit by hand.")
    lines.append("     Regenerate with scripts/sync_command_reference.sh (reads CommandCatalog.all). -->")
    lines.append("")
    lines.append(f"*{len(visible)} commands. Generated from the app's command catalog, so this list always "
                 f"matches the running interpreter. The same verbs work through all three doors "
                 f"(Developer API, RoboRunner, hal CLI). Commands marked **[Advanced]** change or delete "
                 f"data and are refused in Safe mode; switch to Advanced and add a trailing `--yes` (or "
                 f"`CONFIRM`) to run them.*")
    lines.append("")
    for cat in cat_order:
        rows = sorted([v for v in visible if v["cat"] == cat], key=lambda v: v["verb"])
        if not rows:
            continue
        lines.append(f"### {cat_name[cat]}")
        lines.append("")
        lines.append("| Command | What it does |")
        lines.append("|---|---|")
        for v in rows:
            flag = " **[Advanced]**" if v["destructive"] else ""
            summary = v["summary"].replace("|", "\\|")
            lines.append(f"| `{usage(v)}`{flag} | {summary} |")
        lines.append("")
    lines.append("<!-- END GENERATED COMMAND REFERENCE -->")
    return "\n".join(lines), len(visible), hidden


def main():
    cat_order, cat_name, verbs = parse()
    text, visible, hidden = render(cat_order, cat_name, verbs)
    if "--check" in sys.argv:
        # Sanity guard for CI / the sync wrapper: the catalog is large and every
        # verb has a category; a near-empty parse means the format drifted.
        if visible < 80 or not verbs:
            sys.exit(f"ERROR: parsed only {visible} visible verbs — catalog format may have changed.")
        print(f"OK: {visible} visible verbs (+{hidden} debug-only hidden).", file=sys.stderr)
        return
    sys.stdout.write(text + "\n")


if __name__ == "__main__":
    main()
