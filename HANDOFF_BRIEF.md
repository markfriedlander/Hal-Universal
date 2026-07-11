# Hal Universal — Handoff Brief
**Updated:** July 11, 2026 (latest — **DNA cleanup DONE**. Every LEGO block renumbered to a clean **1…59** across all 18 files on one unified marker scheme; `Hal.swift` now leads `Hal_Source.txt` with a **master index** covering every file+block; new **`scripts/validate_lego.py`** fails if markers/index/sequence drift; Hal.swift pointer-stubs deleted; the "32 blocks / Phi-3" self-description falsehoods scrubbed (now count-free); all 18 file headers trimmed to present-tense (dates/history/dead-features gone, real contracts + EmbeddingGemma re-enable recipe kept). Diff was comments-only bar one self-description string; device build clean, no new warnings; Hal_Source.txt re-synced (28,810 lines). **App Store screenshots also DONE** — all 6 (6.5"/1242×2688, dark) recaptured with a real status bar (`devicectl device capture screenshot`) off a clean install of the corrected build; the self-model shot now shows Hal's genuine first-person reflection + fixed self-knowledge. **⭐ NEXT: the ship sequence** [SHIP_BLOCKER flip `kLocalAPIEnabledOnLaunch`→false, CFBundleVersion→7, decide v2.5-vs-v2.1, ASC upload+submit]. Prior this session: reflections un-grounded, source-code seed fixed, Self Model humanized + pink; Apple Watch fully excised; Bonsai ships. See MEMORY current-state.)
**Branch:** `main`
**Production:** Hal Universal **v2.0 is live on the App Store** since 2026-05-19. Non-EU markets only (DSA non-trader; see HISTORY).

> **Toolchain (changed during the 2026-06 gap):** the whole stack is on
> beta — **Xcode-beta** (`/Applications/Xcode-beta.app`), **iOS 27 beta**
> on the device, **macOS 27 beta** on the Mac. Stable `Xcode Release.app`
> is still the active `xcode-select` but has no iOS 27 platform, so all
> device builds must run under
> `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. See the
> Build + Deploy section below.

## Where Hal is right now

**v2.1 is in active development.** A new CC onboarded 2026-07-09 (prior
CC's session was lost from the desktop app). Mark agreed a 7-item v2.1
roadmap (one release, priority order, Ternary Bonsai as cut line) — full
list in NEXT.md → "v2.1 roadmap — AGREED 2026-07-09". Proposals system +
Soul Document are explicitly OUT of scope for now.

**Latest (2026-07-11): item 6 — Ternary Bonsai 8B — is DONE and SHIPS as
curated.** Hal's first 8B and first 2-bit model
(`prism-ml/Ternary-Bonsai-8B-mlx-2bit`, Qwen3-8B arch, 2.32 GB, 65k ctx). The
2-bit load gate passed on the 16 Plus (~12s, no jetsam), and after swapping the
Qwen-derived layer-1 for an anti-deflection one it scored **M1 mixed, M2 pass, M3
pass, M4 standout, M5 pass** (M1 softened from pass → mixed on 2026-07-11: a
follow-up conversation test showed the pristine M1 was a lucky single sample; real
usage slips a mid-answer denial — genuine uncertainty present but wavers, still
better than the outright-fail models; see NEXT 0g). Speed: **decode ~16.6 tok/s** — on par with Llama/Dolphin, NOT slow
(an earlier "~4-5 tok/s" was wall-clock ÷ tokens, conflating decode with per-turn
gate overhead). Mark's call: SHIP as the "deep reasoner" — deepest/most capable,
generates about as fast as the 3B tier. Seed = `ModelCatalogService.bonsai8B2bit` (in
curatedSeeds + availableModels); findings `Docs/Maxim_Suite_Bonsai_2026-07-11.md`; new
test verb `DOWNLOAD_MODEL:<id>:<sizeGB>`. Full story: HISTORY 2026-07-11. **This closes
the v2.1 cut line — items 1-6 are all done except the item-1 ship action (Mark's ASC
step).** Non-blocking follow-ups: measure prefill tok/s (seed carries a conservative
8,000 placeholder); whole-tier gate optimization logged (the per-turn memory-search
gate runs the active model, ~4-5s on the 8B — an app-wide overhead, not a Bonsai
decode property).

**Prior (2026-07-10): item 5.5 — the retrieval-fusion rebalance — is DONE and
device-verified.** The RRF k weights in `searchUnifiedContent` are now tunable
global `@AppStorage` knobs (`SET_RRF_SEMANTIC_K` / `SET_RRF_BM25_DISTINCTIVE_K` /
`SET_RRF_BM25_DEFAULT_K` / `RRF_STATUS`), and the global default moved
**`rrfKSemantic` 60 → 15** (kBM25d 10, default 60). The old k=60 made keyword
matching dominate so the embedder was nearly inert; 15 lifts mean MRR ~+17% on a
59-memory/46-query eval and makes the embedders actually diverge. Evidence ordering
is now **distinctive keyword (10) > semantic (15) > generic keyword (60)** — a rare
exact term beats meaning beats generic overlap. We held `kBM25d=10` and swept only
`kSem` so Bug 2a keeps a 1.5× cushion (k=10 is the boundary; we did NOT cross it).
**Nomic is the end-to-end retrieval champion** (beats mxbai in the full pipeline —
opposite of the pure-cosine A/B). recency_regression still PASS. New instruments:
`tests/rrf_global_sweep.py`, `rrf_deep_sweep.py`. Full story: HISTORY 2026-07-10.
Per-embedder tuning deferred (Mark: "maybe another time"). **Item 5 (mxbai +
multi-embedder) is complete across all three steps** (see below / HISTORY 2026-07-09).

**Roadmap remaining (order in NEXT.md):** just item 1 (v2.0.1 → v2.1 ship — needs
the SHIP_BLOCKER flip + CFBundleVersion bump + Mark's ASC action). Items 2-6 are all
landed; the whole v2.1 feature set is done and the cut line (item 6) shipped.
**Open eyeball for Mark:** the updated embedder model cards + download disclosure
are compile-verified but not visually confirmed on the Model Library embedder screen
(harness can't navigate there).

**Roadmap item 2 (Bug 4 — orphaned recency scoring) is DONE and
device-verified** (2026-07-09). Recency was reconnected into the RRF
fusion in `searchUnifiedContent` via a multiply-blend by `recencyWeight`,
and is guarded by `tests/recency_regression.py` on the live retrieval
path (two test-only API verbs added: `MEMORY_PLANT_AGED[_CLEANUP]`).
Device run: old row (365d) decayed to 19.25% at weight 0.95, fresh row
unchanged, fresh ranked above old. Next up per the roadmap: item 1
(v2.0.1 hotfix ship — needs the SHIP_BLOCKER flip + Mark's ASC action)
and item 3 (Privacy Lock indicator).

**Bug 1 (per-model settings didn't survive app restart) is DONE and
device-verified** (2026-07-09), fixed opportunistically alongside Bug 4.
New `ModelSettingsStore.persistCurrentOverrides(for:)` records per-model
edits as deltas at edit time (six API setters + settings-sheet
`.onDisappear` + `scenePhase .background`), so a set-then-quit with no
model switch survives relaunch. Clamping + Reset unchanged; guarded by
`tests/memory_depth_persistence.py` (terminates + relaunches on device).
Two settings tiers clarified: **per-model** (the six — temperature,
memoryDepth, recencyWeight, recencyHalfLifeDays, maxRagSnippetsCharacters,
ragDedupThreshold) vs **global** (Self-Knowledge, Identity, system prompt,
salon; these never had the bug). "RAG Dedup" is an API-only threshold
(0.85), not a UI on/off.

**Download disclosure sheet race is FIXED and device-verified** (2026-07-09,
Hal.swift `ModelLibraryView`). "I Understand" on the first-MLX "Before You
Continue" sheet used to do nothing — two `.sheet` modifiers on one view can't
present simultaneously, and onContinue presented the license sheet without
dismissing the disclosure. Fixed with the dismiss-first / resume-in-onDismiss
pattern. **Open UX candidate (not actioned):** `ModelLibraryRow`'s Delete
button is hidden for the *active* model (`.mlx && !isActive`), which reads as
"missing" — consider a disabled Delete + "switch models to delete" hint.

**Privacy Lock indicator (v2.1 roadmap item 3) is DONE and device-verified**
(2026-07-09). `lock` / `lock.open` glyph left of the gear (monochrome, matches
gearshape); tap → popover with plain-language state + "Model Library →" link.
New `PrivacyMonitor.swift` (NWPathMonitor + pure `isLocked` truth table +
popover). Live-reactive to model switch and Airplane Mode. A second
sheet-race (the popover → Model Library link) was fixed via
`onDisappear`-resume. Two more polish candidates logged in NEXT (the Delete
hint above; snappier Library dismiss on MLX selection).

**Cross-app model sharing with Posey — INCREMENT #1 DONE + device-verified**
(2026-07-09, roadmap item 4). Mark added the App Group
`group.com.MarkFriedlander.aifamily` capability in Xcode; new
`SharedModelStore.swift` (ported from Posey) + redirected all of Hal's model
paths (HubApi load path, MLXModelDownloader, `isModelDownloaded` → disk-truth)
to the shared container. Hal now sees/loads Posey's four MLX models with zero
re-download; claims on use, deletes refcount-safely (can't nuke Posey's
files); `isExcludedFromBackup` on downloads. Read-only `SHARED_MODELS`
diagnostic added.

**Cross-app DOWNLOAD lock — INCREMENT #3 DONE + device-verified**
(2026-07-09, roadmap item 4). Stops Hal + Posey both fetching the same model
into the shared container at once (wasteful/duplicate, not corrupting — files
are atomic-moved when whole). New `SharedModelStore` BLOCK SMS.4: a per-model
lock in its OWN `download-locks.json` at the store root (NOT a marker in the
model dir — trips `isRepoDownloaded`; NOT in `manifest.json` — an un-updated
Posey would strip the field). Second app that sees a fresh foreign lock WAITS
and adopts the finished copy (zero re-download); takes over only if the holder's
lock goes stale (`downloadLockStaleSeconds = 600`, a timestamp backstop —
heartbeat + disk-growth are both unreliable for a backgrounded single-big-file
download; see HISTORY). `MLXModelDownloader` gains `performLockedDownload` (the
split-out download body), `awaitSharedDownloadThenAdopt` (the wait/adopt/take-
over loop), `adoptSharedModel`, a lock heartbeat in the progress loop, and lock
release on success/cancel/error. `DOWNLOAD_LOCK` API verb + new
`tests/download_lock_regression.py`. **Verified END-TO-END across both real apps**
(2026-07-09, Qwen 3.5 2B, Posey antenna): wait (Hal doesn't duplicate),
take-over-on-stale (Hal starts a real download + release-on-cancel), and the
headline adopt (Posey really downloads ~1.5 GB → Hal adopts the finished copy in
2s with ZERO bytes). The lock-plant + lock-release were simulated (the two lines
Posey doesn't have yet); everything else was real. Device restored to baseline.
**Posey must adopt the matching block** for full two-app protection
(Hal-first is a safe pure addition) — adoption note at
`Posey/docs-internal/CROSS_APP_DOWNLOAD_LOCK.md` + pointer in Posey `next.md`.

**Cross-app model sharing — INCREMENT #2 (legacy migration) DONE +
device-verified** (2026-07-09). `MaintenanceTasks.runAtLaunch()` now migrates a
v2.0 user's old `Caches/huggingface/models/*` into the App-Group shared store so
upgraders don't lose downloads: `@MainActor`, one-shot flag, walks the legacy dir
at repo granularity (community models too), moves each into the shared store (or
removes the legacy duplicate if a shared copy already exists), claims for Hal +
`isExcludedFromBackup`, deletes retired backends. Cheap because Caches→App-Group
is a same-volume rename (no byte copy). Display is disk-truth so a final
`refreshDownloadStates()` is all the UI needs. `LEGACY_MIGRATION` test verb +
`tests/legacy_migration_regression.py`; move/reconcile/retired-skip all verified
via planted fakes (real migration is a no-op on the dev device). Embedder sharing
(Nomic/mxbai) rides with item #5.

**Item 5 (mxbai + multi-embedder) DONE + device-verified 2026-07-09** — all
three steps: mxbai backend + embedder load-path fix (`2accebf`); per-embedder
"keep-both" columns replacing the destructive wipe, so switching embedders is
instant + non-destructive + A/B-able (`95b2f05`); A/B + calibration + model
cards + Recommended badge (`a448540`). Retrieval separation mxbai 0.48 > Nomic
0.30 > NLContextual 0.10; kept all three for user choice (NLContextual default,
mxbai recommended-for-quality). Findings: `Docs/Embedder_AB_Findings_2026-07-09.md`.
New tests: `embedding_columns_regression.py`, `embedder_ab_eval.py`. **Open
eyeball for Mark:** the "Recommended" badge + new embedder card copy are
compile-verified but not visually confirmed on the Model Library screen.

**BIG FINDING from the item-5 follow-up work (2026-07-09):** built the real-world
retrieval eval (`tests/embedder_retrieval_eval.py`,
`Docs/Embedder_Retrieval_Eval_2026-07-09.md`) and it shows **the embedder barely
affects what Hal actually retrieves** — full-pipeline recall is ~identical across
all three (MRR ~0.50), even though pure-semantic recall@3 is mxbai 0.84 vs
NLContextual 0.63. Root cause: the RRF fusion weights BM25 keyword hits ~5.5× more
than semantic (`rrfKBM25=10` vs `rrfKSemantic=60`), so keyword matching dominates.
**Mark AGREED (2026-07-09) to rebalance the fusion** — see NEXT.md item 5.5 for
the ordered plan (tunable knobs → global sweep → per-embedder deltas, guard
overfitting). Also dropped the "Recommended" badge (all three equal) + aligned the
embedder download UX with the LLMs (pre-download disclosure).

Roadmap now: **item 5.5 (rebalance retrieval fusion — AGREED, high priority, do
next)**, item 1 (v2.0.1 ship — Mark's ASC action), item 6 (Bonsai, cut line).
Item 4 (cross-app sharing) is fully done bar Posey adopting the download-lock
block.

**v2.0.1 hotfix** (EmbeddingGemma mis-download) remains **fully verified
— sim + device — deferred to ride with v2.1** per Mark 2026-05-26 (the
orphan-weights bug is bandwidth-leaky but crash-safe).

Refactor sprint: six extractions landed in one day —
MLXModelDownloader (#1, 2026-05-20), ModelCatalogService (#2,
2026-05-26 PM), LocalAPIServer + HalTestConsole (#3, 2026-05-26
EVE), DocumentImportManager (#4, 2026-05-26 NIGHT), SettingsViews
(#5, 2026-05-26 LATE), ChatViews (#6, 2026-05-26 DEEP NIGHT).
Hal.swift is now **12,650 lines, down from 21,266** at the start of
the refactor run (-8,616, ~40.5%). Hal.swift is ~60% of what it was
this morning.

**Goal framing:** per Mark, refactor work continues for as long as
each candidate improves on (1) readability, (2) safety/ease of
extension, (3) stability/diagnosability. Line counts are a proxy.
What's left in Hal.swift is the conceptual heart of Hal —
ChatMessage + MemoryStore (LEGO 02-07), the prompt-budgeting
machinery (07.5/07.6), LLM routing (08), summarization utilities
(8.5), ModelLibraryView + UI helpers (11.5/11.6),
SelfReflectionView (12.6), helper view extensions (15/16),
ChatViewModel itself (17-25), and the watch bridge (31). By the
three criteria the natural pause is here. MemoryStore +
ChatViewModel are interleaved enough that further splitting would
likely hurt diagnosability rather than help.

**LEGO numbering:** keeping current as-is for now per Mark on
2026-05-26 ("we'll renumber after if it makes sense to do so").
Half-numbers and cross-file gaps exist but are cosmetic, not
functional.

### Most recent commits

```
41c0601  Refactor: extract ChatViews (LEGO 09, 09.5, 13, 13.5)
9ffc1a8  Docs: refactor #5 SettingsViews landed; assess ChatView next
be727e4  Refactor: extract SettingsViews (LEGO 10.1-10.4)
0bb0a81  Refactor: extract DocumentImportManager (LEGO 27 + 27.1 + 28)
94578e2  Refactor: extract LocalAPIServer + HalTestConsole to own file
95a05f1  Refactor: extract ModelCatalogService to its own file
93cf4ba  Force local API antenna ON at every launch (dev default)
9f5fdf8  Refactor: extract MLXModelDownloader to its own file
90479cc  v2.0.1 hotfix: remove EmbeddingGemma + parameterize startDownload + cleanup
```

### v2.0.1 hotfix — fully verified, archive pending

**The bug.** On the clean App Store v2.0 install, tapping Download on
the Nomic Embed Text v1.5 row downloaded EmbeddingGemma's 210 MB of
weights instead. Status messages were hardcoded "EmbeddingGemma…"
strings. Root cause: `EmbedderMigrationCoordinator.startDownload()`
hardcoded to `EmbeddingBackend.embeddingGemma.modelID` regardless of
which row's button was tapped. The `HAL_ENABLE_EMBEDDING_GEMMA` compile
flag gated the UI row (no Gemma row in Release) and the runtime embed
path (no Gemma inference) — but NOT the download path. Classic
build-config drift: flag-gated UI + un-gated download = wrong model
downloaded.

**Crash risk to App Store users:** none. The iOS 26.5 Metal init crash
only fires when MLX *loads* the Gemma model, which requires Gemma to be
the active backend, which requires selecting it via the Gemma row,
which doesn't render in Release. App Store build is bandwidth-leaky
(210 MB orphan weights on disk for any user who tapped Download even
once) but crash-safe.

**The fix.** Three coordinated changes, all in commit `90479cc`:

1. **EmbeddingGemma fully commented out + flag removed.** Compiler-
   enforced cleanup — commenting `case embeddingGemma` surfaced every
   switch arm needing treatment (10 sites, each marked `// REMOVED
   2026-05-20:`). `HAL_ENABLE_EMBEDDING_GEMMA` removed from
   project.pbxproj line 586 (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` is
   now just `"DEBUG $(inherited)"`). No flag, no Debug/Release drift,
   no possibility of accidental Gemma activation. Re-enable recipe
   documented at top of EmbeddingBackend.swift as a 6-step checklist.

2. **`startDownload(for backend:)` parameterized.** Takes the tapped
   backend; uses `backend.displayName` in all status messages; two
   defensive guards (`modelID != nil` + `isAvailableInThisBuild`)
   refuse any invalid call. Download button in EmbedderBackendRow now
   passes its row's backend.

3. **MaintenanceTasks.swift (new file).** `runAtLaunch()` deletes
   orphan cache directories for backends in
   `removedEmbeddingBackendModelIDs` (extensible list, just Gemma
   today). Wired into HalAppDelegate boot. Idempotent. Existing App
   Store v2.0 users get the orphan Gemma weights cleaned up without
   any user action.

**Sim verification:** all 8 test plan steps green on iPhone 17 Pro sim.
Pre-planted sentinel cache directory removed at launch with the
correct log line. Model Library shows only NLContextual + Nomic.
Tapping Download on Nomic downloads Nomic (every byte of log evidence
hit `nomic-ai/nomic-embed-text-v1.5`, zero to embeddinggemma). Labels
correct. API rejection paths work.

**Device verification DONE (2026-05-26).** Built Debug from main @
`0c2ac21`, installed on iPhone 16 Plus. `DOWNLOAD_EMBEDDING_MODEL:
nomicswift` → all 8 background tasks wrote into
`Caches/huggingface/models/nomic-ai/nomic-embed-text-v1.5/`, 521.6 MB
safetensors at 73 MB/s, `.mlxModelDidDownload` fired, coordinator
finalized. Grep across 500 log lines for `embeddinggemma` /
`gemma-300m` returned empty — zero Gemma surface. `HALDEBUG-CLEANUP`
correctly quiet (device never had the orphan dir; idempotent skip).
`EMBEDDING_STATUS` confirms nomicswift active at 768 dim. Bug is dead.

### Local API antenna default-on (commit `93cf4ba`)

`Hal.swift` now carries a `kLocalAPIEnabledOnLaunch` constant
force-applied to UserDefaults in init() STEP 0. This boots the dev
antenna ON at every launch regardless of persisted preference, so
device test tooling works on every fresh install without Mark having
to flip the toggle by hand. Two cross-referenced comment blocks
(above the constant + above the AppStorage) point at the same
`SHIP_BLOCKER` marker. Production users get the antenna off when the
constant is flipped to `false` before archive. Single unified build,
no Debug/Release drift — consistent with new SOP #12.

### Refactor — six extractions landed

**#1 (2026-05-20):** `MLXModelDownloader` (LEGO 29) lifted to
`MLXModelDownloader.swift`, 1,717 lines. Holds
`BackgroundDownloadCoordinator` + `MLXModelDownloader` + the
`.mlxModelDidDownload` Notification.Name extension. Hal.swift
21,266 → 19,602 (-1,664).

**#2 (2026-05-26 PM):** `ModelCatalogService` (LEGO 30) lifted to
`ModelCatalogService.swift`, 1,434 lines. Holds `ModelSource`,
`MaximScorecard`, `ModelSettings`, `ModelSettingsStore`,
`ModelConfiguration` (with AFM + four curated MLX seeds), the HF
DTOs, `ModelCatalogService`, and `CatalogError`. Hal.swift 19,627
→ 18,252 (-1,375).

**#3 (2026-05-26 EVE):** `LocalAPIServer + HalTestConsole` (LEGO 32
plus the unmarked API-helper extensions sitting just above it)
lifted to `LocalAPIServer.swift`, 2,025 lines. Holds `extension
MemoryStore` + `extension DocumentImportManager` (API helpers),
`HalTestConsole` (file-channel test harness with the shared
`executeCommand` dispatcher), and `LocalAPIServer` (HTTP server,
NWListener on port 8766). Two compile fixes needed during the cut:
(a) `import WatchConnectivity`, (b) broaden three `private` methods
on `DocumentImportManager` to module-internal so the path-based
import extension can still reach them from a different file.
Hal.swift 18,252 → 16,298 (-1,954).

**#4 (2026-05-26 NIGHT):** `DocumentImportManager + DocxParser +
import models` (LEGO 27 + 27.1 + 28) lifted to
`DocumentImportManager.swift`, 967 lines. Holds the ingest pipeline
(PDF/RTF/docx/txt/md/csv/json/xml/html extractors → entity tagging
via NLTagger → chunking → MemoryStore), the iOS-native
MiniZip+XMLParser docx reader shipped in v2.0, and the value types
`ProcessedDocument` / `DocumentImportSummary`. Smallest external
coupling of any extraction at the time. Build clean first try.
Hal.swift 16,305 → 15,424 (-881).

**#5 (2026-05-26 LATE):** `SettingsViews` (LEGO 10.1, 10.2, 10.3,
10.3.5, 10.4) lifted to `SettingsViews.swift`, 1,618 lines. Holds
`PowerUserMode` enum + `ActionsView` (entry sheet behind the gear
icon — name dates back to v1.x) + `PowerUserView` +
`SystemPromptEditorView` + `ModelFramingDetailView` +
`SalonModeView`. Pure same-module pass-through coupling. Build
clean first try. Smoke test: NAVIGATE settings + SCREENSHOT confirms
the Personality section renders end-to-end. Hal.swift 15,424 →
13,893 (-1,531).

**#6 (2026-05-26 DEEP NIGHT):** `ChatViews` (LEGO 09, 09.5, 13,
13.5) lifted to `ChatViews.swift`, 1,363 lines. Discontiguous
slice: LEGO 09 + 09.5 (App Bootstrap + iOSChatView +
ThreadPanelView) and LEGO 13 + 13.5 (ChatBubbleView +
CompressionExplanationView + TimerView + MarkdownView) were ~1,820
lines apart in Hal.swift; concatenated together with a blank
separator. Cosmetic fix during the lift: LEGO 13's 4-space orphan
indentation stripped (548 lines de-indented). All four LEGO markers
preserved inside the new file; pointer comments at both old slots
in Hal.swift. Recon-validated clean coupling — all ChatViewModel
access is surface-level. Build clean first try. Smoke test:
SCREENSHOT of the chat surface shows title bar + toolbar + three
message bubbles with full footer attribution + MarkdownView text +
composer all rendering through the new file. Known follow-up:
HistoricalContext is logically a MemoryStore concept but lives in
LEGO 09 for historical reasons — flagged for future cleanup.
Hal.swift 13,893 → 12,650 (-1,243).

**Cumulative:** Hal.swift down **8,616 lines (~40.5%)** across six
extractions in one day. ~60% of the original file remains. Pointer
comments at every extracted LEGO slot in Hal.swift; LEGO markers
preserved verbatim inside every extracted file.
`sync_hal_source.sh` extended on each extraction. Every extraction
so far has needed `import Combine` in the new file (SwiftUI
re-exports some but not all of what `@AppStorage` / `@Published` /
`ObservableObject` resolve through — bake into the extraction
template).

---

## File layout

```
Hal Universal/
├── EmbeddingBackend.swift          — Enum + per-backend properties. Re-enable
│                                     recipe for Gemma at top.
├── EmbeddingProvider.swift         — NLContextual + Nomic backends. Gemma
│                                     embed path removed.
├── EmbedderMigrationCoordinator.swift — Migration + per-row UI. Now
│                                     properly parameterized.
├── QueryExpansion.swift            — Async LLM query expansion.
├── PromptDetailView.swift          — Color-coded prompt segment viewer.
├── SelfKnowledgeEngine.swift       — Reflection + trait CRUD.
├── TraitCrystallizer.swift         — Phase 2 reinforcement promotion.
├── ProcessMemoryGuard.swift        — Item 11 os_proc_available_memory.
├── MaintenanceTasks.swift          — NEW (2026-05-20). Orphan-cache cleanup
│                                     at launch. Extensible list.
├── MLXModelDownloader.swift        — Refactor #1 (2026-05-20).
│                                     BackgroundDownloadCoordinator +
│                                     MLXModelDownloader + Notification.Name.
├── ModelCatalogService.swift       — Refactor #2 (2026-05-26 PM).
│                                     ModelSource, MaximScorecard,
│                                     ModelSettings(+Store), ModelConfiguration
│                                     (with AFM + curated MLX seeds), HF API
│                                     DTOs, ModelCatalogService, CatalogError.
├── LocalAPIServer.swift            — Refactor #3 (2026-05-26 EVE).
│                                     MemoryStore + DocumentImportManager
│                                     API-helper extensions, HalTestConsole
│                                     (file-channel + shared executeCommand
│                                     dispatcher), LocalAPIServer (HTTP, port 8766).
├── DocumentImportManager.swift     — Refactor #4 (2026-05-26 NIGHT).
│                                     Document ingest pipeline, iOS-native
│                                     DocxParser (MiniZip + XMLParser),
│                                     ProcessedDocument + DocumentImportSummary
│                                     value types.
├── SettingsViews.swift             — Refactor #5 (2026-05-26 LATE).
│                                     PowerUserMode enum + ActionsView +
│                                     PowerUserView + SystemPromptEditorView +
│                                     ModelFramingDetailView + SalonModeView.
│                                     "MainSettingsView" → ActionsView naming
│                                     note in the file header.
├── ChatViews.swift                 — Refactor #6 (2026-05-26 DEEP NIGHT).
│                                     App bootstrap (HalAppDelegate + @main +
│                                     HistoricalContext + iOSChatView) +
│                                     ThreadPanelView + ChatBubbleView +
│                                     CompressionExplanationView + TimerView +
│                                     MarkdownView. LEGO 13's 4-space orphan
│                                     indentation stripped during the lift.
└── Hal.swift                       — Everything else (~12.7k lines, down
                                      from 21.3k pre-refactor).
```

---

## Build + Deploy (iPhone 16 Plus)

**Must run under the beta toolchain** (`DEVELOPER_DIR` prefix) — stable
Xcode has no iOS 27 platform and won't see the device. No global
`xcode-select` change needed.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

xcodebuild build \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" \
  -configuration Debug

xcrun devicectl device install app --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  "/Users/markfriedlander/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"

xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal
```

- iPhone 16 Plus (device): `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
- Sim UDIDs (recreated during the 2026-06 beta upgrade; old `10C6DB49…`
  is dead): iPhone 17 Pro `80B63D38-7F94-4E88-B4B5-0CD0D8EE3B6F`,
  iPhone 17 `68E7C970-6FE1-477E-A41E-349CF24E388E`
- API host (device): `marks-bigger-ass-fon-16.local` port 8766
- API token (device): `e9ee9ec5b315467fa655bd4296873f43` (in `tests/.hal_api_config.json`)
- Sim API config: `HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/hal_test.py …`
- SCREENSHOT/NAVIGATE: `tests/hal_test.py screenshot|navigate <target>` — already-shipped tooling for device-side visual verification.

---

## SOP (unchanged from prior sessions, one new lesson)

1. **After any change to Hal's source, sync `Hal_Source.txt`:**
   ```bash
   ./scripts/sync_hal_source.sh
   ```
2. **Refactor-as-you-go is mandatory.** Significant changes to a
   section → extract into a dedicated file with a header explaining
   structure. See `MLXModelDownloader.swift` as the template.
3. New enum case → sweep all switches (compiler-enforced).
4. New AppStorage key → `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
5. App build number bump happens at App Store submission (currently at 6 in production; bump to 7 for v2.0.1).
6. Never `NUCLEAR_RESET` between plant and recall in a memory test.
7. **Update HISTORY/HANDOFF/NEXT as work lands** (CLAUDE.md Golden Rule #8).
8. **Warnings = errors** (CLAUDE.md Golden Rule #7).
9. **API > asking the human** — expand the API if a question can't be answered through it.
10. **Don't bail on a probe based on ambiguous telemetry.** Add instrumentation, not exit doors.
11. **Confirm any deviation from a stated directive before executing it.**
12. **Comment-out, don't compile-flag.** New lesson from v2.0.1: flag-gating creates Debug/Release drift. Comment-out keeps code preserved + discoverable without behavioral drift.

---

## Known caveats

- **`SET_MEMORY_DEPTH` doesn't survive app re-init** (Bug 1 from 2026-05-19; deferred). Workaround: re-SET after every relaunch.
- **First chat after SWITCH_MODEL to Gemma/Dolphin fails reliably** (Bug 3 from 2026-05-19; deferred). Workaround: wait 10-15 s before sending.
- **EmbeddingGemma is fully commented out.** Re-enable recipe at top of EmbeddingBackend.swift.
- **No EU distribution.** DSA non-trader choice. Switchable later if Mark wants.
- **Mark's iPhone may still have orphan Gemma weights from pre-fix testing.** Will be cleaned up automatically when the v2.0.1 Debug build is installed for device verification (MaintenanceTasks.runAtLaunch fires).
