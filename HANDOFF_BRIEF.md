# Hal Universal — Handoff Brief
**Updated:** May 16, 2026 (night session)
**Branch:** `main` @ `b26ae8c` — uncommitted changes pending (see "Working tree" below)

> **For post-compaction or next-session CC:** read this brief for current state, then
> `NEXT.md` for what's planned, then `HISTORY.md` for how we got here, then `CLAUDE.md`
> for standing rules. Detail on any specific architectural decision lives in HISTORY's
> dated session entry for that decision.

---

## TL;DR — where Hal is right now

The first App Store v2.0 archive was uploaded earlier today (May 16 day session). Two ship-blockers
surfaced in the night session that prevent submitting that build:

1. **SPM resolver downgrade bug** — fixed in `b26ae8c`. swift-transformers is now pinned to
   exactVersion 1.3.2 in `project.pbxproj` so Xcode can't downgrade it to 1.0.0 (which loses
   the `HuggingFace` transitive module) when destinations switch.
2. **Salon "enabled with 0 seats" silent-no-op bug** — proper fix landed in `b26ae8c`. The bad
   state is now unreachable via API and UI: enabling Salon with no seats auto-populates Seat 1
   with Apple Intelligence; clearing the last seat auto-disables Salon; NUCLEAR_RESET clears
   Salon to defaults.

A third issue surfaced and is **mid-investigation** — Mark's directive landed late night and
some code is uncommitted:

3. **Self-knowledge compression behavior on AFM is wrong.** Findings reported, fix not yet
   landed. See "Active directive" below.

---

## Working tree — uncommitted as of this brief

```
modified:   Hal Universal.xcodeproj/project.pbxproj          # build bump 4→5
modified:   Hal Universal/Hal.swift                          # chunked compression + halving (TO REVERT)
modified:   Hal Universal/Hal_Source.txt                     # synced to Hal.swift
```

- **Build bump 4→5** in pbxproj is intentional and stays. The next archive will be build 5.
- **Chunked compression + empirical halving in Hal.swift** was built tonight and is **to be
  reverted** per Mark's directive (see "Active directive"). It's the wrong solution to the wrong
  problem. The decision was that self-knowledge compression-at-read-time should not exist at all
  for the self-knowledge segment — AFM skips injection entirely, MLX injects raw.

---

## Active directive (Mark, 2026-05-16 night)

Mark has issued a directive on self-knowledge behavior: AFM gets no injection,
MLX injects raw without compression, write-time synthesis keeps the corpus
lean. Implementation has not started.

- **Reasoning + full context:** `HISTORY.md` (2026-05-16 entry, "Self-knowledge:
  a deeper rethink").
- **Concrete next steps:** `NEXT.md` ("Active directive" section).

Implementation is on hold pending Strategic Claude's path-forward plan
based on tonight's audit.

---

## Commits since the May 14 brief

Between the May 14 brief and tonight, there were ~15 commits on May 15 (per-model Layer 1
prompts, structured-output prompts, Maxim re-tests at 0.7, performance benchmark follow-ups,
salon self-knowledge architecture work) and several today (May 16) for the App Store push:

```
b26ae8c  Ship blockers: Salon empty-seats safety net + swift-transformers exact pin
eeb7dbc  Watch + Complication: stop embedding in iOS app for v2.0
871564c  Disk-space refusal: surface message via halLog + MODEL_STATUS API
d9ea6a0  Pre-flight disk-space check before model downloads
0e04ac1  Release prep: v2.0/4 bump, README rewrite, privacy/support HTML, ASC paste-ready
55e80b3  Warnings cleanup: 60 → 0 in Hal.swift; CLAUDE.md adds warnings-as-errors SOP
[... earlier May 15/14 commits captured in their session reports under Docs/CC_Recovery_*.md]
```

Full per-commit detail in `git log`.

---

## Branch state

- `main` is the philosophical Hal (full MLX + AFM). HEAD = `b26ae8c`.
- `hal-lmc-stripped` preserves the v1.x LMC variant — kept on origin for reference, not actively
  developed. The May 16 day session merged the long-running `mlx-experiment` branch into `main`
  via force-push with lease (Option B).
- `mlx-experiment` still exists; superseded by `main`.

---

## Salon state machine — current invariant

Per the night-session fix:

- `salonConfig.isEnabled == true` ⟹ `salonConfig.activeSeats.count >= 1` (invariant)
- All mutations route through `ChatViewModel.setSalonEnabled(_:)` or `setSalonSeat(position:modelID:)`
- Enabling Salon with 0 seats: auto-populates Seat 1 with `apple-foundation-models` (AFM is
  always available, no download required)
- Clearing the last seat while Salon is on: auto-disables Salon
- `NUCLEAR_RESET` clears `salonConfig` back to defaults (`isEnabled = false`, all seats nil)
- Defense in depth: the `/chat` routing path also guards (`isEnabled && !activeSeats.isEmpty`),
  with a HALDEBUG log if it ever fires (it shouldn't, but it's a safety net)

API surface unchanged (`SALON_GET_STATE`, `SALON_SET_ENABLED:true|false`, `SALON_SET_SEAT:N:<id-or-empty>`,
`SALON_SET_MODE:<mode>`, `SALON_SET_SUMMARIZER:<id-or-empty>`) but `SALON_SET_ENABLED` now returns
`autoPopulatedSeat1WithID` and `SALON_SET_SEAT` returns `autoDisabledSalon`.

---

## Compression infrastructure (current uncommitted state — slated for revert/refactor)

Tonight's work added to `TextSummarizer`:
- `SummarizationResult` struct with `text` + `didTruncate` flag
- `summarizeWithVerificationDetailed(...)` — chunked summarization with sentence-bounded chunks
  and empirical halving on overflow
- `safeMaxInputTokensPerCall(contextWindow:outputReserve:)` — conservative size estimate
- `chunkTextBySentences(...)` and `hardSplitByCharacters(...)` — chunking primitives
- `singleCallSummarize(...)` / `singleCallSummarizeOnce(...)` — leaf calls with overflow detection
- `isContextOverflowError(_:)` — error string match for AFM's overflow signal
- `SegmentCompressor.compress` updated to honor `didTruncate` in the footer label

This entire chunked-compression apparatus is the wrong solution per Mark's directive. The right
solution is to not compress self-knowledge at all (AFM skips, MLX injects raw). The
`SummarizationResult.didTruncate` mechanism may still be useful for `autoSummary` and
`shortTermHistory` segments which legitimately need compression — that's a separate decision.

---

## Pre-archive checklist

Forward-looking content moved to `NEXT.md`.

---

## Verified on-device (iPhone 16 Plus) at this brief

- swift-transformers SPM pin resolves cleanly; 15 packages at expected versions
- `BUILD SUCCEEDED` from CLI for both `generic/platform=iOS` and the iPhone UDID, zero warnings
- Salon state-machine: empty-seats enable → auto-populates Seat 1; clear-last-seat → auto-disables;
  intermediate-seat clear preserves enabled state (verified via API)
- NUCLEAR_RESET clears Salon back to defaults (verified via API)
- Chunked compression IS firing on AFM stress test (but per directive, this is the wrong path
  and is being reverted)

---

## Known gotchas

- **AFM's effective input window is smaller than its nominal 4096.** Empirically calls with
  input + boilerplate + output totaling ~2.5K tokens still hit "Exceeded model context window
  size." This is why the chunked-compression approach is unviable for self-knowledge — even
  small chunks overflow. The directive (no self-knowledge on AFM) sidesteps this entirely.
- **Lorem Ipsum stress data tokenizes worse than English.** ~1.4× our chars/4 heuristic for
  Latin-heavy text. Real user content is closer to estimate.
- **`MEMORY_INJECT_TEST` synthetic entries bypass write-time synthesis** because they use unique
  keys (`synthetic_1`...`synthetic_N`). Useful for stress-testing the compressor; NOT useful for
  testing the write-time synthesis system (which needs SIMILAR reflections, not unique keyed
  traits).
- **Structured traits have no semantic synthesis** — only key-based upsert. AI is prompted to
  choose consistent keys but enforcement is at the AI judgment layer, not the DB. Whether this
  needs DB-level dedup is an open question.

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

- **iPhone 16 Plus device ID:** `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
- **Bundle ID:** `com.MarkFriedlander.Hal-Universal`
- **API port:** 8766 (Posey holds 8765)
- **API token:** per-install via Keychain — currently `e9ee9ec5b315467fa655bd4296873f43` in
  `tests/.hal_api_config.json` (regenerated only on uninstall/reinstall)
- **API host (current):** `marks-bigger-ass-fon-16.local`
- **WiFi IP** (drifts): currently `192.168.12.206`
- **iPhone 17 Pro simulator (Mac dev):** UDID `7D4E1F1A-E7EC-4C42-BDF1-BF3BC72F4352`

### CLI build avoids SPM destination-switch hazard

The May 16 SPM bug only fires when Xcode UI switches destinations. CLI `xcodebuild build` does
not re-resolve packages and is safe. The exact-pin on swift-transformers should prevent the bug
from ever recurring, but the principle holds: if Mark needs to switch destinations in the IDE,
he can; the pin protects him.

---

## Test runner — `tests/hal_test.py`

```bash
python3 tests/hal_test.py state
python3 tests/hal_test.py turn "Hi"
python3 tests/hal_test.py switch_model "mlx-community/gemma-4-e2b-it-4bit"
python3 tests/hal_test.py ui_state
python3 tests/hal_test.py rendered_messages
python3 tests/hal_test.py logs [N]
python3 tests/hal_test.py reset
python3 tests/hal_test.py cmd "SALON_GET_STATE"
python3 tests/hal_test.py cmd "MEMORY_INJECT_TEST:<count>:<tokens-each>:<category>"
python3 tests/hal_test.py cmd "RESET_SELF_KNOWLEDGE"
```

Also in `tests/`:
- `tests/maxim_suite.py` — runs 5 maxims against the active model. **Important:**
  the Maxim-3 protocol uses `NEW_THREAD` (not `NUCLEAR_RESET`) between plant and recall.
- `tests/perf_benchmark.py` — short + long context benchmark across 6 models.

Config in `tests/.hal_api_config.json`.

---

## SOP

1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` after every Hal.swift change.
2. New enum case? Sweep all switches.
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
4. App build number bump happens at App Store submission (currently staged at 5, uncommitted).
5. Never use `NUCLEAR_RESET` between plant and recall in a memory test. It wipes the DB.
6. **Update HANDOFF_BRIEF.md and MEMORY.md as work lands, not at session end** (CLAUDE.md
   Golden Rule #8).

---

## Standing Architectural Rules

- No third-party libraries without explicit discussion.
- One block at a time — surgical changes, build clean after each.
- Discussion before code when introducing new structure; autonomous mode OK when extending an
  agreed plan.
- Old code stays — broken or not — until we're confident the new path covers all callers.
- iPhone 16 Plus is primary target.
- 120-second MLX test timeout — never let a generation test run more than 2 minutes without
  aborting.
- API > asking the human — if you can't get an answer from the API, expand the API.
- Documentation costs less than re-discovering a finding. Write the doc when the discovery is
  fresh.
- Warnings are errors (CLAUDE.md Golden Rule #7).
- Docs stay current as work lands (CLAUDE.md Golden Rule #8).

---

## Reference docs

| Doc | What it covers |
|---|---|
| `CLAUDE.md` | Operational reference, Golden Rules, project orientation |
| `HAL_CC_BRIEFING.md` | Narrative onboarding (read once deeply) |
| `Docs/Hal_Ethical_Maxims.md` | The five values governing all decisions |
| `Docs/Hal_Persistent_Memory_Architecture.md` | Memory system design |
| `Docs/Hal_2_0_Master_Development_Plan.md` | Full feature specs |
| `Docs/Salon_Self_Knowledge_Architecture_2026-05-15.md` | Salon + self-knowledge design |
| `Docs/Context_Budget_Implementation_Plan_2026-05-16.md` | Context budgeting (note: chunked compression is being reverted per the night directive — see "Active directive" above) |
| `Docs/ASC_v2.0_Paste_Ready.md` | App Store Connect metadata paste-ready |
