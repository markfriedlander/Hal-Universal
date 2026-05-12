# Hal Universal — Handoff Brief
**Updated:** May 11, 2026 — v1.x release prep
**Branch:** mlx-experiment

---

## v1.x Release Status — Ready for Mark's Hardware Validation

Per `Docs/CC_V1x_Release_Brief.md` from Strategic Claude, this session prepped a fix-and-stabilize release with Gemma 4 E2B as the local-inference option. Done autonomously on Mac while Mark is out with the phone.

### What landed this session

| Commit | What |
|---|---|
| `da94d28` | Model UI filter (AFM + Gemma 4 E2B only) + Salon Mode hidden behind `salonModeExposedInUI = false` flag |
| `(icon)` | New app icon per visual spec (red-orange orb, silver rings, yellowish pupil bloom) |
| `824b7fb` | `selectedModelID` clamp in `ChatViewModel.init` for upgraders with non-allowlisted MLX models; reverted salon force-off at init (caused a sendMessage regression) |

All builds clean: `generic/platform=iOS`, `iOS Simulator (iPhone 17 Pro)`. App launches in simulator without crash. No new asset-catalog warnings.

### What was verified

- **Build stability:** Clean compile for both physical-iPhone destination and simulator.
- **App icon:** Asset catalog accepts all three variants (light, dark, tinted-luminance-map). No actool warnings.
- **Catalog-display fix (commit `90e8097`):** Verified live on Mark's iPhone earlier in the session — `selectedModelDisplayName` correctly shows `"gemma-4-e2b-it-4bit"` instead of `"Apple Intelligence"`.
- **Filter:** ModelLibraryView source code shows the allowlist `["apple-foundation-models", "mlx-community/gemma-4-e2b-it-4bit"]` applied at all three sections (built-in, downloaded, available). No other model can be reached through the user-facing UI.
- **Salon hidden:** `ActionsView.powerUserSection` no longer renders the Single/Multi LLM segmented picker. Only "Single LLM Settings" button is reachable.

### What needs Mark's phone to verify

- **Gemma generation on iPhone 16 Plus.** Last session this morning was at 33-37 tok/s. The intermediate test on the phone during this session showed an unrelated sendMessage regression that was caused by an init-time mutation of `salonConfig.isEnabled` — that mutation has been reverted (commit `824b7fb`). The current build should restore the working chat flow.
- **`screenWidth = 0` fix end-to-end** — only reproducible on cold launch / scene-state-transition timing, which doesn't occur reliably in simulator. The `screenWidth` property now has a three-tier fallback (any non-background scene → UIScreen.main → hardcoded 390); fix landed at commit `00bf3a7`.
- **Icon at device scale** — looks correct in asset catalog; final visual check is on physical hardware.

### Multi-app port family (resolved May 12)

Hal's `LocalAPIServer.apiPort` moved from **8765 → 8766** so it coexists with Posey (also using 8765) and any other app in Mark's app family. Verified May 12: Hal sim build binds 8766 while Posey sim build holds 8765 — both apps responsive on their own ports simultaneously. The pattern: pick the next sequential port and document the assignment in `LocalAPIServer.apiPort` comment + this brief.

Known port assignments:
- **Posey** → 8765
- **Hal** → 8766

---

## Architecture Recap (unchanged from yesterday's session)

Hal runs on a unified chat-message generation path for both AFM and MLX. All subsystems (auto-summary, reflection, RAG snippet summarization, document import summary, salon context-aware) flow through `LLMService.generateChatResponse(messages:temperature:)`. Zero callers remain of the legacy `generateResponse(prompt:)` path; the old functions (`buildPromptHistory`, `buildContextAwarePrompt`, `LLMService.generateResponse`, `MLXWrapper.generate`) are preserved as reference and tagged with ⚠️ DEAD CODE markers.

Chat-message structure assembled in `buildChatMessages(currentInput:)`:
- `.system(...)` with persona + CURRENT CONTEXT block (temporal awareness, injected summary, RAG snippets, self-awareness + self-knowledge)
- Alternating `.user/.assistant` from `vm.messages` (last `effectiveMemoryDepth × 2` non-partial messages, current user dropped — added explicitly at end)
- `.user(currentInput)` — the current turn

Gemma 4 E2B 4-bit on iPhone 16 Plus measured at ~33 tok/s.

---

## v1.x User-Visible Surface

### Model picker (Settings → "Browse Model Library")
- **Apple Intelligence** — always available, no download.
- **Gemma 4 E2B** — fully private, on-device, one-time 3.58 GB download. Visible from app launch (hardcoded `ModelConfiguration.gemma4E2B4bit` seeded into `ModelCatalogService.availableModels` so it's there even without a successful HF catalog fetch).

### Settings → Power User
- Only "Single LLM Settings" button. No mode toggle. No Salon Mode entry.

### To expand the picker later
Edit `ModelLibraryView.userVisibleModelIDs` (Hal.swift, in the Model Filtering section). The catalog/downloader/API all continue to see every model regardless of this filter.

### To re-enable Salon Mode
Set `ActionsView.salonModeExposedInUI = true`. All Salon Mode code remains intact.

---

## App Icon (`Assets.xcassets/AppIcon.appiconset/`)

- `hal_icon_v3.svg` — source SVG (680×680 viewBox, scaled to 1024×1024 at render)
- `hal_icon_v3_light.png` — universal + dark luminosity variants
- `hal_icon_v3_tinted.png` — grayscale luminance map for tinted appearance
- Old v2 PNGs preserved at `Assets.xcassets/.appicon_v2_backup/`

To re-render after editing the SVG:
```bash
cd "Hal Universal/Assets.xcassets/AppIcon.appiconset"
rsvg-convert -w 1024 -h 1024 hal_icon_v3.svg -o hal_icon_v3_light.png
sips --matchTo "/System/Library/ColorSync/Profiles/Generic Gray Profile.icc" hal_icon_v3_light.png --out hal_icon_v3_tinted.png
```

---

## When Mark Returns With the Phone

1. **Install latest build on iPhone 16 Plus:**
   ```bash
   xcodebuild build -project "Hal Universal.xcodeproj" -scheme "Hal Universal" \
     -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" -configuration Debug
   xcrun devicectl device install app --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
     "/Users/markfriedlander/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"
   xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal
   ```

2. **Confirm Gemma generation still works** — single short turn through the API. Last session measured 33-37 tok/s; the chat send regression from this session has been reverted.

3. **Visually confirm new icon** at device scale on home screen and in Settings.

4. **Walk through the simplified Model Library UI** — verify only Apple Intelligence and Gemma 4 E2B appear.

5. **Confirm Settings → Power User shows only "Single LLM Settings"** — no Salon Mode entry.

6. **Increment build/version** in project settings for App Store submission (per Mark — to be discussed when he returns).

---

## API Reference

All commands unchanged from yesterday's expansion. Key release-related ones:

| Command | Description |
|---------|-------------|
| `GET_UI_STATE` | Current view, sheet state, model display name, typing state, error banners |
| `GET_RENDERED_MESSAGES` | Messages bound to chat view (vm.messages) — includes partials |
| `GET_LOGS` / `GET_LOGS:N` | RuntimeLog ring buffer (HALDEBUG-* lines) |
| `LIST_MODELS` | Full catalog — still returns every model even with the UI filter active |
| `SWITCH_MODEL:<id>` | Switch (works for any catalog ID, not just user-visible) |
| `NUCLEAR_RESET` | Wipe all conversation data (preserves self-knowledge) |

Test runner: `python3 tests/hal_test.py [command]`. Config at `tests/.hal_api_config.json` is currently set to Mark's iPhone (`192.168.12.206:8766`).

---

## Build + Deploy (iPhone 16 Plus)

- **Device ID:** `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
- **Bundle ID:** `com.MarkFriedlander.Hal-Universal`
- **API token:** `e9ee9ec5b315467fa655bd4296873f43` (regenerated only on uninstall/reinstall)

---

## Open Issues (Priority Order)

1. **Chat send regression on phone** — observed once this session after the salonConfig.isEnabled=false-at-init change. **Reverted in `824b7fb`.** Needs Mark's device to confirm restoration.
2. ~~Posey port conflict~~ — **Resolved May 12.** Hal moved to port 8766. Both apps coexist on the Mac and on phones.
3. **Dead code** — `buildPromptHistory`, `buildContextAwarePrompt`, `LLMService.generateResponse`, `MLXWrapper.generate` have zero callers but remain tagged in the source. Safe to delete in v2.0 refactor.
4. **RAG dedup / per-snippet summarization** — dropped during chat-path migration. Re-add when conversation length warrants it.
5. **Reflection prompt format** — sometimes produces continuation rather than meta-observation. Already partially addressed (commit `243a02d`). Further polish post-release.
6. **Mac Catalyst UI rendering** — broken, low priority per brief.
7. **Apple Watch companion timeouts** — not investigated this release.

---

## v1.x → v2.0 → v2.x Roadmap (per Strategic Claude)

**v1.x (this release):** Fix, stabilize, ship. AFM + Gemma 4 E2B only. Clean UI.
**v2.0:** Full codebase refactor — multi-file split, comprehensive commenting, dead-code removal, architecture cleanup. No new features.
**v2.x:** Stress testing at volume, additional model evaluation, soul-document deepening, proposals system, Salon Mode re-introduction (it's preserved, not removed).

---

## SOP

1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` after every Hal.swift change.
2. New enum case? Sweep all switches.
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
4. App build number bump happens at App Store submission, not before.

---

## Standing Architectural Rules

- No third-party libraries without explicit discussion.
- One block at a time — surgical changes, build clean after each.
- Discussion before code when introducing new structure; autonomous mode OK when extending an agreed plan.
- Old code stays — broken or not — until we're confident the new path covers all callers.
- iPhone is primary target — evaluate all decisions against iPhone 16 constraints.
- 120-second MLX test timeout — never let a generation test run more than 2 minutes without aborting.
- API > asking the human — if you can't get an answer from the API, expand the API.
