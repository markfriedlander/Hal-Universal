# Hal Universal — Handoff Brief
**Updated:** May 17, 2026 (afternoon, post-Nomic-shipped)
**Branch:** `main` (about to commit Nomic backend work)
**Working tree:** uncommitted Nomic implementation + refactor

> **For the next CC session:** read this brief, then `NEXT.md` for what to
> do next, then the 2026-05-17 afternoon entry in `HISTORY.md` for the
> Nomic story, then `CLAUDE.md` for standing rules.

---

## TL;DR — where Hal is right now

Three switchable embedding backends:

- **NLContextual** (default, built-in, 512-dim) — ships with iOS, no download.
- **EmbeddingGemma 300M** (768-dim, ~210 MB) — compiled out for App Store
  builds via `HAL_ENABLE_EMBEDDING_GEMMA` (Debug-only). Blocked by an
  upstream `mlx-swift` Metal init crash on iOS 26.5; infrastructure stays
  in place ready to flip on when Apple/the MLX team fixes
  `mlx::core::metal::Device::Device()` at `device.cpp:328`.
- **Nomic Embed Text v1.5** (768-dim, ~522 MB) — **available now**, opt-in
  via Model Library. Uses Apple's MLTensor framework via
  `jkrukowski/swift-embeddings` (MIT). No MLX dependency → no Metal
  crash. Purpose-built for asymmetric retrieval (short queries against
  short stored documents) with `search_query:` / `search_document:`
  task instruction prefixes handled inside `EmbeddingProvider`.

**Recall measured on device** with the 70-row eval corpus + 10 ground-truth
queries:

| Metric | NLContextual | Nomic | Δ |
|---|---|---|---|
| Top-1 | 1/10 | **5/10** | +4 |
| Top-5 | 4/10 | **8/10** | +4 |
| Top-10 | 7/10 | **9/10** | +2 |

The three previously-failing queries:
- Berkeley: rank 18 → **5**
- cello: rank 18 → **10**
- Subaru: not in results → 17 (still misses top-10)

Subaru is the only remaining miss. LLM-driven query expansion is queued
as the next layer to address it.

---

## What's in the code right now

### Embedding system (extracted from Hal.swift on 2026-05-17)

```
Hal Universal/
├── EmbeddingBackend.swift              — enum + UserDefaults + crash guard
├── EmbeddingProvider.swift             — provider class + MemoryStore ext
├── EmbedderMigrationCoordinator.swift  — @MainActor state machine + UI
└── Hal.swift                           — everything else
```

`EmbeddingPurpose` enum (`.document` | `.query`) threaded through
`EmbeddingProvider.embed(_:as:)` and `MemoryStore.generateEmbedding(for:as:)`.
Retrieval-asymmetric backends (Nomic) use it; NLContextual/Gemma ignore it.

`EmbeddingBackend.isAvailableInThisBuild` gates the Gemma case on the
`HAL_ENABLE_EMBEDDING_GEMMA` compile flag (Debug only). The UI iterates
`allCases.filter { $0.isAvailableInThisBuild }` so store builds only show
NLContextual + Nomic.

### Nomic load + embed path (`EmbeddingProvider.embedNomicSwift`)

1. Local-directory load via `NomicBert.loadModelBundle(from: URL)`
   (the dedicated NomicBERT loader — Bert's loader chokes on Nomic's
   weight key naming, learned the hard way today).
2. `nomicPrefixed(text, purpose:)` prepends `"search_query: "` /
   `"search_document: "` per Nomic's required task instruction format.
3. `bundle.encode(prefixed, maxLength: 512)` → MLTensor [1, seqLen, hidden].
4. Mean-pool over seqLen, L2-normalize, return `[Double]`.

### Migration + download

`MemoryStore.reEmbedAllNullRows()` re-embeds every NULL-embedding row
using the active backend; passes `.document`. `EmbedderMigrationCoordinator`
orchestrates wipe → warm-up wait → migration on a background task and
publishes phase updates to the UI.

Download flows through `MLXModelDownloader` / `BackgroundDownloadCoordinator`
(same path the LLM models use).

---

## Diagnostic APIs

| Command | Purpose |
|---|---|
| `EMBEDDING_STATUS` | backend name, isLoaded, sample dim, expected dim |
| `SET_EMBEDDING_BACKEND:<name>` | switch backend (nlcontextual / nomicswift / embeddinggemma) |
| `MIGRATE_EMBEDDINGS_REEMBED` | run reEmbedAllNullRows synchronously |
| `DOWNLOAD_EMBEDDING_MODEL[:<backend>]` | start download (defaults to nomicswift) |
| `EMBEDDING_DOWNLOAD_STATUS[:<backend>]` | progress poll |
| `FTS_DIAG` | FTS5 row counts + sample MATCH + schema (for the BM25-zero regression) |
| `MEMORY_DUMP:<limit>` | row dump incl. entity_keywords + embedding dim |
| `MEMORY_SEARCH_DEBUG:<q>` | full RRF pipeline trace |
| `MEMORY_SIMILARITY_DEBUG:<q>` | raw cosine per row |
| `INJECT_REALISTIC_TEST_CORPUS` | 70-row eval corpus, entity_keywords populated |

---

## Build flags

- `HAL_ENABLE_EMBEDDING_GEMMA` — Debug only. Gates the Gemma backend's
  code path (load + embed). When unset, selecting Gemma falls back to
  NLContextual at launch and the Model Library hides the Gemma row.

## Dependencies

```
mlx-swift 0.31.3
mlx-swift-lm 3.31.3        (MLXLLM + MLXLMCommon + MLXHuggingFace + MLXEmbedders)
swift-transformers 1.3.3   (exactVersion pin, bumped from 1.3.2 today)
swift-embeddings 0.0.27    (exactVersion pin, new today — Nomic backend)
  → swift-safetensors 0.1.1
  → swift-sentencepiece 0.0.6
  → swift-numerics 1.1.1
```

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
- API host: `marks-bigger-ass-fon-16.local` (mDNS — phone must be awake + on WiFi)
- API port: 8766
- API token: `e9ee9ec5b315467fa655bd4296873f43` (in `tests/.hal_api_config.json`)
- iPhone 17 Pro sim UDID: `10C6DB49-2723-4F95-8F81-AECB9CD72BD0`
  - sim token: `950c39cf55574c3180734785ec3c52da` (in `tests/.hal_api_config_sim.json`)

For sim runs: `HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/hal_test.py …`

---

## SOP (refactor-as-you-go is now mandatory)

1. **After any change to Hal's source files, sync `Hal_Source.txt`:**
   ```bash
   ./scripts/sync_hal_source.sh
   ```
   The script concatenates all of `Hal Universal/*.swift` in a stable
   order. When you extract a new file from Hal.swift, add it to the
   `FILES` array inside `scripts/sync_hal_source.sh`.

2. **Significant changes to a section of Hal.swift → extract into a
   dedicated file** (per Mark's 2026-05-17 standing instruction).
   Use the existing files (`EmbeddingBackend.swift`,
   `EmbeddingProvider.swift`, `EmbedderMigrationCoordinator.swift`)
   as the template.

3. New enum case → sweep all switches.

4. New AppStorage key → `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.

5. App build number bump happens at App Store submission (currently at 5).

6. Never `NUCLEAR_RESET` between plant and recall in a memory test.

7. **Update HISTORY/HANDOFF/NEXT as work lands** (CLAUDE.md Golden Rule #8).

8. **Warnings = errors** (CLAUDE.md Golden Rule #7).

9. **API > asking the human** — expand the API if a question can't be
   answered through it.

---

## Known caveats

- **EmbeddingGemma is unavailable in this build configuration** because
  the underlying MLX-swift Metal init crashes on iOS 26.5
  (`mlx::core::metal::Device::Device()` at `device.cpp:328` — libc++
  `basic_string(const char*) detected nullptr` from a Metal architecture
  name that returns nil on iOS 26+). Documented upstream issue. Code
  stays in place behind `HAL_ENABLE_EMBEDDING_GEMMA` flag.
- **Nomic adds ~522 MB on disk.** Same mental model as downloading a
  local LLM — user opts in.
- **Nomic load takes ~10–15 s on the iPhone 16 Plus** (MMAP-loading 546 MB
  safetensors + tokenizer JSON parse). Subsequent embeds are fast (~80 ms
  per text on this hardware, including the prefix prepend).
- **FTS5 first-inject-after-install glitch** (documented 2026-05-17
  morning): a fresh install with an immediate inject sees BM25 return 0
  candidates until a NUCLEAR_RESET + re-inject. Minor; the test corpus
  workflow already does the reset.
