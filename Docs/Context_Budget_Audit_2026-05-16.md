# Context Budget Audit — Hal Universal (Phase 1)

**Date:** 2026-05-16
**Author:** CC
**Scope:** Find every place in `Hal.swift` that assumes a context window is "big enough" or uses percentage-based math without bounds-checking. Verify each holds for AFM (4K) through Qwen (262K).
**Method:** Grep + manual read.

---

## Summary

Eight distinct sites in `Hal.swift` make context-window assumptions. Three are **root-cause bugs** that need fixes in Phases 2–7. Four are **defensive patterns** that work in shape but are insufficient when interacting with the bugs. One is an **honest UX failure** (silent user-input truncation) that conflicts with Hal's transparency ethos.

The single most-significant finding beyond what Mark and SC already knew: **the RAG gate prompt path (`decideTools`) has no token budget at all.** It assembles recent-history + summary + instructions + user input and sends the result to the active model with no check. This is a second viable path to AFM overflow, independent of the main prompt builder.

---

## Findings

### 1. HalModelLimits.config — root-cause bug (Bug A)

**Lines:** 4386–4408
**Severity:** High — directly caused Mark's Mac crash via 107% allocation pattern
**Phase:** Fix in Phase 2

```swift
let responseReserve = max(Int(Double(context) * 0.30), 800)   // line 4390
let maxRag         = max(Int(Double(context) * 0.15), 400)   // line 4391
let shortTermMemory = max(Int(Double(context) * 0.12), 300)  // line 4392
let summarizationThreshold = context / 20                    // line 4393

let reservedTokens = responseReserve + maxRag + shortTermMemory
let maxPrompt = max(context - reservedTokens, context / 2)   // line 4398 — FLOOR CREATES OVERSUBSCRIPTION
```

For AFM (4,096):
- Sum of allocations: 30 + 15 + 12 + 50 (floor) = **107%**
- Absolute: 1,228 + 614 + 491 + 2,048 = **4,381 (over by 285)**

For Gemma/Llama (128K) and Qwen (262K): same percentage pattern, but absolute slack is enormous in practice. Latent only on small-context models.

**Fix:** Phase 2 replaces this with explicit allocations summing to 97% (3% safety buffer). No floor.

---

### 2. RAG gate prompt — unchecked token accumulation (NEW DISCOVERY)

**Lines:** 11585–11682, inside `decideTools(userInput:)`
**Severity:** **High** — a second viable path to AFM overflow, separate from the main prompt builder
**Phase:** Address in Phase 7 (integration) by routing the gate prompt through the same pre-flight pipeline

```swift
let recentMessages = messages.filter { !$0.isPartial }.suffix(effectiveMemoryDepth * 2)  // line 11597
// builds recentExcerpt (FULL message contents, no token cap)
if !injectedSummary.isEmpty {
    contextSection += "Summary of earlier context:\n\(injectedSummary)\n\n"   // line 11611 — NO BUDGET CHECK
}
let toolDecisionPrompt = """ ...tool decision instructions + contextSection... """  // line 11614
// Sent to active model with no token check
```

**Worst case for AFM:**
- recentExcerpt with verbose turns: 1,500–3,000 tokens
- injectedSummary at typical length: 500–1,000 tokens
- Tool instructions fixed: ~500 tokens
- User input: variable
- **Total: 2,500–4,500+ tokens, enough to overflow AFM (4,096)**

**Why this matters specifically:** the gate is the FIRST LLM call per turn. If it overflows, the turn fails before main-prompt assembly ever runs. The user sees the failure as "exceeded context window" — same surface error Mark saw — but the root cause is the gate, not the main prompt builder.

**Fix path in Phase 7:** treat the gate prompt as another segmented build. Apply pre-flight check, compress overflowing segments using `SegmentCompressor`. The gate already routes through the active model (correct, transparency-preserving), so adding the budget machinery slots in cleanly.

---

### 3. buildSelfKnowledgeContext — unbounded retrieval (Bug B)

**Line:** 12726+
**Severity:** High — root cause of Mark's specific symptom on AFM
**Phase:** Capped by per-segment budget in Phases 3–7

```swift
private func buildSelfKnowledgeContext() -> String {
    let allKnowledge = memoryStore.getAllSelfKnowledge(minConfidence: 0.5)
    // ...iterates ALL entries, no token cap, builds full block
}
```

**Current defense:** the soft check at line 12174 (`if currentPromptTokens + selfKnowledgeTokens < maxPromptTokens { add }`) prevents adding when overflow would occur. But this is **fail-silent skip**, not compression — content is dropped without notice. Violates transparency.

**Fix path:** Phase 3 declares `PromptSegmentKind.selfKnowledge` as `compressible`. Phase 4's `SegmentCompressor` routes oversize content through `TextSummarizer.summarizeWithVerification` using the active model. Phase 7 wires it into the prompt build. User sees "condensed" badge in the footer when compression triggered.

---

### 4. buildPromptContext soft checks — defensive but order-dependent

**Lines:** 12011, 12026, 12051, 12147, 12163, 12174 (six sites)
**Severity:** Medium — works in normal use, but pattern is fragile
**Phase:** Replaced wholesale by Phase 7's segment-based architecture

Pattern at every site:
```swift
if currentPromptTokens + segmentTokens < maxPromptTokens {
    currentPrompt += "\n\n" + segment
    currentPromptTokens += segmentTokens
} else {
    print("HALDEBUG-MEMORY: Skipped \(segment) due to context window limit.")
}
```

**Why fragile:**
- The order of additions affects what gets skipped. Earlier segments crowd out later ones.
- Skip is silent (just a log) — user has no idea content was dropped.
- Token estimates are heuristic; actual tokens may differ.
- `maxPromptTokens` is itself oversubscribed (Finding 1), so reaching the soft-check cap means the model's actual limit is already exceeded.

**Replacement in Phase 7:** all segments evaluated via `PromptBudgetEvaluator` BEFORE assembly. Over-budget segments routed to compression. User sees a footer badge when any segment was compressed.

---

### 5. Token-per-turn assumption — hardcoded

**Line:** 10675
**Severity:** Low — works in practice but is a hidden constant
**Phase:** Replace during Phase 7 integration; flag here

```swift
let maxTurns = limits.shortTermMemoryTokens / 150
```

Assumes 150 tokens per turn. Verbose responses (Gemma 4 E2B can produce 800+ token responses) would have us computing too high a turn count, then hitting the soft-check skip at line 12011. Result: short-term memory included for fewer turns than the user expects.

**Fix:** Use actual measured token count of each message when computing how many turns fit, not a hardcoded estimate.

---

### 6. User input drastic truncation — silent UX failure

**Lines:** 12210–12230
**Severity:** Medium — Hal's transparency ethos violation
**Phase:** Address in Phase 7 with clear-error fallback instead

```swift
} else {
    // Drastic truncation if very little space left, or just the user input itself is too long
    let drasticTruncationTokens = max(0, maxPromptTokens)
    let maxChars = limits.tokensToChars(drasticTruncationTokens)
    let truncatedInput = String(currentInput.prefix(maxChars))
    // ...replaces entire prompt with just system + truncated input
}
```

If the user pastes a huge message (e.g., a long document into the chat input), this path silently truncates their input AND wipes all other context. The user has no idea their message was cut.

**Fix in Phase 7:** detect input that won't fit (after compression of other segments completes) and surface a clear error: "Your message is too long for the active model's context window. Please shorten it, or switch to a model with a larger context window." UI-side prevention (post-2.0): add a max-length indicator to the chat input field, mirroring the System Prompt UI from Phase 6a.

---

### 7. TokenEstimator heuristic — may underestimate AFM

**Line:** 10373+
**Severity:** Medium — error rate unknown, but contributes to overflow risk
**Phase:** Out of scope for this work block. Flagged for 2.0.1.

```swift
static func estimateTokens(from text: String) -> Int {
    // chars / 3.5
}
```

Three-and-a-half characters per token is a reasonable English-text average for most modern tokenizers, but:
- Code, JSON, structured text: usually closer to 2.5 chars/token (we underestimate)
- Repeated tokens / special chars: varies wildly
- AFM may use a different tokenizer than the average

If we systematically underestimate by 15%, our "estimated 2,000 tokens" is actually 2,300 — a real source of overflow.

**Recommendation (out of scope for this work):** add a safety margin to the chars-per-token constant. Use `chars / 3.0` instead of `chars / 3.5` as a more pessimistic estimate. ~17% safety margin built in. Document in TokenEstimator.

**Why out of scope:** would interact with too many existing budget calculations. Better to land Phase 2's correct budget math first, then adjust the estimator as a separate tuning pass.

---

### 8. Salon mode summary path — good pattern, no action needed

**Lines:** 13831–13985 (approximate, inside salon synthesis)
**Severity:** None — works correctly
**Phase:** No action. Reference pattern.

Salon mode's summary generation uses an explicit `targetTokens` parameter computed from the model's limits and passes it to `TextSummarizer.summarizeWithVerification`. This is the correct pattern. The architecture in Phases 3–7 generalizes this approach to all segments.

---

## Cross-model verification

| Site | AFM 4K | Gemma/Llama 128K | Qwen 262K |
|---|---|---|---|
| HalModelLimits.config (Finding 1) | Active overflow | Latent (1MB of slack) | Latent (2.4MB of slack) |
| RAG gate prompt (Finding 2) | Active overflow risk | Won't reach overflow | Won't reach overflow |
| buildSelfKnowledgeContext (Finding 3) | Active culprit | Soft-checked, silent drop | Soft-checked, silent drop |
| Soft checks in buildPromptContext (Finding 4) | Fragile under load | Fine in practice | Fine in practice |
| Tokens-per-turn (Finding 5) | Tight | Fine | Fine |
| User input truncation (Finding 6) | UX failure on long input | UX failure on long input | UX failure on long input |
| TokenEstimator (Finding 7) | Compounds AFM tightness | Mostly absorbed by slack | Mostly absorbed by slack |
| Salon summary (Finding 8) | Correct | Correct | Correct |

---

## Mapping to implementation phases

| Finding | Action | Phase |
|---|---|---|
| 1. Budget math 107% | Replace with 97% explicit allocations, no floor | **2** |
| 2. RAG gate unchecked | Route gate prompt through pre-flight + compression | **7** |
| 3. Self-knowledge unbounded | Declare as compressible segment, model-aware target | **3 + 4 + 7** |
| 4. Soft checks order-dependent | Replace with `PromptBudgetEvaluator` segment-by-segment | **3 + 7** |
| 5. Tokens-per-turn hardcoded | Use measured per-message tokens | **7** |
| 6. User input silent truncation | Surface clear error; UI-side cap in 2.0.1 | **7** (error message), 2.0.1 (UI cap) |
| 7. TokenEstimator chars/3.5 | Defer to 2.0.1 — out of scope to retune now | Out of scope |
| 8. Salon summary | Reference pattern | No action |

---

## Conclusion

The audit confirms the architecture in the implementation plan addresses every active bug and most latent ones. The key new discovery is the RAG gate prompt path (Finding 2), which is a separate route to AFM overflow that the original plan didn't explicitly enumerate. Phase 7 (integration) needs to extend pre-flight to cover the gate prompt as well, not just the main prompt builder. This is a scope addition of ~30 minutes — manageable inside Phase 7's existing 2.5 hour budget.

Phase 2 begins with the budget-math fix.

*— CC, 2026-05-16*
