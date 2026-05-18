# Hal Universal — Handoff Brief
**Updated:** May 17, 2026 (later evening — Items 1–5 done, two Item-5 follow-ups landed, Item 6 queued)
**Branch:** `main` (about to commit Item 5 follow-ups + Item 6 doc)
**Working tree:** progress-bar-on-recovery bug fix in Hal.swift + Model Library plain-style consistency in EmbedderMigrationCoordinator.swift + four doc updates, will be committed together

> **For the next CC session:** read this brief, then `NEXT.md` for what to
> do next (Item 6 — UI consistency sweep — is the next concrete step), then
> the 2026-05-17 later-evening entry of `HISTORY.md` for how the §7 BGDL
> long-lock test passed (including the harder jetsam-kill-mid-lock case)
> and the two follow-ups that came out of it, then `CLAUDE.md` for
> standing rules.

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

3. **5-item UX sequence + two Item-5 follow-ups: all done. Item 6 queued.**
   - Item 1: Salon cold-launch guard ✓
   - Item 2: Scroll behavior rewrite ✓ (user msg at top, no auto-scroll)
   - Item 3: Visual verifications ✓ (all surfaces clean on sim)
   - Item 4: PromptDetailView color-coded + collapsible ✓
     (wired into ChatBubbleView's assistant-side contextMenu, collapse
     bug fixed via stable segment IDs, legacy unused view removed)
   - Item 5: BGDL long-lock test ✓ PASSED — and passed the harder
     case where iOS jetsam-killed Hal during the lock window. All four
     §7 verification markers fired: bg URLSession kept running in
     nsurlsessiond while Hal's process was dead, downloaded ~1.9 GB
     autonomously, then `migrate ✅ model.safetensors bg→fg with 14341
     bytes of resume data` on unlock. The 1.5s settle delay from
     commit `f78de2c` correctly suppressed the duplicate-enqueue race.
   - Item 5 follow-up A: Progress-bar-on-recovery bug ✓ — Mark caught
     that the Model Library UI showed no progress bar after a jetsam-
     and-resume, even though BGDL was actively downloading. Root cause:
     `resumeInFlightDownloadsIfAny` correctly says "don't re-trigger
     startDownload" when BGDL has in-flight tasks, but it never seeded
     `MLXModelDownloader.downloadStates[modelID]` either. Fixed by
     seeding the @Published dict + spawning a polling task that
     mirrors BGDL byte progress into it.
   - Item 5 follow-up B: Model card UI consistency ✓ — Mark flagged
     that LLM rows and embedding rows had different action-row styles
     (plain icon+text vs .borderedProminent pills). Made embedding
     match LLM (Option A). All Model Library rows now use the same
     plain icon+text style with consistent spacing.
   - Item 6: UI consistency sweep (queued, see NEXT.md) — broader
     pass across Settings, Salon panel, system-prompt editor,
     compression popover, document import, NUCLEAR_RESET dialog, etc.

---

## File layout (extracted from Hal.swift this session series)

```
Hal Universal/
├── EmbeddingBackend.swift              — backend enum + crash guard + UI strings
├── EmbeddingProvider.swift             — 3-backend dispatch + MemoryStore ext
├── EmbedderMigrationCoordinator.swift  — @MainActor state machine + UI rows
├── QueryExpansion.swift                — async expansion + SQLite cache
├── PromptDetailView.swift              — NEW (2026-05-17 eve), color-coded segments
└── Hal.swift                           — everything else (~22k lines, shrinking)

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
