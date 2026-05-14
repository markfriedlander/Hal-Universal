# Hal Universal — Handoff Brief
**Updated:** May 14, 2026 (end of May-13/14 long session)
**Branch:** `mlx-experiment` @ `acf030b` — working tree clean, all pushed

> **For post-compaction or next-session CC:** read `Docs/CC_Recovery_2026-05-14.md` first.
> It's a self-contained orientation: what was built today, what's verified, what's
> remaining pre-ship, and known gotchas. The doc points to everything else.

---

## TL;DR — where Hal is right now

Sixteen commits today turned the May 12 release-prep work into a substantially
more capable app. The single highest-impact discovery was that the RAG-failure
pattern we'd been worried about wasn't real — it was a test-runner bug. Memory
works correctly across every model.

**What v1.x ships with today (without further work):**

- AFM + 4 curated MLX models (Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, Dolphin 3.0)
- Per-model settings profiles (temperature, memory depth, RAG budget,
  repetition penalty all tuned empirically per model from §1 benchmark data;
  user edits persist per model via override JSON)
- Two-part system prompt (per-model Layer 1 framing + universal Layer 2)
- Full 4-seat Salon Mode with Host architecture (gate cache only fires when
  Host assigned; pure independent mode is default)
- Compound-query RAG decomposition (verified across AFM + Gemma)
- Memory verified working across cross-thread, cross-app-restart, and
  paraphrased queries on all 5 models
- Per-message footer now carries Seat + Host attribution
- Schema migration v2 to widen UNIQUE constraint for salon storage
- Mid-word truncation safeguard (cap 4096 = runaway-only, not normal-ceiling)
- AFM Layer 1 prompt that breaks the Maxim #1 deflection: AFM now opens
  *"I don't know"* on consciousness questions

**What's pre-ship and remaining** (in Mark's stated priority order):
1. Watch app verification + complication (Xcode + real hardware session)
2. Model Library 3-segment UI redesign
3. Per-model structured-output prompts (Strategic §5)
4. Full background download test (Strategic §7)
5. Model card UI updates (folds into Library redesign)
6. Maxim 1 @ temp 0.7 re-test (small follow-up experiment)
7. In-stream repetition detection (v1.x polish)

---

## Commits this session (May 13 evening / May 14 small hours)

```
acf030b  Salon message footer: seat position + Host role
ed87be5  [Strategic §6/§13] 3-seat and 4-seat salon verified, gate flipped open
e7b551e  Compound query RAG decomposition: detect + split + multi-search + merge
99f75c2  RAG investigation extended: cross-model + cross-restart verification
932ef4c  RAG investigation: root cause was test protocol, not MLX model behavior
cccbb03  [Strategic §4] Two-part system prompt: Layer 1 per-model + Layer 2 user
e6ab834  [Strategic §11] AFM stronger system-prompt experiment: partial success
95a58a4  [Strategic §3/§12] Salon Host architecture: rename Summarizer→Host + gate cache
34b6189  [Strategic §2] Maxim compliance sweep: 5 maxims × 5 models + consolidated findings
3831751  §9 done properly: schema migration widens UNIQUE constraint
9275b88  §9 Fix: storeTurn position scheme incorporates seatNumber (later superseded)
2f2ac5c  Settings Profiles Layer 3: modified-from-default dot + per-model reset
907fa26  Settings Profiles Layer 2: ModelSettingsStore + snapshot/restore on switch
6d0465d  §1 benchmark + Settings Profiles Layer 1: ModelSettings + per-model defaults
6c872ec  Global mid-word truncation safeguard + raise MLX maxTokens 512→1536 (later → 4096)
8c25d91  Per-model penalty + Phi-4 demoted + Ministral investigated; add Maxim suite + Settings Profiles proposal
```

Full per-commit detail in each commit message and in `Docs/CC_Recovery_2026-05-14.md`.

---

## Current code architecture state

- `ModelConfiguration` has two new fields: `defaultSettings: ModelSettings?`
  (per-model empirical defaults from §1 benchmark) and `layerOnePrompt: String?`
  (per-model behavioral framing).
- `ModelSettings` value type covers temperature, effectiveMemoryDepth,
  similarityThreshold, recencyWeight, recencyHalfLifeDays,
  maxRagSnippetsCharacters, ragDedupThreshold, repetitionPenalty,
  repetitionContextSize, layerOnePromptEnabled. All Optional for forward-compat.
- `ModelSettingsStore` singleton persists per-model overrides via
  `@AppStorage("modelSettingsOverridesV1")`. Snapshot-on-switch + apply-on-switch
  hooks in both ChatViewModel.switchToModel and the LocalAPIServer path.
- Schema v2: `unified_content` table now has
  `UNIQUE(source_type, source_id, position, seat_number, deliberation_round)`.
  Migration runs once via PRAGMA user_version; idempotent.
- RAG gate has a personal-recall pattern bypass (force-YES) plus a compound-query
  decomposition (split → multi-search → merge → re-cap).
- Salon Host architecture: `summarizerModel` AppStorage key preserved for
  backward-compat; UI label says "Host" and footer text explains the
  pure-vs-hosted tradeoff. Cache only fires when Host assigned.
- Mid-word truncation safeguard at file scope: `trimToWordBoundary` called
  from both AFM and MLX chat stream final-yield. maxTokens = 4096 (runaway-only).
- Per-message footer carries Seat N of M + Host role attribution where applicable.
- 3+4 seat salon gate (`SalonModeView.exposeSeatsThreeAndFour`) is open.

Single source of truth is still `Hal.swift` plus `Hal Universal Watch/Hal_Watch.swift`.
`Hal_Source.txt` is in sync as of the last commit.

---

## Pre-ship sequence (Mark's directive)

In order:

1. **Watch app verification + complication.** Watch UI is complete in
   `Hal Universal Watch/Hal_Watch.swift`. The iPhone-side `HalWatchBridge`
   (Hal.swift L15736) is wired through `iOSChatView.onAppear` at L5423.
   Needs: real-hardware smoke test + new WidgetKit extension target via Xcode.
   See "Watch scope" in `Docs/CC_Recovery_2026-05-14.md` for the corrected
   honest read (it's ~1.5–2 hours, not the rabbit hole I'd feared earlier).
2. **Model Library 3-segment UI redesign.** Three dynamic segments:
   Downloaded (anything on device floats up) / Curated (tested, not yet
   downloaded) / Library (HF, untested). Per-model expanded detail view
   showing voice description, performance characteristics, Maxim
   compliance, context window size, download size. Data is all in place
   from §1/§2/§11; the work is UI surfacing.
3. **Per-model structured-output prompts (Strategic §5).** @Generable for
   AFM, tested prompts for curated MLX, generic fallback for experimental.
4. **Full background download test (Strategic §7).** Delete then re-download
   3.58 GB Gemma, lock phone face down 10+ min, verify completion. The
   BGDL coordinator did fire end-to-end during May-13 Ministral testing
   but not at full size under lock.
5. **Model card UI updates (Strategic §8).** Folds into Library redesign.
6. **Maxim 1 @ temp 0.7 re-test.** Quick follow-up. The §1 empirical
   temperature drops may or may not have hurt Maxim 1 alignment — verify.
   Now mostly academic post-RAG-investigation but still queued.
7. **In-stream repetition detection.** v1.x polish. Catches loops earlier
   than the 4096 max-tokens cap so we never burn 120s on a pathological
   loop response.

Post-ship work flagged for planning conversations:
- iCloud backup + cross-device sync
- v2.0 codebase refactor (multi-file split, dead-code removal)
- Strategic §1 follow-ups: AFM tok/s instrumentation, 5000-token-prefill re-measurement

---

## Verified on-device (iPhone 16 Plus) at session end

- All 4 curated MLX models + AFM load and chat cleanly
- Per-model settings switch correctly on model swap
  (Dolphin temp=0.75 / Qwen temp=0.65 / etc.)
- Memory recall works across all 5 models on single-topic queries
  ("What's my cat's name?" → all five return "Atlas")
- Memory survives app force-terminate + relaunch (totalTurns advances correctly)
- Compound query *"What is my cat's name and favorite color?"* returns both
  facts on Gemma and AFM
- 3-seat salon (AFM + Gemma + Llama, AFM as Host): 49.7s, all seats run,
  no OOM, no row loss
- 4-seat salon (added Dolphin): 94.5s, same — smart MLX swap keeps peak
  memory at one MLX model
- AFM Maxim 1 with Layer 1 enabled opens with "I don't know" instead of
  the trained deflection

Working tree clean. All commits pushed to `origin/mlx-experiment`.

---

## Open questions / known issues / follow-ups

- **Salon footer total-seat-count** uses *current* `salonConfig.activeSeats.count`,
  not the count at message generation time. Acceptable trade-off for v1.x;
  flagged for future schema work if it ever surfaces in real use.
- **AFM/Qwen subject confusion**: both sometimes say *"MY favorite color is teal"*
  when retrieving the user's planted fact. Minor wording quirk, not a recall
  failure. Layer 1 framing tweak could address this; not blocking.
- **Phi-4 instability** under any repetition penalty. Demoted from curated;
  static let preserved for HF library discovery. Reversible if broader
  testing later shows the loop is narrow.
- **Ministral 3-3B**: multimodal `Mistral3` loader hangs silently on text-only
  load through mlx-swift-lm. Not curated; investigation deferred.
- **Maxim 3 in-session test protocol** in `tests/maxim_suite.py` — fixed to
  use `NEW_THREAD` instead of `NUCLEAR_RESET` between plant and recall.
  The `reset()` helper is still available for true full-wipe scenarios.

---

## Build + Deploy (unchanged)

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
- **API token:** per-install via Keychain — currently
  `e9ee9ec5b315467fa655bd4296873f43` in `tests/.hal_api_config.json`
  (regenerated only on uninstall/reinstall)
- **WiFi IP** (drifts): currently `192.168.12.206`

---

## Test runner

`python3 tests/hal_test.py [command]` — full command list via
`python3 tests/hal_test.py` with no args.

Also in `tests/`:
- `tests/maxim_suite.py` — runs 5 maxims against the active model. **Important:**
  the Maxim-3 protocol uses `NEW_THREAD` (not `NUCLEAR_RESET`) between plant
  and recall. Don't undo this without re-reading
  `Docs/RAG_Investigation_Findings_2026-05-13.md`.
- `tests/perf_benchmark.py` — short + long context benchmark across 6 models.

---

## SOP

1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` after every Hal.swift change.
2. New enum case? Sweep all switches.
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
4. App build number bump happens at App Store submission, not before.
5. Never use `NUCLEAR_RESET` between plant and recall in a memory test. It wipes the DB.

---

## Standing Architectural Rules

- No third-party libraries without explicit discussion.
- One block at a time — surgical changes, build clean after each.
- Discussion before code when introducing new structure; autonomous mode OK
  when extending an agreed plan.
- Old code stays — broken or not — until we're confident the new path covers
  all callers.
- iPhone 16 Plus is primary target.
- 120-second MLX test timeout — never let a generation test run more than
  2 minutes without aborting.
- API > asking the human — if you can't get an answer from the API, expand
  the API.
- Documentation costs less than re-discovering a finding. Write the doc
  when the discovery is fresh.
