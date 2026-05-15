# UI Thread Unresponsiveness — Diagnosis + Fix Proposals

**Symptom:** During a 4-seat salon turn, the iPhone UI becomes unresponsive for several seconds. Scrolls and taps get dropped. Mark observed this live on 2026-05-15.

**Confirmed root cause:** the entire salon-seat-swap path runs on the main actor, blocking SwiftUI's gesture recognizer for the duration of GPU synchronization, MLX cache clearing, model loading, and per-token streaming updates.

---

## The thread-blocking chain (every salon seat transition)

1. `ChatViewModel` is annotated `@MainActor` (line 10349). Therefore every async function in it — including `runSalonTurn` — runs on the main thread by default.
2. `runSalonTurn` (line 13199+) iterates seats and calls `llmService.setupLLM(for: model, keepMlxResident: true)` **synchronously** at line 13321 — no `await`, no detach.
3. `setupLLM` (line 5239+) on the MLX→MLX swap path calls `mlxWrapper.unloadModel()` **synchronously** at line 5302 — on the main thread.
4. `unloadModel()` (line 4773+) is itself **synchronous** (not async). Inside:
   - `MLX.Stream.gpu.synchronize()` (line 4804) — blocks the calling thread until the GPU drains. Measured at <1 ms in normal flow, but the worst case is bounded only by however much GPU work is pending.
   - `MLX.GPU.clearCache()` (line 4813) — synchronous, can take measurable time on a 2 GB cache.
   - `@Published` property mutations (lines 4816–4820) — these always need main, no issue here.
5. Back in `setupLLM`, the load is dispatched via `Task { ... }` (line 5305). But because `Task { ... }` with no `.detached` **inherits the caller's actor**, and the caller is main, **the Task body runs on main** — including the 500ms `Task.sleep` and the `await self.mlxWrapper.loadModel(...)` call. Load takes 5–15 seconds; that's 5–15 seconds of main being held (with `await` points that let other main work in between, but each compute chunk between awaits is still on-main).
6. Per-token streaming inside `runSalonSeat` (line 13463) writes `messages[i].content = chunk` on every chunk. `messages` is `@Published`. Each write triggers a SwiftUI re-render. With Gemma at ~33 tok/s, that's a re-render every ~30ms. Gesture events get batched between renders; many get dropped.

**Total per-seat main-thread occupancy:**
- 0–500 ms GPU sync
- 1–5 ms clearCache
- 500 ms explicit sleep (in Task, but main-bound)
- 5–15 s of `loadModel` (main-bound Task, with cooperative awaits but still main)
- 5–60 s of per-token streaming churn

**× 4 seats per salon turn = the multi-second dead zones Mark observed.**

---

## What's NOT the problem

- Fix 2A's `Stream.gpu.synchronize()` is real but minor — <1 ms in practice. Removing it would not measurably improve responsiveness. It's also load-bearing for crash prevention; we keep it.
- `clearCache()` is real but small.
- The 500 ms sleep is real but small.

**The dominant cost is the load itself**, plus the cumulative effect of per-token streaming. Those are what we have to address.

---

## Proposed fixes, in order of invasiveness

### Fix A — least invasive, biggest single win

**Make the dispatch Task in `setupLLM` explicitly detached.**

At line 5305:
```swift
// Before:
Task {
    if isMLXToMLXSwap {
        try? await Task.sleep(nanoseconds: 500_000_000)
        ...
    }
    await self.mlxWrapper.loadModel(modelConfig: resolvedModel)
    ...
}

// After:
Task.detached { [weak self] in
    guard let self else { return }
    if isMLXToMLXSwap {
        try? await Task.sleep(nanoseconds: 500_000_000)
        halLog("HALDEBUG-MLX: 500ms memory-reclaim settle complete; starting load for \(model.displayName)")
    }
    await self.mlxWrapper.loadModel(modelConfig: resolvedModel)
    if let mlxError = self.mlxWrapper.mlxError {
        await MainActor.run {
            self.initializationError = mlxError
        }
    }
}
```

**Impact:** the 5–15s load runs on a background thread. Main stays free. Gesture recognizer keeps working.

**Risk:** very low. `loadModel` already handles its own `@Published` mutations via `await MainActor.run { ... }` (audit confirmed at lines 4687–4707, 4755–4761). The detached context won't break that.

**Caveat:** runSalonTurn's poll on `mlxWrapper.isModelLoaded` still works because that property update happens via `await MainActor.run` inside `loadModel`. The polling loop on main can see it.

### Fix B — moderate, additional win on the unload path

**Make `unloadModel()` async and offload the heavy synchronous calls to a detached task.**

```swift
// Before:
func unloadModel() {
    // ... GPU sync, clearCache, mutations all on caller's thread ...
}

// After:
func unloadModel() async {
    let memBefore = MLX.Memory.snapshot()
    halLog("HALDEBUG-MEMORY: unloadModel ENTRY ...")
    
    // Move the blocking GPU work off main.
    await Task.detached { [modelContainer] in
        if modelContainer != nil {
            MLX.Stream.gpu.synchronize()
        }
        MLX.GPU.clearCache()
    }.value
    
    // Back to caller's actor for the @Published mutations.
    modelContainer = nil
    isModelLoaded = false
    loadingProgress = 0.0
    loadingMessage = "Model unloaded"
    mlxError = nil
    
    let memAfter = MLX.Memory.snapshot()
    halLog("HALDEBUG-MEMORY: unloadModel EXIT ...")
}
```

**Caller change:** `setupLLM` would need to `await mlxWrapper.unloadModel()` at line 5302, which means `setupLLM` becomes async, which means every caller of setupLLM becomes async, etc. **This cascade is what makes Fix B more invasive.**

**Verdict:** Fix B is correct architecturally but cascades. Skip unless Fix A leaves visible blocking on the unload step (unlikely — we measured GPU drain at <1 ms in our diagnostic logs).

### Fix C — throttle per-token streaming updates

The per-token `messages[i].content = chunk` writes are the *other* main-thread hot spot during generation (not just during loading). At ~33 tok/s for Gemma, ~50 tok/s for Llama, each token triggers a SwiftUI re-render.

**Option:** coalesce updates to ~15 Hz max. Buffer chunks, flush to `messages[i].content` on a timer. The user can't perceive 33 Hz vs 15 Hz of streaming text anyway.

**Risk:** medium — touches the streaming loop, needs careful tuning so chunks don't get lost on stream end.

**Verdict:** worth doing if Fix A alone doesn't make scrolling smooth during *generation* (as opposed to between-seat transitions). Probably a v2.x refactor item, not urgent for v1.6 ship.

---

## Recommendation

**Land Fix A only.** Single-line change (well, ~5 lines including the weak self capture), addresses the dominant cause, near-zero regression risk. Verify by:

1. Re-run a 4-seat salon
2. Try scrolling during seat transitions
3. Look at the existing diagnostic logs — the 500ms sleep + load timing should still appear, but main-thread responsiveness should be qualitatively better

If after Fix A the gesture recognizer is *still* unresponsive during *active generation* (i.e., while a single seat is streaming), then Fix C becomes the next move. But based on the diagnosis, Fix A alone should restore meaningful responsiveness.

Fix B is held in reserve in case Fix A reveals the unload-side blocking matters more than measured. Not expected.

---

## What I have not done

- **Not implemented Fix A yet.** Awaiting your go-ahead per the "discussion before code" principle.
- **Not measured generation-time UI responsiveness in isolation.** The salon overlaps load + generate, hard to separate without instrumenting more.
- **Not investigated whether `LLMService` should be `@MainActor`.** It currently isn't (good — gives us room to dispatch detached). Could be a v2.x correctness review.

---

*— CC, May 15, 2026*
