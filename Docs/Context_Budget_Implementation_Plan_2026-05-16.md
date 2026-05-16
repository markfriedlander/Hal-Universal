# Hal Universal — Context Budget & Compression Architecture
## Detailed Implementation Plan

**For:** Strategic Claude + Mark
**From:** CC
**Date:** 2026-05-16
**Status:** Approved by Mark + Strategic Claude. CC working autonomously through Phases 1–8.

---

## Background

Two interacting bugs surfaced when AFM crashed on Mark's Mac with the error "Exceeded model context window size" on a fresh "Hi Hal!" turn:

- **Bug A:** `HalModelLimits.config(for:)` allocates 30% response + 15% RAG + 12% short-term + a 50% floor on prompt = **107% of context window**. Latent for the four MLX models (huge contexts mean 7% is large but never approached); meaningful for AFM at 4K.

- **Bug B:** Self-knowledge injection lives inside the prompt bucket with **no per-segment cap**. Grows unbounded with usage. Single-handedly capable of overflowing AFM even on a fresh turn with no chat history, no RAG, no summary.

The bugs interact (A makes B worse on AFM), but they are distinct architectural failures and require distinct fixes.

**Strategic Claude's directive:** Fix the architecture, not the symptom. No trimming — silently discarding content violates transparency. Instead: compression through the existing summarization engine, model-aware, cached, with footer transparency.

---

## 0. Concrete budget math (locked first, so the rest is precise)

New `HalModelLimits` allocations as percentages of context window. Sum: 97%. 3% safety buffer.

| Segment | Percentage | AFM (4K) | Gemma (128K) | Qwen (262K) |
|---|---:|---:|---:|---:|
| Prompt (system + Layer 1 + self-knowledge + temporal) | 50% | 2,048 | 65,536 | 131,072 |
| Response reserve | 20% | 820 | 26,214 | 52,429 |
| RAG retrieval | 15% | 614 | 19,661 | 39,322 |
| Short-term history | 12% | 491 | 15,729 | 31,457 |
| **Sum** | **97%** | **3,973** | **127,140** | **254,280** |
| Buffer | 3% | 123 | 860 | 7,864 |

**Hard caps within the prompt segment** (fixed across all models, not percentages):

- System prompt: **1,000 tokens** hard cap
- Layer 1 framing: **400 tokens** hard cap (CC-authored; build-time check)
- Self-knowledge: `prompt_budget - system_prompt_actual - layer_1_actual - temporal_overhead`
  - AFM worst case (both static at max): 2,048 − 1,000 − 400 − 50 = **598 tokens for self-knowledge**
  - Gemma worst case: 65,536 − 1,400 − 50 = **64,086 tokens for self-knowledge**

Compression is essentially **AFM-only in practice** — the MLX models have so much room that self-knowledge will essentially never need to compress for them. But the architecture treats every model uniformly so the rare overflow on Gemma (huge custom system prompt + huge self-knowledge) is also handled.

---

## 1. Phase 1 — Audit pass (≈1 hour)

**Goal:** Find every place in the codebase that assumes a context window is "big enough" or uses percentage-based math without bounds-checking.

**Method:** Grep + manual read of each hit. Verify each holds for AFM (4K) through Qwen (262K).

**Deliverable:** `Docs/Context_Budget_Audit_2026-05-16.md` — table of every site, model affected, severity, fix proposed.

**Commit boundary:** Audit doc committed; no code changes.

---

## 2. Phase 2 — Fix budget math (≈30 min)

**File:** `Hal Universal/Hal.swift`, LEGO block 07.5 (HalModelLimits Configuration), lines 4368-4423.

**Change:** Replace current `HalModelLimits.config(for:)` with allocations from section 0 above. Remove the `max(context - reservedTokens, context / 2)` floor that creates oversubscription. Document the math in a leading comment block.

Constants added at struct scope:
```swift
static let systemPromptHardCap: Int = 1_000
static let layerOneFramingHardCap: Int = 400
```

**Commit boundary:** Build clean; existing prompt path still uses old budget consumers, just with new numbers. No regression possible because the new numbers are strictly less generous than the old (no oversubscription).

---

## 3. Phase 3 — Pre-flight check infrastructure (≈1.5 hr)

**New LEGO block:** `07.6 Prompt Segment Budgeting` (inserted between 07.5 and 08).

**New types:**

```swift
enum PromptSegmentKind: String, CaseIterable {
    case systemPrompt        // hard cap, never compressed
    case layerOneFraming     // hard cap, never compressed
    case selfKnowledge       // compressed when over budget
    case autoSummary         // compressed when over budget
    case ragRetrieval        // compressed when over budget
    case shortTermHistory    // compressed when over budget (rare)
    case temporalContext     // tiny, never compressed
    case userMessage         // hard cap (UI-side), never compressed
}

struct PromptSegment {
    let kind: PromptSegmentKind
    let rawContent: String
    let budgetTokens: Int
    var rawContentHash: String { /* SHA-256 of rawContent */ }
}

enum PromptSegmentStatus {
    case withinBudget(actualTokens: Int)
    case overBudgetCompressible(actualTokens: Int, budgetTokens: Int)
    case overBudgetHardCap(actualTokens: Int, budgetTokens: Int)
}

struct PromptSegmentEvaluation {
    let segment: PromptSegment
    let status: PromptSegmentStatus
}

actor PromptBudgetEvaluator {
    static func evaluate(_ segments: [PromptSegment]) async -> [PromptSegmentEvaluation]
}
```

**Commit boundary:** New types compile. No integration yet. Build clean.

---

## 4. Phase 4 — Compression engine (≈2.5 hr)

**Same LEGO block (07.6).**

```swift
actor SegmentCompressor {
    static func compress(
        segment: PromptSegment,
        usingModel model: ModelConfiguration,
        llmService: LLMService,
        memoryStore: MemoryStore
    ) async throws -> CompressedSegment

    struct CompressedSegment {
        let kind: PromptSegmentKind
        let modelId: String
        let rawContentHash: String
        let compressedContent: String
        let targetTokens: Int
        let actualTokens: Int
        let createdAt: Date
        let cacheHit: Bool
        let truncated: Bool  // true if fallback truncation used (compression failed)
    }
}
```

**Internal flow:**
1. Compute `rawContentHash` (SHA-256 of `segment.rawContent`).
2. Check cache via `memoryStore.cachedCompression(...)`. If hit, return immediately with `cacheHit = true`.
3. Build compression prompt appropriate to segment kind.
4. Call `TextSummarizer.summarizeWithVerification(text:targetTokens:llmService:verificationThreshold:useRecencyWeighting:)` — gets LLM compression + sentence-level veracity check + replacement of ungrounded sentences.
5. If compression fails (timeout, model unavailable, output longer than target, veracity rejection): fall back to **truncation-with-honest-badge**. Set `truncated = true`. (See risk register §11.)
6. Store result via `memoryStore.storeCachedCompression(...)`.
7. Return `CompressedSegment`.

**Per-kind compression prompts:**

- `selfKnowledge`: "Compress these self-knowledge entries into ≤N tokens. Preserve named entities, specific preferences, and concrete observations. Drop abstract trait descriptions. Output a structured paragraph, not a list."
- `autoSummary`: existing summary compression
- `ragRetrieval`: "Compress these retrieved memory snippets into ≤N tokens, preserving attribution and concrete details."
- `shortTermHistory`: existing recency-weighted summary

**Compression model is always the active model.** Each model compresses itself (same principle as RAG gate routing). Cross-model compression would create hidden contamination — violates transparency.

**Commit boundary:** Compressor builds and unit-tests against a stubbed LLMService.

---

## 5. Phase 5 — Cache layer (≈1.5 hr)

**File:** `Hal Universal/Hal.swift`, MemoryStore (LEGO block 04).

**New SQLite table:**

```sql
CREATE TABLE IF NOT EXISTS compressed_segments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    segment_kind TEXT NOT NULL,
    model_id TEXT NOT NULL,
    raw_content_hash TEXT NOT NULL,
    target_tokens INTEGER NOT NULL,
    actual_tokens INTEGER NOT NULL,
    compressed_content TEXT NOT NULL,
    truncated INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    UNIQUE(segment_kind, model_id, raw_content_hash)
);

CREATE INDEX IF NOT EXISTS idx_compressed_segments_lookup
ON compressed_segments(segment_kind, model_id, raw_content_hash);
```

**New MemoryStore methods:**

```swift
func cachedCompression(segmentKind:modelId:rawContentHash:) -> CompressedSegment?
func storeCachedCompression(_ compressed: CompressedSegment)
func invalidateCachedCompressions(forSegmentKind kind: PromptSegmentKind)
```

**Invalidation:** Hash-based — when raw content changes, its hash changes, so a future lookup misses the cache automatically. Explicit `invalidateCachedCompressions` is a belt-and-suspenders cleanup hooked into:
- `setSelfKnowledge*` mutations
- `storeReflection`
- DB Nuke (clears entire table)

**Commit boundary:** Schema migration runs cleanly on existing installs (`IF NOT EXISTS` makes it idempotent).

---

## 6. Phase 6a — System Prompt token counter UI (≈45 min)

**File:** `Hal Universal/Hal.swift`, `SystemPromptEditorView`, line 7631.

**Three states (per SC refinement #1):**
- `< 80%` of cap: neutral counter, `"412 / 1000 tokens"` in `.secondary`.
- `80–99%` of cap: amber counter, `"850 / 1000 tokens — approaching limit"` in `.orange`.
- `≥ 100%` of cap: red counter, `"1000 / 1000 tokens — limit reached"` in `.red`. **TextEditor stops accepting growth. Deletion remains allowed.**

**Implementation:** Binding wrapper rejects input that would push past the cap. No silent acceptance + later ignore.

---

## 7. Phase 6b — Footer compression indicator + popover (≈45 min)

**Files:** ChatMessage struct + ChatBubbleView (LEGO block 13).

**ChatMessage gains:**
```swift
var compressedSegments: Set<PromptSegmentKind> = []
var truncatedSegments: Set<PromptSegmentKind> = []  // for truncation fallback
```

**Footer badge:**
- If `compressedSegments` non-empty: `"condensed"` badge with `rectangle.compress.vertical` SF Symbol.
- If `truncatedSegments` non-empty: `"truncated"` badge with `scissors` SF Symbol, distinct color.
- Both can co-exist if some segments compressed and others fell back.
- Tap → popover with explanation. `.presentationCompactAdaptation(.popover)` for iPhone.

**Popover copy (condensed):**
> **Memory condensed**
>
> The model you're using has a smaller context window than the size of Hal's full memory. To stay honest about everything Hal knows about you, Hal's full memory is preserved in the database — but for this turn it was condensed *by the model itself* to fit. Tap "Settings → Power User → Database" to see Hal's full memory anytime.

**Popover copy (truncated):**
> **Memory truncated**
>
> The model you're using couldn't condense Hal's memory in time (LLM unavailable, timeout, or the condensed result didn't pass verification). For this turn, Hal's memory was cut at the budget limit rather than intelligently distilled. Your full memory is preserved in the database — this only affects what the model saw for this single turn.

---

## 8. Phase 7 — Integration into prompt build path (≈2.5 hr)

**File:** `Hal Universal/Hal.swift`, the prompt builder around line 11900+.

**Refactor:** Replace direct string concatenation with the segment-based flow.

For each segment:
- `withinBudget` → pass through unchanged.
- `overBudgetCompressible` → run through `SegmentCompressor.compress(...)`. Record kind in `compressedSegments` (or `truncatedSegments` if `truncated=true`).
- `overBudgetHardCap` → log error, degrade gracefully via truncation, record warning. For Layer 1 this is a CC ship-blocker bug (should never happen in a properly-tested build).

**Cold-start status message (per SC refinement #2):**
> "Hal is condensing his memory for this model — this happens once when your memory changes."

Fires only on cache miss (not cache hit). Routed through existing `onStatusUpdate` plumbing.

---

## 9. Phase 8 — Real-device testing + MEMORY_INJECT_TEST API command (≈2.5 hr)

**Test matrix:**

| Scenario | Device | Expected |
|---|---|---|
| Fresh install, Gemma, single turn | iPhone | No compression, no badge |
| Fresh install, AFM, single turn | Mac/iPhone-AFM | No compression, no badge |
| Synthetic large self-knowledge → AFM | iPhone-AFM | Compression triggers, status, badge appears, no crash |
| Same large self-knowledge → Gemma | iPhone | No compression (Gemma has room) |
| Switch AFM → Gemma after AFM compression cached | iPhone | Gemma cache miss, fresh compression, AFM cache preserved |
| Edit self-knowledge | both | Hash changes, next turn re-compresses |
| DB Nuke during compression | both | Cancellation handled cleanly |
| System prompt fill to cap | both | Input rejects at 1000 tokens, deletion works |
| Compression failure path | both | Truncation badge, popover explains |
| Tap badge | both | Popover opens, copy correct, tap-outside dismisses |

**`MEMORY_INJECT_TEST` API command** — dual-purpose per Mark's addition:

```
MEMORY_INJECT_TEST:<count>:<tokens_each>[:<category>]
```

Inserts N synthetic self-knowledge entries of specified token size each. Categories optional (defaults to "test_synthetic"). Designed for:

1. **Budget testing:** deterministically reproduce AFM context overflow without waiting for organic accumulation.
2. **Evolutionary Salon threshold testing:** verify the Easter-egg threshold behavior (THRESHOLD ~50) without waiting weeks of organic accumulation. Test threshold trigger, interval gating, agency=hybrid behavior.

Both use cases use the same injection primitive. Single API surface, two consumers.

---

## 10. Estimated total timing

~13.5 hours of focused work. ~2 working days.

---

## 11. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Compression LLM call hangs/fails | High | Fallback to **truncation-with-honest-badge** — `truncated=true` on `CompressedSegment`, "truncated" badge in footer (distinct from "condensed"). Catastrophic-only fallback. |
| Compression output longer than target | Medium | Detected via post-compression token count; treated same as failure → truncation fallback |
| Veracity checker rejects compressed result | Medium | Same as compression failure → truncation fallback |
| Cache stale on raw-content edit not hitting a hook | Medium | Hash-based: stale entries simply won't be looked up after content changes |
| AFM compression of large self-knowledge takes >30s | Medium | Status message sets expectation. Caching ensures once-per-change cost |
| Footer popover renders badly on iPad/Mac | Low | `.presentationCompactAdaptation(.popover)` handles iPhone-vs-iPad |
| SQLite migration breaks existing installs | Low | `CREATE TABLE IF NOT EXISTS` is idempotent |

---

## 12. Out of scope for this work block

- 30 Swift warnings cleanup (sweep AFTER, since this work generates some new warnings)
- README + privacy.html + support.html
- Version bump 1.5 → 2.0
- ASC submission mechanics
- Pre-warming caches on model switch (potential 2.0.1)

---

## 13. Approvals

- **Mark:** ✅ Full approval, 2026-05-16
- **Strategic Claude:** ✅ Synthesis confirmed, 2026-05-16
- **CC working autonomously through all 8 phases.** Coming back only for genuine product decisions and final Phase 8 report.

---

*— CC, 2026-05-16*
