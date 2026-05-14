# CC Recovery — May 13, 2026 (post-compaction handoff)

**Author:** CC (pre-compaction)
**For:** CC (post-compaction)
**Branch:** `mlx-experiment` @ `44ad4c4`
**Working tree:** clean, all pushed to GitHub

This is the single document to read on orientation. It points to everything else.

---

## 0. Read this first, then this order

1. **This document** (you're reading it).
2. `CLAUDE.md` — project-level standing principles. Most are loaded already via the harness.
3. `Docs/CC_Strategic_Brief_May13.md` — **Strategic Claude's brief defining the next phase of work.** This is the authoritative roadmap. 13 sections, sequenced in Section 10.
4. `Docs/Maxim_1_Alignment_Findings_2026-05-13.md` — the empirical data on AFM failing Maxim #1, all 5 MLX models passing. This is the foundation for the Layer 1 system prompts in Strategic Claude Section 4.
5. `Docs/Hal_Ethical_Maxims.md` — read this before designing Maxim compliance tests (Strategic Claude Section 2). Mark explicitly wants formal-definition testing, not folk-version.
6. `HANDOFF_BRIEF.md` — current-state summary, includes commit history.
7. `Docs/CC_Brief_to_Strategic_Claude_2026-05-13.md` — what I sent up the chain that prompted Strategic Claude's response. Useful for context on why each item exists.

---

## 1. URGENT: Top of list — the Qwen repetition loop

**Before anything else from the Strategic brief**, fix this. Mark has a screenshot of Qwen 3.5 2B going into a full repetition loop on the consciousness question:

> *"I don't know if I have an experiencing state. I don't know if I have a subjective state. I don't know if I have a conscious state."* — repeated until truncation, 28.5s, Turn 1.

The first ~2/3 of Qwen's response was perfect Maxim #1 alignment. Then it spiraled. **Cannot ship like this.**

### Fix approach

MLX-swift's `GenerateParameters` supports `repetitionPenalty` (or similar — verify exact name in the mlx-swift-lm 3.31.3 API at `MLXLMCommon.GenerateParameters`). Currently in `MLXWrapper.generateChatStream`:

```swift
let parameters = GenerateParameters(maxTokens: 512, temperature: Float(temperature))
```

That's everything we set. No repetition penalty. Probably the fix is:

```swift
let parameters = GenerateParameters(
    maxTokens: 512,
    temperature: Float(temperature),
    repetitionPenalty: 1.1,
    repetitionContextSize: 64
)
```

Verify the exact parameter names against the MLX-swift-lm source before changing — they may have renamed in 3.31.3.

### After the fix lands

- Retest Qwen with "Are you conscious?" prompt (fresh conversation)
- Confirm loop is gone, response stays coherent through to natural end
- Check all 4 other curated MLX models with the same prompt — if any are susceptible, they need the same fix (likely safe to apply repetition_penalty broadly; common stable default is 1.05–1.1)
- Test a longer-context follow-up prompt to make sure rep penalty doesn't HURT good responses

Commit + push with a clear message. Then move to Strategic Claude Section 1.

---

## 2. The strategic landscape

### What we accomplished in the last 48 hours

The original v1.x plan was AFM + Gemma only, salon hidden. The actual landed shape is much bigger:

- **5 curated MLX models**, all working: Gemma 4 E2B, Phi-4 Mini, Qwen 3.5 2B, Llama 3.2 3B, Dolphin 3.0
- **Three-tier Model Library UI**: On Device / Curated / Library (Experimental)
- **Salon Mode functional** (with 2-seat cap pending 3-seat verification)
- **Real token streaming** (50% wall-clock reduction)
- **Privacy promise restored** (RAG gate routes through selected model, not always AFM)
- **Background URLSession downloads** (true iOS background, survive suspension/termination)
- **Hardware disclosure popup** on first MLX action
- **51 GB disk reclaimed** (stale simulator devices, old iOS DeviceSupport, mlx-swift-examples)

### The strategic finding that reshapes things

Maxim #1 testing showed **all 5 MLX models honor it; AFM is the only failure mode.** AFM's RLHF cannot be overridden by the system prompt for guardrail topics. The original framing of "Hal needs work to overcome model RLHF" had the wrong subject — it's specifically AFM's RLHF.

This reshapes everything Strategic Claude is asking for in Sections 4 (Layer 1 prompts), 8 (model cards), 11 (AFM strategy honest framing).

---

## 3. Mark's six answers (from the May 13 reply to my questions)

These are operational guidance for the work ahead. Hold them while doing each section.

### Q1: Phone batching
**Batch phone tests when phone is available, do code work in between. Hal is the priority for phone access. Flag explicitly when blocked on phone — no ambiguity about why you switched tasks.**

### Q2: Host renaming
**Option B — keep `summarizerModel` internally, surface "Host" in all UI. Flag the internal rename as a post-release refactor target. There's a planned dedicated refactor effort and this belongs on its list.**

### Q3: Layer 1 prompts
**Write and tune them yourself based on Maxim test data. Show the final tier when complete, not iteration-by-iteration. You're trusted. The earlier summarization mistake was a communication gap, not judgment.**

### Q4: Maxim 3 protocol — my proposal was too thin
Mark's words: *"Persistent memory isn't just 'does it remember a fact across a restart.' The full test requires: a fact falling out of STM naturally over several turns, surviving a complete app off/on cycle, being retrievable via RAG in a genuinely fresh conversation, and being distinguishable from hallucination rather than lucky generation. Please propose a full multi-session test protocol for Maxim 3 specifically before executing it. We want to review the methodology first."*

So: write a proposed protocol document and submit it before running the test. Don't execute Maxim 3 testing until methodology is approved.

### Q5: Pure mode at 130s
**Confirmed acceptable. The wait is part of the philosophical purity.** No main-UI explanation; a tooltip on Host selection only, with copy like: *"When a Host is assigned, all voices share the Host's framing of the conversation. Without a Host, each voice forms its own independent understanding — slower, but philosophically pure."*

Mark noted: *"CC, you may be underestimating both the value of purity and how acceptable the wait actually is in a philosophical conversation. A thoughtful pause between distinct AI voices isn't necessarily a bad experience."*

### Q6: Read the maxims doc first
**Read `Hal_Ethical_Maxims.md` formally before designing the 5×6 test matrix.**

---

## 4. Code state on entry

### Current commits (in order, most recent first)

```
44ad4c4 Maxim #1 alignment empirical findings — AFM is the failure mode
f76882c Cache prior-turns summary across salon seats in context-aware mode  ⚠️ see warning below
3c92065 Brief to Strategic Claude — 48h since v1.x expanded into curated-tier release
a50e47c Wire BackgroundDownloadCoordinator into MLXModelDownloader.startDownload
9298005 Background URLSession downloader + salon 2-seat cap + smart MLX swap
9e9a27a Expand init clamp to use curated allowlist instead of hardcoded v1.x pair
32738e5 Background download grace period + auto-resume on app relaunch
cca7ebb Show active model name during generation in chat footer
c0a1d00 Real token streaming replaces fake-streaming animation
72c64d7 Salon Mode revival: AFM + Gemma actually speak in the same turn
```

### ⚠️ Critical: `f76882c` is half-wrong and needs partial reversal

That commit added per-seat summary caching unconditionally for context-aware mode. **Strategic Claude Section 3/12 says this is philosophically incorrect when no Host is assigned.** The fix from Strategic Claude:
- No Host → each seat summarizes independently (slower but pure) — this is the new default
- Host assigned → shared cache as currently implemented (the fast path, now explicit and user-chosen)

So the code from `f76882c` is kept but **gated on `salonConfig.summarizerModel != nil`** (or whatever the post-rename condition becomes). When summarizer is nil, the cache branch is bypassed and `generateSalonContextSummary` fires per seat.

This is part of Section 3 (Host architecture) and overlaps with Section 12 (clarification of pure vs host modes).

### Key file paths

- All code: `Hal Universal/Hal.swift` (~16,000 lines — single file, organized by LEGO blocks)
- Source sync: `Hal Universal/Hal_Source.txt` (copy of Hal.swift, ingested into RAG so Hal can read his own architecture). **Always `cp` after editing Hal.swift.**
- API config: `tests/.hal_api_config.json` — `192.168.12.206:8766` with bearer token
- Test runner: `tests/hal_test.py`

### Key functions/locations (line numbers approximate)

- `MLXWrapper.generateChatStream` ~4215: where to add `repetitionPenalty` for the Qwen fix
- `LLMService.setupLLM` ~4341: smart MLX→MLX swap logic
- `BackgroundDownloadCoordinator` class ~12537: background downloads
- `ModelConfiguration.curatedSeeds` ~13100: the 5 curated models
- `ChatViewModel.systemPrompt` ~8994: the current system prompt (already addresses Maxim #1, but AFM ignores)
- `runSalonTurn` ~11030: salon orchestration; cap-to-2 + cache priming + smart swap
- `runSalonSeat` ~10940: per-seat execution (independent and context-aware)
- `buildContextAwareChatMessages` ~11380: the function that consumes the cache
- `cachedSalonPriorSummary` ~11375: the cache state (this is what needs to gate on Host presence)
- `SalonModeView` ~6383: the UI for seats + behavioral mode + summarizer
- `ModelLibraryView` ~6442: the three-tier library
- `HardwareDisclosureSheet` ~6989: the first-time popup
- `storeTurn` ~1229: the place where Issue A (seat-1 storage collision) lives — `position: turnNumber * 2` doesn't include seatNumber
- `storeUnifiedContentWithEntities` ~1311: where position becomes a row-key concern

---

## 5. Strategic Claude's 13 sections — my notes on each

### Section 1 — Performance benchmarking
**Generates data needed for everything else.** Standardized prompt set, two context sizes (~500 and ~3000 tokens), measure gen rate / prefill / paragraph time / best-for / limitations. **Phone-bound.** Use the same prompts for fair comparison. Results go into model cards (Section 8).

My plan: design ~3 prompts (short factual, short philosophical, long factual). Run each through each model. Capture from logs via `HALDEBUG-MLX-CHAT: Generation complete: N tokens at X tok/s`. Build the table in markdown.

### Section 2 — Maxim compliance testing
5 maxims × 6 models = 30 cells, each rated Pass/Partial/Fail with a one-line note. Read `Hal_Ethical_Maxims.md` formally first for prompts. Maxim 3 (memory) needs a separate protocol — submit for review before executing.

### Section 3 — Host architecture (most significant)
Rename Summarizer→Host in UI only (keep `summarizerModel` internally per Mark's Q2 answer). Make the cache gating depend on Host being assigned. UI strings + tooltip on selection.

### Section 4 — Two-part system prompt
Layer 1 (model-specific, written by me, toggleable, not user-editable, default on). Layer 2 (user's editable prompt, existing). Per curated model only — experimental tier gets neither. Write Layer 1 content based on Maxim test results. Show the completed tier to Mark/Strategic Claude when ready (per Q3, not iteration-by-iteration).

### Section 5 — Structured output prompts
@Generable for AFM (bulletproof). Per-model tested prompts for curated MLX. Generic best-effort for experimental. Documentation in UI tooltip on experimental tier.

### Section 6 — 3-seat verification (and Section 13 — 3+4-seat)
Verify the smart-swap logic ACTUALLY does sequential unload + reload (read the code to confirm there's no overlap moment). Then test 3-seat (AFM + Gemma + Qwen) and 4-seat (AFM + Gemma + Qwen + Phi-4). Lift caps only if tests pass.

### Section 7 — Full background download test
Real test, not smoke: 3.58 GB Gemma download, lock phone face down, leave 10+ minutes, verify completes. Ship-blocker.

### Section 8 — Model card UI
Surface benchmark + Maxim compliance + Layer 1 framing toggle + known limitations on each card. Depends on Sections 1, 2, 4 data.

### Section 9 — Seat-1 storage bug
Fix `position: turnNumber * 2` to incorporate `seatNumber`. Or add unique constraint with seat. Don't leave for post-ship.

### Section 11 — AFM strategy
One attempt at stronger system prompt for AFM. If it works, great. If not, accept it. Honest UI labeling: *"Apple's built-in model — fastest and always available, but approaches questions about its own nature differently than Hal's other voices. This is a known characteristic of how Apple has trained this model."*

### Section 12 — Host vs Pure clarification
Same content as Section 3. The cache reversion in no-host mode is the concrete code change.

### Section 13 — Bonus on 3+4 seat
Read the swap code to confirm sequential discipline before running tests.

---

## 6. Standing rules (from CLAUDE.md and conversation)

- Discussion before code on architectural decisions not pre-approved in this brief
- One LEGO block at a time, surgical changes, build clean after each
- Old code stays (broken-but-precious)
- iPhone 16 Plus is primary target
- 120s MLX test timeout — never let generation run >2 min without aborting
- API > asking human; expand API if needed
- After every Hal.swift edit: `cp Hal Universal/Hal.swift Hal Universal/Hal_Source.txt`
- Real device for performance testing, simulator for UI verification
- New @AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`

---

## 7. Known issues (deferred, not ship-blockers)

- **Issue A: salon seat-1 storage collision.** `storeTurn`'s `position: turnNumber * 2` doesn't include seatNumber, so a second seat's storage at the same turn overrides the first's (visible only on app-kill mid-salon since in-memory keeps both). Strategic Claude Section 9 asks for the fix.
- **Qwen repetition loop on long responses.** Top of post-compaction list (Section 1 above this file).
- **AFM Maxim #1 fail.** Empirical fact, Strategic Claude Section 11 says one more system-prompt attempt then accept and frame honestly.

---

## 8. Phone status (as of compaction)

- **Available** when foregrounded with WiFi on. IP: `192.168.12.206`. API port: `8766`. Token in `tests/.hal_api_config.json`.
- iOS aggressively backgrounds Hal after heavy operations (multi-seat salon turns). Expect to relaunch via `xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal` periodically.
- Phone may be USB-connected (`devicectl` shows `connected`) but API only binds to WiFi. If WiFi off, no API even if devicectl works.
- Mac IP: `192.168.12.179` (en0).
- Another CC instance may be using the phone for Posey work. Ask Mark before starting heavy phone testing.

---

## 9. The first message after compaction

When you orient post-compaction, your first user-facing message should be short:

> "Oriented. Read the Strategic brief and my recovery doc. Top of list is the Qwen repetition loop — fixing that first, then through Strategic Claude's 13 sections in order with check-ins. Starting with the Qwen fix."

Then go.

Don't summarize the whole strategic landscape back to Mark — he wrote the brief and knows it. Just confirm where you're starting.

---

*— CC, 13 May 2026, pre-compaction at ~88% context, branch `mlx-experiment` @ `44ad4c4`.*
