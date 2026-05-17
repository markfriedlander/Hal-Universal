# Hal Universal — Handoff Brief
**Updated:** May 17, 2026 (post-RAG-rebuild)
**Branch:** `main` @ `b6f964b` — working tree clean (HISTORY/HANDOFF/NEXT updates pending in next commit)
**Origin:** `origin/main` at `eeb7dbc` — local is **ahead by 6 commits**, push pending

> **For post-compaction or next-session CC:** read this brief for current state, then
> `NEXT.md` for what's planned, then `HISTORY.md` for how we got here, then `CLAUDE.md`
> for standing rules.

---

## TL;DR — where Hal is right now

The RAG memory retrieval pipeline was rebuilt May 17 (three commits A/B/C). The system
now uses Apple's NLContextualEmbedding (transformer-based, replaces the older non-contextual
NLEmbedding), SQLite FTS5 with Porter stemming for BM25 keyword search (replaces the
LIKE-substring approach), and Reciprocal Rank Fusion to combine the two retrievers by
rank (replaces threshold-based filtering and score-based combination).

Result: planted-fact recall went from effectively dead (carried only by literal-substring
keyword matches) to 7/10 on natural-language queries against a realistic 70-row corpus.
The 3 remaining misses are queries with zero surface-term overlap to the plant — a model-
strength limit, not an architectural one.

Cluster A from earlier (AFM no self-knowledge, MLX raw injection, chunked compression
strip) remains in place. Salon state-machine fix and SPM exact pin remain in place.

---

## Working tree

Clean as of `b6f964b`. The HISTORY/HANDOFF/NEXT doc updates for the RAG rebuild are
pending in the next commit.

---

## Active work — pending decisions

Cluster C from May 16 (structured-trait synthesis + scroll behavior) was deferred when
the RAG question surfaced. Those items remain to be done. See `NEXT.md`.

---

## Recent commits

```
b6f964b  Commit C: Hybrid retrieval with Reciprocal Rank Fusion; remove relevance-threshold UI
1550325  Commit B: FTS5 BM25 keyword search replaces LIKE substring path
67efc30  Commit A: Replace NLEmbedding with NLContextualEmbedding everywhere
158dc15  HANDOFF_BRIEF: post-Cluster-A refresh
f43b1e2  Cluster A directive: AFM no self-knowledge, MLX raw inject, strip chunked compression
b26ae8c  Ship blockers: Salon empty-seats safety net + swift-transformers exact pin
```

Full per-commit detail in HISTORY.md.

---

## Architecture (current)

### RAG retrieval (May 17 rebuild)

`searchUnifiedContent` is now hybrid with RRF fusion:

1. **Semantic retrieval** — `NLContextualEmbedding` (via `EmbeddingProvider` singleton)
   produces sentence vectors. Cosine similarity scored across all rows with embeddings.
   Top 50 candidates by score, no threshold.
2. **BM25 retrieval** — SQLite FTS5 (`unified_content_fts` virtual table) with
   `porter unicode61` tokenizer. `bm25()` function ranks. Top 50 candidates.
3. **RRF fusion** — `rrf(d) = sum over each list L of 1/(60 + rank_L(d))`. Combines
   the two ranked lists by RANK, not score. Documents that rank highly in both win.
4. Top `maxResults` from fused list, capped by token budget.

The `relevanceThreshold` variable still exists in AppStorage and per-model settings
for backward compat, but is no longer consulted in the retrieval path. The Settings UI
slider was removed.

### Self-knowledge (May 16)

- AFM: skipped entirely in `buildChatMessages`. AFM users get no persistent self-knowledge.
- MLX: injected raw in `resolveSegment(.selfKnowledge, ...)` — no compression call.

### Salon state machine (May 16)

- Invariant: `salonConfig.isEnabled ⟹ activeSeats.count >= 1`
- Helpers `setSalonEnabled`/`setSalonSeat` enforce; bad state unreachable via API + UI.

### Embedding model

- `NLContextualEmbedding(language: .english)`, 512-dim, on Neural Engine
- Loaded once at app launch via `EmbeddingProvider.shared.warmUp()`
- Per-token vectors mean-pooled to sentence-level
- No fallback embedding system

---

## Diagnostic APIs (added May 16/17)

- `EMBEDDING_STATUS` — is the contextual model loaded? sample vector dim?
- `MEMORY_DUMP:<limit>` — recent unified_content rows, embedding presence
- `MEMORY_SEARCH_DEBUG:<query>` — full hybrid retrieval pipeline trace
- `MEMORY_SIMILARITY_DEBUG:<query>` — raw cosine similarity, threshold-free
- `INJECT_REALISTIC_TEST_CORPUS` — 70-row realistic conversational fixture

### New test harness

- `tests/rag_threshold_eval.py` — 10 ground-truth queries × similarity scoring across
  thresholds. Confirms threshold-based filtering is the wrong knob; RRF supersedes.

---

## Known gotchas

- **NLContextualEmbedding asset download** — on a brand-new install, the model needs to
  download its assets via `requestAssets`. The EmbeddingProvider blocks on first use via
  DispatchSemaphore; subsequent calls are fast. Warm-up at app launch front-loads this.
- **Source code in unified_content** — `Hal_Source.txt` ingested for self-knowledge access
  is a 1.18M-char blob. It's now excluded from BM25 (it matched every common word with
  high TF and dominated ranking). Semantic still includes it. Source-code retrieval needs
  its own dedicated path eventually.
- **Cosine "negative" cases** — semantic loop now skips rows with `similarity <= 0`
  (rare but possible for orthogonal/anti-correlated content). They would add noise to
  RRF without contributing signal.
- **3 ground-truth queries miss in top-10** — Subaru, Berkeley, cello. These are
  queries with no surface-term overlap to the plant ("Where do I live now?" vs "house
  in Berkeley on Vine Street"). Needs entity-aware indexing or a stronger embedding to
  bridge.

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

- **iPhone 16 Plus device ID:** `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
- **Bundle ID:** `com.MarkFriedlander.Hal-Universal`
- **API host:** `marks-bigger-ass-fon-16.local`
- **API port:** 8766
- **API token:** per-install via Keychain — currently `e9ee9ec5b315467fa655bd4296873f43`
- **iPhone 17 Pro simulator:** UDID `7D4E1F1A-E7EC-4C42-BDF1-BF3BC72F4352`

The CLI build avoids the SPM destination-switch hazard fixed by `b26ae8c`.

---

## Test runner — `tests/hal_test.py` + `tests/rag_threshold_eval.py`

```bash
python3 tests/hal_test.py state
python3 tests/hal_test.py turn "Hi"
python3 tests/hal_test.py switch_model "mlx-community/gemma-4-e2b-it-4bit"
python3 tests/hal_test.py rendered_messages
python3 tests/hal_test.py logs [N]
python3 tests/hal_test.py reset
python3 tests/hal_test.py cmd "EMBEDDING_STATUS"
python3 tests/hal_test.py cmd "INJECT_REALISTIC_TEST_CORPUS"
python3 tests/hal_test.py cmd "MEMORY_DUMP:20"
python3 tests/hal_test.py cmd "SALON_GET_STATE"

# RAG eval harness:
python3 tests/rag_threshold_eval.py
```

---

## SOP

1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` after every Hal.swift change.
2. New enum case? Sweep all switches.
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
4. App build number bump happens at App Store submission (currently at 5).
5. Never use `NUCLEAR_RESET` between plant and recall in a memory test.
6. **Update HANDOFF_BRIEF.md, NEXT.md, and HISTORY.md as work lands** (CLAUDE.md Golden Rule #8).

---

## Standing Architectural Rules

- No third-party libraries without explicit discussion.
- One block at a time — surgical changes, build clean after each.
- Discussion before code when introducing new structure; autonomous mode OK when extending
  an agreed plan.
- Old code stays — broken or not — until we're confident the new path covers all callers.
- iPhone 16 Plus is primary target.
- 120-second MLX test timeout.
- API > asking the human — if you can't get an answer from the API, expand the API.
- Warnings are errors (CLAUDE.md Golden Rule #7).
- Docs stay current as work lands (CLAUDE.md Golden Rule #8).
