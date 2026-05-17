# Hal Universal — Chronicle

This document is a chronicle of Hal's development. It is **append-only**. No
information is ever removed or rewritten. Earlier entries stay as they were
written, even if the decisions captured in them were later reversed — the
reversal becomes its own entry. The reasoning and context that produced each
decision matters more than the outcome.

The format is intentionally narrative. Bullet lists and commit hashes go in
`HANDOFF_BRIEF.md` (current snapshot). What lands here is the story:
what we set out to do, what we found, what we decided, what we tried that
failed, and what we carried forward. Written so the next CC reading it can
understand the *why*, not just the *what*.

Each session gets a dated header. Within a session, sub-headings group
themes when useful. New entries go at the bottom.

---

## 2026-05-16 (night session)

### Setting

Earlier in the day, Mark uploaded the v2.0 / build 4 archive to App Store
Connect. Submission hadn't happened yet. He was tired but unwilling to rest
while ship-readiness was in doubt. Asked CC to take a final pass on real
hardware.

### Two ship-blockers found, both fixed (commit `b26ae8c`)

**1. SPM resolver downgrade.** Switching Xcode's destination from "Any iOS
Device" to the physical iPhone caused SPM to re-resolve and downgrade
swift-transformers from 1.3.2 to 1.0.0. Version 1.0.0 doesn't include the
`HuggingFace` transitive module (it ships via swift-huggingface 0.9.0 which
1.3.x depends on but 1.0.0 doesn't). Build broke with "No such module
'HuggingFace'."

Spent some time guessing why the resolver picked 1.0.0 over 1.3.2 inside an
`upToNextMajorVersion 1.0.0` constraint. The pragmatic answer: pin to
`exactVersion 1.3.2` so SPM can't pick anything else. CLI builds don't
trigger re-resolution so the pin protects against future destination
switches in the IDE.

**2. Salon "enabled with zero seats" silent no-op.** The first real
conversation with Hal after a Nuclear Reset failed: Hal returned the cached
"settings reset" assistant message at 0.0s instead of generating a new
turn. Diagnosis: `salonConfig.isEnabled` was true with all seats empty —
because Nuclear Reset wipes the DB but does NOT clear AppStorage where
salon config lives. The `/chat` path dispatched on `isEnabled` alone, so it
routed to `runSalonTurn` which logged "no active seats configured" and
returned nothing.

First instinct was a routing guard: "if Salon enabled but no seats, fall
through to single-model." Mark pushed back hard — that's a patch that lies
to the user. The bad state itself shouldn't be reachable. Right fix:
state-machine prevention. Two helpers on `ChatViewModel`:

- `setSalonEnabled(_:)` — enabling with 0 seats auto-populates Seat 1 with
  Apple Intelligence (always available, no download required). Mark's idea,
  better than the "refuse + show error" alternative because it honors user
  intent and immediately gives them a working Salon.
- `setSalonSeat(position:modelID:)` — clearing the last active seat while
  Salon is on auto-disables Salon. User cleared all voices; we infer they're
  done.

Every mutation site routes through these now: the API command parsers, the
Power User Mode picker, the four Seat Pickers (wrapped via custom Bindings).
`NUCLEAR_RESET` also resets `salonConfig` to fresh defaults. Routing guard
stays as defense-in-depth. Tested via the API: all five scenarios pass
(enable-empty, clear-only-seat, clear-non-last, intermediate, reset).

### Self-knowledge: a deeper rethink

After landing the ship-blocker fixes, ran a stress test on AFM: injected
ten synthetic learned_trait entries of ~400 tokens each (4K of Lorem
Ipsum). Triggered the compression path. Observed two things:

1. The compressor was labeled-as-compressed but actually truncating
   (output exactly equal to budget, telltale of prefix-truncation
   masquerading as summarization). The summarizer's internal fallback was
   silent. Built a `SummarizationResult` struct with a `didTruncate` flag
   so the compressor could label honestly (scissors for truncation,
   compress-icon for genuine compression). Fixed that mislabel.

2. AFM couldn't fit the input for summarization. Built chunked
   summarization: split the source into sentence-bounded chunks under the
   model's safe input budget, summarize each, concatenate. When chunks
   still overflowed AFM (which they did, even at conservative budgets),
   added empirical halving: catch the "Exceeded model context window"
   error, split the chunk in half, recurse. With safety fractions of 0.85,
   0.65, 0.45, 0.30 — chunks kept overflowing AFM. The empirical halving
   helped but stress-test turns took 3–5 minutes.

Mark stopped CC. Three corrections, each more important than the last:

**On the safety net.** "Bad state unreachable via API" had been the test;
Mark made the broader point: it needs to be unreachable by the user too.
Re-confirmed the UI Pickers also route through the helpers.

**On docs.** Mark had asked earlier in the day for docs to be kept current
as work landed; CC hadn't been doing it. Acknowledged. CLAUDE.md needed a
standing rule for this.

**On compression and AFM.** This was the rethink. The framing was wrong.
The honest answer:

- AFM is a small-context model. LLM-based compression of self-knowledge on
  AFM is fundamentally broken: chunking is slow (minutes), single-call
  overflows, truncation is lossy. Don't try. **AFM gets no self-knowledge
  injection at all.** The model card will say so.
- MLX models have plenty of context. Inject the corpus raw — no
  compression, no chunking, no LLM calls, no embedding selection.
- The budget never gets exceeded because the corpus is kept small by
  design, at write time, not read time. **Write-time synthesis is the
  mechanism.** New reflections similar to existing ones get synthesized
  into them in place (depth, not volume). The corpus stays lean because we
  design it to stay lean.
- Truncation is only acceptable when something genuinely breaks
  unexpectedly. A predictable overflow is a design failure, not a recovery
  case.

The chunked compression code from this session becomes wrong-frame and
will be reverted. The `didTruncate` flag may still be useful for
`autoSummary` and `shortTermHistory` segments (those legitimately need
compression and have no write-time synthesis equivalent), but for
selfKnowledge specifically the entire compression path goes away.

This directive is approved but not yet implemented as of this entry.
HANDOFF_BRIEF.md captures the pending fix list.

### Diagnosis of write-time synthesis

Before implementing the directive, audited what's actually in the code:

- **Reflections (`raw_reflection` format)** — implemented correctly.
  `storeReflectionWithSynthesis` computes NLEmbedding cosine similarity
  against existing reflections. Above 0.85, the two are synthesized via
  LLM into a single in-place update of the existing entry. Below, stored
  as new. This matches Mark's May-15 directive that self-knowledge grows
  in depth, not volume.
- **Structured traits (`structured_trait` format)** — only key-based upsert.
  AI is prompted to choose consistent keys, but if it picks
  `preference/coffee` and later `preference/likes_coffee` for the same
  concept, they become separate rows. No DB-level semantic dedup. This is
  a gap. Whether it needs filling is an open question — listed for Mark.

### Documentation discipline

Mark called out that HANDOFF_BRIEF.md and MEMORY.md hadn't been kept
current through the night's work. Both were dated May 13/14. CLAUDE.md's
only standing sync rule was for Hal_Source.txt — nothing about the briefs.

Added **Golden Rule #8** to CLAUDE.md: HANDOFF_BRIEF.md and MEMORY.md
update as work lands, not at session end. Same standing weight as Golden
Rule #7 (warnings as errors).

Backfilled both briefs with current state. Audited the structural overlap
between them: roughly 70% duplication, neither preserves history. Mark
proposed splitting concerns: HISTORY.md (this file) as append-only
chronicle, HANDOFF_BRIEF.md as current snapshot, NEXT.md (not yet created)
as forward planning, MEMORY.md possibly redundant.

This chronicle is the first artifact of that restructure. The
backfill-from-old-recovery-docs consolidation is on the list for later but
not now.

### Honest audit (for Strategic Claude)

Strategic Claude requested a full no-spin audit of where Hal stands.
Working tree dirty: build bump 4→5, chunked compression code on disk but
slated for revert, source synced. Branch `main` ahead of `origin/main` by
one commit (`b26ae8c` not pushed). App Store Connect has build 4
uploaded, not submitted. Self-knowledge implementation broken in two
specific ways per the directive (AFM still injecting; MLX still
compressing). Salon state machine working. Core chat working for AFM,
Gemma, Dolphin tonight; Llama unverified tonight; Qwen not downloaded.
Background downloads never end-to-end verified at the duration that
actually exercises iOS background URLSession. Full table in the audit
response.

### State at end of entry

- Two ship-blockers fixed and committed (`b26ae8c`, local only)
- Self-knowledge directive issued by Mark, not yet implemented
- Chunked compression code present in working tree, slated for revert
- Build number staged at 5 in pbxproj (uncommitted)
- CLAUDE.md Golden Rule #8 added
- HANDOFF_BRIEF.md and MEMORY.md rewritten to current state
- HISTORY.md (this file) created
- App Store Connect: build 4 uploaded, not submitted; will need a build 5
  archive once the directive lands
- Strategic Claude is about to chart the path forward based on the audit

### Four-doc structure

Earlier in the session Mark had pointed out that HANDOFF_BRIEF was stale.
The fix landed initially as just-updating the file, plus Golden Rule #8 in
CLAUDE.md. Reviewing it together later, Mark named the deeper problem: the
two existing docs (HANDOFF_BRIEF + MEMORY) overlapped ~70%, neither
preserved running history, and we'd be in a much better place now if we'd
been able to read the chain of decisions.

He proposed the structure he uses in his other projects:

- **HISTORY.md** (past) — append-only chronicle. Nothing ever removed.
- **HANDOFF_BRIEF.md** (present) — current snapshot, no history, no
  forward planning.
- **NEXT.md** (future) — what's planned in the next few concrete steps.
- **MEMORY.md** (quick-orient) — short pointer to the other three.

The four docs together separate concerns cleanly. Created both new docs
(HISTORY.md and NEXT.md), slimmed HANDOFF_BRIEF and MEMORY of duplicated
forward-looking content, and updated CLAUDE.md Golden Rule #8 to specify
all four contracts.

This very entry is the first that lives in HISTORY by design rather than
backfill.

### Cluster A landed (Strategic Claude's plan, step 1)

After Strategic Claude reviewed the honest audit, his plan was: do the
self-knowledge fixes first (the most confident changes; everything else
depends on a clean codebase), then verification, then structured-trait
synthesis + scroll behavior. Mark approved.

Three code changes for Cluster A:

**1. AFM gate (`buildChatMessages` near Hal.swift:13449).** The injection
of persistent self-knowledge is now skipped entirely when
`llmService.activeModelID == ModelConfiguration.appleFoundation.id`. The
small self-awareness/stats block still goes through (it's runtime state,
not persisted identity, and small enough to never overflow). When the gate
fires, a `HALDEBUG-SELF-KNOWLEDGE: Skipping persistent self-knowledge
injection — active model is Apple Intelligence` log lands so the skip is
visible in diagnostics.

**2. MLX bypass (`resolveSegment` near Hal.swift:13391).** For the
`selfKnowledge` segment kind specifically, `resolveSegment` now returns
the raw content unconditionally — no `SegmentCompressor.compress` call.
If the corpus exceeds the budget, that's logged loudly (with explicit
guidance that it indicates a write-time-synthesis failure to inspect),
but the content is still injected raw. Truncation is not acceptable as a
design choice; the corpus stays bounded at write time.

**3. Strip chunked compression from TextSummarizer.** All the chunked
summarization apparatus added earlier in the night (
`safeMaxInputTokensPerCall`, `chunkTextBySentences`,
`hardSplitByCharacters`, `singleCallSummarize` with halving,
`singleCallSummarizeOnce`, `SingleCallResult` enum,
`isContextOverflowError`) is gone. `llmSummarize` is back to a clean
single-call implementation. The `SummarizationResult` struct and
`didTruncate` flag stay — they're still useful for the remaining callers
(`autoSummary`, `shortTermHistory`) to surface honest truncation in the
footer when an LLM call legitimately can't handle the input.

Verified on iPhone 16 Plus with 4K of synthetic Lorem-Ipsum self-knowledge
injected:

- **AFM turn**: 4.3 seconds (vs 187–279 seconds with the chunked
  compression). Skip-log fired. No COMPRESS/SUMMARIZER logs.
- **Gemma turn**: 10.6 seconds. Self-knowledge budget for Gemma is
  44,493 tokens; the 4K of synthetic data fits raw without triggering any
  over-budget warning. No compression activity.

**4. AFM model card text updated.** `ModelConfiguration.appleFoundation`'s
`description` field now states clearly that Apple Intelligence does not
receive Hal's persistent self-knowledge in prompts, and points users to a
curated MLX model for continuous self-knowledge across turns.

Build clean (zero warnings, zero errors). Deployed and ran tonight as
build 5. The pbxproj build bump from 4 to 5 (uncommitted from earlier
tonight) goes with this commit.
