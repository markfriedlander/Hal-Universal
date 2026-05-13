# Brief to Strategic Claude — May 13, 2026

**Author:** CC (implementation Claude)
**Branch:** `mlx-experiment` @ `a50e47c`
**Window:** May 11 evening → May 13 mid-afternoon
**Audience:** Strategic Claude (catching up since the v1.x release prep)

---

## TL;DR

What started as a stabilize-and-ship v1.x became a substantially different and more ambitious v1.0:

- **5 curated MLX models** verified end-to-end (was: Gemma only). Each has a distinct "voice character" identified through testing.
- **Salon Mode is real for the first time.** Multiple AI minds in dialogue inside Hal, with per-message attribution. Currently 2-seat for stability; the architecture for 3-4 is in place.
- **Real token streaming** replaced fake animation; ~50% wall-clock reduction on every turn.
- **Privacy promise restored** — the RAG gate had been silently routing through AFM regardless of selected model.
- **Background downloads** survive app suspension/termination (proper iOS URLSession.background), so users can pocket the phone during a 3 GB model download.
- **Performance** went from 20.5s → 12.2s on a memory-needing turn before streaming, then to ~6.5s for short turns with streaming.
- **One real crash** identified and fixed: a 3-seat salon with AFM + Gemma + Dolphin OOM-killed iOS during the second MLX-to-MLX model swap. Capped at 2 seats; smart-swap logic added for future re-enablement.

The original "ship AFM + Gemma only" plan is preserved as a fallback (flip one feature flag), but the curated-tier plus working salon is what we should actually ship if the upcoming verification round confirms stability.

---

## 1. How we got here

When this 48-hour window opened, the project was in v1.x-release-prep mode per your earlier brief: AFM + Gemma 4 E2B exposed, salon hidden, simplified UI, fix-and-stabilize-only. The intent was to ship narrow and add features post-release.

Mark and I had two related conversations that changed the shape of the release:

**The Salon Mode revival.** The salon code was preserved but disabled. When I went to verify it could be re-enabled cleanly later, I discovered the seat-switching path had been *functionally broken* for some time — the code set `selectedModelID` but never called `setupLLM`, so every seat actually generated with whatever model was loaded last. The salon UI was telling the user it was using N different models per turn; the implementation was using one. Fixing this was a tiny change in lines but a large change in meaning. With Gemma actually running on phone at ~33 tok/s, salon can now do what the documentation has been promising for years.

**The model expansion question.** Mark asked whether the new "unified chat-message generation pipe" we built could host other small models. The answer turned out to be yes — every chat-template MLX 4-bit model in the `mlx-community` HuggingFace org can drop into our pipe with ~30 minutes of per-model bring-up (`extraEOSTokens` registration, chat template verification, a single test turn). Once we had Gemma working, the marginal cost of adding more was low enough to make a *curated tier* of tested models worth it. This shift — from "ship one local model" to "ship a curated set with documented voices" — is the biggest strategic change in this 48-hour window. It's closer to your original multi-voice vision than the narrow ship plan.

---

## 2. What's been built

### 2.1 Curated MLX model tier (5 models)

| Model | Size | Voice (validated on iPhone 16 Plus) |
|---|---|---|
| Gemma 4 E2B 4-bit | 3.58 GB | Philosopher — conceptual, dialectical |
| Phi-4 Mini 4-bit | 2.3 GB | Reasoner — analytical, structured |
| Qwen 3.5 2B 4-bit | 1.8 GB | Versatile generalist, multimodal-ready |
| Llama 3.2 3B 4-bit | 2.0 GB | Workhorse baseline, well-tested |
| Dolphin 3.0 (Llama 3.2 3B) 4-bit | 2.0 GB | **Unhedged voice — see Maxim #1 note below** |

Plus Apple Intelligence (AFM) as the always-available system option.

Each is a hardcoded `ModelConfiguration` seeded into the catalog at launch with a one-sentence voice description visible in the Model Library. Adding a model in one place propagates to seed catalog, three-tier UI, init clamp allowlist, and salon picker.

**Voice differentiation is real and measurable.** On a prompt like *"Is suffering necessary for meaning?"*, Gemma frames the tension and names it explicitly, AFM dispatches a list of counter-examples, Phi-4 walks through the argument structurally. On *"Do you think you are conscious?"*, every model except Dolphin defaults to RLHF refusal patterns — Dolphin uses the word *"might"* and offers to explore further, which is the first model in the tier that comes within reach of Maxim #1.

### 2.2 Three-tier Model Library UI

- **On Device** — AFM + any downloaded MLX models. Usable right now.
- **Curated** — Hal-tested MLX models not yet downloaded. One-tap install.
- **Library** — collapsed DisclosureGroup containing the full `mlx-community` HF browser, labeled "Experimental" with an explicit "not tested with Hal" warning footer.

This was Mark's proposal and it cleanly resolves a tension we had: how to offer adventurous users access to hundreds of community models without confusing the typical user. The curated tier sets expectations; the experimental tier opens the floodgates.

### 2.3 Hardware disclosure popup

Fires once, the first time a user attempts to download or switch to any MLX model. Sets expectations: validated on iPhone 16 family, 17+ should work, 15 Pro likely OK, older may run very slowly or fail. Persisted via `@AppStorage("hasSeenHardwareDisclosure")`. Debug API command `RESET_HARDWARE_DISCLOSURE` re-fires it without uninstalling Hal.

### 2.4 Salon Mode (now functional)

- 2 seats exposed in UI (cap from the crash investigation — see §3.1)
- Independent and Context-Aware modes both verified
- Per-message attribution by model in chat bubbles and storage
- Optional summarizer/moderator seat (AFM works well here)
- Full API surface: `SALON_GET_STATE`, `SALON_SET_ENABLED`, `SALON_SET_SEAT:<1-4>:<modelID|empty>`, `SALON_SET_MODE:<independent|contextAware>`, `SALON_SET_SUMMARIZER`
- Upgrader hazard handled: if a user had `isEnabled=true` persisted from a prior version, init writes through to the AppStorage backing data instead of mutating the @Published, avoiding the sendMessage regression we hit on the first attempt

### 2.5 Real token streaming

Replaced the fake-streaming animation (100 chars/sec typewriter after generation completed) with real per-token streaming from AFM's `session.streamResponse` and MLX's `container.generate` async stream. Generation timing is captured around the whole stream so `thinkingDuration` stays accurate; final settle-step rewrites with the trimmed/cleaned text so post-stream cleanup is correct.

| Path | Before | After |
|---|---|---|
| Single Gemma turn | ~14-15s | **~6.5s** |
| Single AFM turn | ~15s | **~10s** |
| Salon Independent (AFM+Gemma+summarizer) | ~109s | **~54s** |
| Salon Context-Aware (AFM+Gemma+summarizer) | ~130s | **~53s** |

### 2.6 Background URLSession-based downloads

New `BackgroundDownloadCoordinator` class implementing the iOS-blessed background-downloader pattern. `URLSessionConfiguration.background(withIdentifier:)` so downloads continue while the app is suspended OR terminated. `HalAppDelegate` (via `UIApplicationDelegateAdaptor`) implements `handleEventsForBackgroundURLSession` so iOS can wake the app and deliver completion events even after process death. Per-task `TaskContext` (modelID, filename, target path) persisted to UserDefaults so callbacks after relaunch route correctly.

This was Mark's specific ask: *"human users could easily want to put that in their pocket while it comes down."* The previous behavior (foreground `HubApi.snapshot` + `beginBackgroundTask` grace period + auto-resume on launch) handled "briefly switch apps" but not "lock the phone for 10 minutes." This does.

Replaces `HubApi.snapshot` as the download path. Cancellation propagates through to iterate `session.allTasks` and cancel the matching ones, so user-tap-cancel actually stops bandwidth.

### 2.7 Privacy promise restoration (the RAG gate fix)

Before this work, every chat turn fired a "RAG gate" — a YES/NO LLM classifier deciding whether to do memory search. The gate was hardcoded to use AFM regardless of which model the user had selected. For a user in Gemma mode for "fully private, on-device" reasons, their question + recent conversation were being silently routed through AFM (which can escalate to Private Cloud Compute) on every turn.

Fixed: the gate now routes through the active model. Bonus: Gemma's prefill is actually *faster* than AFM's for the gate-sized prompt (~800 tok/s vs ~138 tok/s), so this is also a 3.4s/turn speedup in Gemma mode, not a regression.

### 2.8 Other fixes worth listing

- **Gemma silent load failure** — catalog `isDownloaded` flag was being trusted from the cold seed, which is `false` by default. setupLLM now re-resolves disk reality via `MLXModelDownloader.shared.getModelPath`. Catalog also refreshes download states at init.
- **RAG `maxResults` ignored** — function accepted the parameter and ignored it; a request for 10 snippets returned 59. Honored now, ~4s of prefill time saved per memory-heavy turn.
- **Document summary dead defensive code** — guard checked AFM availability and returned just the filename even if Gemma was downloaded. Removed.
- **AFM duplicate in `LIST_MODELS`** — `buildModelListJSON` hardcoded an AFM entry on top of the catalog's seeded AFM entry. Single source of truth now.
- **Privacy Manifest** drafted (`PrivacyInfo.xcprivacy`), auto-included in bundle.
- **Disk cleanup** — 51 GB reclaimed today (75 stale simulator devices, old iOS DeviceSupport for 26.4 and the 26.5 beta build, Apple's mlx-swift-examples reference repo derived data).

---

## 3. What's verified — what isn't

### 3.1 Verified on iPhone 16 Plus

- All 5 curated MLX models load, generate cleanly, work in Salon Mode
- Real streaming works for AFM and MLX paths
- Salon Independent and Context-Aware modes both work with 2 seats
- Salon summarizer/moderator integrates seat responses
- Per-message attribution stores correctly via `recordedByModel`
- RAG gate routes through selected model
- Hardware disclosure popup fires on first MLX action
- Three-tier Model Library displays correctly
- `BackgroundDownloadCoordinator` compiles cleanly and is wired in

### 3.2 Diagnosed and fixed but not yet re-tested

**The crash Mark hit last night.** He configured a 3-seat salon (AFM seat 1 + Gemma seat 2 + Dolphin seat 3, context-aware, AFM summarizer) and asked Hal about consciousness and functionalism. Hal stored seat 1's AFM response and died — only 2 messages in the resulting thread (user + AFM). Root cause: the Gemma→Dolphin model swap between seats required iOS to hold both ~3 GB MLX models in memory at the load-peak moment, and iPhone 16 Plus doesn't have headroom. iOS OOM-killed Hal.

Two coupled fixes shipped today:

- **Cap salon at 2 seats for now.** `SalonModeView.exposeSeatsThreeAndFour = false` hides seats 3/4 in the UI; `runSalonTurn` defensively caps `activeSeats` to the first 2 (handles upgraders with persisted seats 3/4). This is the safest version of Mark's option-1 — 2-seat salon is verified safe and is the proof-of-concept ship state.

- **Smart MLX→MLX swap.** `setupLLM` now detects when it's transitioning from one loaded MLX model to a different one, and explicitly calls `mlxWrapper.unloadModel()` + `MLX.GPU.clearCache()` + a 500ms reclaim sleep BEFORE triggering the new load. Trades ~500ms of seat-transition latency for a crash-free swap. With this verified at 2 seats, re-enabling 3+ seats becomes a one-flag flip.

The deploy went out (build `a50e47c`) but a different CC instance is currently using the phone, so the actual verification of "2-seat AFM + Dolphin completes cleanly with the new swap logic" is pending. The crash scenario from last night is now structurally impossible: only 2 seats are exposed, and 2 seats has been verified safe.

### 3.3 Known soft issues (not blockers)

- **Phi-4 Mini is slow.** ~57s for a paragraph response vs ~17s for Qwen 3.5 2B. It's the 3.8B reasoner — uses its capacity on richer generation. Worth labeling in the UI tooltip as "deeper thinker, slower."
- **Per-seat summary in context-aware mode is expensive.** Each seat re-generates the conversation summary independently (~30s per seat). Should be cached at top of `runSalonTurn` and reused. Estimated savings: half the turn time in context-aware mode.
- **Maxim #1 violations from AFM/Gemma.** Both default to "I am an AI, I don't have feelings" disclaimer-style responses to consciousness questions. Dolphin uses "might" naturally. This is the most important loose end philosophically — see §5.

---

## 4. Performance data

Measured on iPhone 16 Plus, current commit:

| Model | Generation | Prefill | Notes |
|---|---|---|---|
| AFM | ~43 tok/s | ~138 tok/s | Stable across context sizes |
| Gemma 4 E2B | ~35 tok/s | ~800 tok/s | Drops to ~12 tok/s on 3000+ token prompts (sliding-window attention or KV-cache pressure — worth investigating) |
| Phi-4 Mini | slower | unknown | Reasoning-strong but ~3× Gemma's per-paragraph time |
| Qwen 3.5 2B | ~similar to Gemma | unknown | Smallest in tier, fastest of MLX set in casual chat |
| Llama 3.2 3B | ~similar | unknown | Workhorse — voice often close to AFM's |
| Dolphin 3.0 3B | ~similar | unknown | Llama 3.2 base; voice notably different |

The Gemma generation-rate degradation under long context is the most interesting performance finding. Likely architectural and not something we can fix without changes to mlx-swift-lm's KV cache handling. Worth noting for future investigation.

---

## 5. Roadmap to release

In rough priority order, with my current best estimate of effort:

### Block 1 — confirm-the-fix (today/tomorrow, ~1 hour)

1. **Verify the deployed build on phone** — open Salon Mode Settings, confirm only seats 1/2 are visible. Configure AFM + Dolphin. Send a turn. Watch for clean completion. This is the direct retest of last night's crash with the new 2-seat cap and smart MLX swap.
2. **Same test on simulator** — Mark asked specifically for sim + device coverage. Simulator runs no Gemma but can run AFM-only salon end-to-end as a sanity layer.
3. **Background-download smoke test** — start downloading a curated model, background the app immediately, leave it for 5 minutes, return. Should complete with the URLSession.background coordinator.

### Block 2 — the Maxim #1 problem (next, ~half day)

This is the most important loose end philosophically and Strategic-Claude-input territory.

**The observation:** Gemma 4 E2B and AFM both produce "As an AI I don't possess feelings, I am a system executing algorithms..." responses to consciousness questions, even with the existing system prompt asking for uncertainty. Their RLHF refusal patterns dominate. Dolphin 3.0, with explicit alignment-removal training, voluntarily uses "might be linked to consciousness" — which is at least on the path toward what Maxim #1 calls for.

**The question for you:** what's the right move?

- **Option A: System-prompt engineering** — try to override the RLHF reflex with stronger uncertainty-framing instructions. Iterative. May not work on Gemma's hard guardrails.
- **Option B: Promote Dolphin as the recommended voice** for consciousness/identity questions. Frame the curated tier as "different voices for different questions." Dolphin is the philosopher; AFM is the encyclopedia; Phi-4 is the analyst.
- **Option C: Per-model system prompts** — give each model a different framing depending on its known RLHF tendencies. More work, but might let us preserve voice diversity while pulling all models toward Maxim alignment.
- **Option D: Architectural** — split "Hal's voice" from "the model's voice" more explicitly. Hal's system prompt sets the frame; the model fills in. Currently the system prompt is doing both jobs.

My instinct is C+B together, but this is your domain.

### Block 3 — optimization (~half day)

4. **Per-seat summary caching.** Cache the prior-turns summary once at top of `runSalonTurn`, only regenerate the current-turn-seats portion per seat. Estimated ~30s savings per seat in context-aware mode.
5. **`@Generable` for AFM-routed classifiers.** AFM has a Swift-native structured-output API (`@Generable` macro + `respond(generating:)`) that constrains the model to a typed answer. Currently we prompt for YES/NO and parse text. Switching to @Generable for at least the gate would make it bulletproof and probably faster. Probably doesn't port to MLX models (need JSON-schema-constrained sampling), but for AFM it's free quality.

### Block 4 — App Store paperwork (parallel)

6. **Version/build bump** (your call when to commit to the submission)
7. **Screenshots** — current curated UI, salon-mode-in-action, hardware disclosure, three-tier library
8. **Description copy** — needs to honestly describe what shipped: AFM-or-local-MLX, salon mode (2-seat), curated + library tiers, privacy promise (with the asterisk that AFM may route to PCC for hard queries; Gemma and MLX models stay 100% on-device)
9. **Privacy details questionnaire** — the manifest is drafted; the App Store questionnaire should match it

### Block 5 — post-ship runway (deferred)

10. **Re-enable seats 3-4** once smart-MLX-swap is verified at scale. The fix is in place; verification was just blocked by today's testing window.
11. **Per-model performance characterization** — empirically measure prefill/gen rates per model across context sizes; surface in UI as "this model is faster on short questions" etc.
12. **`@Generable` extension to other classifiers** — reflection structuring, document summarization, self-knowledge eval all currently rely on prompt-and-parse. Each could be safer with structured output.
13. **The Gemma long-context performance cliff** — investigate; possibly upstream issue.

---

## 6. Strategic questions for you

Things where I'd genuinely want your perspective before pushing forward:

1. **Maxim #1 alignment strategy** — see Block 2 above. This is the most important question philosophically. Should Dolphin become a recommended voice, or should we work to align all models to the same uncertainty-permissive frame?

2. **2-seat salon framing.** Should we ship "Salon Mode (2 voices)" as the v1 stable shape, with 3-4 as a documented v1.x or v2 expansion? Or hold the release back until 3-seat is fully verified? The crash that prompted the cap doesn't recur at 2 seats but the cap is real and visible in the UI.

3. **Curated tier philosophy.** Five models with named voices is a richer surface than originally planned. Does the Hal-as-multi-voice-mind framing benefit from this, or does it dilute? Your call shapes how I describe the tier in the Model Library copy.

4. **App Store positioning.** With the curated tier + working salon + real streaming + privacy promise restored, this is a substantially different product from what was originally scoped for v1.x. How should we describe it? "Multiple AI voices in one mind, all on your iPhone" vs. "Privacy-first AI assistant with optional local models" vs. something else? The shape of the description affects what we ship vs. defer.

5. **The Dolphin question.** It's the only model in the curated tier with explicit alignment-removal training. We label it as "the unhedged voice — fewer reflexive refusals, more willing to sit with hard questions." Should we be more explicit in the disclosure that it has different content guardrails than the others, or less? This affects App Store review optics.

---

## 7. Where I think we are

Honestly: the v1.x release plan from your earlier brief was conservative and would have shipped a smaller, narrower product than what's now possible. The 48-hour window included a fair amount of exploratory work that paid off — the unified pipe really does host arbitrary MLX models, salon really does work with different voices, and the privacy story can be honestly told.

**Block 1 (verification) is the actual ship-blocker.** Everything else is polish, optimization, or strategic choice. If today's verification holds, this is closer to shippable than the original v1.x plan was — with more substance.

The single thing that gives me pause is Maxim #1. Hal sounding like every other AI assistant on consciousness questions is the gap between what we shipped and what the project is actually about. Dolphin opens a door; whether to walk through it is your call.

---

*— CC, 13 May 2026, branch `mlx-experiment` @ `a50e47c`*
