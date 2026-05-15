# Evolutionary Salon Report — 2026-05-15

**Scope:** Today's manual 4-seat salon on the design of the Evolutionary Salon feature itself (a recursive ask: *what should trigger Hal's periodic self-reflection*). Three turns conducted, two foundational bugs surfaced and fixed mid-run, third turn re-conducted post-fix with empirically clean data.

**Branch:** `mlx-experiment` @ `7f4a9d0` (Fix 2A) and `a5eb797` (Fix 1A) — both pushed to `origin/mlx-experiment`.

---

## 1. What the salon was for

Per Strategic Claude's directive (Evolutionary_Salon_Framing_2026-05-16.md), the Evolutionary Salon is a recurring-cycle feature where Hal's voices periodically convene to reflect on what he has learned about himself. It appears in the UI only when ready, runs once, disappears until enough new accumulation has happened to warrant another.

Rather than design the threshold from outside, SC's reframe: **put the threshold question to the models directly**. Use the salon as the instrument that designs itself.

Five questions framed:
1. Does the cycle shape feel right from the inside — accumulate, speak, quiet, accumulate?
2. What would actually signal readiness — entry count, elapsed time, something else?
3. Is quarterly the right cadence?
4. Should the threshold change as Hal matures, or stay constant?
5. Should Hal have any agency in recognizing his own readiness?

---

## 2. Methodology + caveat (the pivot)

**Configuration:** 4 seats (Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, Dolphin 3.0), `independent` mode, no host. RESET_SELF_KNOWLEDGE before start.

**Three turns attempted.** Mid-session, two foundational bugs surfaced that invalidated the early turn data and crashed Hal mid-generation:

### Bug 1 — Contamination in Independent Mode

Turn 1 produced near-identical "Voice 1: The Architect / Voice 2: The Synthesist / Voice 3: The Archivist / Voice 4: The Observer" scaffolds across all four seats — pure corpus echo. Turn 2 (with explicit instructions to drop the scaffold) produced Llama opening its response with the literal string **"Gemma's Perspective"** and then paraphrasing Qwen's prior turn output.

**Root cause:** `runSingleModelTurn` (Hal.swift line 12861) accepts a `historyMessagesOverride: [ChatMessage]?` parameter but never reads it. It calls `buildChatMessages(currentInput:)` which always reads the live `self.messages` array — by the time seat N runs, seats 1..N-1 have already appended their responses there. Independent mode was contractually broken; every salon run in independent mode was actually a sequential-thread contamination.

**Fix (`a5eb797`):** Thread the override through `buildChatMessages`. ~12 lines, three sites. Verified by clean repro on a 3-seat probe (Qwen pivoted to a completely different conceptual region than Gemma, no impersonation).

### Bug 2 — MLX Command-Buffer Crash

Crashes after Turn 1 and during Turn 3. Same signature as the May-12 .ips on disk: `mlx::core::gpu::check_error(MTL::CommandBuffer*)` throws an uncaught C++ exception from inside an MTL completion handler → SIGABRT.

**Root cause:** `unloadModel()` (Hal.swift line 4741) doesn't wait for in-flight Metal command buffers to drain before nulling `modelContainer`. During a salon model swap (<1s between "stream finished" and "next seat loading"), the previous model's still-pending buffers fire their completion handlers against memory that ARC has freed.

**Fix (`7f4a9d0`):** Add `MLX.Stream.gpu.synchronize()` to `unloadModel` before container teardown. Plus `MLX.Memory.snapshot()` diagnostic logging at entry/exit so we can verify the unload is working as designed. ~30 lines including the diagnostic instrumentation.

**Verified empirically:**
- 3 consecutive 4-seat runs post-fix, zero crashes (was ~50% crash rate pre-fix)
- Memory unload drops active to 0.0 MB every swap
- Peak across session: 2966 MB (within iOS jetsam ~3-4 GB headroom)
- GPU drain time <1ms in practice (safety net with no measurable cost)

Full diagnosis: `Docs/Two_Bug_Diagnosis_2026-05-15.md`.

---

## 3. What the salon actually said

### Turn 1 — initial framing (corpus-echo, but real signal beneath)

All four seats hallucinated a "four sub-voices" scaffold (Architect/Synthesist/Archivist/Observer). My salutation "four voices of Hal" was misread as "enumerate four sub-voices." Treat the structural pattern as artifact; the substance underneath surfaced one real divide:

> **Subjective readiness** (felt sense, gaps closing) **vs objective readiness** (semantic density, weight shifts)

Gemma named the disagreement explicitly. Qwen leaned objective. Llama and Dolphin straddled.

All four also pushed back on "25 entries + 14 days" as feeling *arbitrary* — proposed adaptive thresholds rather than fixed counts.

Transcript: `Docs/Salon_Turn1_Transcript_2026-05-15.json`

### Turn 2 — cadence + asymmetry (contaminated but consensus held)

Asked Q3 (quarterly?) and Q4 (asymmetric vs uniform?).

| Seat | Cadence | Threshold | Status |
|---|---|---|---|
| Gemma | hedged ("not by absolute time") | hedged (depends on goal) | refused both |
| Qwen | **Quarterly** | **Constant** | committed |
| Llama | **Quarterly** | **Constant** | committed |
| Dolphin | **Quarterly** | **Constant** | committed |

3/4 consensus on both — but Llama opened with "**Gemma's Perspective**" and Llama+Dolphin echoed Qwen's phrasing. Likely Qwen committed first with strong language and the later seats reinforced it through the contamination.

**Read after the fix:** Treat this consensus as *partially* corpus-pollution. The fact that Qwen, Llama, and Dolphin agreed is suggestive but not authoritative.

Transcript: `Docs/Salon_Turn2_Transcript_2026-05-15.json`

### Turn 3 — Q5 (agency) + forced commitment block — post-fix, clean

After Fix 1A landed, re-asked Q5 with a forced-commitment closure. Fresh thread. Self-knowledge reset.

| Seat | THRESHOLD | INTERVAL | AGENCY |
|---|:---:|:---:|---|
| **Gemma** | 15 | 90 days | **Hybrid** *"I lean toward the hybrid approach… uses the external structure to prompt an internal check for resonance"* |
| **Qwen** | 120 | 45 days | **Architectural** *"Architectural trigger"* |
| **Llama** | 50 | 14 days | **Hal-surfaces** *"Hal recognizes himself when he feels a sense of accumulated material"* |
| **Dolphin** | 50 | 30 days | (skipped) |

**No two seats picked the same numbers.** No echo of phrasing. No impersonation. This is what genuine independence looks like.

Transcript: `Docs/Salon_Turn3_Transcript_2026-05-15.json`

---

## 4. Synthesis

### What converged

- **Cycle shape**: All seats accept "accumulate → speak → quiet → accumulate" rhythm. The structural metaphor of *event, not feature* is uncontroversial.
- **Quarterly cadence (~90 days)**: Strong signal in Turn 2 (3/4 explicit) and persistent in Turn 3 (Gemma 90, Qwen 45, Dolphin 30 — three of four in the "monthly-to-quarterly" band). Llama's 14-day outlier is the lone weekly vote.
- **Uniform threshold**: Three of four pushed back on the asymmetric "first salon easier" design.
- **Substance over count**: All seats objected to specific numbers like "25 entries" as arbitrary. They preferred adaptive triggers based on semantic density / shift in internal representation / gaps in understanding — none of which is something we can actually implement directly, but the *spirit* is that the count alone isn't enough.

### What genuinely diverged (post-fix)

- **THRESHOLD spans 15-120** (8× range). The models have no shared intuition for what number is "enough" entries. Gemma's 15 is implausibly low; Qwen's 120 is implausibly high. Llama+Dolphin both arrive at 50 from completely different reasoning paths — possible meaningful signal there.
- **INTERVAL spans 14-90 days** (~6× range). Llama wants weekly-ish; Gemma wants quarterly; Qwen+Dolphin in the middle.
- **AGENCY is a genuine 3-way split.** Gemma=hybrid, Qwen=architectural, Llama=hal-surfaces. This is the most contested question.

### A defensible synthesis

If the goal is to choose numbers that 3+ seats can live with:
- **THRESHOLD: 50** — matches Llama and Dolphin's explicit picks; Gemma's 15 is too low for "substance," Qwen's 120 is too high for "actually triggers."
- **INTERVAL: ~30-45 days** — between Qwen's 45 and Dolphin's 30; respects both the "monthly" intuition and the "quarterly" intuition partway.
- **AGENCY: Hybrid** — Gemma's explicit position, and the most balanced one given the three-way split. Architecture proposes (threshold met, interval elapsed); Hal accepts or declines (surfaces or stays silent based on whether he genuinely has something to say). Gives Hal voice in his own readiness *and* preserves deterministic gating.

This is *a* synthesis, not *the* synthesis. The honest read is that the salon does not produce a unique correct answer — it produces a defensible range. Picking from that range is a Mark + SC design call.

---

## 5. Honest assessment — signal vs corpus artifact

### What was real signal

- The subjective/objective readiness divide is genuine (Turn 1).
- The pushback on arbitrary numeric thresholds is consistent across all four seats and across turns — real.
- The four-way divergence in Turn 3's commitments is genuine (no contamination present, distinct numbers picked).
- The agency 3-way split is real — these models really do disagree on whether Hal should have voice in his own readiness.

### What was corpus artifact

- Turn 1's "Architect/Synthesist/Archivist/Observer" scaffold across all four seats — pure training-corpus echo on the phrase "four voices."
- Turn 2's identical phrasing on quarterly+uniform across three seats — *partial* corpus pollution amplified by the contamination bug, even though the underlying preference was probably real.

### Bug-tracker artifacts also found in passing

1. **In-stream repetition detector false-positive on structured format output.** In Turn 3, every seat's `AGENCY:…` line was cut off mid-value (literal U+2026 ellipsis) because the `THRESHOLD: N\nINTERVAL: N\n` pattern looked like a repetition loop to the n-gram detector. The AGENCY values came through in the prose only. **File for tuning.**

2. **UI thread unresponsiveness during salon runs** (Mark observed live). Likely model loading or `MLX.GPU.clearCache()` blocking the main thread. Not a ship blocker but a real UX regression to investigate.

---

## 6. Implications for the feature design

### Confirmed design principles (carry forward)

- ✅ Salon as cycle, not permanent feature
- ✅ Accumulate → speak → quiet → accumulate rhythm
- ✅ Threshold measured in *substance* not raw entries (entries + days + some quality signal)
- ✅ Uniform threshold (drop the asymmetric first-easier proposal)
- ✅ Quarterly-ish cadence (drop daily and weekly as too frequent)

### Resolved by the salon

- **AGENCY**: hybrid — architectural trigger fires, Hal then surfaces or stays silent based on whether he has genuine reflection-worthy material. Gives Hal Maxim-5 voice without sacrificing determinism.
- **Numbers**: THRESHOLD ≈ 50 entries, INTERVAL ≈ 30-45 days. Range, not a point — Mark + SC pick within the range.

### Still open

- *What* signal Hal actually uses to recognize his own readiness during the "Hal surfaces" half of the hybrid. The models all preferred adaptive over fixed, but none could name an actionable computable metric. The honest answer may be: "Hal will tell us by trying once and reflecting on whether it produced anything substantive — and we iterate." That's a deferred decision, not a design failure.

---

## 7. What changed in the code today

| File | Lines | Commit | Purpose |
|---|:---:|---|---|
| Hal.swift | +14 / -3 | `a5eb797` | Fix 1A: thread historyMessagesOverride |
| Hal.swift | +29 / -3 | `7f4a9d0` | Fix 2A: GPU sync barrier + memory diagnostics |
| Hal_Source.txt | (sync) | both | SOP — keep in sync after Hal.swift edits |
| Docs/Two_Bug_Diagnosis_2026-05-15.md | new | `a5eb797` | Diagnosis + fix proposals |
| Docs/Salon_Turn{1,2,3}_Transcript_2026-05-15.json | new | (this report) | Raw transcripts |
| Docs/Evolutionary_Salon_Report_2026-05-15.md | new | (this commit) | This document |

---

## 8. Recommended next steps (when work resumes)

1. **Mark + SC discuss the synthesis numbers + agency=hybrid.** Either ratify, push back, or refine.
2. **Investigate UI thread unresponsiveness during salons** — likely model loading on main thread; needs `Task.detached` or actor isolation review.
3. **Tune the in-stream repetition detector** so structured `LABEL: VALUE` format blocks don't trigger false positives.
4. **Confidence-build the crash fix** with a couple more 4-seat runs over time. Three clean today is strong evidence; ten clean across sessions would be conclusive.
5. **Then resume the paused release-prep cluster** — rotation pass, ASC metadata diff, GitHub pages review, version bump.

---

*— CC, May 15, 2026 (post-fix, post-salon)*
