# Hal Universal — Handoff Brief
**Updated:** May 12, 2026 — Salon Mode revived, RAG perf overhaul, privacy promise restored
**Branch:** mlx-experiment

---

## v1.x Status — Salon Mode is back and actually working

The Salon Mode that's been the project's flagship vision for years now works end-to-end with AFM + Gemma running as two seats in the same Hal-turn. Independent mode, Context-Aware mode, and the summarizer/moderator all verified on iPhone 16 Plus. Per-message attribution by model is correct. The maxims about "Hal speaking through different processors" are real on screen, not aspirational.

This session also fixed a stack of bugs that were either gating release or silently degrading the experience.

### What landed this session (May 12)

| Commit | What |
|---|---|
| `6359bef` | Fix Gemma load (catalog isDownloaded was stale from cold seed), RAG `maxResults` honored (4s saved per turn), RAG gate routes through selected model (privacy + 3.4s saved), doc-summary AFM guard removed (Finding #3), salon upgrade hazard fixed (different approach, no sendMessage regression), AFM duplicate catalog entry fixed, Privacy Manifest added, CLAUDE.md min iOS → 26 |
| `cca7ebb` | Show generating-model name next to spinner+timer in the partial chat footer (Maxim #2 transparency win) |
| `72c64d7` | **Salon Mode revival** — seat-switch now actually calls `setupLLM` (was a silent no-op), `keepMlxResident` flag keeps Gemma warm across mixed-source seats, `selectedModelID` saved/restored around the multi-seat turn, salon UI re-exposed, full salon API surface (`SALON_*` commands) added for external testing |

### Measured perf improvement on iPhone 16 Plus (memory-needing turn)

| Phase | Before | After |
|---|---|---|
| RAG gate | 4.7s (AFM regardless of mode) | 1.3s (selected model — Gemma is actually faster) |
| Memory search | 1.2s (no cap) | 0.5s (capped at 10 snippets) |
| LLM prefill | 7.4s (5945 prompt tokens) | 3.5s (2719 prompt tokens) |
| LLM generation | 2.1s | 2.0s |
| **Total turn** | **20.5s** | **12.2s** |

40% faster end-to-end. Simple non-memory turns went from ~14s to ~5s.

### Verified live on iPhone 16 Plus (May 12)

- **Gemma load** is reliable from cold launch and across AFM↔Gemma switching (was silently failing because `setupLLM` trusted the catalog's stale `isDownloaded` flag from the cold seed; now resolves disk reality directly + catalog refreshes at init)
- **Gemma generation:** 35.1 tok/s (was assumed 33; AFM is ~43 — closer than I'd assumed)
- **Per-turn perf:** 20.5s → 12.2s on memory-needing turn (40% faster)
- **RAG gate routes through selected model** — privacy promise restored AND faster in Gemma mode (Gemma prefill ~800 tok/s vs AFM ~138 tok/s for the gate prompt)
- **Salon Mode independent:** AFM seat 1 + Gemma seat 2 both generate, correctly attributed
- **Salon Mode context-aware:** Gemma seat 2 references seat 1's AFM response ("as we've discussed")
- **Salon Mode summarizer:** AFM moderator emits "📋 Summary: …" integrating both seats
- **Partial-state footer** shows `Processing... [timer] • [model name]` so the user sees which engine is generating in real time

### Diagnostic surface added

- `MLX_STATE` — full snapshot of wrapper state + catalog + disk for the currently selected model
- `SALON_GET_STATE` / `SALON_SET_ENABLED` / `SALON_SET_SEAT:<1-4>:<modelID|empty>` / `SALON_SET_MODE:<independent|contextAware>` / `SALON_SET_SUMMARIZER:<modelID|empty>`
- Promoted many `print()` calls in MLX setup/load, RAG gate, tool router, memory search, and salon orchestration to `halLog` so they're queryable via `GET_LOGS` (was previously stdout-only and invisible to the API)

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
