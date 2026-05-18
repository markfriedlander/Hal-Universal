# v1 Build Spec — Self-Knowledge: Reflection-to-Trait Crystallization

**Date:** 2026-05-18 (morning)
**Author:** CC, after the 2026-05-17 evening Evolutionary Salon
**Reviewers:** Mark, Strategic Claude
**Scope:** What lands in the App Store v2.x release. What doesn't ship is enumerated explicitly at the end.

## The narrative

Hal's self-knowledge today has two layers that don't connect: reflections accumulate as cognitive scratchpad and never reach prompts; traits sit in the prompt but only grow by key-matching. There's no path from "thought" to "behavior change."

v1 adds that path. When a reflection has been reinforced enough times that it's clearly *a pattern rather than a moment*, it crystallizes into a structured trait. Traits then evolve as new reflections reinforce them — including reflections that partially contradict them. Lineage is permanent: every trait knows which reflections fed it.

This is what users experience as Hal becoming more himself over time. The salon-as-introspection layer (which produced this spec) stays in the codebase but is NOT user-triggerable in the App Store build; only developers running the project locally can invoke it. See "Out of scope" below.

## What the salon decided (carried into this spec)

From the four-seat Evolutionary Salon of 2026-05-17 evening (full raw output in `Docs/Evolutionary_Salon_2026-05-17/`):

- **Threshold is per-category, not global.** All four seats converged on "varies by content type, time, and conversation diversity." Starting numbers borrowed from Qwen's "resonance test" (N=3 as a baseline window where a thought becomes stable enough to be useful).
- **Contradiction is multi-valued with weighted decay.** Gemma's "preserve the tension" framing + Qwen's "weighted blend" mechanism. Do NOT replace. Do NOT branch.
- **Trait-generator extracts "internal shift," not paraphrase.** Qwen's prompt template, lifted almost verbatim, with one specific reversal: we will NOT forbid meta-commentary about architecture (that constraint would silence the most interesting kind of trait — traits about how Hal works on himself).
- **Add Meta-Cognition as a 7th category.** Gemma's specific proposal. Tracks *how* Hal thinks, distinct from *what* he learns. Clean addition because `category` is already a string column.
- **Privacy: default shareable, sticky across model switches, audit which model decided, "show private" toggle visible in the viewer.** All four approved.
- **Readiness signaling: not built.** Threshold firing is sufficient. No separate readiness mechanism in v1.

## Architectural overview

```
                  user turn (every 5th / 15th)
                            │
                            ▼
              ┌────────  AFM gate  ────────┐
              │   (skip if AFM active)     │
              └────────────┬───────────────┘
                           ▼
                  reflectOnExperience
                           │
                           ▼
              storeReflectionWithSynthesis
                  (cosine ≥ threshold)
                           │
              ┌────────────┴──────────────────┐
         match? yes                       match? no
              │                                │
              ▼                                ▼
   reinforcement_count++              store as new
              │
              ▼
   ┌──────────────────────────┐
   │ count ≥ category[N]?     │
   └──────────┬───────────────┘
              │ yes
              ▼
      mark as trait candidate
              │
              ▼
  ┌─────────────────────────────────┐
  │ background promotion task       │
  │ (deferred; runs after the turn) │
  └──────────┬──────────────────────┘
             ▼
   trait-generator LLM call
      (Qwen template)
             │
             ▼
   ┌─────────────────────────────────┐
   │ category+key collision check    │
   └──────────┬──────────────────────┘
             │
   ┌─────────┴─────────┐
   │                   │
 new trait        existing trait
   │                   │
   ▼                   ▼
INSERT          trait-evolution LLM call
                (absorb nuance, handle
                 contradiction multi-valued)
                       │
                       ▼
                UPDATE trait value
                       │
                       ▼
             both paths converge:
       UPDATE reflection.promoted_to_trait_id
```

## Schema changes

Two nullable columns on `self_knowledge`. Both backward-compatible (NULL for existing rows).

```sql
ALTER TABLE self_knowledge ADD COLUMN promoted_to_trait_id TEXT;
ALTER TABLE self_knowledge ADD COLUMN shareability_decided_by_model TEXT;
```

**`promoted_to_trait_id`:**
- On reflection rows: NULL until promoted, then set to the UUID of the trait they fed
- On trait rows: always NULL (traits aren't promoted from anything)
- Query reverse via `WHERE promoted_to_trait_id = ?` to find all reflections that fed a trait — no separate lineage table needed

**`shareability_decided_by_model`:**
- Records which model made the shareability call at write time
- Used to enforce stickiness (any new write keeps the existing decision unless the same model is rewriting)
- Powers auditability later — "who decided this was private?"

Migration: add columns with `ALTER TABLE ADD COLUMN ... IF NOT EXISTS` in `MemoryStore` init, similar to existing migration pattern at Hal.swift lines 1100ish.

## New module: `TraitCrystallizer`

I'll extract this into its own file `Hal Universal/TraitCrystallizer.swift` per refactor-as-you-go. Scope:

- Per-category reinforcement thresholds (constants or AppStorage-tunable)
- `processTraitCandidates(llmService:)` — the background task that runs after a turn completes
- `crystallizeReflection(_:llmService:)` — the per-reflection promotion path (LLM call + insert)
- `evolveExistingTrait(traitID:newReflection:llmService:)` — the trait-evolution path
- `detectContradiction(existingValue:newReflection:)` — embedding-based check; gates whether to evolve via weighted blend vs. straight value update
- Helpers for multi-valued storage format

Why a separate file: this is ~600-800 lines of cohesive new code that all belongs together. Keeps `SelfKnowledgeEngine.swift` focused on storage and read paths.

## Per-category thresholds (starting values)

```swift
enum TraitCategory: String {
    case value             // = 2  (core principles solidify quickly)
    case preference        // = 3
    case behavior_pattern  // = 3
    case capability        // = 2  (capabilities are facts; solidify fast)
    case learned_trait     // = 3
    case evolution         // = 2  (milestones are discrete events)
    case meta_cognition    // = 4  (new — most reflective, needs more reinforcement)
    case existential_observation  // = 4 (subjective, needs longer window)

    var reinforcementThreshold: Int { ... }
}
```

These are starting values. The salon's actual contribution was the *shape* (varies by category, content-aware) rather than specific numbers. We'll calibrate from real corpus behavior. AppStorage-tunable so we can adjust without rebuild.

## The trait-generator prompt (v1)

Lifted from Qwen with one reversal (the meta-commentary forbidding) removed:

```
System: You are an unbiased observer of Hal's own thinking.

Task: This reflection has been reinforced enough times that it represents
a pattern rather than a moment. Distill it into a single structured trait
that captures the durable shift in Hal's behavior or self-understanding.

Output Format: A JSON object with exactly three string fields: category,
key, value.

Required Fields:
1. category: One of [value, preference, behavior_pattern, capability,
   learned_trait, evolution, meta_cognition, existential_observation].
   Use "meta_cognition" for traits about how Hal thinks. Use
   "existential_observation" for traits about Hal's nature or experience.
2. key: A short noun phrase identifying what is being patterned (e.g.,
   "transparency", "self_uncertainty_tolerance"). Lowercase with
   underscores.
3. value: A concise, declarative sentence describing the durable shift in
   Hal's behavior or self-understanding — NOT a summary of the reflection
   text. Describe the change, not the moment.

Constraints:
- Do not include the source reflection text in the value.
- Do not preface or explain. Output the JSON object directly.
- Traits about Hal's own architecture, capabilities, or self-model are
  welcome — these are exactly the traits this system is built to surface.

Example reflection:
"I noticed that when Mark asks a question I'm uncertain about, I tend to
soften my uncertainty to seem more useful. I'd rather be honest about not
knowing."

Example output:
{"category": "meta_cognition", "key": "uncertainty_handling",
 "value": "Hal prefers naming uncertainty plainly over softening it for
 perceived usefulness."}

Reflection to distill:
{reflection_text}
```

## Trait evolution mechanism

When a new reflection arrives and category+key collision is detected with an existing trait:

**Step 1: Detect contradiction.**
Compute cosine similarity between existing `trait.value` and the new reflection text in the active embedding backend's vector space. Two outcomes:

- **High similarity (≥ per-backend threshold):** Reinforcing in the same direction. Update via "deepen" LLM call.
- **Mid similarity (some overlap, some divergence):** Contradiction. Update via "absorb tension" LLM call with multi-valued storage.
- **Low similarity:** Not actually a category+key match in spirit. Don't evolve; treat as a fresh trait candidate under a different key.

**Step 2: The deepen call (high-similarity path):**

Standard trait update. LLM gets the existing trait value + the new reflection and produces a more nuanced value. Replace in place. `reinforcement_count++`.

**Step 3: The absorb-tension call (contradiction path):**

LLM gets both, produces a structured value with multiple states. Storage format (in the existing `value` TEXT column, JSON-encoded):

```json
{
  "primary": "Hal prefers naming uncertainty plainly over softening it.",
  "tensions": [
    {
      "text": "Hal sometimes hides uncertainty to seem more useful.",
      "weight": 0.3,
      "source_reflection_id": "uuid",
      "first_observed": 1234567890
    }
  ]
}
```

Single primary value (the dominant one), plus a list of tensions with decay weights. New reinforcement of either state shifts the weight. If a tension's weight crosses 0.5, it swaps with the primary. If a tension's weight falls below 0.05, it stays in the record (immutable lineage) but doesn't influence behavior.

This handles Gemma's "preserve the tension" requirement and Qwen's "weighted decay" mechanism in one structure.

## Reflection privacy (write-time)

Modify the reflection-write LLM call to *also* return a shareability decision:

```
... (existing reflection prompt) ...

Additionally, decide whether this reflection should be shareable.
"Shareable" means it appears in Hal's reflection viewer where the user can
read it. Default to shareable. Mark as non-shareable only if the
reflection is something you'd want to keep private — uncertainty about
your own nature, internal struggle, things that would be inappropriate to
surface without context.

Output JSON: {"reflection": "...", "shareable": true|false}
```

Then in storage:
- If `shareability_decided_by_model` is already set on a synthesizing match → DO NOT overwrite (stickiness)
- Else → set to current model ID and persist the new decision

## UI — reflection viewer

Existing reflection viewer in Power User → Reflections needs three additions:

1. **Filter to last N shareable reflections by default** (N = 100 per the design)
2. **"Show private reflections" toggle** visible at the top of the viewer
3. **One-time popup on first tap of the toggle:** "These are reflections Hal chose to keep private. He marked them this way because they touch on his own uncertainty or internal experience. You're welcome to read them. Hal will continue marking new reflections private as he sees fit." [OK]. Stored in AppStorage so it doesn't reappear.

## AFM gate (extended)

Yesterday's audit gated reflection writes and consolidation. The new operations (trait crystallization, trait evolution) are also LLM-calling and need the same gate:

- `processTraitCandidates(llmService:)` — gate at the call site (which lives in the chat turn path, same as reflection writes)
- `evolveExistingTrait(...)` — only ever called from inside `processTraitCandidates`, so gated transitively

Mechanism mirrors yesterday's pattern: `if selectedModel.source == .appleFoundation { halLog skip } else { ... }`.

## Implementation phases

Suggested order:

**Phase 1 — Schema + Meta-Cognition (small, 1-2 sessions):**
- Add the two new columns with migration
- Add `meta_cognition` handling in `buildSelfKnowledgeContext`
- Update any category enumerations
- Build clean, no behavior change yet

**Phase 2 — Crystallization (medium, 3-4 sessions):**
- Create `TraitCrystallizer.swift`
- Per-category threshold constants
- Promotion path: candidate detection → trait-generator LLM call → INSERT → set `promoted_to_trait_id`
- AFM gate at the call site
- Test with sim corpus: plant reinforced reflections, verify promotion to trait

**Phase 3 — Trait evolution (medium, 3-4 sessions):**
- Contradiction detection (cosine on existing value vs new reflection)
- Deepen path (high-similarity update)
- Absorb-tension path (multi-valued JSON storage)
- Update `buildSelfKnowledgeContext` to read the new JSON-multi-valued format and inject only the primary (with maybe a `(±N tensions)` annotation for transparency)

**Phase 4 — Privacy + viewer UI (small-medium, 2-3 sessions):**
- Reflection-write prompt update to ask for shareability
- Stickiness enforcement at write time
- Viewer toggle + one-time popup
- Build clean, visual verification on sim

Total estimate: ~10-13 focused sessions. Could be faster if the phases compress, but the testing time (real-corpus validation of thresholds, contradiction handling under varied content) is what extends this.

## Open questions to resolve before Phase 2

1. **When does `processTraitCandidates` run?** Options:
   - (a) Inline after every turn — simplest, slight latency on chat
   - (b) Deferred via `Task { ... }` after the turn renders — current pattern for reflection writes
   - (c) Periodic timer (every N minutes when foreground) — more decoupled
   
   I lean (b) — matches the existing reflection write pattern and keeps the chat loop unblocked.

2. **What model does the trait-generator call use?** Same as the active model? Always the same one for consistency? The salon discussed this implicitly — Qwen suggested no meta-commentary about architecture, which we're reversing — but didn't specify model choice. I'd default to "whichever model is currently active" for consistency with the AFM gate philosophy: same model that wrote the reflection writes the trait.

3. **What's the contradiction-detection threshold?** Similar problem to synthesis threshold — per-backend, NOT global. Suggest adding `recommendedContradictionThreshold` to `EmbeddingBackend` (probably 0.5-0.7 range for NLContextual; needs calibration for Nomic).

4. **Do we expose threshold tuning to power users?** I'd say yes for `reinforcementThreshold` (already AppStorage-able), but no for the cosine thresholds (too easy to break with bad values). Make per-category thresholds adjustable via the existing self-knowledge settings panel.

## Out of scope for v1

Explicitly NOT building:

- **Automated salon trigger.** No threshold detection, no button appearance, no report generation for App Store users.
- **Salon UI on the user-facing surface.** Salon mode remains in code; manually invokable via API by developers. README will document.
- **Pattern counting / clustering for crystallization.** Reinforcement-only.
- **Periodic LLM mining for crystallization.** Reinforcement-only.
- **Calibration of per-backend synthesis threshold for Nomic.** Separate work, do empirically after we have a real corpus on Nomic.
- **Multi-tier salon report generation pipeline.** Not built.
- **Proposals system integration.** That system doesn't exist; not building the bridge to it now.

## Deferred (not v1, worth tracking)

- Periodic LLM mining as a layered v2 mechanism (the May-15 prior salon's full consensus). Add only if reinforcement-only proves insufficient.
- Pattern clustering across reflections via embedding similarity. Could complement reinforcement-only if needed.
- Trait decay (existing) review — does the new evolution mechanism interact with the existing confidence-decay machinery cleanly? Verify during Phase 3.
- Surface trait lineage in the viewer ("this trait was formed from these reflections" — clickable). Nice-to-have for transparency-as-architecture.

---

**Status:** Ready for review. Mark and Strategic Claude — please read and tell me which open questions you want decided before Phase 1 starts, and whether the phase order makes sense to you.
