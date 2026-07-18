# Hal Universal — Handoff Brief
**Updated:** July 16, 2026 (late)
**Branch:** `main`
**Production:** **v2.5 shipped** (build 2.5(4), via Xcode Cloud). v2.0 first went live 2026-05-19. Non-EU markets only (DSA non-trader).

> This file is the **present-tense snapshot** — where Hal is *right now*.
> History lives in `HISTORY.md`; forward plans live in `NEXT.md`. Keep it lean.

> **Toolchain (BETA STACK since 2026-06):** Xcode-beta (`/Applications/Xcode-beta.app`),
> iOS 27 beta on the device, macOS 27 beta on the Mac. Stable `Xcode Release.app` is the
> active `xcode-select` but has no iOS 27 platform, so **every device build must prefix
> `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`**. Install/launch via `devicectl`.

> **Xcode Cloud is OFF (deactivated 2026-07-18).** The "Default" workflow was building on
> *every* push to `main` ("any file changes") and uploading each build to App Store Connect —
> it ran up 10 builds (incl. website/docs commits) before we caught it. Master toggle is now
> deactivated in App Store Connect → Hal Universal → Xcode Cloud → Manage Workflows → Default.
> **A push to `main` no longer triggers a build — this is intentional, not a breakage.** To
> ship the next version: either flip that workflow back on (and first change its start
> condition off "any file changes on main"), or just archive+upload from Xcode on the Mac.
> Full story in HISTORY (2026-07-18).

---

## Where Hal is right now

**Active arc: the reasoning / "watch Hal think" feature + a hardened model-download subsystem.**

### Just landed — committed `cd39dd2` (2026-07-16), device-verified
The **model download/share subsystem is now bulletproof against interruption and abnormal cleanup**:
- **`clearHubCache` → `clearHalsModels`** — claim-aware delete. "Clear Cache" no longer `rm -rf`'d the
  whole App-Group container (which wiped every family app's models); it releases only Hal's claims and
  deletes only models nobody else claims. Button relabelled + copy names co-claiming apps.
- **Nested-repo downloads** — recursive HF listing (`?recursive=1`) + create the file's subdir before the
  move. A nested file (e.g. `1_Pooling/config.json`) was previously invisible and silently lost while the
  model reported "ready".
- **Failed move ≠ success** — new failure path refuses to claim/mark-downloaded, releases the lock,
  removes the partial dir. A completion **sentinel** (`.hal-download-complete`) means a partial download
  is never mistaken for complete (resume path + `startDownload` both gate on it via `forceResume`).
- **Interrupted download resumes to completion** (was permanently stuck — `startDownload` returned early
  on a partial dir). **`deleteModel`** now cancels in-flight tasks + releases the lock + clears the marker.
- **Instrument hardened** — `RuntimeLog` mirrors every line to `os_log` (subsystem
  `com.MarkFriedlander.Hal-Universal`, category `runtime`), streamable from a Mac while the app is
  backgrounded/locked: `log stream --predicate 'subsystem == "com.MarkFriedlander.Hal-Universal"'`.

Also in `cd39dd2` (WORK IN PROGRESS, not finished/verified): the reasoning feature + full per-model
sampler wiring (`ModelSettings` + `reasoningSettings`) + tuning harnesses under `tests/`.

### Uncommitted right now (this session, code-done, device-verify pending)
- **Qwen `reasoningSettings` re-seeded** to the MEASURED recipe (temp 0.7, presence 0.5, top_p 0.95,
  top_k 20, rep 1.0) — replacing the wrong model-card temp-1.0/presence-1.5 that loops.
- **`detectRepetitionLoop` widened** — exact-period search (`trailingRepeatPeriod`), range 30–420 stepped
  by 1 (old 30–80/step-10 missed every real loop). **Offline-validated against the corpus: 8/8 loops
  caught, 0 false positives.**
- **(in progress) NLContextual first-run fix** — see NEXT.

### The two big open pieces (see NEXT.md for detail)
1. **Reasoning "hammer"** — a force-close `LogitProcessor` that bounds runaway thinking (sampler alone is
   insufficient — the 144-turn battery proved the good cell still hangs ~25% math / ~60% open-ended).
   Architectural wrinkle to design first: a custom `LogitProcessor` on Hal's generate path currently
   trades away KV-cache quantization. NOT yet built.
2. **API hardening (ship requirement)** — `LocalAPIServer` is `@MainActor`, so every command runs on the
   main thread; heavy file work (directory walks, manifest coordination vs. the download's lock refresh)
   wedges the whole app under load. Root cause pinned; fix = move file work off the main actor in the
   command handlers. Deserves its own focused session (it ships in the public "let other LLMs talk to Hal"
   API).

**Priority arc (Mark):** back up Hal's personally-created traits (soul/identity) so development stops
wiping his memory. Proposals system + Soul Document remain explicitly OUT until Mark's ready.

---

## Architecture pointers

- **`Hal.swift`** (~12.9k lines) — the conceptual heart: `MemoryStore` + `ChatViewModel` + prompt
  budgeting + LLM routing + summarization, kept together on purpose for diagnosability (a 2026-05-26
  refactor sprint pulled 40% out into the files below). Also holds `RuntimeLog`/`halLog`,
  `ReasoningTuning`, `detectRepetitionLoop`, `splitThinkTokens`.
- **`MLXModelDownloader.swift`** — `BackgroundDownloadCoordinator` (URLSession download engine, resume,
  failure path) + `MLXModelDownloader` (download/delete/adopt, `DownloadState`).
- **`SharedModelStore.swift`** — App-Group paths + refcount `manifest.json` + `download-locks.json` +
  the completion sentinel. **The cross-app contract**: Hal, Posey, and AI-Camera share this format
  byte-for-byte (verified 2026-07-16). Drift = silent data loss.
- **`ModelCatalogService.swift`** — catalog + curated seeds + `ModelSettings` (now with full sampler:
  topP/topK/minP/presencePenalty) + `reasoningSettings` variant.
- **`LocalAPIServer.swift`** — `HalTestConsole` (shared `executeCommand` dispatcher) + `LocalAPIServer`
  (HTTP, NWListener :8766). `@MainActor` — see API-hardening item above.
- **`MaintenanceTasks.swift`** — launch one-shots (legacy migration, orphan-cache cleanup).
- **`PrivacyMonitor.swift`** — network-state → lock indicator.
- **LEGO blocks**: every file carries numbered `// ==== LEGO … ====` markers, clean 1…59; guarded by
  `scripts/validate_lego.py`. Preserve them in any extraction.

**Curated models:** AFM (on-device) + Gemma 4 E2B, Qwen 3.5 2B (the reasoning model), Llama 3.2 3B,
Dolphin 3.0, Ternary Bonsai 8B (2-bit "deep reasoner"). Embedders: NLContextual (default), Nomic
(end-to-end retrieval champion), mxbai. EmbeddingGemma parked (upstream mlx-swift iOS Metal crash).

---

## Build + Deploy (iPhone 16 Plus)

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild build -scheme "Hal Universal" \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6"
xcrun devicectl device install app --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  "$HOME/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"
xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal
```

- **Device:** iPhone 16 Plus `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`. API host
  `marks-bigger-ass-fon-16.local:8766`, token in `tests/.hal_api_config.json`.
- **Sims:** iPhone 17 Pro `80B63D38-7F94-4E88-B4B5-0CD0D8EE3B6F`, iPhone 17
  `68E7C970-6FE1-477E-A41E-349CF24E388E` (config `HAL_API_CONFIG=.hal_api_config_sim.json`).
- **Only the FOREGROUND app's local-API antenna responds** (iOS suspends background apps); switch apps
  via `devicectl` launch. The antenna is OFF by default (`kLocalAPIEnabledOnLaunch = false`); flip to
  `true` for local device testing, **revert before commit/ship**.
- **Live device log stream** (works while backgrounded/locked, since 2026-07-16): the `os_log` mirror, or
  attach at launch with `devicectl device process launch --console`.
- **Test runner:** `tests/hal_test.py` (`cmd`, `turn`, `state`, `logs`, `screenshot`, `navigate`,
  `think_stream`, …). Sync source after any change: `./scripts/sync_hal_source.sh`.

---

## SOP (standing rules)

1. **Sync `Hal_Source.txt` after any source change** (`./scripts/sync_hal_source.sh`) — it's the copy Hal
   reads about himself.
2. **Warnings = errors** (Golden Rule #7) — fix in the same commit.
3. **Docs current as work lands** (Golden Rule #8) — HISTORY (past) / HANDOFF (present) / NEXT (future).
4. **Comment-out, don't compile-flag** (#12) — flag-gating creates Debug/Release drift.
5. **LEGO blocks stay everywhere**; `scripts/validate_lego.py` must pass.
6. **Discussion before code** on anything non-trivial; small surgical moves over rewrites.
7. **Ask before multi-agent fan-outs**, and **announce + wait** before asking Mark to physically do
   something on the device (memory: `ask-before-multi-agent-fanout`, `announce-and-wait-for-interaction`).

---

## Known caveats

- **API antenna wedges under download load** — `LocalAPIServer` is `@MainActor`; must be hardened before
  the API ships (see NEXT).
- **NLContextual embedder can go temporarily non-computing after an OS-level asset invalidation.** Apple's
  NLContextual model asset is **device-wide** (`/var/db/com.apple.naturallanguaged/`), shared across all
  apps, and **survives app deletion** — so this is NOT "first install only" and **cannot be reproduced by
  deleting Hal.** It recurs whenever the OS invalidates/re-provisions that asset (an OS update — including
  the iOS 27 beta — or storage-pressure eviction): the asset re-downloads and iOS recompiles it (~30 s
  into an `e5bundlecache`), and during that window `load()` succeeds but `embeddingResult` produces no
  vectors. **FIX (written, uncommitted, EmbeddingProvider.swift `ensureNLLoadedBlocking`):** a warm-up
  probe refuses to cache a model that can't compute, and `embedNLContextual` retries each query — so
  semantic degrades to keyword (RRF handles a nil semantic arm) and **self-heals the moment the recompile
  finishes**, no relaunch required. Un-reproducible on Mark's phone (asset already recompiled); will
  confirm in the wild after the next OS cache invalidation. *(Corrected 2026-07-16: an earlier read called
  this "first-ever use" — wrong; Hal had used NLContextual on this phone for months, so the asset was
  already present and got invalidated, not freshly downloaded.)*
- **Reasoning model (Qwen) loops** on ~25% of math / ~60% of open-ended even at the best sampler cell —
  the hammer is required (not yet built). This is an industry-wide property of small thinking models, not
  a Hal bug.
- **EmbeddingGemma fully commented out** — re-enable recipe atop `EmbeddingBackend.swift` (blocked on an
  upstream mlx-swift iOS Metal-init crash).
- **No EU distribution** (DSA non-trader). Reversible.
- **Bug 3** — first chat after SWITCH_MODEL to a ~3 GB MLX model can fail; wait 10–15 s (mitigated by
  reload-on-demand).
- **Uninstalled-app claims are never reaped** — deleting a family app leaves its manifest claims forever,
  pinning shared models. Contract-level fix, deferred (see NEXT).
