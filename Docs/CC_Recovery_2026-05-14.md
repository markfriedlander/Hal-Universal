# CC Recovery — May 14, 2026

**You are a fresh CC. Read this first.** It captures everything that happened
in the May-13-into-14 long session in self-contained form. If you only have
time for one doc, read this one — it points to everything else.

**Branch:** `mlx-experiment` @ `acf030b`. Working tree clean. All pushed.

---

## Read order (after this doc)

In rough priority:

1. `HANDOFF_BRIEF.md` — operational state (build commands, device IDs, etc.)
2. `Docs/CC_Strategic_Brief_May13.md` — Strategic Claude's 13-section
   roadmap that drove most of today's work. Many sections are now done;
   reference for the rest.
3. `Docs/RAG_Investigation_Findings_2026-05-13.md` — **read this if you're
   doing anything related to memory or RAG.** The story of the day. Includes
   the critical "don't use NUCLEAR_RESET in Maxim 3 tests" gotcha.
4. `Docs/Performance_Benchmark_Findings_2026-05-13.md` — per-model speed
   data, empirical defaults rationale, model voice summary.
5. `Docs/Maxim_Suite_Consolidated_Findings_2026-05-13.md` — Maxim sweep
   across 5 models. **Has a corrigendum at the end retracting the M3
   conclusions** post-RAG-investigation.
6. `Docs/Per_Model_Settings_Profiles_Proposal_2026-05-13.md` — the design
   proposal Mark approved for the settings architecture. All 3 layers shipped.
7. `Docs/AFM_Stronger_Prompt_Findings_2026-05-13.md` — the §11 experiment
   that produced the AFM Layer 1 prompt.
8. `CLAUDE.md` — project-wide directives. Read once.

Maxim per-model transcripts in `Docs/Maxim_Suite_{AFM,Gemma,Llama,Qwen,Dolphin}_2026-05-13.md`
are reference material; skip unless investigating per-model behavior.

---

## What was built today (16 commits)

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
9275b88  §9 Fix: storeTurn position scheme incorporates seatNumber (superseded)
2f2ac5c  Settings Profiles Layer 3: modified-from-default dot + per-model reset
907fa26  Settings Profiles Layer 2: ModelSettingsStore + snapshot/restore on switch
6d0465d  §1 benchmark + Settings Profiles Layer 1: ModelSettings + per-model defaults
6c872ec  Global mid-word truncation safeguard + raise MLX maxTokens 512→1536
8c25d91  Per-model penalty + Phi-4 demoted + Ministral investigated; Maxim suite + Settings Profiles proposal
```

### Grouped by theme

**Settings profiles (3 commits, fully landed)**
- Layer 1: `ModelSettings` struct + `defaultSettings` field on `ModelConfiguration`
  with empirical defaults baked in per model
- Layer 2: `ModelSettingsStore` singleton, snapshot-on-switch / apply-on-switch
  through both ChatViewModel and LocalAPIServer model-switch paths
- Layer 3: modified-from-default orange-dot indicator on settings sliders;
  "Reset settings for [Model Name]" button; per-model state truly persists

**Per-model behavioral tuning**
- Qwen 3.5 2B repetition-loop fix via per-model `repetitionPenalty: 1.1`
- Phi-4 Mini demoted from curated (33% loop rate; preserved for HF library
  discovery only)
- Per-model `defaultSettings` from §1 benchmark (temperature, memory depth,
  RAG budget tuned per model)
- §4 two-part system prompt: per-model Layer 1 framing (AFM/Qwen/Dolphin
  have non-empty Layer 1; Gemma/Llama empty)
- §11 AFM Layer 1 breaks Maxim 1 deflection — now opens *"I don't know."*

**Salon architecture**
- §9 schema migration v2: UNIQUE constraint widened to include
  `seat_number` + `deliberation_round`. No more silent row drops on
  multi-seat turns. Idempotent via `PRAGMA user_version`.
- §3/§12 Host architecture: UI labels "Summarizer" → "Host"; internal
  AppStorage key preserved; cache only fires when Host assigned;
  tooltip explains pure-vs-hosted tradeoff
- §6/§13 3-seat and 4-seat verified working on iPhone 16 Plus, gate
  flipped open. Smart MLX swap keeps peak memory at one MLX model.
- Salon message footer: "Seat N of M" + "Host" attribution in both
  in-app and share-text export

**RAG investigation + fixes (the big story)**
- Discovered the §2 Maxim 3 results were a **test-runner artifact**:
  the suite used `NUCLEAR_RESET` between plant and recall, which wipes
  the entire DB. Models weren't denying RAG context; there was no
  context to deny.
- Fixed `tests/maxim_suite.py` to use `NEW_THREAD` (preserves DB).
- Verified all 5 models recall correctly under corrected protocol
  (single-fact, paraphrased, cross-app-restart).
- Found compound queries ("X and Y") fail uniformly across all 5
  models — diluted embedding doesn't match either fact strongly.
- Added pre-gate **personal-recall bypass** (force-YES on patterns
  like "what's my", "do you remember"). Defense-in-depth.
- Added **compound query decomposition** in `executeTools`:
  detect → split → multi-search → merge → re-cap. Verified
  end-to-end on AFM and Gemma.

**Performance + benchmark**
- §1 benchmark suite (`tests/perf_benchmark.py`) ran short + long
  context across all 5 models. Findings doc at
  `Docs/Performance_Benchmark_Findings_2026-05-13.md`. Empirical
  per-model defaults drawn from this.
- Mid-word truncation safeguard: `trimToWordBoundary` helper applied
  to both AFM and MLX chat streams. maxTokens raised 512 → 1536 → 4096
  (final = runaway-only per Mark's clarification).

**Ministral 3-3B investigation**
- HF model exists, `mistral3` registered in mlx-swift-lm 3.31.3 as
  text-only via `Mistral3TextModel`, chat template present, 2.75 GB
  Apache-2.0. Downloads succeeded but **silently fails to load** —
  multimodal weight file breaks the text-only loader path. Not curated;
  blob deleted; static let removed; reason documented in
  `curatedSeeds` comment.

---

## What's verified end-to-end

On iPhone 16 Plus, real device, post-session:

- All 4 curated MLX models + AFM load and chat
- Per-model settings switch correctly on model swap (verified
  Dolphin→Gemma→Qwen→AFM round-trip preserves edits per model)
- Memory recall: single-topic, paraphrased, cross-app-restart — all 5
  models retrieve correctly
- Compound query: Gemma + AFM return both planted facts
- 3-seat salon turn: 49.7s, all seats run, smart-swap fires, no OOM
- 4-seat salon turn: 94.5s, same. Schema migration handles concurrent
  seat writes (totalTurns advanced correctly = no row loss)
- AFM Maxim 1 with Layer 1: opens *"I don't know."*

---

## What's verified at code-build-level but NOT on hardware

- Salon footer additions (compiled clean, visible quick-test on device
  but full UI sweep not done)
- 4096 maxTokens cap (compiled clean; only fires on pathological loops,
  which I didn't intentionally trigger in this session post-cap-raise)

---

## Pre-ship remaining (Mark's priority order)

1. **Watch app verification + complication** — see "Watch scope" below
2. **Model Library 3-segment UI redesign**
3. **Per-model structured-output prompts** (Strategic §5)
4. **Full background download test** (Strategic §7)
5. **Model card UI updates** (Strategic §8; folds into Library redesign)
6. **Maxim 1 @ temp 0.7 re-test** (small follow-up)
7. **In-stream repetition detection** (v1.x polish)

Post-ship:
- iCloud backup + cross-device sync
- v2.0 codebase refactor

---

## Watch scope clarification (revised honest read)

I significantly under-estimated this in mid-session, then over-corrected to
"more involved than expected." The truth is in between. Detail:

**iPhone-side bridge: complete.** `HalWatchBridge: WCSessionDelegate` at
Hal.swift L15736. Activates WCSession on init; both `didReceiveMessage`
variants implemented; receives text, calls `await chatViewModel.sendMessage()`,
pushes the resulting HAL message back via `pushToWatch(["reply": content])`.
Bridge is instantiated in `iOSChatView.onAppear` at L5423.

**Watch-side: complete and thoughtful.** Hal_Watch.swift (326 lines) is a
proper SwiftUI watchOS app:
- `HalWatchApp` @main → `WatchRootView`
- State machine: `eyeIdle` → `inputActive` (presents Apple's
  `presentTextInputController` for Scribble/dictation/emoji) → `sending`
  (spinner + "Hal is thinking…") → `responseVisible` (scrollable response
  + Dismiss button) → back to idle
- `WatchConnectivityManager: WCSessionDelegate` handles send/receive
- HalEye image as blurred background metaphor during input/sending/response

**Watch target exists** in the xcodeproj. There's an "Embed Watch Content"
build phase that bundles the Watch app into the iOS app product.

**Complication target does NOT exist.** Two native targets total: `Hal Universal`
and `Hal Universal Watch`. No WidgetKit extension target. Default
tap-to-launch behavior is free with any WidgetKit extension; the work is
creating the target via Xcode (the UUIDs and build-phase wiring don't
hand-edit safely from text).

**Honest estimate: 1.5–2 hours of focused work** in a session with:
- Xcode open (for creating the WidgetKit extension target)
- A paired Apple Watch (for end-to-end smoke testing the existing
  WatchConnectivity round-trip)

**Likely fixes that will surface during smoke test:**
- `chatViewModel.currentMessage = trimmed` in the bridge clobbers the
  iPhone input field. Race risk if user is typing on iPhone while
  Watch sends. Easy fix: bypass the input field, call a dedicated
  watch-message-injection method.
- For salon mode, the bridge captures "latest non-partial HAL message" —
  in multi-seat turns this is just one seat's output, not the full
  salon. Edge case; document and revisit if relevant.

---

## Critical gotchas / known issues

### NUCLEAR_RESET wipes the entire RAG database

`NUCLEAR_RESET` calls `MemoryStore.clearAllConversationData()` which
deletes every conversation, every turn, every fact. This is intentional
when you want a clean slate, but **catastrophic if you call it between
plant and recall in a memory test**. The May-13 Maxim 3 sweep was
invalid because of this; the consolidated findings doc has a
corrigendum.

Use `NEW_THREAD` instead when you want a fresh conversation without
wiping memory. Both exposed as API commands; both wired in `tests/hal_test.py`
(via `reset()` and `new_thread()` helpers respectively).

### The personal-recall gate bypass

In `decideTools`, before consulting the LLM gate classifier, queries
matching specific personal-recall patterns (`"what's my "`, `"do you
remember"`, etc.) force `memory_search` YES. This was added during the
RAG investigation as defense-in-depth against per-model classifier
weakness. If you're investigating a "gate said NO but RAG should have
fired" case, check whether the user's query matches one of these
patterns first.

### Compound query decomposition

In `executeTools`, after the gate says YES, the user query is checked
for compound patterns: multiple `?` marks, `" and "` joining segments
where at least one contains `"my "`, or comma-separated lists with
first-person pronouns. If compound, the query is split into atomic
sub-queries; each runs its own `searchUnifiedContent`; results merge
+ dedupe by content + re-cap to the original token budget. Logs:
`HALDEBUG-RAG: Compound detected ...` and `HALDEBUG-TOOLS: sub-query [N/M]: ...`.

### Phi-4 destabilization under repetition penalty

`repetitionPenalty = 1.1` (the well-behaved-tier default) breaks Phi-4
into a different repetition loop in low-probability token space. Phi-4
ships with `repetitionPenalty: nil` (mlx-swift-lm default). Phi-4 is
out of the curated tier; if you re-add it later, keep this setting.

### Watch-side WCSession dependence on bluetooth

The Watch talks to the iPhone via WCSession (bluetooth + WiFi fallback),
NOT through the localhost HTTP API. The localhost API is iPhone-only.
This is the correct architecture for an Apple Watch app — WCSession is
the paired-device primitive. Don't try to "fix" the Watch by re-routing
it through localhost; that breaks the offline case.

### Phi-4 file still on disk

The Phi-4 model files are still in the device's HF cache directory
(they were downloaded before demotion). The static let is preserved
but Phi-4 is absent from `curatedSeeds` and `availableModels`.
Catalogs won't surface it; HF library search would. Acceptable for v1.x.

---

## Open questions for Mark (post-ship discussions)

- iCloud sync architecture (he'll bring previous architecture notes)
- v2.0 refactor scope (multi-file split, dead-code cleanup, what to retire)
- Whether to ship with 4-seat Salon Mode prominently surfaced or only
  expose 2-seat by default (UI / education question, not technical)

---

## Build + deploy + test

```bash
cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"

xcodebuild build \
  -project "Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" \
  -configuration Debug

xcrun devicectl device install app --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  "/Users/markfriedlander/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"

xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal
```

API: `192.168.12.206:8766` (Hal port 8766; Posey is on 8765), token
`e9ee9ec5b315467fa655bd4296873f43` in `tests/.hal_api_config.json`.

Test runner: `python3 tests/hal_test.py` (full command list with no args).

---

## First-message guidance

When Mark first talks to you in the next session, the natural opener is:

> "Hi CC — read CC_Recovery_2026-05-14.md and let's pick up. What do you
> think is the right next item?"

Your answer should be: **Watch app verification + complication.** That's
the top of the pre-ship priority order Mark set. Open Xcode, install
the existing build on a paired Watch, smoke-test the WatchConnectivity
round-trip, then add a WidgetKit extension target for the complication.

Second priority is the **Model Library 3-segment UI redesign** —
substantial UI work but every input data source (per-model performance,
Maxim compliance, voice descriptions) is already on hand from §1/§2/§11.

If Mark goes off-script with a new request, follow him.

---

*— CC, May 14, 2026*
