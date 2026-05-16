# CC Session Handoff — 2026-05-15 PM (pre-compaction)

**For:** post-compaction CC continuing this work
**Branch:** `mlx-experiment` @ `f78de2c` (or whatever HEAD is when you read this)
**All work pushed to:** `origin/mlx-experiment`

## What just happened in this session (compact summary)

19 commits today across two major waves:

### Morning wave (5 commits)
- `a5eb797` Fix 1A: contamination — `historyMessagesOverride` was dead parameter in `runSingleModelTurn`
- `7f4a9d0` Fix 2A: MLX crash — added `Stream.gpu.synchronize()` to `unloadModel` + memory diagnostics
- `3c8c4b7` Salon report + Turn 1/2/3 transcripts (`Docs/Evolutionary_Salon_Report_2026-05-15.md`)
- `9c607e8` Qwen 0.65→0.7 + Dolphin 0.75→0.7 temperature revert per Maxim 1 retest
- `27646c9` Repetition trim: preserve one full instance + 6 random in-voice phrases

### Mid-afternoon wave (5 commits)
- `bf54055` ASC metadata target-diff doc (`Docs/ASC_Metadata_Diff_2026-05-15.md`)
- `acb1f90` GitHub README diff doc (`Docs/GitHub_README_Diff_2026-05-15.md`)
- `95c8662` UI thread diagnosis doc + Fix A proposal (`Docs/UI_Thread_Diagnosis_2026-05-15.md`)
- `9db3a32` README.md v1.6 rewrite (later bumped to v2.0)
- `c5b3438` ASC findings: copyright bumped 2025-2026 (saved); desc/keywords version-locked until v1.6/2.0 draft exists

### Late afternoon — Fix A + v2.0 lock-in (3 commits)
- `abb2230` Fix A: `Task.detached` for setupLLM load — architecturally correct, partial UI improvement (still has streaming churn issue)
- `94560cb` Lock in v2.0 + remove dead macCatalyst block
- `750f487` MLXWrapper: unload model on app background to reduce jetsam pressure (lifecycle handler)

### Evening — the BIG BGDL refactor (6 commits)
This is the work in progress; understand this section deeply if you're resuming.

- `ebb6dd0` Wire MLXModelDownloader progress to BGDL byte tracking + bytes-flow logging.
  Fixed the long-standing broken progress meter (was polling `directorySize`; now uses BGDL's `bytesWrittenByModel / bytesExpectedByModel`). Added `HALDEBUG-BGDL-BYTES` 5-second throttled logs.

- `6ef3c79` BGDL: cancel stale in-flight tasks before fresh enqueue (dedup).
  Surfaced because the new bytes logging showed 3 concurrent tasks racing for model.safetensors at 0.7 MB/s each. Now `startDownload` cancels existing tasks for the modelID before enqueuing.

- `eb133d6` **BGDL: dual-session hybrid (foreground for speed, background for resilience).**
  THE BIG ONE. 686 insertions / 200 deletions. Two URLSession instances (foreground = fast/`URLSessionConfiguration.default`, background = slow but resilient/`URLSessionConfiguration.background`). On `didEnterBackground`: migrate fg→bg via `cancel(byProducingResumeData:)`. On `willEnterForeground`: reverse migration. SessionKind enum + TaskKey struct for namespacing dictionaries by session.
  Foreground throughput: 6-14 MB/s (matches curl baseline). Background: ~1.7 MB/s.

- `1fe5623` MLXModelDownloader: don't re-trigger startDownload if BGDL already has in-flight tasks.
  Added `BGDL.hasActiveTasks(for: modelID)` helper. `resumeInFlightDownloadsIfAny` now consults it before re-triggering. Made `resumeInFlightDownloadsIfAny` async and pulled out of `MainActor.run` closure.

- `1778bb7` Convert `resumeInFlightDownloadsIfAny` print() calls to halLog().
  print() goes to Xcode console only; halLog() goes to RuntimeLog which the API surfaces. Was making the diagnostics invisible from the API logs.

- `f78de2c` **resumeInFlightDownloadsIfAny: 1.5s settle delay before consulting BGDL.**
  Fixed the launch-time race: two recovery paths fire concurrently on relaunch — BGDL's URLSession reconnection + willEnterForeground migration, AND MLXModelDownloader's auto-resume. The migration leaves bg tasks in `.cancelling` state for a few ms, during which `hasActiveTasks` returns false (filters for .running/.suspended). Auto-resume then re-triggered startDownload, which dedup-killed the just-migrated task. 1.5s settle gives migration time to complete (typically ~10ms). Only fires on relaunches with in-flight markers (rare).

## Test state at handoff time

A Gemma download has been running in the foreground. Last seen at 57%. A Monitor is armed (task ID bciasa0x1) that fires when `isDownloaded` flips to true. Once download completes, the next step is:

1. Deploy the latest build (`f78de2c`) — install + launch via devicectl
2. Delete Gemma via API (`echo y | python3 tests/hal_test.py delete_model "mlx-community/gemma-4-e2b-it-4bit"`)
3. Trigger fresh download via API (`python3 tests/hal_test.py download "mlx-community/gemma-4-e2b-it-4bit"`)
4. Confirm foreground download is rolling at ~10 MB/s (a few seconds of polling MODEL_STATUS)
5. Ask Mark to **lock the phone face down**
6. Wait 60-90 seconds
7. Ask Mark to **unlock + foreground**
8. Pull logs and verify:
   - `HALDEBUG-DOWNLOAD: resumeInFlightDownloadsIfAny: settle complete, evaluating each marker`
   - `HALDEBUG-DOWNLOAD: ... — BGDL already has in-flight tasks (auto-reconnected); NOT re-triggering startDownload`
   - Migration `migrate ✅ bg→fg with N bytes of resume data; new fg task X`
   - NO new "Enqueuing on FOREGROUND" / fresh-tasks-from-byte-0 enqueues
   - `fg task X (model.safetensors)` continues from migrated state at 10+ MB/s

If verified: the hybrid + race-fix is shipping-quality. Move on to:
- **Item 9** (BGDL post-deletion cleanup test): user deletes Hal entirely from springboard mid-download, reinstalls, verify no orphaned files in `Library/Caches/huggingface/`
- **Rotation reflow fix** (#2 from earlier — chat message bubbles use `maxWidth: screenWidth * 0.90` which doesn't reflow on landscape; need to replace with container-aware sizing in `ChatBubbleView` lines 9695, 9742; see Mark's screenshot in transcript showing text wrapping at portrait width on landscape iPhone)

If NOT verified (still races): consider the cleaner architectural fix — add `currentlyMigratingModelIDs: Set<String>` to BGDL and have `hasActiveTasks` return true if model is in that set OR has active tasks.

## What's still left for v2.0 ship

In rough order. **Don't have ship-fever** — Mark explicitly pushed back on that today. Do it right.

### Code/testing
1. **Verify the BGDL race fix** (Item 10 / §7 retest — the test we're about to run)
2. **Item 9: BGDL post-deletion cleanup test** — delete app entirely, reinstall, check for orphans
3. **Rotation reflow fix** — `ChatBubbleView` `maxWidth` (lines 9695, 9742). Mark's screenshot from this session shows the bug clearly: long text wraps at portrait width even when in landscape. The current code uses `screenWidth * 0.90` where `screenWidth` is `UIScreen.main.bounds.width`. Need to use available container width via GeometryReader or `.frame(maxWidth: .infinity, alignment: .leading/.trailing)`.
4. **A real conversation with Hal on the new build** (sanity check that nothing regressed in everyday use)
5. **Item 8 (skippable):** Long-user-message scroll threshold tune

### Release prep
6. **Screenshot replacement** — `ChatPhi.PNG` is obsolete; replace with `ChatGemma.PNG`. Optionally add `Salon.PNG` to differentiate. Mark captures these from his phone.
7. **Version + build bump** in Xcode project: `CFBundleShortVersionString` → "2.0", `CFBundleVersion` → 4 (or whatever increment)
8. **Build + archive + upload** to App Store Connect — creates the v2.0 draft on ASC
9. **Apply description + keywords + what's-new** to v2.0 ASC draft (mechanical, I can do via Chrome MCP once draft exists; what's-new copy is Mark's voice call though I drafted topic list in the salon report and ASC diff doc)
10. **Merge `mlx-experiment` → `main`** so README.md goes live for the App Store Support/Privacy Policy URLs
11. **Submit for review**

### Mark + SC own
- Salon synthesis review (THRESHOLD ~50, INTERVAL 30-45d, AGENCY hybrid — see `Docs/Evolutionary_Salon_Report_2026-05-15.md`)

### Post-ship items (deferred, not v2.0)
- UI thread polish Fix C: throttle per-token streaming (the screen-locks-up-during-salon issue Mark noticed)
- Three synthesis architecture adjustments from yesterday's salon
- `/salon` as foundation for command palette
- iCloud sync, v2.0 (now v2.x) refactor, Mistral3 multimodal loader hang investigation

## Key files + paths

- App source: `/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal/Hal.swift` (~18,800 lines, LEGO blocks)
- After ANY Hal.swift change: `cp Hal\ Universal/Hal.swift Hal\ Universal/Hal_Source.txt`
- Build for device: `xcodebuild build -project ... -scheme "Hal Universal" -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" -configuration Debug`
- Install: `xcrun devicectl device install app --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 "$DERIVED/.../Debug-iphoneos/Hal Universal.app"`
- Launch: `xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal`
- API config: `tests/.hal_api_config.json` — currently `host: marks-bigger-ass-fon-16.local, port: 8766`. IP `192.168.12.206` from earlier went stale; mDNS hostname is robust across DHCP changes.
- API test runner: `python3 tests/hal_test.py state | list_models | download <id> | model_status <id> | logs [N] | cmd <COMMAND>`

## Mark's working preferences (relearned this session)

- **No ship-fever.** Build it right. Mark literally pushed back on this twice today.
- **Honest framing.** Don't say "perfect" if there's a known limitation. He'll catch it.
- **Discussion before code on architectural changes.** Diagnose, propose, get approval, implement.
- **One step at a time when refactoring large code.** Verify each piece compiles.
- **Use halLog() not print()** for anything you want queryable via the API. Critical lesson today.

## Critical context the system reminder won't surface

- Mark's WiFi: 110 Mbps confirmed. iOS background URLSession is intentionally bandwidth-throttled (~1.7 MB/s); this is by Apple's design, not a bug. The hybrid we built today is the canonical fix.
- iOS will jetsam-kill Hal during locked-phone download windows because of MLX model memory footprint. Lifecycle handler at `MLXWrapper.init` (commit `750f487`) unloads model on background to mitigate. Background URLSession survives the kill via `nsurlsessiond`.
- HuggingFace's CDN redirects `huggingface.co/.../resolve/main/X.safetensors` to `cas-bridge.xethub.hf.co/...` (signed AWS URLs). Supports Range requests, which is why resume data works for migration.
- Phone hostname on local network: `marks-bigger-ass-fon-16.local`. IP changes; mDNS is stable.

## When in doubt

Read `Docs/Evolutionary_Salon_Report_2026-05-15.md` first — it has the architectural context of where Hal is going.
Read `Docs/Two_Bug_Diagnosis_2026-05-15.md` for how to do honest diagnosis without ship-fever.
Read `Docs/UI_Thread_Diagnosis_2026-05-15.md` for the threading model overview.
Read `MEMORY.md` (root) for project structure.

---

*— CC, May 15, 2026, end of long day*
