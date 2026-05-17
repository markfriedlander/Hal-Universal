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

---

## 2026-05-17 (RAG architectural rebuild — Commits A/B/C)

### Setting

Cluster B verification on May 16 night surfaced that RAG planted-fact
recall was failing on AFM and Gemma. The first instinct was to chase
the relevance threshold. Several rounds of diagnosis ruled that out:

- Built `MEMORY_DUMP`, `MEMORY_SEARCH_DEBUG`, `MEMORY_SIMILARITY_DEBUG`
  diagnostic APIs to see exactly what the pipeline was doing.
- Found that `NLEmbedding.sentenceEmbedding` produced cosine similarity
  scores in the 0.2–0.5 range for related content but 0.5–0.7 for
  question-shape false positives ("What kind of car do I have?" ↔
  "What's the deal with sourdough starter?" = 0.68). Noise floor was
  HIGHER than plant signal.
- Built `INJECT_REALISTIC_TEST_CORPUS` (70 rows: 10 planted facts + 50
  general turns) and `tests/rag_threshold_eval.py` (10 ground-truth
  recall queries, precision/recall at multiple thresholds).
- Confirmed: no threshold value works. At 0.25, 7/10 plants pass but
  with avg 26 noise rows passing too. At 0.50, zero plants pass.
- The historical "May 14 RAG verified" test only worked because the
  query happened to share a literal substring with the plant ("cat's
  name") — the LIKE keyword path carried recall; semantic was
  effectively dead since March (when the 0.75 threshold landed).

### Research before redesign

Rather than tune the wrong knob further, did systematic research on how
production conversational AI systems handle this problem. Findings:

- Apple's `NLContextualEmbedding` (iOS 17+, transformer-based, on
  Neural Engine) is the documented replacement for the older
  `NLEmbedding.sentenceEmbedding`. Was never used in Hal.
- Hybrid retrieval (BM25 + dense vector) with Reciprocal Rank Fusion
  is the industry-standard architecture (Elasticsearch, OpenSearch,
  Weaviate all ship it by default; Mem0 uses it). Dense-only: ~78%
  recall@10. Sparse-only: ~65%. Hybrid: ~91%.
- SQLite FTS5 ships on iOS with the `porter` tokenizer (English
  stemming) and built-in `bm25()` scoring. The current LIKE substring
  approach is a deliberate-rejection-less oversight, not a considered
  choice.

Strategic Claude approved the three-commit plan with simplifications:
- No migration infrastructure — wipe and start fresh
- No hash fallback — gone
- Remove the threshold UI entirely
- Move `verifyNarrative` to NLContextualEmbedding too (one system)

### Commit A — `67efc30` — NLContextualEmbedding everywhere

- New `EmbeddingProvider` singleton wraps `NLContextualEmbedding`,
  lazy-loaded on first use (asset download via `requestAssets` with
  DispatchSemaphore for synchronous first-call), warm-up triggered
  at app launch.
- `MemoryStore.generateEmbedding` delegates to the provider; returns
  empty array when model isn't loaded (callers tolerate it).
- `TextSummarizer.verifyNarrative` also moved to the provider; TF-IDF
  fallback retained for the case where the model fails to load.
- Removed `generateHashEmbedding` and the NLEmbedding revision-loop
  fallback. One embedding system, no junk fallbacks.
- `wipeStaleEmbeddingsIfNeeded` in `setupPersistentDatabase` checks
  `UserDefaults["embeddingSystemVersion"]`; if not 2, NULLs all
  embedding BLOBs on `unified_content` and `self_knowledge`. The
  next access re-embeds with the new model.
- New `EMBEDDING_STATUS` diagnostic API.

Result: plant scores jumped from mean 0.27 → 0.83. Plant recall
@ threshold 0.50 went 0/10 → 10/10. BUT noise also climbed to mean
0.88, so threshold-based filtering still doesn't separate signal
from noise; many plants still bury below question-shape false
positives.

### Commit B — `1550325` — FTS5 BM25 + Porter stemming

- New `unified_content_fts` virtual table (FTS5, `porter unicode61
  remove_diacritics 2` tokenizer).
- Triggers keep FTS in sync with `unified_content` on INSERT /
  DELETE / UPDATE. Backfill on first launch.
- `searchUnifiedContent` keyword path replaced: LIKE substring loop
  removed; FTS5 MATCH with `bm25()` scoring used instead.
- New `sanitizeFTSQuery` helper strips punctuation, lowercases, joins
  tokens with OR (FTS5 default is AND, which is too restrictive).
- Source_code rows excluded from BM25 path — Hal's source code is in
  `unified_content` for self-knowledge access, but its million-char
  size matches every common word under BM25 OR semantics and would
  dominate ranking on every query.
- Token-budget loop changed from `break` to `continue` on too-large
  snippets — prior behavior killed ALL retrieval if the top-ranked
  snippet was a big document.

Result: keyword matching now stems correctly ("dogs" → "dog", "running"
→ "run"). BM25 produces meaningful rankings. But the simple
score-combine path (still summing semantic + BM25 with recency boost)
doesn't separate signal cleanly because the scoring systems live on
incompatible scales.

### Commit C — `b6f964b` — RRF fusion + remove threshold UI

- `searchUnifiedContent` rewritten around two ranked candidate lists
  keyed by row id. Each retriever (semantic + BM25) returns its top
  50; their RANKS in those lists are what feed RRF.
- Reciprocal Rank Fusion: `rrf(d) = sum over each list L of 1/(60 +
  rank_L(d))`, k=60 (canonical). Documents that rank highly in BOTH
  lists win. Score scale becomes irrelevant.
- The `relevanceThreshold` filter in semantic loop removed — RRF
  doesn't need it.
- Settings UI "Similarity Threshold" slider deleted (replaced with a
  comment explaining the threshold-free retrieval).
- `relevanceThreshold` @AppStorage var retained for backward compat
  with per-model settings infrastructure; no longer affects retrieval.

Verified on 10 ground-truth natural-language queries against 70-row
realistic corpus:

  Plant in top 10 retrieved snippets: **7/10**
    Pepper #1, Anthropic #6, Atlas #2, marathon #5, Tartine #1,
    Iceland #5, Karamazov #7
  Misses: Subaru, Berkeley, cello — queries with zero surface-term
    overlap to the plant ("Where do I live now?" vs "house in Berkeley
    on Vine Street"). Pure semantic + BM25 can't bridge "live" →
    "Berkeley" without entity-aware indexing or a stronger embedding.

This is a massive improvement from the prior architecture where
semantic search was effectively dead and recall was carried by
literal-substring keyword matches.

### State at end of entry

- `main` ahead of `origin/main` by 6 commits (`67efc30`, `1550325`,
  `b6f964b` for the RAG rebuild; `f43b1e2`, `158dc15`, `b26ae8c` from
  prior work)
- All builds clean (zero warnings, zero errors)
- App on iPhone 16 Plus running build 5 with NLContextualEmbedding
  loaded (512-dim vectors)
- Three new diagnostic APIs: `EMBEDDING_STATUS`, `MEMORY_DUMP`,
  `MEMORY_SEARCH_DEBUG`, `MEMORY_SIMILARITY_DEBUG`,
  `INJECT_REALISTIC_TEST_CORPUS`
- New test harness: `tests/rag_threshold_eval.py`
- 3 plants out of 10 still don't reach top-10 for the harder queries
  ("Where do I live now?" needs entity bridging; that's follow-up
  work, not blocking)

### Threshold deletion + SC investigation (later same day, 2026-05-17)

Strategic Claude pushed back on the "model-strength limit" characterization
of the 3 RAG misses. Six directives:

1. Delete `relevanceThreshold` entirely — no variable, no AppStorage,
   no comment.
2. Show actual NLContextualEmbedding cosine scores for the 3 missed
   plants against their recall queries.
3. Verify NLTagger entity extractor is wired.
4. Research EmbeddingGemma as alternative.
5. Push everything.
6. No explanations of why things are hard; findings and proposals only.

**Commit `9712a87`** — `relevanceThreshold`/`similarityThreshold` deleted
end-to-end. Removed: MemoryStore @AppStorage var, DefaultSettings
constant, ModelSettings field + init/merge plumbing, all 6 per-model
defaults, ModelSettingsStore.K constant + serialize/deserialize,
snapshot/apply/restore plumbing in 3 sites, SET_SIMILARITY_THRESHOLD
API command, /state JSON output entry, settings-change dialogue
detection, NotificationName, debug-API JSON fields, doc comments.
Build clean.

**Commit `2e1bd26`** — `tests/rag_threshold_eval.py` committed (had been
untracked from when it was created during the diagnostic work).

**Investigation findings:**

*Actual NLContextualEmbedding cosine scores for the 3 missed plants:*

| Query | Plant | Plant rank | Plant score | Top-noise score |
|---|---|---|---|---|
| "Where do I live now?" | "house in Berkeley..." | **17** of 70 | 0.8033 | 0.8789 (imposter syndrome) |
| "What kind of car do I have?" | "2018 Subaru Outback..." | **48** of 70 | 0.7719 | 0.8691 (imposter syndrome) |
| "What instrument am I learning?" | "cello lessons..." | **13** of 70 | 0.8349 | 0.9025 (learn a new language) |

The plants ARE embedded with sensible semantic scores — they're just
not the highest-scoring rows. NLContextualEmbedding compresses scores
into a narrow band (0.69–0.91 across all rows), so question-shape
similarity from unrelated rows beats true semantic matches from
plants. The "model-strength limit" framing from the previous entry
was correct in conclusion but understated: this is a discrimination
problem more than a "no surface overlap" problem.

*NLTagger entity extractor: working in real chat path.* Verified by
sending a real chat turn ("My wife and I just bought a house in
Berkeley...") and then querying BM25 for the literal term "Berkeley" —
returns the plant with `isEntityMatch: true`. `extractNamedEntities`
fires at `Hal.swift:1597` in the `storeTurn` path. **But** the eval
corpus injection (`INJECT_REALISTIC_TEST_CORPUS`) bypasses this — it
passes `entityKeywords: ""` directly. So all 70 eval rows have empty
entity_keywords; the eval understated BM25's real-world contribution.

*EmbeddingGemma research:* 308M params, MTEB SOTA for open <500M
models (61.15 mean Multilingual v2). Matryoshka dims 768→128.
`mlx-swift-lm 3.31.3` (already in Hal's deps) ships `MLXEmbedders`
library; available on HuggingFace as `mlx-community/embeddinggemma-*`
variants. Same loading + macro pattern as Hal's existing MLX LLM
models. No direct head-to-head benchmark vs NLContextualEmbedding
on short conversational content — would need to run through the
same eval harness to measure.

*Three proposals submitted, no implementation started:*
- B: Re-run eval with corpus injection that populates entity_keywords
  (fair baseline for BM25 contribution)
- A: Add EmbeddingGemma as alternative EmbeddingProvider backend, A/B
  measure against NLContextualEmbedding
- C: Entity-aware query expansion (orthogonal to A and B)

Recommended order: B → A → C.

### State at end of entry

- `main` at `2e1bd26`, in sync with `origin/main`
- Working tree clean (only untracked: `Docs/SC_Release_Materials/` which
  has been untracked all along, not part of any planned commit)
- Eval harness committed and pushed
- threshold sites: zero remaining in code
- Context low — next session needed for implementation work
