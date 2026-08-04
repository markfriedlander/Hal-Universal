#!/bin/bash
# Regenerate the auto-generated Command Reference region of HAL_GUIDE.md from the
# command catalog. Run after any CommandCatalog change; also called by
# sync_hal_source.sh. Idempotent: replaces everything between the
# "BEGIN/END GENERATED COMMAND REFERENCE" markers with fresh catalog output, so the
# guide's command tables can never drift from the code (same idea as Hal_Source.txt).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUIDE="$ROOT/HAL_GUIDE.md"
GEN="$ROOT/scripts/gen_command_reference.py"

python3 "$GEN" --check   # sanity guard: bail if the catalog parse looks wrong

python3 - "$GUIDE" "$GEN" <<'PY'
import re, subprocess, sys
guide_path, gen_path = sys.argv[1], sys.argv[2]
block = subprocess.check_output([sys.executable, gen_path], text=True).rstrip("\n")
text = open(guide_path, encoding="utf-8").read()
pat = re.compile(r"<!-- BEGIN GENERATED COMMAND REFERENCE.*?<!-- END GENERATED COMMAND REFERENCE -->", re.DOTALL)
if not pat.search(text):
    sys.exit("ERROR: BEGIN/END GENERATED COMMAND REFERENCE markers not found in HAL_GUIDE.md")
# lambda avoids re backreference interpretation of any special chars in the block.
open(guide_path, "w", encoding="utf-8").write(pat.sub(lambda m: block, text))
print("Command Reference region updated in HAL_GUIDE.md")
PY
