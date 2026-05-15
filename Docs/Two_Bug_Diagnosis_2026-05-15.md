# Two-Bug Diagnosis — 2026-05-15

**Context:** Manual 4-seat Evolutionary Salon revealed two foundational bugs blocking ship. Mark paused all other work and asked for clean diagnoses + proposed fixes before any code changes. This is that document.

**Bugs in scope:**
1. **Contamination** — Independent-mode salon seats see prior seats' responses from the same turn.
2. **Crash** — MLX GPU command-buffer error during back-to-back seat switches triggers an uncaught C++ exception → `SIGABRT`.

---

## Bug 1: Contamination in Independent Mode

### Symptom

Today's Turn 2 in the 4-seat Evolutionary Salon, with `behavioralMode: "independent"` confirmed via `SALON_GET_STATE`, produced this from Llama (seat 3 in the rotation):

> **Gemma's Perspective**  
> I perceive that our discussion revolves around readiness signals — both subjective and objective measures.
> ...

Llama opened by ventriloquizing Gemma. It also echoed phrasing from Qwen's earlier turn ("biological rhythm of consolidation", "artificial friction"). In independent mode this should be impossible — each seat is supposed to be in an isolated room.

### Root cause (confirmed by direct code inspection)

`runSingleModelTurn` (line 12861) accepts a `historyMessagesOverride: [ChatMessage]?` parameter:

```swift
private func runSingleModelTurn(userInput: String,
                                 historyMessagesOverride: [ChatMessage]? = nil,
                                 skipUserMessage: Bool = false) async {
    ...
    let chatMessages = await buildChatMessages(currentInput: userInput)  // line 12920
    ...
}
```

The parameter is **declared and never read**. The call to `buildChatMessages` at line 12920 passes only `currentInput`; the override is dropped on the floor.

`buildChatMessages` at line 12061+ then reads conversation history directly from `self.messages` (line 12186: `let nonPartial = messages.filter { !$0.isPartial }`). By the time seat N runs in a salon turn, seats 1..N-1 have already appended their responses to `self.messages` — so seat N's "history" includes them.

### Why the call site looked fine

`runSalonTurn` at line 13117 correctly captures the baseline:
```swift
let baselineHistory = messages.filter { !$0.isPartial }
```
And `runSalonSeat` at line 13309 correctly passes it through:
```swift
await runSingleModelTurn(userInput: userInput,
                         historyMessagesOverride: baselineHistory,
                         skipUserMessage: true)
```

The contract looks right at both call sites. The bug lives in the receiver. It would pass code review by sight — only behavioral evidence (Llama saying "Gemma's Perspective") surfaces it.

### Scope of impact

- **Affects ALL independent-mode salon runs.** Yesterday's 3-seat salon almost certainly had the same contamination, but the seats happened to converge on similar substance anyway, so it didn't visibly mark itself.
- **Context-aware mode is fine.** It uses a different code path (`buildContextAwareChatMessages` at line 13343), which is presumably designed to include prior seats — by design.
- **Single-model chat is fine.** No salon → no contamination problem.

### Confidence: HIGH

Direct code inspection + behavioral evidence. No ambiguity.

---

## Bug 2: MLX GPU Command-Buffer Crash

### Symptom

Two crashes today (Turn 1 post-completion, Turn 3 mid-Dolphin) during the 4-seat Evolutionary Salon. Same signature as the May-12 crash log on disk:

```
Type:           EXC_CRASH (SIGABRT)
Termination:    Abort trap: 6
Faulting frame: mlx::core::gpu::check_error(MTL::CommandBuffer*)
Call path:      MTL::CommandBuffer completion handler → MTLDispatchListApply
                → -[_MTLCommandBuffer didCompleteWithStartTime:endTime:error:]
                → IOGPU notification queue
```

**What it means:** MLX submits Metal command buffers to the GPU. When a buffer completes, MLX's completion handler runs `check_error(MTL::CommandBuffer*)`. If the command buffer's `error` property is non-nil, MLX throws a C++ exception. Swift cannot catch C++ exceptions — they unwind through `std::terminate` → `abort()` → `SIGABRT`.

So the proximate trigger is: **a Metal command buffer came back from the GPU with an error attached**, and MLX's response to that is to crash the process.

### Root cause — why the command buffer errors

The salon swap sequence (`setupLLM`, lines 5208–5247):

1. Seat A finishes streaming; Swift `stream.finish()` returns to runSalonTurn
2. runSalonTurn calls `setupLLM(B, keepMlxResident: true)`
3. setupLLM detects MLX→MLX swap, calls `mlxWrapper.unloadModel()` (line 5226)
4. `unloadModel()` (line 4741):
   - `modelContainer = nil` — drops the Swift reference; ARC begins teardown of the MLX model
   - `MLX.GPU.clearCache()` — clears MLX's CPU-side allocator cache
   - Sets flags

5. setupLLM then fires an `async Task` (line 5230) that sleeps 500ms and then loads B
6. setupLLM returns to caller while load is still pending

**The missing step in `unloadModel()`** is a GPU synchronization barrier. There is no `MLX.GPU.synchronize()`, no `commandQueue.waitUntilCompleted()`, no equivalent. The Swift side considers seat A "done" the moment the last token streamed out — but Metal's GPU side may still be executing A's final command buffers, or may have buffers queued behind them.

When we then:
- Null `modelContainer` (releasing the model's weight matrices and KV cache buffers)
- Clear the allocator cache (returning backing memory)
- 500ms later, begin loading B (which allocates new GPU resources, potentially reusing the same memory regions)

…we create a window in which an in-flight buffer from A's generation can fire its completion callback referencing memory that has been freed or reassigned. The Metal driver detects the corruption and surfaces it as `commandBuffer.error`. MLX's `check_error` then throws.

### Why the salon triggers it specifically

A normal single-model conversation never hits this race: there's only one model, no swaps, and any pending GPU work has time to finish before the user sends the next message (1+ seconds of human reaction time = plenty for the GPU to drain).

A 4-seat salon does four MLX→MLX swaps per user turn, with sub-second latency between "stream finished" and "next model loading." The race window is wide and the failure rate is high — we saw it ~67% of the time today (2/3 turns).

### Why the 500ms `Task.sleep` doesn't fix it

The 500ms sleep was added to fix a *different* problem: iPhone 16 Plus doesn't have RAM headroom for two ~3GB MLX models simultaneously, so loading B while A's pages are still resident OOM-killed Hal. The sleep gives iOS time to reclaim A's freed pages before B's load peak.

That's a CPU-side memory pressure fix. It does not address GPU-side synchronization. The two problems are unrelated.

### Confidence: MEDIUM-HIGH

- The stack trace is unambiguous about *what* throws (MLX command-buffer check_error).
- The salon-induced race condition is the most plausible reason for the buffer to error.
- But I have NOT yet seen today's `.ips` files — Xcode hadn't synced them when I started; they may show up shortly and could reveal a different root cause (e.g. resource limit hit, not a swap race). Worth grabbing before committing to a fix.
- Outside chance: this is an MLX framework bug that triggers under any heavy load, swap or no swap. Less likely given the timing correlation with seat switches, but not zero.

---

## Proposed Fixes — Ordered by Invasiveness

### For Bug 1 (Contamination)

**Fix 1A — least invasive, recommended:**

Thread `historyMessagesOverride` through `buildChatMessages`.

1. Change `buildChatMessages(currentInput:)` signature to `buildChatMessages(currentInput:historyOverride:)`, default `nil`.
2. At line 12186, use the override when provided:
   ```swift
   let source = historyOverride ?? messages
   let nonPartial = source.filter { !$0.isPartial }
   ```
3. At line 12920 in `runSingleModelTurn`, pass it through:
   ```swift
   let chatMessages = await buildChatMessages(
       currentInput: userInput,
       historyOverride: historyMessagesOverride
   )
   ```

Estimated change: ~6 lines across 2 sites. One LEGO block. Safe. No effect on existing single-model or context-aware paths because the override defaults to nil.

**Verification:** After landing, retry an independent-mode salon turn (3 seats to avoid Bug 2 until that's also fixed). Confirm Llama no longer opens with "Gemma's Perspective" and that each seat's `fullPrompt` (in the chat response payload) shows the same history.

---

### For Bug 2 (Crash) — three options, in order

**Fix 2A — least invasive, addresses root cause:**

Add an explicit GPU sync barrier to `unloadModel()` BEFORE dropping `modelContainer`.

In `unloadModel()` at line 4741, before line 4745 (`modelContainer = nil`):
```swift
// Wait for all in-flight GPU work to complete before tearing
// down model state. Without this, a salon model-swap can race
// with the previous model's pending command buffers, which then
// fire their completion handlers against freed backing memory
// and crash via mlx::core::gpu::check_error.
if let container = modelContainer {
    await container.synchronize()  // or whatever the MLX-swift API exposes
}
```

**Caveat:** I have not verified that `mlx-swift`'s `ModelContainer` exposes a synchronize method. The MLX C++ core has `mx::synchronize()`. The Swift wrapper may or may not surface it. **This is the first thing to verify before writing the fix.**

Alternative API possibilities to check:
- `MLX.GPU.synchronize()` — global GPU sync
- `MLX.Stream.synchronize()` — per-stream sync
- Direct Metal: get the command queue used by MLX and call `waitUntilCompleted()` on its last buffer

If none of these work cleanly, fall back to Fix 2B.

Estimated change: ~5 lines, one LEGO block, plus possibly a small change to make `unloadModel` async.

**Verification:** Re-run a 4-seat salon. The crash should not reproduce. Watch for any new slowdown in seat transitions (sync barrier may add 100-500ms per swap depending on the size of the buffer queue).

---

**Fix 2B — moderate invasiveness, structural:**

Make `setupLLM` truly blocking on the swap. Currently the unload-sleep-load sequence runs in a fire-and-forget `Task` (line 5230). The polling in `runSalonTurn` checks `isModelLoaded` but doesn't gate on GPU drain. Restructure:

1. Make `unloadModel` async and properly await all GPU work.
2. Inline the 500ms sleep into the awaited path, not a Task.
3. Make `loadModel` properly serialize after unload completion.

This is more correct architecturally but touches more code and changes the threading model. Fix 2A may be enough on its own.

---

**Fix 2C — defense in depth, doesn't address root cause:**

Add an Objective-C++ bridging file that wraps the MLX evaluate call in a C++ `try/catch`. Catches the C++ exception, converts to a Swift `Error`, surfaces as a Swift-catchable throw.

This **does not** fix the underlying GPU race. It only prevents the abort and lets Hal recover gracefully — the salon turn would fail for that seat but Hal would stay alive.

Worth doing eventually as a backstop regardless of Fix 2A. iOS apps should not crash even when MLX is unhappy. But it's the most invasive change (adds an Obj-C++ file, requires bridging header), so it's a v2.x refactor item, not a v1.x patch.

---

## What I Have NOT Done

- **Not pulled today's `.ips` files.** They hadn't synced when I started; Mark may need to refresh Xcode's Devices view to pull them. Pre-fix, I want to confirm the today crashes match May-12's signature exactly.
- **Not verified the MLX-swift sync API.** Need to either read mlx-swift source or test in a quick build whether `container.synchronize()` (or alternative) exists.
- **Not touched any code.** Per directive.
- **Not retried any salon work.** Per directive.

---

## Recommended Sequence

1. **Pull today's `.ips` files** to confirm crash signature matches. (Mark re-opens Xcode → Devices → View Device Logs.)
2. **Confirm mlx-swift sync API** by reading `~/Library/Developer/Xcode/DerivedData/Hal_Universal-*/SourcePackages/checkouts/mlx-swift/Sources/MLX/*.swift` or by quick build experiment.
3. **Apply Fix 1A** (contamination) — small, low-risk, well-contained.
4. **Apply Fix 2A** (crash) — slightly larger, but small. Stage it on its own commit so it can be reverted independently if it introduces regression.
5. **Re-run 3-seat salon** to verify Fix 1A (no "Gemma's Perspective" header).
6. **Re-run 4-seat salon** to verify Fix 2A (no crash).
7. **Then resume** the Evolutionary Salon design conversation, the synthesis work, the scroll/icon/metadata/release prep.

Estimated work: ~half a day for both fixes including verification.

---

## Honest Read

These are both real bugs. Bug 1 is a textbook "declared but unused parameter" that would have been caught by any code review with the actual call traced through. Bug 2 is a subtler synchronization issue that wouldn't show up under any non-salon workload.

Both can ship-block — Bug 1 because it invalidates the entire premise of independent mode; Bug 2 because it crashes Hal under the very feature we're shipping.

But both are also small in scope, and the proposed fixes are surgical. This is a half-day detour, not a refactor.

---

*— CC, May 15, 2026*
