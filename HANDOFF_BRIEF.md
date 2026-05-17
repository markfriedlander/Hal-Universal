# Hal Universal — Handoff Brief
**Updated:** May 17, 2026 (morning, post-EmbeddingGemma-scaffolding)
**Branch:** `main` @ `2237e2a` — in sync with `origin/main` (everything pushed)
**Working tree:** clean (only untracked: `Docs/SC_Release_Materials/`, pre-existing)

> **For the next CC session:** read this brief, then `NEXT.md` for what to do first,
> then the 2026-05-17 morning entry of `HISTORY.md` for how we got here, then
> `CLAUDE.md` for standing rules.

---

## TL;DR — where Hal is right now

The RAG memory pipeline shipped last night (NLContextualEmbedding + FTS5 BM25 +
RRF fusion) is unchanged at the algorithm level. Today's work added the **second
embedding backend** as an opt-in user upgrade:

- **EmbeddingProvider** now dispatches on `UserDefaults("embeddingBackend")`:
  `nlcontextual` (default, NLContextualEmbedding, 512-dim) or `embeddinggemma`
  (EmbeddingGemma 300M MLX 4-bit, 768-dim).
- **MLXEmbedders** is linked from `mlx-swift-lm 3.31.3` (already a transitive
  checkout; just added the framework reference to the Hal Universal target).
- **Catalog-driven download**: a new "Embedding (Memory)" section in Model
  Library, modeled on "Hal's Picks", offers a one-tap download (uses the
  existing `MLXModelDownloader` / `BackgroundDownloadCoordinator` pipeline that
  powers the LLM downloads).
- **Two-way migration**: switching backends wipes the embedding column on every
  stored row and re-embeds them via the new backend
  (`MemoryStore.reEmbedAllNullRows`). Forward and back. Driven by
  `EmbedderMigrationCoordinator` (state machine: idle → downloading → switching
  → migrating → done | error).

Default behavior unchanged: NLContextual is still the active embedder. Users
have to opt in to upgrade, and they can switch back at any time.

**Known unknown:** EmbeddingGemma's load path crashes on the iOS 26.5 simulator
(libc++ Hardening string-nullptr inside MLXEmbedders.loadContainer). Likely
sim-only — the device may not enforce that hardening — but **on-device
verification is pending**. See NEXT.md for the test plan.

---

## What's in the code right now

### Embedding system (`EmbeddingProvider`, Hal.swift around line 3754)

Two paths through `embed(_:)`:
- **NLContextual path**: `embeddingResult(for:language:)` per token, mean-pool
  to 512-dim. Same as yesterday. Lazy-load + asset download via DispatchSemaphore.
- **EmbeddingGemma path**: `EmbedderModelFactory.shared.loadContainer(from:
  directory, using: tokenizerLoader)` (load-from-local-directory, the catalog
  downloader handles the actual download). Per-call inference runs in a
  Task.detached → container.perform → mean-pool inside the model →
  `pooled.asArray(Float.self)` → bridged back to `[Double]` via DispatchSemaphore.

Backend is selected via `EmbeddingBackend.current()` which reads UserDefaults
each call. Changing the backend bumps `EmbeddingBackend.systemVersion`, so
`wipeStaleEmbeddingsIfNeeded` triggers a wipe on next call.

`EmbeddingBackend` enum is nonisolated + Sendable (project default isolation
is MainActor; without the explicit annotations, the enum members would inherit
MainActor and produce warnings in nonisolated contexts).

### Migration (`MemoryStore.reEmbedAllNullRows`, around line 678)

Two-pass migration over `unified_content`:
  1. SELECT id, content WHERE embedding IS NULL → collect candidates
  2. UPDATE embedding = ? WHERE id = ? for each, calling
     `generateEmbedding(for: content)` (dispatches to current backend)

Logs decile progress. Returns (updated, skipped, failed). Single-row (not
batched) — keeps the code simple; batching can come later if real-world
corpora prove slow.

`generateEmbedding` is now nonisolated so the migration can run from any
queue. EmbeddingProvider.embed is already nonisolated + thread-safe.

### User upgrade UI (Model Library section, around line 9837)

Between "Hal's Picks" and "Community Models":

- `EmbedderBackendRow` per backend, with accordion expand and the existing
  status-dot vocabulary (green = active, grey = downloaded, none = not
  downloaded).
- Confirmation dialog before switching, warning about the re-embed step.
- `EmbedderMigrationStatusRow` renders inline during downloading / migrating /
  done / error phases.

Coordinator: `EmbedderMigrationCoordinator.shared` (`@MainActor` singleton,
ObservableObject). Phase enum drives the UI; `switchAndMigrate` orchestrates
wipe → warm-up → migration in a single background task.

---

## Diagnostic APIs

| Command | Purpose |
|---|---|
| `EMBEDDING_STATUS` | Backend name, `isLoaded`, sample vector dim, expected dim |
| `SET_EMBEDDING_BACKEND:<name>` | Switch backend, wipe embeddings, warm up new backend |
| `MIGRATE_EMBEDDINGS_REEMBED` | Run `reEmbedAllNullRows` synchronously (returns counts) |
| `DOWNLOAD_EMBEDDING_MODEL` | Kick off Gemma download (~210 MB) via BGDL pipeline |
| `EMBEDDING_DOWNLOAD_STATUS` | Read-only progress poll for the Gemma download |
| `MEMORY_DUMP:<limit>` | Recent rows; now includes `entityKeywords` per row |
| `MEMORY_SEARCH_DEBUG:<query>` | Full hybrid retrieval trace |
| `MEMORY_SIMILARITY_DEBUG:<query>` | Raw cosine per row (used by `rag_threshold_eval.py`) |
| `INJECT_REALISTIC_TEST_CORPUS` | 70-row corpus, now with entity_keywords populated |

---

## Eval harnesses

- **`tests/rag_threshold_eval.py`** — raw cosine per query, baseline behavior
  unchanged.
- **`tests/rag_pipeline_eval.py`** — full RRF pipeline via `MEMORY_SEARCH_DEBUG`,
  reports plant rank in top-N. **New as of this session.**

Both harnesses honor an `HAL_API_CONFIG` env var so sim configs work without
editing the device config (`tests/.hal_api_config_sim.json` is checked in for
the iPhone 17 Pro sim).

**Current measured baseline (NLContextual, post-Proposal-B):**
- Plant scores mean 0.83, top-noise mean 0.88 (raw cosine).
- Full-pipeline RRF: top-10 7/10, top-5 4/10, top-1 1/10. Berkeley/cello/Subaru
  ranked 13–18 of 20.

**Gemma baseline:** not yet measured (sim crash blocks; device pending).

---

## Known caveats

- **iOS Simulator can't run EmbeddingGemma's load.** MLXEmbedders'
  `loadContainer(from: directory, ...)` crashes in libc++ Hardening with a
  string-nullptr. Reproduces with `#hubDownloader()` too. Likely sim-only —
  hardening is enabled in `iPhoneSimulator26.5.sdk/usr/include/c++/v1/string`.
  Device behavior pending.
- **NLContextual still has the narrow-band discrimination problem** described
  yesterday. Until Gemma is tested on device, the 7/10 top-10 baseline stands.
- **`entity_keywords` only catches person/place/organization** (NLTagger's three
  categories). Common nouns like "cello", "marathon", "Subaru" don't get
  extracted on plants. Real-world impact: BM25 helps for queries that share
  proper-noun terms, doesn't help for natural-language recall like
  "What instrument am I learning?".

---

## Recent commits (since last brief)

```
2237e2a  Embedder upgrade UI in Model Library (Proposal A user flow)
77df7ae  Embedding migration + download API commands
8823a65  Proposal A scaffolding: EmbeddingGemma backend (load-from-directory)
07cfe3a  Proposal B: populate entity_keywords in test corpus; add pipeline eval harness
c93b17f  Docs: handoff brief for next session — RAG state + 3 proposals + how to start
2e1bd26  tests: rag_threshold_eval.py — 10-query ground-truth eval harness for RAG
9712a87  Delete relevanceThreshold/similarityThreshold entirely
```

`origin/main` is at `2237e2a`. Local matches. Everything pushed.

---

## Build + Deploy (iPhone 16 Plus)

```bash
xcodebuild build \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" \
  -configuration Debug

xcrun devicectl device install app --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  "/Users/markfriedlander/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"

xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal
```

- iPhone 16 Plus: `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
- Bundle ID: `com.MarkFriedlander.Hal-Universal`
- API host: `marks-bigger-ass-fon-16.local` (mDNS — phone must be awake + on WiFi)
- API port: 8766
- API token: `e9ee9ec5b315467fa655bd4296873f43` (in `tests/.hal_api_config.json`)
- iPhone 17 Pro sim UDID: `10C6DB49-2723-4F95-8F81-AECB9CD72BD0`
  - sim token: `950c39cf55574c3180734785ec3c52da` (in `tests/.hal_api_config_sim.json`)

For sim runs: `HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/hal_test.py …`

---

## SOP

1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` after every Hal.swift change.
2. New enum case? Sweep all switches.
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
4. App build number bump happens at App Store submission (currently at 5).
5. Never use `NUCLEAR_RESET` between plant and recall in a memory test.
6. **Update HISTORY/HANDOFF/NEXT as work lands** (CLAUDE.md Golden Rule #8).
7. **Warnings = errors** (CLAUDE.md Golden Rule #7).
8. **API > asking the human** — expand the API if a question can't be answered through it.
