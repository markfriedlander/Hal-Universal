# Hal Universal — Handoff Brief
**Updated:** May 26, 2026 (refactor #6 ChatViews landed; Hal.swift down ~40.5% in one day's refactor sprint)
**Branch:** `main` @ `41c0601` (clean tree, all pushed)
**Production:** Hal Universal **v2.0 is live on the App Store** since 2026-05-19. Non-EU markets only (DSA non-trader; see HISTORY).

## Where Hal is right now

v2.0 shipped. v2.0.1 hotfix (EmbeddingGemma mis-download) is **fully
verified** — sim + device — but **deferred to v2.1** per Mark's call
on 2026-05-26: the orphan-weights bug is bandwidth-leaky but
crash-safe, so it can ride with the next bigger release.

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
- iPhone 17 Pro sim UDID: `10C6DB49-2723-4F95-8F81-AECB9CD72BD0`
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
