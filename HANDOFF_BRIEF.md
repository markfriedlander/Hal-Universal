# Hal Universal — Handoff Brief
**Updated:** May 17, 2026 (post-RAG-rebuild + threshold deletion)
**Branch:** `main` @ `2e1bd26` — in sync with `origin/main` (everything pushed)
**Working tree:** clean (only untracked: `Docs/SC_Release_Materials/`, pre-existing)

> **For the next CC session:** read this brief, then `NEXT.md` for what to do first,
> then `HISTORY.md` for how we got here (the 2026-05-17 entry covers the RAG rebuild
> and threshold deletion in detail), then `CLAUDE.md` for standing rules.

---

## TL;DR — where Hal is right now

The RAG memory pipeline was architecturally rebuilt May 17:
- **NLContextualEmbedding** replaces the older NLEmbedding.sentenceEmbedding (transformer-based, 512-dim, on Neural Engine, single embedding system everywhere)
- **FTS5 + Porter stemming** replaces the LIKE-substring keyword search (proper BM25 ranking)
- **Reciprocal Rank Fusion** combines semantic + BM25 by rank (k=60, industry standard, threshold-free)
- **`relevanceThreshold` / `similarityThreshold` deleted entirely** — no variable, no AppStorage key, no UI

Working state on iPhone 16 Plus: build 5 deployed, NLContextualEmbedding loaded (512-dim),
all builds clean (zero warnings, zero errors).

**Eval result:** 7/10 ground-truth plants retrieved in top 10 from the 70-row realistic
corpus. The 3 misses (Berkeley, Subaru, cello) plant-rank 13–48 of 70 in raw semantic;
they're being beaten by question-shape unrelated rows that score 0.86–0.91. Three
proposals submitted (B/A/C order) — no implementation started; pending next session.

---

## What's in the code right now

### RAG retrieval path (`searchUnifiedContent`, Hal.swift around line 4256)

```
Query → sanitize → two retrievers in parallel:
  1. Semantic: cosineSimilarity(queryEmb, allRowEmbs) → top-50 by score → ranks
  2. BM25: FTS5 MATCH ... ORDER BY -bm25() → top-50 → ranks
  → RRF fusion: rrf(d) = Σ over each list L of 1/(60 + rank_L(d))
  → sort by RRF desc
  → take top maxResults (10 single / 5 per sub-query)
  → token-budget pass: skip too-large snippets, break on running-total overflow
  → build RAGSnippet objects
```

No threshold filter. Source-code rows excluded from BM25 (1.18M-char blob would
dominate every common-word match).

### Embedding system (`EmbeddingProvider`, Hal.swift around line 3614)

Single global singleton wraps `NLContextualEmbedding(language: .english)`. Lazy-loaded
on first call (DispatchSemaphore around `requestAssets` for one-shot asset download).
Warmed up at app launch (`AppDelegate.didFinishLaunchingWithOptions`). Per-token vectors
mean-pooled to a single 512-dim sentence vector. `embed(_:) -> [Double]?` returns nil
when model isn't loaded (BM25 carries until it is).

No fallback embedding system. No hash fallback. The old NLEmbedding revision-loop is gone.

### Self-knowledge (May 16, still in place)

- AFM: skipped entirely in `buildChatMessages` (per Mark's directive, AFM gets no
  persistent self-knowledge)
- MLX: injected raw in `resolveSegment(.selfKnowledge, ...)` — no compression call

### Salon (May 16, still in place)

Invariant `salonConfig.isEnabled ⟹ activeSeats.count >= 1` enforced through helpers
`setSalonEnabled` / `setSalonSeat`. Bad state unreachable via API + UI.

---

## Diagnostic APIs added during the rebuild

| Command | Purpose |
|---|---|
| `EMBEDDING_STATUS` | Is NLContextualEmbedding loaded? Sample vector dim. |
| `MEMORY_DUMP:<limit>` | Recent `unified_content` rows with embedding presence (`embeddingDoubles` field) |
| `MEMORY_SEARCH_DEBUG:<query>` | Full hybrid retrieval pipeline trace — semantic + BM25 + RRF, returns ranked snippets |
| `MEMORY_SIMILARITY_DEBUG:<query>` | Raw cosine similarity per row, threshold-free, no RRF. Used by the eval harness. |
| `INJECT_REALISTIC_TEST_CORPUS` | Inject 70-row corpus (10 plants + 50 general turns) for reproducible eval |

All four invoked via `python3 tests/hal_test.py cmd "<COMMAND>"` or direct
`curl POST /command` with the bearer token from `tests/.hal_api_config.json`.

---

## Eval harness — `tests/rag_threshold_eval.py`

**What it does.** Calls `MEMORY_SIMILARITY_DEBUG` for each of 10 hard-coded
ground-truth recall queries against the 70-row corpus. For each query reports:
- Plant's rank in the cosine-sorted list (and the plant's score)
- Top non-plant score (worst false positive for that query)
- At thresholds 0.25 / 0.35 / 0.45 / 0.50: does the plant pass, and how much
  noise passes alongside

**How to run (manual setup required first):**

```bash
# 1. Make sure Hal is running on the device and reachable
python3 tests/hal_test.py state

# 2. Reset DB and inject the corpus
python3 tests/hal_test.py reset
python3 tests/hal_test.py cmd "INJECT_REALISTIC_TEST_CORPUS"

# 3. Run the eval
python3 tests/rag_threshold_eval.py
```

**What "good" looks like.** With NLContextualEmbedding (current):
- Plant scores: mean 0.83 (range 0.77–0.91)
- Top-noise scores: mean 0.88 (range 0.86–0.91)
- Plant recall @ all tested thresholds: 10/10 (because scores all clear them)
- **But** the plant is buried under noise in raw rank — only the FULL RRF
  pipeline (tested separately via `MEMORY_SEARCH_DEBUG`) achieves 7/10 in top 10.

The eval probes RAW SEMANTIC similarity. To measure the full pipeline (semantic
+ BM25 + RRF), use `MEMORY_SEARCH_DEBUG:<query>` directly and count plant ranks
in the returned `entries` list. There's no automated harness for the full
pipeline yet; building one would be a Proposal-B-style improvement.

**Important methodology caveat.** The corpus injection bypasses
`extractNamedEntities` at write time — all 70 rows have empty `entity_keywords`.
This understates BM25's real-world contribution (real chat turns DO populate
entity_keywords via `extractNamedEntities` at `Hal.swift:1597`). Proposal B
addresses this.

---

## Known behavior caveats

- **NLContextualEmbedding compresses cosine into a narrow band.** Empirically:
  all pairs of short conversational content score 0.69–0.91. Plants score 0.77–0.84
  against their recall queries; noise scores 0.86–0.91. The model produces
  meaningful semantic distance but doesn't strongly discriminate at this size.
- **The eval corpus has no entity_keywords.** See above. Real chat data does.
- **First-launch asset download for NLContextualEmbedding** blocks the calling
  thread via DispatchSemaphore. Warm-up at app launch front-loads this so chat
  turns don't pay. If offline at first launch, EmbeddingProvider sets
  `loadAttempted = false` so the next call retries.
- **3 ground-truth plants miss top-10 retrieval:** Subaru, Berkeley, cello.
  Pure semantic + BM25 can't bridge `"live"` → `"Berkeley"` reliably given the
  current embedding model. Proposals A/B/C address.

---

## Recent commits (since last brief)

```
2e1bd26  tests: rag_threshold_eval.py — 10-query ground-truth eval harness for RAG
9712a87  Delete relevanceThreshold/similarityThreshold entirely
c07cd4c  Docs: chronicle RAG rebuild (A/B/C), refresh HANDOFF + NEXT
b6f964b  Commit C: Hybrid retrieval with Reciprocal Rank Fusion; remove relevance-threshold UI
1550325  Commit B: FTS5 BM25 keyword search replaces LIKE substring path
67efc30  Commit A: Replace NLEmbedding with NLContextualEmbedding everywhere
```

`origin/main` is at `2e1bd26`. Local matches. Everything pushed.

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
- Sim UDID: `7D4E1F1A-E7EC-4C42-BDF1-BF3BC72F4352` (iPhone 17 Pro)

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
