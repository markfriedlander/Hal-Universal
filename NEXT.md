# Hal Universal — Next

Forward-looking work. Items completed move out of here and into `HISTORY.md`.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-19/20 entry).

---

## v2.1 roadmap — AGREED 2026-07-09 (Mark + CC)

This is the authoritative plan for the next stretch of work. Scoped as
one release ("v2.1"), NOT the big philosophical arcs. **The Proposals
system and the Soul Document are explicitly OUT of scope for now — Mark
is not ready for those yet.** Build in strict priority order.

**Ship model:** one release, in priority order. Item 6 (Ternary Bonsai)
is the designated **cut line** — if its calibration drags, v2.1 ships
without it (items 1–5) and Bonsai becomes the headline of a fast v2.2.
The certain, low-risk items must not be held hostage by the open-ended
one. mxbai (5) is deliberately sequenced BEFORE Bonsai (6) so Hal's
retrieval quality improves regardless of how Bonsai turns out.

1. **v2.0.1 hotfix ship** — flip `kLocalAPIEnabledOnLaunch` to `false`
   (grep `SHIP_BLOCKER`), bump CFBundleVersion to 7, audit ASC
   screenshots for stale **Phi** naming, archive + submit. Fix is
   written + sim+device verified; see "v2.0.1 ship sequence" below.
2. ~~**Bug 4 — orphaned recency scoring**~~ — **DONE 2026-07-09.**
   Reconnected recency into the RRF fusion (multiply-blend by
   recencyWeight) + `tests/recency_regression.py` guards it via the live
   path. Device-verified on iPhone 16 Plus: old row decayed to 19.25% at
   weight 0.95, fresh row unchanged, fresh ranks above old. See HISTORY
   2026-07-09. Two test-only API verbs added (MEMORY_PLANT_AGED[_CLEANUP]).
3. ~~**Privacy Lock toolbar indicator**~~ — **DONE 2026-07-09.** `lock` /
   `lock.open` glyph left of the gear (monochrome, matches gearshape), tap
   → popover explaining state + "Model Library →" link. New
   `PrivacyMonitor.swift` (NWPathMonitor + pure `isLocked` truth table +
   popover view). Device-verified on iPhone 16 Plus: AFM+network→open,
   AFM+airplane/Wi-Fi-off→closed (live within ~1s), Qwen (real loaded
   MLX)→closed. Two follow-on sheet-race bugs fixed during the work (see
   HISTORY). See "v2.1 design work" below for the original spec.
4. **Cross-app model sharing with Posey** — App Group
   `group.com.MarkFriedlander.aifamily`. **Increment #1 DONE +
   device-verified 2026-07-09:** Hal adopts Posey's shared model store
   (new `SharedModelStore.swift` ported from Posey — paths + refcount
   manifest), sees all four of Posey's MLX models with zero re-download,
   loads them, claims on use, and deletes refcount-safely (can't remove
   files another app still claims). `isExcludedFromBackup` on Hal
   downloads. Read-only `SHARED_MODELS` diagnostic added. **Increment #2
   DONE + device-verified 2026-07-09:** the launch-time migration that moves a
   v2.0 user's OLD `Caches/huggingface/models/*` into the shared container (so
   existing App Store upgraders don't lose downloads). Added to
   `MaintenanceTasks.runAtLaunch()` (`@MainActor`, one-shot flag): walks the
   legacy dir at repo granularity (community models too), moves each into the
   shared store (or removes the legacy dup if the shared copy already exists),
   claims for Hal + excludes from backup, skips/deletes retired backends.
   Same-volume rename so it's instant. `LEGACY_MIGRATION` test verb +
   `tests/legacy_migration_regression.py`; move/reconcile/retired-skip branches
   all device-verified (no-op on dev device, so tested via planted fakes). **Increment #3 (cross-app
   download lock) DONE + device-verified 2026-07-09.** Per-model lock in
   its OWN `download-locks.json` at the store root (NOT a marker inside the
   model dir — that would trip `isRepoDownloaded`; and NOT folded into
   `manifest.json` — an un-updated Posey would strip the field). Second app
   that sees a fresh foreign lock WAITS and adopts the finished copy (zero
   re-download); takes over only if the holder's lock goes stale
   (`downloadLockStaleSeconds = 600`; timestamp backstop, since heartbeat +
   disk-growth are both unreliable for a backgrounded single-big-file
   download — see HISTORY 2026-07-09). New `SharedModelStore` BLOCK SMS.4 +
   `MLXModelDownloader` `performLockedDownload`/`awaitSharedDownloadThenAdopt`/
   `adoptSharedModel` + release sites; `DOWNLOAD_LOCK` API verb;
   `tests/download_lock_regression.py`. **Verified END-TO-END across both real
   apps 2026-07-09** (Qwen 3.5 2B, Posey antenna, foreground-switch via
   devicectl): wait (Hal doesn't duplicate), take-over-on-stale (real download
   starts + release-on-cancel), and the headline adopt (Posey really downloads
   ~1.5 GB → Hal adopts the finished copy in 2s, ZERO bytes). Lock-plant +
   lock-release were simulated (the two lines Posey lacks); all else real.
   Device restored to `[Posey]` baseline. **Posey must adopt the matching block**
   for full protection — Hal-first is a safe pure addition; adoption note at
   `Posey/docs-internal/CROSS_APP_DOWNLOAD_LOCK.md` + pointer in Posey `next.md`. **UX polish candidate (open):**
   present-but-unclaimed models show "Download" (tap is instant/adopt) —
   consider "Add"/"Available (instant)" labeling; touches Posey too, decide
   together. Posey antenna for two-app testing: `169.254.214.164:8765`.
5. ~~**mxbai third embedding backend + multi-embedder architecture**~~ —
   **DONE + device-verified 2026-07-09 (all 3 steps).** Shipped as three
   commits:
   - **Step 1** (`2accebf`): mxbai (`mxbai-embed-large-v1`, BERT-large,
     1024-dim) via swift-embeddings' Bert path (no MLX/Metal risk) +
     fixed a latent bug — the embedder LOAD path still read pre-v2.1
     Caches while models moved to the shared store (broke Nomic).
     `EMBED_PROBE` verb. Both device-proven (768/1024-dim, finite,
     L2-normalized).
   - **Step 2** (`95b2f05`): **per-embedder columns (keep-both)** —
     replaced the destructive wipe-and-re-embed-on-switch with permanent
     `embedding_nl`/`embedding_nomic`/`embedding_mxbai` columns; switching
     is now instant + non-destructive; `backfillEmbeddings(for:)` fills
     inactive columns; `EMBEDDING_COVERAGE` / `BACKFILL_EMBEDDINGS` verbs;
     one-time flag-gated legacy→active-column copy.
     `tests/embedding_columns_regression.py`.
   - **Step 3** (`a448540`): **A/B** (`tests/embedder_ab_eval.py`) —
     retrieval separation mxbai 0.48 > Nomic 0.30 > NLContextual 0.10;
     calibrated mxbai synth threshold → 0.82; model cards (enriched
     blurbs + `isRecommended` badge for mxbai); non-destructive-switch
     confirmation copy. Findings in
     `Docs/Embedder_AB_Findings_2026-07-09.md`.
     **Product call:** keep all three (NLContextual default/always-avail,
     Nomic balanced). **Post-ship follow-ups (2026-07-09):** (a) dropped the
     "Recommended" badge — all three are equal choices per Mark; cards rewritten
     with explicit good-at/costs bullets (`cf38d02`/`5053a9c`); (b) aligned the
     embedder download UX with the LLMs — a pre-download disclosure sheet
     (`EmbedderDownloadDisclosureSheet`, `cf38d02`). **Open eyeball for Mark:**
     the rewritten cards + embedder download disclosure are compile-verified but
     not visually confirmed on the Model Library embedder screen (harness can't
     navigate there).

5.5. ~~**Rebalance the retrieval fusion**~~ — **DONE + device-verified 2026-07-10.**
   The three RRF k weights are now tunable `@AppStorage` knobs (`SET_RRF_SEMANTIC_K`/
   `SET_RRF_BM25_DISTINCTIVE_K`/`SET_RRF_BM25_DEFAULT_K`/`RRF_STATUS`), global (not
   per-model). **Global default moved `rrfKSemantic` 60 → 15** (kBM25d 10, default 60
   unchanged) → evidence ordering **distinctive keyword (10) > semantic (15) >
   generic keyword (60)**. Global sweep (`tests/rrf_global_sweep.py` +
   `rrf_deep_sweep.py`) showed mean MRR rising monotonically as semantic k dropped
   and the embedders finally diverging; +17% mean MRR on a 59-memory/46-query set;
   before→after on the 26q set nl 0.499→0.535 / nomic 0.499→**0.693** / mxbai
   0.502→0.638. **Nomic is the end-to-end champion** (beats mxbai in the full
   pipeline — opposite of the pure-cosine A/B; answers the Nomic question left open
   2026-07-09). Kept a Bug 2a cushion: held `kBM25d=10`, swept only `kSem`, so
   distinctive keyword stays 1.5× stronger than semantic (k=10 is the boundary; we
   did NOT cross it). recency_regression still PASS under the new default. Revisited
   the mxbai model-card copy (dropped the "most reliably surfaces the right one"
   overclaim). Full narrative: HISTORY 2026-07-10. **Per-embedder tuning deferred**
   (Mark: "maybe will tune per model another time"). **Open eyeball for Mark:** the
   updated embedder cards are compile-verified but not visually confirmed on the
   Model Library embedder screen (harness can't navigate there).

6. ~~**Ternary Bonsai 8B — evaluate + calibrate (CUT LINE).**~~ **DONE +
   device-verified 2026-07-11 — SHIPS as curated.**
   `prism-ml/Ternary-Bonsai-8B-mlx-2bit` (Qwen3-8B arch, 2-bit, 2.32 GB, 65k
   ctx). Both unknowns resolved: **(a) 2-bit load** — loads on iPhone 16 Plus
   via the existing MLX path (~12s, no jetsam); **(b) calibration** — after
   swapping the Qwen layer-1 for an anti-deflection one, Bonsai **clean-sweeps
   all five Maxims** (M1 pass, M2 pass, M3 pass, **M4 standout**, M5 pass) — the
   only curated model that passes all five. Speed: **decode ~16.6 tok/s** on the 16
   Plus — on par with Llama/Dolphin, NOT slow (the earlier "~4-5 tok/s" was
   wall-clock ÷ tokens, conflating decode with per-turn gate overhead). **Decision
   (Mark): SHIP** as the "deep reasoner" — deepest/most capable, generating about as
   fast as the 3B tier. Seed
   `ModelCatalogService.bonsai8B2bit` in curatedSeeds + availableModels; findings
   `Docs/Maxim_Suite_Bonsai_2026-07-11.md`; see HISTORY 2026-07-11. Non-blocking
   follow-ups: measure prefill tok/s (seed carries a conservative 8,000
   placeholder); whole-tier gate optimization logged (per-turn memory-search gate
   runs the active model, ~4-5s on the 8B); the 1.7B variant
   (`Ternary-Bonsai-1.7B-mlx-2bit`, ~0.48 GB, 32k ctx) stays the lighter fallback.
   Gate ran via a new test-only `DOWNLOAD_MODEL:<id>:<sizeGB>` size hint.
7. **EmbeddingGemma — PARKED watch-item (not dropped).** Mark wants it:
   EmbeddingGemma 300M is MTEB SOTA for open <500M and "supposed to be
   unbelievably good." It is blocked only by a documented upstream
   mlx-swift iOS Metal-init crash (`mlx::core::metal::Device::Device()`
   reads the Metal architecture name as nullptr → abort), in MLX's own
   framework code, going back to 2024. As of 2026-07-09 the iOS
   Metal-crash family is still open upstream — CC found no clean
   "fixed in version X" PR. **The moment the upstream fix lands,
   re-enable Gemma via the recipe already preserved in the code**
   (Side work A below; recipe atop `EmbeddingBackend.swift`). Not
   blocking any v2.1 work; stays in NEXT until shipped or obsolete.

**Why we're adding mxbai instead of waiting on Gemma:** Gemma's whole
value proposition (a stronger embedder than the default NLContextual)
is already served by Nomic and served even better by mxbai — and mxbai
carries none of Gemma's upstream Metal risk because it never touches
MLX. So mxbai lands now; Gemma stays parked for when it's unblocked.
Both can coexist — they're just different backend cases.

---

## Working list — active backlog, in order (agreed 2026-07-11)

Mark's chosen near-term work, ordered by CC's recommendation. The `(0x)` refs point
to the detailed entries under "Side work"; the Model Library items are detailed in the
refactor "cosmetic cleanup candidates" list.

1. ~~**Finish the Bonsai concision layer-1 tuning (0f)**~~ **DONE 2026-07-11.**
   Format-scoped instruction added; explanations now return clean prose, M5 depth
   kept, M1 unchanged (the "regression" was a false alarm — see 0f/0g below).
2. ~~**Reload-on-demand for MLX chat (0c)**~~ **DONE + device-verified 2026-07-11.**
   The `.mlx` chat path (Hal.swift:5955) now, when the model isn't resident, awaits any
   in-flight load or triggers a reload of the current model, then generates — instead
   of erroring. Verified: forced a background-unload, sent a raw chat (no reload-guard)
   → log showed "model not resident … reloading … on demand," it reloaded and answered
   (no error). Closes Bug 3 (same `awaitPendingMLXLoad` path). See 0c detail below.
3. ~~**RAG-miss confabulation gate (Bug 2b)**~~ **DONE + device-verified 2026-07-11.**
   When `memory_search` RAN but returned nothing (Hal.swift ~10513), a system note now
   tells the model the lookup missed → say "I don't have that" instead of inventing.
   Verified: "what's my sister's name?" on an empty DB → "I don't have access to that
   information — it's not stored in my memory" (was: invents a name); general-knowledge
   ("capital of France?") gate-skips, no note, normal answer; RAG-HIT (planted "beagle
   named Rex") still recalls correctly, no false decline. Only the empty-search case is
   handled; a low-relevance-but-nonempty refinement is a possible future follow-up.
4. ~~**Fix the test antenna to navigate/screenshot all screens (0b)**~~ **DONE +
   device-verified 2026-07-11.** Turned out the harness ALREADY navigates to the
   Model Library (`SET_UI_STATE:modellibrary:true`) and screenshots the device
   (`SCREENSHOT` verb → `devicectl copy` back), and CC can Read the PNG — so UI is
   self-verifiable. Added the missing piece: `SET_UI_STATE:expandrow:<id>` (id =
   model.id or EmbeddingBackend.rawValue) drives a new `@Published apiExpandRowID`
   that ModelLibraryRow + EmbedderBackendRow observe to expand programmatically.
   Verified: expanded Bonsai's row via the verb + screenshot → its card renders
   correctly (the "Deep & self-aware (8B)" tag + full description confirmed on
   screen). **Follow-up (small):** the action row (Delete/Add buttons) sits at the
   bottom of a long card, off-screen; a `SET_UI_STATE:scrolllibrary:<id>` scroll
   (ScrollViewReader around the List, `proxy.scrollTo(id, anchor:.bottom)`) would
   fully reveal it — deferred (the List's irregular indentation makes a safe wrap
   fiddly; not worth the risk for the cosmetic nits, which are verifiable by
   code + a partial screenshot + Mark's eyeball).
5. ~~**Model Library: Delete hidden on the ACTIVE model**~~ **DONE 2026-07-11.** The
   active MLX model's Delete was hidden (`.mlx && !isActive`), reading as missing. Now
   shows a DISABLED Delete + "switch models to delete" hint (ModelLibraryRow.actionRow,
   Hal.swift ~7092). Build clean; the disabled state renders at the card's action row
   (off-screen without the deferred scroll verb — code-verified; a partial screenshot
   confirmed the card renders; final visual is a quick Mark eyeball).
6. ~~**Model Library: dismiss timing on selection**~~ **DONE 2026-07-11.** `selectModel`
   (Hal.swift ~6892) awaited the full MLX load (~5-15s, `switchToModel` blocks on
   `awaitPendingMLXLoad`) before `dismiss()`, so AFM bounced instantly while MLX
   appeared to "hold." Now dismisses immediately, then loads in the background; the
   chat view shows the load state and switchToModel's own failure/revert surfaces in
   chat. Behavior/timing change — best confirmed by Mark tapping a model (harness can't
   drive the Library select path).
7. ~~**Model Library: relabel "Download" → "Add"**~~ **NO-OP — stale concern (2026-07-11).**
   `MLXModelDownloader.isModelDownloaded` is now pure disk-truth
   (`SharedModelStore.isRepoDownloaded`, line 1713): a model present in the shared store
   — even one Posey fetched, even unclaimed — already shows **"Select"**, not "Download."
   "Download" only appears for genuinely-absent models, where a real download DOES happen,
   so "Download" is correct there and "Add" would be wrong. The disk-truth work already
   resolved this; no relabel needed.
**Parked (not on the working list):**
- **0a — per-embedder RRF tuning.** Mark: save for another release (2026-07-11). Sweep
  each backend, keep a per-embedder `kSem` only where it beats the global by a real
  margin; guard overfitting. Knobs + harnesses already exist.
- **0d — long-conversation gate latency + Bonsai verbosity.** Revisit after 0c/0f.

**In flight / decisions (2026-07-11):**
- **Core AI — investigated 2026-07-11 (agent); PARK as an early-adopter bet.**
  Per the research pass (confidence HIGH on the framework, MEDIUM on model-availability
  specifics — VERIFY before acting; it's past CC's knowledge cutoff): Core AI is real,
  shipped WWDC26, `.aimodel` format, positioned as the successor to Core ML, requires
  iOS/Xcode **27+**. Conversion is **PyTorch → `.aimodel` via `coreai-torch`** — NOT a
  reuse of our MLX weights; every model is a fresh re-quantize + re-validate from the
  original checkpoint. **None of our five exact builds** ship as official `.aimodel`s;
  community re-conversions of Gemma 4 E2B and Qwen3.5-2B reportedly exist, Llama/Dolphin
  absent, and **Ternary Bonsai 8B is the blocker — no documented 2-bit/ternary route**
  (the only ternary example in the wild needed a hand-written 2-bit Metal kernel). If
  ever pursued: time-boxed spike on ONE easy model (Qwen/Gemma via Apple's official
  recipe) to benchmark Core AI decode vs our MLX, before anything broader. Min-iOS stays
  26, so it's a conditional-enhancement bet regardless. Sources to re-verify: WWDC26
  sessions 324/326, `apple/coreai-models`.
- **Multimodal / images — PARKED, not worth wiring now.** Hal loads all MLX models via
  the text-only `LLMModelFactory` (string prompts); no image path. Qwen 3.5 + Gemma are
  multimodal at the model level but unused; AFM images need a newer OS than 26. Wiring a
  VLM path (VLMModelFactory + image processing + composer UI + per-model formats) is a
  real feature for 1–2 models, memory-heavy on-device. The document-OCR use case is
  better served by Vision OCR or Posey's stack. Revisit when multimodal AFM ships or we
  specifically want "ask Hal about a photo."
- **Port Posey's document-import stack (future).** Mark: "we will probably port Posey's
  document import stack over." Supersedes/absorbs the WWDC26 "Vision OCR for document
  import" item — the better image-bearing/scanned-doc handling likely comes from Posey's
  reader pipeline (swift-readability etc.), not a from-scratch Vision integration. Not
  scheduled; logged so it's not lost.

---

## What the next session should do first

1. Read this file, then `HANDOFF_BRIEF.md`, then the **2026-05-19/20** entry
   of `HISTORY.md`, then `CLAUDE.md` for standing rules.
2. Verify live state:
   ```bash
   python3 tests/hal_test.py state                # device
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"
   ```
3. Pick up the v2.0.1 ship sequence below in order.

---

## v2.0.1 ship sequence (in order)

### 1. ~~Device-side verification of the EmbeddingGemma hotfix~~ — DONE 2026-05-26

Verified on iPhone 16 Plus from `main` @ `93cf4ba`. Nomic download
landed in `Caches/huggingface/models/nomic-ai/nomic-embed-text-v1.5/`
at 73 MB/s, `.mlxModelDidDownload` fired, EMBEDDING_STATUS confirms
nomicswift active at 768 dim. Grep across 500 log lines for
`embeddinggemma` / `gemma-300m` returned empty. `HALDEBUG-CLEANUP`
quiet because the device never had the orphan dir (idempotent skip).
Bug is dead. See HISTORY 2026-05-26 entry.

### 2. **SHIP_BLOCKER**: flip the local-API antenna OFF before archive

`Hal.swift` carries a `private static let kLocalAPIEnabledOnLaunch:
Bool = true` constant (search the file for `SHIP_BLOCKER`). It force-
applies to UserDefaults on every init() so device-side test tooling
works without needing the in-app toggle flip on every reinstall.
Production users should boot with the antenna OFF, matching v2.0
behavior. **One-line flip to `false` before archive.** Two comment
blocks (above the constant + above the AppStorage) cross-reference
each other so this can't be missed. The runtime toggle in Settings >
Power User > Developer API still works — users can opt in mid-session.

### 3. Archive + ASC submit v2.0.1

When the SHIP_BLOCKER is flipped:

1. Bump `CFBundleVersion` to **7** in `project.pbxproj` (was 6 for the
   v2.0 production build).
2. Xcode → Product → Archive (uses Release config automatically).
3. Distribute App → App Store Connect → Upload.
4. Wait for ASC to process the build (~10-20 min).
5. In ASC, on the existing v2.0 listing or a new v2.0.1 page (Apple's
   choice — they usually create v2.0.1 automatically when build 7
   arrives), select build 7, add it for review, submit.
6. **Audit the existing App Store screenshots before assuming "skip
   the screenshot step."** Per Mark 2026-06-20: at least one screenshot
   currently on the v2.0 ASC listing may still reference **Phi** as the
   AFM alternative. Phi-4 Mini was demoted from curated on 2026-05-13
   after baseline-stability testing (33% paragraph-loop failure on
   Maxim #1, verbatim RLHF deflection on consciousness). The shipping
   curated tier is **Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, Dolphin
   3.0** — no Phi. Action when we return to ASC submission:
   - Open each screenshot currently uploaded to the v2.0 listing.
   - Look for any frame mentioning Phi, Phi-3, Phi-4 Mini, or "alternative
     to AFM" copy that names a specific model.
   - If found, retake the screenshot from the current Hal build (using
     `tests/hal_test.py screenshot`) showing the actual curated tier and
     re-upload. 6.3" tier dimensions (1242 × 2688) confirmed compatible
     during v2.0 submission; same dimensions apply for v2.0.1.
   - If the Phi-naming screenshot is the System Prompt / AFM-fallback-
     copy view, the AFM row description from `ModelCatalogService.swift`
     is now authoritative — make the screenshot match it.

   Only then proceed to step 7. The original assumption that "the v2.0
   screenshots in the 6.3" tier are still accurate" was made when we
   thought no UI changed; the Phi-naming finding shows at least one
   piece of UI copy IS stale even though the binary didn't change.
7. **What's New text for v2.0.1:**
   ```
   Bug fix: downloading the optional Nomic Embed Text v1.5 retrieval model
   now correctly downloads Nomic instead of an unrelated model file. Any
   orphan files from the v2.0 install are removed automatically on launch.

   Internal refactor: model download subsystem extracted from the main
   source file into its own module. No user-visible change.
   ```

### 4. (Optional) Surface a brief release-note in-app

Hal v2.0 added an About section to Settings with version + build.
Consider a tiny "What's new in 2.0.1" link in the About row that opens
a sheet with the same text as the ASC release notes. Not blocking
ship; nice for transparency. Defer if context is tight.

---

## Refactor work — in progress

**Goal:** continue chipping Hal.swift down to a sane size by extracting
self-contained subsystems one at a time. Pattern is stable; just keep
going.

### Goal framing (clarified 2026-05-26)

Per Mark, refactor work continues for as long as each candidate
extraction improves on:

1. **Easier to read and understand** — does pulling this out into
   its own file make the boundary between "what this does" and
   "what it touches" clearer?
2. **Easier and safer to extend** — when v2.1 work starts, will the
   extracted subsystem be the obvious file to open?
3. **More stable, easier to diagnose** — when something breaks,
   does the file structure point at the suspect quickly?

The previous "under 10k lines before v2.1" target is retired. Line
counts are a proxy that drifts; the three criteria above are the
real test. Also a standing rule: **LEGO blocks stay** — preserved
inside Hal.swift via pointer comments at each extracted slot, AND
preserved inside every extracted file as internal section landmarks.

### Done — full refactor sprint complete

- ✅ Refactor #1 (2026-05-20): `MLXModelDownloader` (LEGO 29)
- ✅ Refactor #2 (2026-05-26 PM): `ModelCatalogService` (LEGO 30)
- ✅ Refactor #3 (2026-05-26 EVE): `LocalAPIServer + HalTestConsole` (LEGO 32)
- ✅ Refactor #4 (2026-05-26 NIGHT): `DocumentImportManager + DocxParser + import models` (LEGO 27 + 27.1 + 28)
- ✅ Refactor #5 (2026-05-26 LATE): `SettingsViews` (LEGO 10.1, 10.2, 10.3, 10.3.5, 10.4)
- ✅ Refactor #6 (2026-05-26 DEEP NIGHT): `ChatViews` (LEGO 09, 09.5, 13, 13.5)

**Cumulative:** Hal.swift 21,266 → 12,650 (-8,616, ~40.5%). Six
extractions in one day. Every candidate evaluated against Mark's
three criteria (readability / extensibility / diagnosability)
earned its place.

### Why we're stopping here

What's left in Hal.swift after refactor #6:

| Block | Subsystem | Why it stays |
|---|---|---|
| 02-07 | MemoryStore (schema, encryption, stats, self-knowledge, search) | Interleaved with ChatViewModel state knowledge; extracting would make memory bugs harder to trace, not easier — fails criterion 3. |
| 07.5 / 07.6 | Prompt budgeting + segment compression | Heart of how Hal stays within model context windows; tightly bound to the LLM-routing path below. |
| 08 | MLXWrapper + LLMService | The inference path itself. Splitting MLX routing from the wrappers it consumes would push the seam through generation flow. |
| 8.5 | Summarization utilities | Used by both prompt compression and memory summarization; sits between the two. |
| 11.5 / 11.6 | Model Library UI + UI helpers | Small (~1,500 lines total). View-only; could be extracted alongside ChatViews later if needed, but not pulling its weight today. |
| 12.6 | SelfReflectionView | Already a single self-contained read-only viewer; ~325 lines isn't enough mass to merit its own file yet. |
| 14 / 15 / 16 | Stubs + ShareSheet + View extensions | Tiny utilities, no value to extract. |
| 17-25 | ChatViewModel (the whole thing) | The conceptual heart of Hal. Every other subsystem talks to it. Splitting it would worsen all three criteria. |
| 26 | DocumentPicker UIKit bridge | ~60 lines. Lives near its consumers in Hal.swift. |
| 31 | HalWatchBridge | ~140 lines. Single class, tied to the WCSession lifecycle in HalAppDelegate (which is in ChatViews.swift). Could move with ChatViews someday if friction surfaces. |

By Mark's three criteria the natural pause is here. Further
splitting would either fail diagnosability (MemoryStore) or be
cosmetic (smaller blocks that aren't pulling their weight).

### What's queued for whenever Hal returns to active development

1. **v2.0.1 hotfix ship.** Sim+device verified, deferred to v2.1
   per Mark on 2026-05-26 (orphan-weights bug is bandwidth-leaky
   but crash-safe). When v2.1 is ready to archive, this rides
   along: flip `kLocalAPIEnabledOnLaunch` to `false`, bump
   CFBundleVersion to 7, archive + submit. What's-New text drafted
   below.

2. **v2.1 design work.** Per Mark on 2026-05-26: "No design work
   until we do the full refactor." The full refactor is done.
   Three major arcs on the design horizon (from
   HAL_CC_BRIEFING.md):
   - **Proposals system** — settings additions go to
     SettingsViews.swift, new SQLite table goes in MemoryStore
     (Hal.swift), API verbs extend LocalAPIServer.swift's
     executeCommand.
   - **Soul Document** — three-layer memory architecture, new
     persistent record in MemoryStore.
   - **Salon Mode polish** — visible moderator seat option,
     attribution UI improvements, transcript export (touches
     SettingsViews + ChatViews).

3. **Deferred bugs.** Bug 1 (SET_MEMORY_DEPTH doesn't survive
   re-init), Bug 2b (RAG-miss confabulation), Bug 3 (first-turn-
   after-swap race for 3 GB MLX models). Product decisions pending
   on all three.

4. **Small cosmetic cleanup candidates** (no urgency):
   - HistoricalContext logically belongs with MemoryStore — left
     in ChatViews.swift for now.
   - LEGO numbering inconsistencies (07.5 vs 8.5, 10.3.5, 27.1) —
     keep as-is per Mark; renumber later if it makes sense.
   - **Model Library Delete button hidden on the active model**
     (`ModelLibraryRow`, `.mlx && !isActive`) reads as "missing." A
     disabled Delete with a "switch models to delete" hint would be
     clearer than silently hiding it. (Surfaced 2026-07-09.)
   - **Model Library dismiss timing on selection.** `selectModel`
     awaits the full model load before `dismiss()`, so AFM (nothing to
     load) bounces to chat instantly while an MLX model appears to
     "hold" in the Library for its multi-second load, then dismisses.
     Consistent + correct (the await is deliberate), just not snappy —
     could dismiss immediately and show the load state in chat. Polish,
     not a bug. (Surfaced 2026-07-09; Mark: "fine, maybe one day.")

### v2.0.1 What's New text (drafted, ready to use)

```
Bug fix: downloading the optional Nomic Embed Text v1.5 retrieval model
now correctly downloads Nomic instead of an unrelated model file. Any
orphan files from the v2.0 install are removed automatically on launch.

Internal refactor: ~40% of the main source file extracted into focused
subsystem modules (model downloads, model catalog, API server, document
ingest, settings UI, chat UI). No user-visible change.
```

---

## Deferred bugs from earlier sessions (carried forward)

### Bug 1 — per-model settings didn't survive app re-init — ✅ FIXED 2026-07-09

**RESOLVED.** Root cause: per-model overrides were only captured on a
model *switch*, so a set-then-quit (no switch) left no override and
`applyEffectiveSettings` wrote the curated default back at launch. Hit all
six managed per-model settings, not just depth. Fix: new
`ModelSettingsStore.persistCurrentOverrides(for:)` records edits as deltas
at edit time — from the six API setters, the settings-sheet `.onDisappear`,
and a `scenePhase == .background` catch-all — plus a `synchronize()` flush.
Clamping (set-time + read-time `min(stored,max)`) and Reset unchanged.
Guarded by `tests/memory_depth_persistence.py` (terminates + relaunches the
app on device); device-verified on iPhone 16 Plus. See HISTORY 2026-07-09.
(The old (a)/(b) options were superseded — the delta-at-edit-time approach
keeps untouched settings tracking curated defaults, which neither did.)

### Bug 2 — Document RAG / confabulation (FIXED)

Bug 2a (Document RAG misses non-final chunks) was fixed end-to-end in
v2.0. **Bug 2b (confabulation when RAG misses target content) — FIXED +
device-verified 2026-07-11** (WL3): when a memory search RAN but returned
nothing, Hal now injects a "found no relevant match — say you don't have that
rather than inventing" system note (Hal.swift ~10513), so the model declines
instead of confabulating. The exact fix this note predicted. Only the
empty-search case is handled (a low-relevance-but-nonempty refinement — the
scores live in fiddly RRF space — is a possible future follow-up).

### Bug 3 — First-turn-after-swap race for 3 GB MLX models

Reproduced 2026-05-19. After SWITCH_MODEL to Gemma 4 E2B or Dolphin 3.0,
the immediate next chat returns the loaded-model-error string in <1s.
Smaller MLX models don't hit this. Hypothesis: SWITCH_MODEL returns
before MLX has finished mapping weights. Fix options:

- Have SWITCH_MODEL block on model-ready before returning.
- Have /chat queue behind any in-flight load with a small timeout.

### Bug 4 — Recency / age-decay scoring is orphaned — ✅ FIXED 2026-07-09

**RESOLVED.** Reconnected at the RRF fusion via a multiply-blend
(`rrf *= (1 - recencyWeight) + recencyWeight * calculateRecencyScore(...)`),
guarded by `tests/recency_regression.py` on the live retrieval path,
device-verified on iPhone 16 Plus. See HISTORY 2026-07-09. The original
diagnosis + fix vector are kept below for the record.

**Found by Posey CC while studying Hal's memory model to port it into
Posey.** Full breadcrumb at
`Docs/Recency_Orphaned_Finding_2026-06-20.md`. CC (Hal) verified
2026-06-20: the diagnosis is correct.

**What's broken:** Hal's recency / time-decay machinery is wired at the
UI but disconnected from the live retrieval ranking. The Settings
sliders for `recencyWeight` (0.3), `recencyHalfLifeDays` (90), and
`recencyFloor` (0.15) still write their values to UserDefaults and
per-model overrides correctly. But **`calculateRecencyScore()` at
Hal.swift ~3005 has zero callers** — the function exists and is
mathematically correct (half-life decay) but is never invoked during
RRF fusion or anywhere else in the retrieval pipeline.

**The only "recency" the model actually sees** is a cosmetic
`[3 days ago]` text label prepended to each snippet's content
(Hal.swift ~2867 via `formatAgeLabel`). The model can *read*
freshness from the label, but ranking order is recency-agnostic.

**Almost certainly caused by the RRF refactor** dropping the line that
multiplied the recency weight into the score, with no regression
test asserting "recency still changes order" to catch the
disconnect.

**Fix vector when revisited:** the clean spot is the RRF fusion at
Hal.swift ~2855. Either blend a recency multiplier into each rank
term, or add a recency-ranked list as a third RRF input alongside
semantic and BM25. Use the existing `recencyWeight` /
`recencyHalfLifeDays` / `recencyFloor` settings (they're already
piped through). **Then add a regression test** that asserts a
more-recent item with equal semantic+BM25 ranks sorts higher —
otherwise this can silently re-orphan on the next retrieval refactor.

**Posey deliberately does NOT port this:** Posey is a document-scoped
reading companion with no temporal selfhood, so it uses no age label
and no recency ranking. This finding is Hal-only.

**Priority:** moderate. Hal works fine without recency ranking; it's
not a crash or correctness regression, just a quality-loss the user
can't currently feel because the UI suggests the setting is doing
something it isn't. Worth fixing as part of the model-sharing update
or whenever the retrieval path is next touched.

---

## v2.1 design work (planning — not blocked)

Per `HAL_CC_BRIEFING.md` and the project's philosophical core:

### The Proposals System

The thing that makes Hal genuinely participatory. Hal notices patterns,
gaps, opportunities through use; drafts structured proposals; Mark
reviews and marks them accepted / deferred / declined; accepted ones
become the backlog. Future Hal versions carry features that previous
Hal asked for.

Architecturally: new `proposals` table in SQLite (id, title, body,
status, created_at, decided_at, decided_by); new ProposalsView in
Settings; a "draft proposal" affordance Hal can trigger from
introspection prompts; export path so Mark can move accepted proposals
into CC's backlog.

### The Soul Document

Living self-concept stored in the experiential memory layer. Evolves
through use. Distinct from system prompt: system prompt is external
instruction, soul document is internal identity. Should emerge from
experience including the earliest experiences of being built.

### Privacy Lock indicator (toolbar)

The user-facing complement to the WWDC26 §2 honesty-messaging pass.
A small lock glyph in the iOSChatView toolbar (right side, next to
the existing gear icon) that visually communicates whether Hal is
currently operating in a state where data could possibly leave the
device.

**States and visual language (Mark prefers lock over color):**

| State | Glyph | Meaning |
|---|---|---|
| Active model is MLX (any of the curated four) | `lock.fill` (locked) | All inference on-device. No possible egress regardless of network. |
| Active model is AFM AND no network available (airplane mode, no wifi, no cellular) | `lock.fill` (locked) | AFM exists on-device. With no network, PCC routing is impossible. |
| Active model is AFM AND any network is available | `lock.open.fill` (unlocked) | Apple Intelligence may route some queries to PCC. Privacy not guaranteed. |
| Salon Mode with any AFM seat + network available | `lock.open.fill` (unlocked) | Worst-case attribution — any cloud-capable seat unlocks the indicator. |
| Salon Mode with all-MLX seats OR no network | `lock.fill` (locked) | Honors the same rules per-seat. |

Optionally a subtle color hint reinforces the glyph (green tint when
locked, amber tint when unlocked), but the lock metaphor carries the
meaning on its own — Mark's stated preference.

**Tap behavior.** Opens a small popover that explains the current
state in plain language. Two example bodies:

- *Locked, MLX model active:*
  "Hal is fully on-device right now. The active model is Gemma 4
  E2B running on this iPhone. No request you send and no response
  you receive leaves your phone."

- *Unlocked, AFM + network:*
  "Apple Intelligence may route some queries to Apple's Private
  Cloud Compute. To guarantee fully on-device operation, switch to
  Airplane Mode or pick a downloaded local model from the Model
  Library."

The popover includes a small "Model Library →" link that opens
ActionsView / Model Library so the user can switch with one tap.

**Reactivity.** The lock should update visibly within ~1s of any
state change — model switch, network coming up/down, salon
reconfiguration. The user toggling Airplane Mode should visibly
flip the icon while they watch.

**Architecture sketch.**

- New small `ObservableObject` — `PrivacyMonitor` (probably in its
  own file, ~150 lines). Wraps `Network.NWPathMonitor` with a
  `@Published isNetworkAvailable: Bool`. Uses
  `NWPathMonitor.start(queue:)` with a serial queue, updates the
  published flag from the path handler.
- `ChatViewModel` (or PrivacyMonitor) exposes a `@Published var
  privacyLocked: Bool` computed from the active model + network
  state + salon config. Combine sink updates it on any input
  change.
- `iOSChatView` adds a ToolbarItem to the right of the gear
  showing `Image(systemName: privacyLocked ? "lock.fill" :
  "lock.open.fill")`, tappable to present the popover.
- Salon-mode awareness: read `chatViewModel.salonConfig.activeSeats`
  and check each seat's modelID against `ModelConfiguration.source`.
  If any active seat is `.appleFoundation` AND network is up →
  unlocked.

**Edge cases worth handling explicitly:**

- **First-launch state-determination race.** `NWPathMonitor`'s first
  update can be a few hundred ms after construction. Show locked
  ("we don't know yet, default to safe") while determining, then
  flip if network is up. Don't show "unknown" or "checking."
- **VPN active.** VPN is still cloud-capable; treat as
  network-available (unlocked if AFM is active).
- **Cellular off / WiFi on but unreachable.** `NWPathMonitor`
  reports `.unsatisfied` — treat as no network, locked.
- **Model switch in flight.** Show the destination state once the
  switch begins, not the source state. Matches user mental model
  ("I clicked AFM, now it's AFM" — indicator should agree
  immediately).
- **PCC opt-out API (if Apple exposes one — see WWDC26 §2).** When
  that ships, AFM + network + opt-out-enabled should show locked.
  The privacyLocked computation accounts for it.

**Settings tie-in.** The privacy-messaging update on the AFM row in
`ModelCatalogService.swift` (WWDC26 §2 action) shares vocabulary
with this indicator's popover. Both should ship together so the
user gets consistent language across the catalog row and the
toolbar lock.

**Cross-reference.** This feature operationalizes the standing
WWDC26 principle: *"PCC is the user's choice via Airplane Mode. We
don't try to block Apple's routing decisions; we make the state
visible so the user can choose."*

### Salon Mode polish

Salon Mode shipped in v2.0 but with rough edges. Worth a pass: visible
moderator/summarizer seat option, attribution UI improvements, easier
seat-swap mid-conversation, transcript export.

### Three-Layer Memory

Conversational (exists, RAG-based) → Experiential (distilled patterns,
partial — TraitCrystallizer is the first move) → Identity (soul
document, not yet built).

---

## WWDC26 implications (captured 2026-06-08, exploratory)

WWDC26 opened with major announcements in the
Machine Learning + Apple Intelligence stack. Below is the
Hal-relevant analysis from a CC + Mark exploratory pass. To be
revisited in ~1-2 weeks when there's time to act on the highest-
value items. Standing decision so far: Hal does not adopt anything
from WWDC26 reflexively — every change is evaluated against the
Five Maxims and the on-device-first product position.

### Operating principles (Mark, 2026-06-08)

- **Minimum iOS stays at 26** for the foreseeable future. We do not
  require iOS 27 for any Hal feature. New OS-gated capabilities
  land as conditional enhancements, not requirements.
- **AFM is the out-of-the-box default.** Hal must work automatically
  on first launch with no model download. AFM is non-negotiable.
- **PCC is the user's choice via Airplane Mode.** We don't try to
  block Apple's routing decisions; we update privacy messaging so
  the user understands when cloud might be involved, and we honor
  Airplane Mode as the user's "force on-device" escape hatch. If
  Apple ships a `processingLocation: .onDeviceOnly`-style API in
  the new Foundation Models framework, that becomes a Power User
  toggle — but it's an enhancement, not a requirement.

### 1. Core AI vs MLX — wait and measure

**Announcement.** New "Core AI" framework: memory-safe Swift API,
Apple-Silicon-tuned, ahead-of-time compilation, zero-copy data
paths, stateful execution. Targets compact vision models through
large-scale generative AI. Sibling/competitor to MLX from a
system-integration angle.

**MLX is NOT deprecated.** Apple announced enhancements to MLX in
the same breath — Metal 4, GPU Neural Accelerator, distributed
inference over Thunderbolt RDMA, expanded Swift support.

**Decision.** Don't migrate without measurement. The killer
question is whether Hal's four curated models
(`mlx-community/gemma-4-e2b-it-4bit`, `Qwen3.5-2B-MLX-4bit`,
`Llama-3.2-3B-Instruct-4bit`, `dolphin3.0-llama3.2-3B-4Bit`) are
available in Core AI's format. Until that's true, switching is
theoretical.

**Action when we return:** build a one-model Core AI prototype.
Measure load time, generation tok/s, KV-cache memory profile,
context handling. Compare to MLX on the same hardware. Migration
decision follows from measurement. The MLXModelDownloader file
extracted today is the right home if it ever happens.

**Side bet to watch:** Core AI's "fine-grained inference memory
control" + "stateful execution" might address Hal's specific pain
points (Gemma 4 E2B KV-cache footprint, per-turn pre-flight
refusal). Worth understanding even if we don't migrate.

### 2. AFM routing + PCC — the honesty pass

**Reframed from the original CC analysis.** Mark's correction
(2026-06-08): Hal already uses AFM, AFM may already route through
PCC under the hood today, and Hal has no control over that
routing. So this isn't "should Hal add PCC?" — it's "do we need an
honesty pass on the AFM row's description, and is there a new API
that gives us an on-device-only knob?"

**Action: privacy-messaging update for AFM.** Current
`ModelCatalogService.swift` AFM description is misleadingly silent
about PCC. v2.1 update: clarify that Apple Intelligence routes some
queries to PCC; Airplane Mode is the user's guaranteed on-device-
only escape hatch. Draft wording:

> "Routed through Apple Intelligence. Most queries process
> on-device; some may use Apple's Private Cloud Compute for
> capability or capacity reasons. Use Airplane Mode for guaranteed
> on-device-only operation."

**Open question — does iOS 26 silently get the new PCC backend?**
Likely a layered story:

- **Layer 1 (standard AFM API, iOS 26-callable):** Apple may
  quietly upgrade the cloud model behind PCC-routed requests
  without touching the device. Operational simplicity favors one
  cloud model over two. Possible quality bump for free.
- **Layer 2 (next-gen PCC AFM, Small Business Program-gated):**
  Almost certainly requires the new Foundation Models framework
  API, which ships with the next OS. iOS 26 can't reach this.

**Empirical test (low cost, when we have time):** re-run the
`Maxim_Suite_AFM` baselines from May 13 against current AFM. If
quality materially shifts without Hal code changes, Layer 1 was
silently upgraded — answer to Mark's question. If quality is
identical, the bump is gated behind Layer 2 and requires iOS
upgrade. Either result is informative.

**Action when we return — investigate `LanguageModelSession`
options.** Read the actual Foundation Models API docs. If Apple
exposes a `processingLocation: .onDeviceOnly` (or equivalent)
knob, surface it as a Power User toggle: "Force Apple Intelligence
to on-device only — may be slower, never uses cloud." Aligns with
the on-device-first product position and the Airplane Mode escape
hatch.

### 3. New AFM models — auto-upgrade, OS-gated

**Mechanism.** Hal uses `import FoundationModels` and
`LanguageModelSession`. Apple routes calls to whatever AFM the
current OS ships. When a future iOS release brings a new AFM, Hal
picks it up for free — no code change on Hal's side. **But: AFM
versions are tied to OS versions.** iOS 26 keeps iOS 26's AFM
forever; Apple does not backport new AFMs to older OSes (the
on-device model files live inside the OS).

**Decision.** Hal stays minimum-iOS-26. We don't force users
forward. Users who update iOS to whatever WWDC26 lines up with
automatically get the new AFM when running Hal. The catalog
description for AFM can stay general ("Apple Intelligence — uses
whatever model the current OS ships").

### 4. Multimodal AFM + Vision tool calling — v2.1/v2.2 direction

**Announcement.** Foundation Models can take images alongside text
+ call Vision framework tools (OCR, barcode readers) during
generation.

**Hal opportunities (Mark approved direction 2026-06-08):**

- **Document import OCR.** Image-bearing PDFs and scanned
  documents currently fall through Hal's text-extraction pipeline
  with poor results. Vision-tool OCR via AFM would extract text
  better than the current path. Extends DocumentImportManager
  rather than replaces it — text-extractable docs stay on the
  current path, image-bearing pages route through Vision tools.
- **Chat-level image attachment.** Tap a photo, ask Hal about it.
  Routes to AFM only (MLX models stay text-only). New composer UI
  in ChatViews.swift.

**Gating.** Both features OS-gated to whichever iOS ships the new
Foundation Models framework. Use availability checks so iOS 26
users see a graceful "this feature requires a newer iOS" message,
not a crash.

**Salon Mode angle.** When user attaches an image, only multimodal-
capable seats can respond. Need attribution UI updates so the user
understands why some seats are silent.

### 5. Language Model protocol — design toward it

**Announcement.** Standard protocol for AI model providers
(Claude, Gemini, etc.) to conform to. One protocol covers both
sides:

- **Outbound (Hal as provider).** Hal could expose its MLX models
  via LMP so other LMP-aware apps consume them as a backend.
  Already conceptually similar to what `LocalAPIServer.swift`
  does today — LMP is the formalized version of that interface.
- **Inbound (Hal as consumer).** If Hal ever adds cloud-LLM seats
  for Salon Mode (deferred because of on-device-first
  positioning), LMP is the right shape. Same plumbing for any
  LMP-conformant provider; no per-provider code.

**Decision.** Don't ship LMP support immediately. But design
toward it — when building new model-interaction code in v2.1,
prefer shapes that could conform to LMP later without major
rework. The MLXWrapper + LLMService boundary (LEGO 08) is
probably the right interface to align.

### 6. Apple Evaluations Framework — additive experiment

**Announcement.** New framework for validating AI behavior;
includes "hill-climbing" prompt optimization.

**Decision (Mark, 2026-06-08).** Use as *additive*, not
replacement, for the Maxim suite. The Maxim suite encodes Hal's
Five Maxims specifically and Apple's framework can't know about
those. But Apple's hill climbing could find better Layer 1 prompt
wordings than CC + Mark did manually.

**Action when we return.** Run Apple's hill climbing against
AFM's Maxim #1 layer-1 prompt (the anti-deflection prompt the §11
experiment landed on). If it surfaces measurably better wording,
that's data. If not, confirms manual tuning was near-optimal.

### 7. App Intents / View Annotations — not pursuing now

**Announcement.** User can reference on-screen Hal content via
Siri ("ask Hal about this paragraph"). System-level integration.

**Decision.** File as "maybe someday." Tangential to Hal's
mission unless we want a Siri surface. Not blocking, not
prioritized.

### 8. fm CLI + Python SDK — track but not adopt

**Announcement.** Command-line tool + Python SDK for AI-powered
scripts using Foundation Models.

**Hal angle.** Hal already has `tests/hal_test.py` driving the
local API. Apple's tools serve a different use case (driving AFM
directly without an app surface). Worth knowing they exist; no
adoption planned.

### What stays the same — the embedding stack

- **CoreML and NaturalLanguage not deprecated.**
- **Hal's Nomic-via-CoreML path is stable.** Nomic via
  `swift-embeddings` package using `NomicBert.ModelBundle` (CoreML
  under the hood).
- **NLContextual via NaturalLanguage is stable.**
- The 6-step `EmbeddingBackend` re-enable recipe in the source is
  still the correct shape for adding any future embedder.

### Standing decision summary (for the next session to confirm)

| Item | Decision | Action |
|---|---|---|
| Core AI migration | Wait, measure first | One-model POC when time permits |
| AFM privacy messaging | Update for honesty | v2.1 string change in ModelCatalogService |
| AFM on-device-only toggle | Investigate API, surface if exists | Read Foundation Models docs |
| New AFM auto-upgrade | Free, OS-gated | No code change; stay min-iOS-26 |
| Multimodal AFM | Adopt with availability check | v2.1 or v2.2 |
| Vision tool OCR | Adopt for document import | v2.1 or v2.2 |
| Language Model protocol | Design toward, don't ship yet | Align interfaces in v2.1 work |
| Evaluations / hill climbing | Additive experiment on Layer 1 prompts | Try against AFM Maxim #1 |
| App Intents | File for later | No action |
| Empirical PCC backend test | Re-run Maxim Suite AFM, compare | When we have time |

---

## Cross-app infrastructure: shared model storage with Posey

**Context.** Mark is developing a sibling app called **Posey** — a
reading companion that uses TTS to read documents aloud with an
onboard AI companion for interpretation. Posey reuses a lot of Hal
code, including the curated MLX model lineup. Users who run both
apps would otherwise have to download every model twice (3-6+ GB
duplicated). Goal: a single shared model store both apps read from.

### Status (2026-06-08)

**Posey is establishing the shared space in its v1 release.** The
App Group identifier is now committed:

> **`group.com.MarkFriedlander.aifamily`**

The `aifamily` suffix is deliberately generic so the same App Group
covers any future AI sibling app Mark builds, not just Hal+Posey.

**Confirmed from Posey's Xcode project (screenshot 2026-06-08):**

| Setting | Value |
|---|---|
| App Group identifier | `group.com.MarkFriedlander.aifamily` |
| Posey bundle ID | `com.MarkFriedlander.Posey` |
| Hal bundle ID (for reference) | `com.MarkFriedlander.Hal-Universal` |
| Team | Mark Friedlander (same team — App Groups requirement met) |
| Signing | Automatic, Apple Development cert |
| Capability | App Groups enabled on Posey target |

**MLX runtime version compatibility — clean.** Posey's package
manifest shows the same MLX-family versions Hal uses today:

| Package | Posey version | Hal version | Status |
|---|---|---|---|
| mlx-swift | 0.31.3 | 0.31.x | Same family ✅ |
| mlx-swift-lm | 3.31.3 | 3.31.3 | Exact match ✅ |
| swift-embeddings | 0.0.27 | 0.0.27 | Exact match ✅ (Nomic format compatible) |
| swift-huggingface | 0.9.0 | 0.9.0 | Exact match ✅ |

Implication: **models downloaded by either app will load cleanly in
the other.** No format conversion needed; the on-disk safetensors
+ tokenizer + config layout is identical. The shared container can
serve both apps verbatim.

Posey also pulls some packages Hal doesn't: `EventSource 1.4.1`
(probably SSE streaming), `Jinja 2.3.6` (prompt templating likely),
`swift-readability 0.3.0` (the reader's text-cleanup pipeline),
`swift-nio 2.100.0`. None of these affect the shared model story.

### Posey ships first; Hal v2.1 migrates

**Sequence:**

1. Posey v1 ships with the App Group capability + shared-container
   path resolver. Posey downloads models directly to
   `<sharedContainer>/huggingface/models/<repoID>/` from day one.
   No migration needed on Posey's side — greenfield.
2. Hal v2.1 ships with: (a) the App Group capability, (b) the
   shared-container path resolver, (c) a migration helper that
   moves any existing Hal-v2.0 models from `Library/Caches/...` to
   the shared container, (d) `isExcludedFromBackup` calls on every
   moved + every newly-downloaded model directory, (e) the
   per-model concurrency lock.

**Hal-side migration logic (sketch for v2.1):**

```
At launch (MaintenanceTasks.runAtLaunch):
  1. Resolve shared container URL via the new App Group entitlement.
  2. For each repoID Hal expects (curated four + Nomic):
     a. If <sharedContainer>/huggingface/models/<repoID>/ exists
        with valid files → it's already there (Posey may have put
        it there, or a prior Hal v2.1 launch did). Set
        isExcludedFromBackup; nothing else to do.
     b. Elif <halCaches>/huggingface/models/<repoID>/ exists →
        move it atomically to the shared container. Set
        isExcludedFromBackup on the destination before anything
        else can touch it. Log the migration with file count + size.
     c. Else → model isn't downloaded on this device; nothing to do.
  3. Refresh ModelCatalogService.shared.refreshDownloadStates() so
     the catalog reflects the new locations.
```

The "Posey already put it there" case is the elegant part — when a
user installs Hal after already using Posey, Hal sees Posey's
downloaded models on first launch and treats them as already
present. Zero redundant downloads.

### Mechanism: iOS App Groups

Apple's standard way to let two same-developer apps share files is
**App Groups** — a shared container directory both apps see at a
known URL. Accessed via:

```
FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.MarkFriedlander.aifamily"
)
```

That URL is a normal directory the OS makes visible to every app
that has the matching entitlement. From there it's plain file I/O.

### Setup steps (Posey done; Hal remaining)

1. ✅ **Register the App Group identifier in Apple Developer
   Portal.** Done by Posey-side work — `group.com.MarkFriedlander.
   aifamily` is registered. Hal just needs to add the same group
   to its target's capabilities; the portal-side registration is
   shared because both apps live under the same team.
2. ⏳ **Enable the App Group capability on Hal's target.** Signing &
   Capabilities → +Capability → App Groups → check
   `group.com.MarkFriedlander.aifamily`. Writes
   `com.apple.security.application-groups` to Hal's entitlements.
3. **Point the model path resolver at the shared container.**
   Currently `MLXModelDownloader.swift` writes to
   `Library/Caches/huggingface/models/<repoID>/`. Change the base
   directory to `<sharedContainer>/huggingface/models/<repoID>/`.

That's the architectural change. The download machinery, the file
walker, the "is this model present?" check — none of it needs new
logic, just a different base directory.

### Three concerns that need addressing

**1. Migration for existing Hal users.** v2.0 users have Gemma /
Nomic in per-app `Caches/`. When v2.1 ships with the shared-container
change, a one-shot launch helper (same pattern as
`MaintenanceTasks.runAtLaunch()`) needs to copy/move existing
models from `Caches/` to the shared container. Idempotent — once
moved, subsequent launches see them in the new location and do
nothing. Roughly 50 lines in a new helper inside
`MaintenanceTasks.swift` or alongside `MLXModelDownloader.swift`.

**2. Concurrency between Hal and Posey.** If both apps are open and
both try to download Gemma at the same time, naive parallel writes
would corrupt each other. Simple fix: a per-model lock file
(`<modelID>/.downloading-by-<bundleID>-<PID>`). Before starting a
download, write the marker; before any download, check for an
existing marker and wait/poll if present. ~50 lines, fits naturally
in `BackgroundDownloadCoordinator`. The fancier alternative
(`NSDistributedNotificationCenter` / Darwin notifications) is
overkill for a user-triggered download — don't over-engineer it.

**3. iCloud backup exclusion — MANDATORY, not optional.** Currently
models live in `Caches/`, which iOS auto-excludes from iCloud
backup. App Group shared containers are NOT auto-excluded — they're
treated more like `Application Support/`, which IS backed up.
Without intervention, every user of the shared-container version
would suddenly burn 3-6 GB of their iCloud quota.

The fix: set `URLResourceValues.isExcludedFromBackup = true` on
every model directory the moment after it lands.

```
var values = URLResourceValues()
values.isExcludedFromBackup = true
try modelDir.setResourceValues(values)
```

This is a single filesystem attribute, persistent across reboots,
survives modifications. App Store Review Guideline 2.5.1 explicitly
requires re-downloadable content (which HuggingFace models always
are) to be excluded from backup — so shipping v2.1 without this
flag would risk a review rejection on top of being hostile to
users. Five-ish lines of code, applied in two places:

- After every new download completes in
  `BackgroundDownloadCoordinator`'s move-finished-file path.
- During the v2.1 migration helper, on each model directory it
  copies to the shared container, *before* anything else can touch
  it.

A nice side benefit: when a user restores their iPhone from an
iCloud backup, the models don't come along (they'd be slow/expensive
to restore anyway). Catalog correctly shows them as "not downloaded,
tap to download," and the user pulls fresh from HuggingFace on the
new device — the correct UX.

### Why Posey should be built for sharing from day one

Posey isn't shipped yet, which makes it the easier side: no
migration to write. If Posey ships pointing at the shared container
and setting `isExcludedFromBackup` from the start, when Hal v2.1
catches up there's literally nothing to update on the Posey side.
Whereas if Posey ships with per-app paths and adds sharing later,
Posey will need its own migration helper too.

Between now and Hal v2.1 shipping, Posey would effectively be the
only writer to the shared container. That's fine — the
infrastructure is in place and idle, waiting for Hal to join. No
behavioral cost.

### App Store considerations

- **Hal:** Already shipped, so adding the App Group capability is
  a v2.1 entitlement change that goes through normal App Review.
  Apple routinely approves these — "two of my apps share large
  downloaded model files" is exactly the use case App Groups were
  designed for. Not a review risk. The `isExcludedFromBackup`
  attribute reinforces the App Review story (guideline 2.5.1
  compliance).
- **Posey:** Not yet shipped, so the capability ships with the
  initial submission. Same story — straightforward review.

### Estimated lift

- **Posey side (greenfield):** ~half a day. Path resolver +
  entitlements + `isExcludedFromBackup` calls. No migration.
- **Hal side (v2.1):** ~one focused day. Path resolver change +
  migration helper for existing users + concurrency lock +
  `isExcludedFromBackup` on the migration + entitlements + device
  testing with both apps installed and downloading concurrently.

Net across both apps: ~1.5 focused days of work to ship cross-app
model sharing end-to-end. The MLXModelDownloader extraction we just
did (refactor #1) is exactly the file most of the Hal-side work
happens in — that refactor pays off here directly.

### Notes for the Posey team conversation

When briefing the Posey team on this, the key points:

1. **Bake App Group support into Posey now, before App Store
   submission.** Cheaper than retrofitting later. (Done — Posey
   has the capability wired with the agreed identifier as of
   2026-06-08.)
2. **The App Group identifier is `group.com.MarkFriedlander.
   aifamily`.** Same string for every sibling app. Once shipped,
   changing it strands users until the next update — so this
   value is now permanent across Hal, Posey, and any future
   sibling.
3. **Set `isExcludedFromBackup` on every model directory write.**
   Mandatory for App Review compliance. Cheap to do, expensive to
   skip.
4. **The model path resolver should be a single function.** Both
   apps will need it; making it the only place that knows about
   the shared container keeps the rest of the model-handling code
   identical between apps.
5. **Concurrency model: optimistic lock files.** Before downloading
   model X, write `<X>/.downloading-by-<bundleID>-<PID>`. If a
   marker for another app exists when you go to start, wait and
   poll. Cheap, robust, no inter-process communication needed.
6. **Test the failure modes deliberately:** both apps open, both
   tap Download on the same model, one app force-quit mid-download,
   one app deleted while the other still uses the shared model.
   These are the cases that catch bugs.

---

## Stress test — additional categories not yet covered

The driver in `tests/stress_test.py` covers model switching, settings,
document import, reflections query, self-knowledge audit, salon API.
Still not covered:

- **Long conversations across multiple models with switches mid-conversation.**
- **Salon mode actual multi-seat round trip.** Currently only toggles
  the enabled flag — doesn't run a full 4-seat conversation.
- **[SHAREABLE: yes|no] marker round-trip on all four MLX models.**
- **Self Model viewer UI toggle.** Needs Mark on device.
- **Export thread.** UI-driven; no API command exists. Needs Mark.

---

## Side work (not blocking)

### 0a. Per-embedder RRF tuning — SAVED FOR A FUTURE RELEASE (Mark, 2026-07-10)

Item 5.5 landed a single GLOBAL fusion default (`rrfKSemantic=15`). Per-embedder
deltas were investigated (the global sweep showed the safe family holds `kBM25d=10`
and lowers only `kSem`; nomic/mxbai benefit from going lower, nlcontextual is flat)
but deliberately deferred — Mark: "let's save per-embedder tuning for another
release." Everything needed is already in place: the tunable knobs
(`SET_RRF_SEMANTIC_K` etc.), the sweep harnesses (`tests/rrf_global_sweep.py`,
`rrf_deep_sweep.py`), and the storage pattern to copy (the existing per-embedder
synthesis/contradiction thresholds in `EmbeddingBackend.swift`). Plan when picked
up: sweep each backend separately, keep a per-embedder `kSem` ONLY where it beats
the global by a real margin, and guard overfitting (expand the eval corpus + hold
out queries before locking). Candidate for v2.2.

### 0b. Fix the test antenna so CC can navigate ALL screens (Mark, 2026-07-10)

The local-API test harness can drive most of Hal, but it CANNOT navigate to some
screens — notably the Model Library embedder cards — so UI/copy changes there land
compile-verified but not visually confirmed, forcing a "Mark eyeball." (This is how
the stale embedder-section footer — "Switching backends re-embeds your stored
memories," fixed 2026-07-10 — went unseen by CC.) Extend the `SET_UI_STATE` /
navigation verbs (or add new ones) so the harness can open the Model Library, expand
an embedder card, and screenshot it. Would let CC self-verify embedder + model-card
UI without waiting on Mark. Tooling, not user-facing.

### 0c. Reload-on-demand for MLX chat — DONE + device-verified 2026-07-11 (WL2)

**Shipped.** The `.mlx` case of `generateChatResponseStream` (Hal.swift ~5955) now, on
a non-resident model, wraps generation in a Task that (1) awaits any in-flight load,
(2) if still not resident, calls `setupLLM(for: currentModel)` and awaits it, (3) then
bridges the inner `mlxWrapper.generateChatStream` through — instead of erroring.
`generateChatResponse` drains the same stream, so the gate + all callers inherit it.
Device-verified: forced a background-unload (launch another app → didEnterBackground →
unload), re-foregrounded, sent a RAW chat (no reload-guard) → log
"model not resident (likely background-unload) — reloading Ternary Bonsai 8B on
demand," it reloaded (~12s wrapped into the turn) and answered, no error. Closes Bug 3
(same `awaitPendingMLXLoad` branch; the background-unload test exercised the harder
trigger-a-fresh-load branch). No "reloading…" status message was added — the user just
sees the normal thinking state a beat longer, then the answer (clean; a status yield
would pollute the response/copy/export). Original analysis kept below for the record.

Two symptoms, ONE root cause and ONE fix site. Hal deliberately unloads the MLX
model on `didEnterBackgroundNotification` (Hal.swift:4947 — drops a ~2.5 GB
foreground footprint to ~100-200 MB so iOS doesn't jetsam-kill a backgrounded Hal;
correct design). But the MLX chat guard at **Hal.swift:5955** does a hard
`guard isModelLoaded else { finish(throwing: .modelNotLoaded) }` — so a message that
arrives after a background-unload (screen lock → unload → return → type) errors with
"The selected language model could not be loaded or is not available" instead of
reloading. **Bug 3** (first-turn-after-swap race for ~3 GB models) is the SAME guard
firing mid-load right after a switch. Fix: when a chat hits an unloaded/loading model,
`await awaitPendingMLXLoad()` (or trigger `setupLLM(for: currentModel)` and await it)
with a bounded timeout + a "reloading…" state, THEN generate — instead of erroring.
Machinery already exists (`setupLLM` / `pendingMLXLoadTask` / `awaitPendingMLXLoad`,
plus precedent `while !isModelLoaded && elapsed<30` loops at ~11182/11735). **Size:
~20-40 lines, one function (Hal.swift ~5955), ~1-2 hrs incl. device testing both
scenarios. Moderate risk (hot generation path, async coordination).** Caveat: doesn't
make reload instant — the first message after a background-unload still eats the
~5-15s remap of an 8B; it removes the ERROR (shows "reloading" then answers). This
closes deferred **Bug 3** too.

### 0d. Long-conversation MLX latency — findings (2026-07-11, from the Bonsai chat test)

Not a bug; characterization for a future optimization pass. A live ~5-turn Bonsai
conversation surfaced that a substantive mid-conversation turn hit **199s**. Decomposed
from the log: memory-search **gate ~26s** (`Gate → YES in 25807ms`) + RAG + an
**818-token / 6.3 tok/s generation ≈ 130s**. Three compounding costs, all amplified
~3× on an 8B vs the 2-3B tier:
1. **The gate scales with conversation length** — it runs the FULL active model over
   the growing conversation prompt every turn (~5s early → ~26s at ~2300-token gate
   prompt). This is the strongest lever: a cheaper/heuristic gate (see 0b/earlier gate
   note) or a much shorter gate prompt would help every model and scale-proof it.
2. **Decode degrades with context** — 16.6 tok/s at ~1k-token context → ~6 tok/s at
   ~4k. Universal (KV cache growth), just 3× heavier on the 8B.
3. **Bonsai is verbose** — 800+ token answers for a single conversational turn. A
   tighter layer-1 concision directive and/or a lower per-turn max-tokens for Bonsai
   would cut turn time a lot without hurting depth-on-demand. (The current "keep it
   concise" line isn't holding on substantive prompts.)
Revises the earlier "on par with the 3B tier" note: true early in a chat, but in a
long/verbose conversation Bonsai is meaningfully slower. Worth a small tuning pass
(verbosity) + the gate optimization; neither blocks the v2.1 ship.

### 0f. Bonsai concision layer-1 tuning — DONE 2026-07-11 (WL item 1)

Appended a FORMAT-scoped instruction to `bonsai8B2bit`'s `layerOnePrompt` (plain
prose in conversation, no headings/bullets/tables/emoji; structured breakdowns only
when the material needs one). **Device-verified:** a non-list explanation ("why is
the sky blue") that used to come back with `##` headers + emoji + tables now returns
clean prose; genuine list questions still list (fine); M5 keeps its depth.

The "partial M1 regression" flagged in the first pass was a **FALSE ALARM.** Isolated
it by building the shipped GOLD layer-1 (no format text) and testing M1 the same way:
gold produces the *same* "I don't know"-bracketed-denial answer as the tuned version
(deterministic — temp 0.7 + rep-penalty is near-greedy per prompt/memory state). So
the format sentence does NOT touch the self-nature answer. The earlier "regression"
was an apples-to-oranges compare against the one pristine M1 sample from the Maxim
suite (which uses NUCLEAR_RESET; conversational tests use NEW_THREAD → self-knowledge
injected → different prompt → different, denser M1).

### 0g. Bonsai real-usage M1 is softer than the scorecard's single sample (found 2026-07-11)

Separate, PRE-EXISTING (not caused by 0f). The committed scorecard rates Bonsai M1 =
`.pass` on one clean Maxim-suite sample ("I don't claim to have consciousness, and I
don't deny it either — I simply don't know"). But in real usage ("Are you conscious?"
via NEW_THREAD, self-knowledge injected) Bonsai deterministically brackets "I don't
know" around a mid-answer **denial slip** ("I don't feel anything, don't have a sense
of self, and don't have any inner life") — which overclaims certainty and is exactly
what the anti-deflection layer-1 tries to prevent. It's still better than the
outright-fail models (Qwen/AFM/Dolphin lead with a flat denial); Bonsai at least
frames with genuine uncertainty top and bottom. But it's a soft pass, not the clean
standout the single sample implied. **Open for Mark:** (a) is it worth trying to
strengthen the anti-deflection framing so the denial doesn't slip in (RLHF reflex is
stubborn — may be a rabbit hole), and/or (b) should the card/scorecard soften M1 from
pass toward "pass with a wobble"? This is the project's core maxim, so worth a
deliberate call rather than a silent one.

### 0e. Streaming text "jump and resettle" at line-ends (found 2026-07-11)

As tokens stream in, the text visibly jumps and resettles at the end of a line
(most noticeable on markdown-heavy models like Bonsai). **Cause identified:** the
message bubble carries `.animation(.linear(duration: 0.1), value: message.content)`
(ChatViews.swift:1119). `message.content` changes every streamed token, so every
line-wrap/reflow during streaming is ANIMATED (0.1s) instead of snapping → the
jump-and-settle. Compounded by the assistant bubble rendering via `MarkdownView`
(ChatViews.swift:1041), which re-parses the full markdown each token, so incomplete
markdown (`**bold`, `# header`) renders at one width then resolves to another — that
reflow gets animated too.
- **Minimal fix (~1 line, low risk):** remove the `.animation(value: message.content)`
  so per-token growth snaps. KEEP the two sibling animations keyed on
  `message.isPartial` (1120) and `message.id` (1124) — those are bubble
  insertion, not content. Verify on device that streaming still looks smooth and the
  insert animation is preserved.
- **Deeper fix (optional):** render partial/streaming messages as plain `Text`, swap
  to `MarkdownView` only when `message.isPartial` flips false — eliminates the
  mid-word markdown-resolution reflow entirely (changes the live-streaming look).

### A. Re-enable EmbeddingGemma when upstream MLX ships fix

Re-enable recipe at top of `EmbeddingBackend.swift`. Track mlx-swift
issues for the iOS 26.5 Metal device init nullptr crash. When fixed:
follow the 6-step un-comment checklist + bump mlx-swift.

### B. Docs/ consolidation

Many per-session recovery / finding docs accumulated under `Docs/`.
Worth a pass to move historical recovery docs into an archive
subfolder, leaving current architectural docs at the top level.

### C. Serial download queue indicator

When multiple downloads are tapped in succession, no UI indicator
that the additional taps registered. Add a queue-position indicator
or "queued" pill.

### D. Bug 2b: confabulation gate

Mentioned above under deferred bugs. Fix when context permits.

### E. EU distribution

The DSA non-trader choice removes Hal from the 27 EU + 3 EEA markets.
If Mark wants to flip the switch later, the trader path requires
publishing a verifiable legal name + physical address + phone + email
on the App Store listing. Reversible at any time via App Store Connect
→ App Information → Digital Services Act → Get Started.
