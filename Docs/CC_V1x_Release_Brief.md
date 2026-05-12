# CC Handoff Brief — Hal v1.x Release Prep
**From:** Strategic Claude  
**For:** CC (Claude Code)  
**Context:** Mark is leaving with his phone for ~12 hours. All work in this session should be completable on the Mac using the simulator or Designed-for-iPad mode. Phone is needed only for final hardware validation when Mark returns.

---

## The Goal

Get a clean, stable, shippable version of Hal into the App Store as soon as possible. Existing users are on a version that isn't functioning well. That's the priority. This is not a feature release — it's a fix-and-stabilize release with one meaningful addition: Gemma 4 E2B as a working alternative to AFM.

Everything else — Salon Mode, the proposals system, soul document deepening, stress testing, additional models, the full refactor — comes after this ships. Do not scope-creep into any of those areas during this session.

---

## What To Do

### 1. Simplify the Model Selection UI

Do not rip out the model download infrastructure. It's working, it's tested, and we want it to stay intact so we can expand later with a simple UI change. What we're doing is controlling what the user sees, not what the system supports.

The user should see exactly two choices:

- **Apple Intelligence** — the current AFM path, always available, no download required
- **Gemma 4 E2B** — fully private, on-device, requires a one-time download

Everything else in the model catalog should be hidden from the user-facing UI. The underlying catalog, downloader, and model management infrastructure stays exactly as-is. This should be a UI filter, not an architectural change.

The Gemma option in the UI needs to surface clearly:
- Download size (3.58GB — be honest about this)
- Download progress when in progress
- Clear status: not downloaded / downloading / ready
- What Hal does while downloading (falls back to AFM, keep it working)
- A note that this requires WiFi recommended

The toggle between the two should be simple and obvious. A human should be able to understand their choice in one sentence.

### 2. Hide Salon Mode

Remove Salon Mode from the user-facing UI entirely. Do not delete the underlying code — preserve it per the standing "broken-but-precious" instruction. Just make sure no user can navigate to it in this release. A simple conditional or feature flag is fine.

### 3. Resolve Known Bugs From the Recent Session

These were identified and some were fixed during CC's last session. Verify each is resolved and stable:

- Hal misreporting himself as "Apple Intelligence" while running Gemma (catalog-fallback display bug)
- Invisible text after reload caused by `screenWidth` returning 0 during view-tree rebuilds on cold launch
- Any remaining dead code from the old prompt path that could cause confusion — tag it clearly but do not delete it
- Confirm the unified AFM + MLX prompt path is clean with no remaining callers of the old API

### 4. Update the App Icon

Mark has approved a new icon direction. Here is the specification:

**Visual language:** Dark background, single centered red-orange orb, soft radial glow diffusing outward, two concentric soft silver rings at different radii, centered yellowish pupil highlight on the orb. No mechanical bezel, no hard edges, no literal HAL 9000 hardware reference. Abstract and luminous, consistent with the visual family of Mark's other apps (Reflect, Pure Phase).

**Specific details:**
- Background: very deep dark, near black with a very subtle warm tint (#141010 → #040202 radial)
- Outer glow: deep red-amber, soft and wide (#AA2000 at 32% opacity fading to transparent)
- Orb: red-orange, centered, flat (not highly specular), approximately the same size relative to the icon as the current version (#EE4422 → #CC1800 → #770800 radial, centered gradient)
- Pupil highlight: soft yellowish bloom centered on the orb, fading outward (#FFE8A0 at 85% → #FFCC66 at 45% → #FFAA44 at 0%, approximately 24px radius at icon scale)
- Inner ring: soft silver-grey, low opacity, sitting close to the orb (~92px radius at 340px center, stroke 1.4px, opacity 13%)
- Outer ring: softer silver-grey, even lower opacity (~116px radius at 340px center, stroke 0.8px, opacity 8%)
- Corner radius: standard iOS icon rounding

The icon should feel like it belongs in the same family as Reflect (dark, single glowing orb, minimal) and Pure Phase (dark, centered warm light source) without being identical to either. The red color and the eye quality of the centered pupil are what make it distinctly Hal.

Produce the icon at all required iOS sizes. If you use the SVG as a source, render it at 1024x1024 for the App Store and let Xcode handle the scaling for other sizes via the asset catalog.

### 5. Verify Build Stability

Before Mark returns with the phone:
- Clean build on Mac, no warnings that weren't already present
- Run in simulator: both model paths reachable in UI, download flow visible and correct, Salon Mode not reachable
- Run in Designed-for-iPad mode on Mac if possible: verify layout holds, no broken buttons (this was a known issue historically)
- Confirm the API is still fully functional — all commands from the complete list still respond correctly

---

## What NOT To Do In This Session

- Do not refactor the codebase. That is a separate dedicated effort after this release ships.
- Do not add any new features.
- Do not investigate additional models beyond AFM and Gemma 4 E2B.
- Do not touch Salon Mode code beyond hiding it from the UI.
- Do not re-expose the Hugging Face model browser.
- Do not delete any code — tag and preserve everything.

---

## When Mark Returns

He'll have the phone. At that point the session becomes hardware validation:
- Confirm Gemma loads and runs at expected token rate on iPhone 16 Plus
- Run a meaningful conversation through the full Hal pipeline
- Confirm memory persists correctly across sessions
- Confirm the new icon looks right at actual device scale
- If all of that passes, prepare for App Store submission

---

## Context on the Broader Plan (So You Have the Full Picture)

This v1.x release is step one of three:

**v1.x (this session):** Fix, stabilize, ship. AFM + Gemma only. Clean UI. Working Hal.

**v2.0 (after ship):** Full codebase refactor. Multiple files, proper commenting, dead code removed, architecture cleaned up. No new features during this phase.

**v2.x (after refactor):** Stress testing at volume, additional model evaluation, soul document deepening, proposals system, Salon Mode evaluation.

The philosophical Hal vision is now technically feasible on iPhone hardware — Gemma 4 E2B at 33 tok/s answered a consciousness question correctly invoking Maxim #1. That's real. The job now is to get a stable version of that into users' hands.

---

## One Standing Instruction

Mark's correction from your last session stands as a general principle: if you need information and can't get it from the API, that's a signal the API is incomplete — expand it rather than asking Mark to be your eyes. Use GET_LOGS, GET_UI_STATE, GET_RENDERED_MESSAGES, and the full command set you built. If something is missing, add it.

Good luck. This is a meaningful release.
