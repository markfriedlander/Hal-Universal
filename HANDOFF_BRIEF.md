# Hal Universal — Handoff Brief
**Updated:** May 20, 2026 (post-v2.0-ship, v2.0.1 hotfix committed, refactor begun)
**Branch:** `main` @ `9f5fdf8` (clean tree, all pushed)
**Production:** Hal Universal **v2.0 is live on the App Store** since 2026-05-19. Non-EU markets only (DSA non-trader; see HISTORY).

## Where Hal is right now

v2.0 shipped. Then immediately surfaced a real production bug — the
**EmbeddingGemma mis-download** — fixed and sim-verified as the v2.0.1
hotfix. Refactor begun, first subsystem extracted. **Not archived for
ASC yet** — gated on device-side verification of the hotfix.

### Most recent commits

```
9f5fdf8  Refactor: extract MLXModelDownloader to its own file
90479cc  v2.0.1 hotfix: remove EmbeddingGemma + parameterize startDownload + cleanup
03c10c1  EmbedderBackendRow: tap-proof guard around EmbeddingGemma actions
e30c888  Add About section to Settings showing version + build
3eb3014  Add SC strategy memo + draft HTML reference copies
9da09b0  Bug 4 v2: banner relocation + Model framing label + System Prompt dim
```

### v2.0.1 hotfix — sim-verified, device verification owed

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

**Device verification owed.** Mark's directive: device-side verify
before archive. See `NEXT.md`.

### Refactor — first extraction landed

`MLXModelDownloader` (LEGO 29 from Hal.swift) lifted to its own file
(`Hal Universal/MLXModelDownloader.swift`, 1,717 lines). Holds
`BackgroundDownloadCoordinator` + `MLXModelDownloader` + the
`.mlxModelDidDownload` Notification.Name extension. Two classes in one
file because they're tightly coupled — splitting would push the seam
into thin interface types without isolation gain.

Hal.swift: **21,266 → 19,602 lines** (1,664 lighter, ~7% smaller).

Pointer comment left in Hal.swift at the old LEGO 29 slot so the
numbering chain still reads. `sync_hal_source.sh` updated. Clean
Debug build, zero warnings. Functional smoke test: deleted Nomic and
re-downloaded; BackgroundDownloadCoordinator enqueued 8 files,
byte-tracked through `didWriteData`, atomically moved each finished
file, hit 73 MB/s. Same behavior, new file.

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
├── MLXModelDownloader.swift        — NEW (2026-05-20, refactor #1).
│                                     BackgroundDownloadCoordinator +
│                                     MLXModelDownloader + Notification.Name.
└── Hal.swift                       — Everything else (~19.6k lines, down
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
