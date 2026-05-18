# Hal Universal — Handoff Brief
**Updated:** May 18, 2026 (morning — Evolutionary Salon happened, v1 build spec written, Phase 1 of crystallization landed)
**Branch:** `main` (about to commit combined Phase 1 + deferred extraction/AFM-audit/threshold work + salon archive + build spec)
**Working tree:** SelfKnowledgeEngine.swift (new) + Hal.swift edits + EmbeddingBackend.swift + sync script + Hal_Source.txt resync + Docs/Evolutionary_Salon_2026-05-17/ (new) + Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md (new) + four doc updates, all committed together

> **For the next CC session:** read this brief, then `NEXT.md` for Phase 2
> of the v1 crystallization build (TraitCrystallizer.swift + reinforcement-
> based promotion), then the 2026-05-18 morning entry of `HISTORY.md` for
> Phase 1 details and the Evolutionary Salon chronicle, then
> `Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md` for the full spec,
> then `CLAUDE.md` for standing rules.

---

## TL;DR — where Hal is right now

Three big things landed this session:

1. **Three-backend embedding system + dynamic BM25 quality gate.**
   - NLContextual (default, built-in, 512-dim)
   - EmbeddingGemma (compiled out via `HAL_ENABLE_EMBEDDING_GEMMA` —
     blocked by upstream MLX iOS Metal crash)
   - Nomic Embed Text v1.5 (opt-in via Model Library, 522 MB,
     swift-embeddings on Apple's MLTensor)
   - Dynamic BM25 quality gate: measures semantic relative spread
     and BM25/semantic top-K median agreement per query, includes
     or excludes BM25 from RRF accordingly. Self-correcting, no
     hardcoded rules.
   - **Recall on device (10 ground-truth queries, 70-row corpus):**
     - NLContextual: 1/10 top-1, 4/10 top-5, 7/10 top-10
     - Nomic + gate: **9/10 top-1, 10/10 top-5, 10/10 top-10**

2. **LLM-driven query expansion (async).**
   - `QueryExpansion.expand(query:memoryStore:llmService:)` is `async`,
     no DispatchSemaphore (the prior version deadlocked under MainActor).
   - Triggers when initial top-1 RRF < 0.020 AND !isEntityMatch.
   - SQLite cache keyed by `(SHA-256 of normalized query, model_id)`.
     Cleared on model switch.
   - Doesn't move numbers on this corpus (the gate already maxes Nomic;
     under NL the LLM produces conceptual synonyms that don't lexically
     match plant text), but infrastructure is solid for richer corpora.

3. **5-item UX sequence + two Item-5 follow-ups: all done.** History.
   (Salon cold-launch guard, scroll rewrite, visual verifications,
   PromptDetailView wired with collapse-bug fix, §7 BGDL long-lock
   passed including jetsam-kill recovery, progress-bar-on-recovery
   fix, Model Library plain-style consistency.) See HISTORY for
   2026-05-17 entries.

4. **Yesterday's late-evening deferred work:** SelfKnowledgeEngine.swift
   extraction from Hal.swift (~1,844 lines, three LEGO blocks pulled
   into one new file), per-backend `recommendedSynthesisThreshold` on
   EmbeddingBackend, and AFM gate audit that found two real gaps
   (reflectOnExperience and consolidateAndDecay both fired regardless
   of active model — fixed). All committed today with Phase 1.

5. **The Evolutionary Salon ran (2026-05-17 evening).** 4 seats
   (Gemma, Llama, Qwen, Dolphin), independent mode, no host. 5.5 min
   wall clock for all four. Raw output archived at
   `Docs/Evolutionary_Salon_2026-05-17/`. Decisions carried into v1
   spec: per-category threshold (no global N), multi-valued
   contradiction handling, Qwen's trait-generator template
   (minus the meta-commentary forbidding), add Meta-Cognition as 7th
   category, no readiness mechanism.

6. **v1 build spec written and Phase 1 landed.**
   `Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md` is the spec.
   Phase 1 (today) added two nullable columns to `self_knowledge`
   (`promoted_to_trait_id`, `shareability_decided_by_model`) with
   ALTER migration, added Meta-Cognition handling to
   `buildSelfKnowledgeContext`, and added a `DB_SCHEMA:<table>` API
   diagnostic. Migration verified on real device (22 columns now,
   the two new ones at positions 21 and 22). Phase 2 next:
   TraitCrystallizer.swift + reinforcement-based promotion.

---

## File layout (extracted from Hal.swift this session series)

```
Hal Universal/
├── EmbeddingBackend.swift              — backend enum + crash guard + UI strings
│                                          (+ recommendedSynthesisThreshold per-backend)
├── EmbeddingProvider.swift             — 3-backend dispatch + MemoryStore ext
├── EmbedderMigrationCoordinator.swift  — @MainActor state machine + UI rows
├── QueryExpansion.swift                — async expansion + SQLite cache
├── PromptDetailView.swift              — color-coded segments, collapsible sections
├── SelfKnowledgeEngine.swift           — NEW (2026-05-17 late eve): MemoryStore
│                                          self-knowledge CRUD, maintenance, reflection
│                                          orchestration. Extracted from Hal.swift LEGO
│                                          blocks 4.1/4.2/4.3 (~1,900 lines). +
│                                          Phase 2 helpers: getTraitCandidates,
│                                          markReflectionPromoted.
├── TraitCrystallizer.swift             — NEW (2026-05-18, Phase 2): reflection-to-trait
│                                          promotion engine. Per-category reinforcement
│                                          thresholds, candidate scanner, Qwen-derived
│                                          trait-generator LLM prompt, JSON parse +
│                                          INSERT-trait + stamp-lineage. Chained into
│                                          Type 1 reflection Task in chat path under
│                                          AFM gate.
└── Hal.swift                           — everything else (~19.7k lines, shrinking)

scripts/
└── sync_hal_source.sh                  — concatenates all .swift into Hal_Source.txt
                                          for self-knowledge ingestion (per CLAUDE.md SOP)
```

When you extract a new file, add it to the `FILES` array in
`sync_hal_source.sh` and re-run it.

---

## Build flags

- `HAL_ENABLE_EMBEDDING_GEMMA` — Debug only. Gates the Gemma backend's
  code path. Release builds compile it out; the UI hides the Gemma row.

## Dependencies

```
mlx-swift 0.31.3
mlx-swift-lm 3.31.3        (MLXLLM + MLXLMCommon + MLXHuggingFace + MLXEmbedders)
swift-transformers 1.3.3   (exactVersion pin)
swift-embeddings 0.0.27    (exactVersion pin) — Nomic backend
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
- API host: `marks-bigger-ass-fon-16.local` (mDNS — phone awake + on WiFi)
- API port: 8766
- API token: `e9ee9ec5b315467fa655bd4296873f43` (in `tests/.hal_api_config.json`)
- iPhone 17 Pro sim UDID: `10C6DB49-2723-4F95-8F81-AECB9CD72BD0`
  - sim token: `950c39cf55574c3180734785ec3c52da` (in `tests/.hal_api_config_sim.json`)

For sim runs: `HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/hal_test.py …`

---

## SOP (refactor-as-you-go is mandatory)

1. **After any change to Hal's source, sync `Hal_Source.txt`:**
   ```bash
   ./scripts/sync_hal_source.sh
   ```
2. **Significant changes to a section of Hal.swift → extract into a
   dedicated file.** Use any of the existing extracted files as a
   template (EmbeddingBackend.swift, EmbeddingProvider.swift,
   EmbedderMigrationCoordinator.swift, QueryExpansion.swift,
   PromptDetailView.swift).
3. New enum case → sweep all switches.
4. New AppStorage key → `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
5. App build number bump happens at App Store submission (currently 5).
6. Never `NUCLEAR_RESET` between plant and recall in a memory test.
7. **Update HISTORY/HANDOFF/NEXT as work lands** (CLAUDE.md Golden Rule #8).
8. **Warnings = errors** (CLAUDE.md Golden Rule #7).
9. **API > asking the human** — expand the API if a question can't be
   answered through it.

---

## New diagnostic / UI API commands this session

| Command | Purpose |
|---|---|
| `SET_UI_STATE:<settings\|threadPanel\|none>:<true\|false>` | Programmatic sheet toggle for automation |
| `SET_FORCE_EXPANSION:<true\|false>` | Force LLM expansion on every query (diagnostic) |
| `MEMORY_SEARCH_EXPANDED:<query>` | Two-pass search-with-expansion diagnostic |
| `CLEAR_QUERY_EXPANSION_CACHE` | Wipe cache |
| `QUERY_EXPANSION_CACHE_STATUS` | Count cached entries |
| `DOWNLOAD_EMBEDDING_MODEL[:<backend>]` | Catalog-driven download |
| `EMBEDDING_DOWNLOAD_STATUS[:<backend>]` | Progress poll |
| `SET_EMBEDDING_BACKEND:<name>` | Switch backend, wipe embeddings |
| `MIGRATE_EMBEDDINGS_REEMBED` | Re-embed all NULL rows |
| `FTS_DIAG` | FTS5 row counts + sample MATCH |
| `DB_SCHEMA:<table>` | NEW (2026-05-18) PRAGMA-based schema inspection for any table |

---

## Known caveats

- **EmbeddingGemma is compile-out in Release builds** — upstream MLX
  Metal init crash on iOS 26.5. Code stays behind
  `HAL_ENABLE_EMBEDDING_GEMMA` ready to re-enable.
- **Nomic load takes ~10–15 s on iPhone 16+** (MMAP-loading 546 MB
  safetensors + tokenizer JSON). Subsequent embeds are fast (~80 ms).
- **FTS5 first-inject-after-install glitch** (documented earlier
  today): a fresh install with an immediate inject sees BM25 return 0
  candidates until a NUCLEAR_RESET + re-inject. The eval workflow does
  the reset.
- **Pre-existing nonisolated/MainActor warnings in PromptDetailView.swift**
  (export-tag + token-budget helpers, ~7 warnings). They've been there
  since commit `61f8240` and are unrelated to this session's changes.
  Worth a follow-up commit to clean up per Golden Rule #7, but not a
  blocker.
