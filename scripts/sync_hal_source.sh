#!/usr/bin/env bash
# sync_hal_source.sh — Regenerate Hal_Source.txt from the Swift source files.
#
# Hal_Source.txt is bundled with the app and ingested into RAG so Hal can
# read his own architecture. Since 2026-05-17 the source is split across
# several files; this script concatenates them in a deterministic order so
# Hal's self-knowledge contains everything.
#
# Add new Swift files to FILES below as they're extracted.

set -euo pipefail

# Resolve repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Order matters only for readability — the concatenation is for ingestion,
# not compilation. Hal.swift comes FIRST because its header carries the
# MASTER LEGO INDEX (a table of contents for every file and block); the
# supporting files follow. Reading order = LEGO numbering order = index
# order, so Hal_Source.txt reads front-to-back as 1..N.
FILES=(
  "Hal Universal/Hal.swift"
  "Hal Universal/EmbeddingBackend.swift"
  "Hal Universal/EmbeddingProvider.swift"
  "Hal Universal/EmbedderMigrationCoordinator.swift"
  "Hal Universal/QueryExpansion.swift"
  "Hal Universal/PromptDetailView.swift"
  "Hal Universal/SelfKnowledgeEngine.swift"
  "Hal Universal/TraitCrystallizer.swift"
  "Hal Universal/ProcessMemoryGuard.swift"
  "Hal Universal/MaintenanceTasks.swift"
  "Hal Universal/PrivacyMonitor.swift"
  "Hal Universal/SharedModelStore.swift"
  "Hal Universal/MLXModelDownloader.swift"
  "Hal Universal/ModelCatalogService.swift"
  "Hal Universal/LocalAPIServer.swift"
  "Hal Universal/DocumentImportManager.swift"
  "Hal Universal/SettingsViews.swift"
  "Hal Universal/ChatViews.swift"
  "Hal Universal/About.swift"
  "Hal Universal/ThermalGovernor.swift"
  "Hal Universal/RoboRunner.swift"
)

OUT="Hal Universal/Hal_Source.txt"

{
  for f in "${FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "sync_hal_source.sh: ERROR — missing file: $f" >&2
      exit 1
    fi
    echo "// ==== FILE: $(basename "$f") ===="
    cat "$f"
    echo ""
  done
} > "$OUT"

lines=$(wc -l < "$OUT")
echo "sync_hal_source.sh: wrote $OUT ($lines lines, ${#FILES[@]} files)"
