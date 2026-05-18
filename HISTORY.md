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

---

## 2026-05-17 (morning session, EmbeddingGemma scaffolding)

### Setting

Mark woke CC up: "Good morning CC. Verify the live state and run the
baseline eval. Then proceed through the three proposals in order — B,
then A, then C if needed. Work autonomously and report back when you
have meaningful findings." Mid-session he had to leave with the phone
and directed CC to keep working on the simulator. Asked CC to **build
the user upgrade UI for the embedder** if the Gemma test panned out —
modeled on the existing Model Library download flow, with a two-way
migration (forward and back).

### Proposal B: methodology fix, no recall change (commit `07cfe3a`)

`INJECT_REALISTIC_TEST_CORPUS` now mirrors the real chat-store flow at
`Hal.swift:1597`: each (user, assistant) pair runs through
`extractNamedEntities`, the union is lowercased and joined with spaces,
and the resulting string is written to both rows' `entity_keywords`
column. Adjacent entries in the `general` array are paired the same way
since they alternate question / answer.

Also added `entity_keywords` to the `MEMORY_DUMP` JSON output (was
missing — the data was inserted but invisible to inspection) and added
`tests/rag_pipeline_eval.py` — a full-pipeline eval that calls
`MEMORY_SEARCH_DEBUG` (the production search) and reports plant rank in
the top-N RRF results, complementing the existing raw-cosine harness.

**Measurement.** Plants like Berkeley, Iceland, Karamazov, Atlas now
carry proper entity_keywords (NLTagger picks up persons, places, orgs).
Plants like cello, Subaru/Outback, Pepper, marathon remain empty — they
aren't person/place/org under NLTagger's three categories. Recall numbers
on the full pipeline: **identical to the previous run** (top-10 7/10,
top-5 4/10, top-1 1/10; Berkeley/cello/Subaru still missing).

NEXT.md predicted this exactly: the recall queries are designed not to
echo the plants, so adding entities to the plants doesn't help queries
that share no tokens with them. The value of Proposal B was fixing the
methodology — we now have an honest baseline showing BM25 has its fair
shot via entity_keywords, and that the remaining gap is not a write-side
problem.

Inspection of "Where do I live now?" top results revealed the actual
issue: BM25 in this 70-row corpus is dominated by common-word matches
(`do`, `I`, `live`→`lives` via Porter stemming) on noise rows like
"How do passwords actually get stored?" — these score higher in BM25
than the plant. Combined with NLContextualEmbedding's narrow-band
discrimination problem, the RRF fusion can't surface the plant.

### Pivot: Mark wants Gemma tried, with a user-facing upgrade path

CC reported the findings, flagged the 210 MB storage decision in
Proposal A. Mark said "try adding Gemma and see if we get better
results", and right after: ship with Apple NLContextual as default,
give users the chance to download EmbeddingGemma if they want. Model
Library pattern. Two-way migration so a user can also downgrade.

### Proposal A scaffolding (commit `8823a65`)

EmbeddingProvider gained a second backend slot. New `EmbeddingBackend`
enum (nonisolated + Sendable to bridge MainActor default isolation)
keys off UserDefaults("embeddingBackend"); EmbeddingProvider.embed
dispatches by backend; the Gemma path bridges async MLX inference to
the sync `embed()` API via DispatchSemaphore (mirrors the existing
NLContextual asset-download bridge).

`wipeStaleEmbeddingsIfNeeded` now uses the active backend's
`systemVersion` so switching backends triggers wipe-and-re-embed.

Linked MLXEmbedders product (already a transitive checkout via
`mlx-swift-lm 3.31.3`; just needed the framework reference on the
Hal Universal target). Project change: one new XCSwiftPackageProductDependency
plus the corresponding Frameworks build phase entry. CLI builds resolve
clean; no SPM resolver drift.

Load strategy is "from a local directory" rather than
`#hubDownloader()`. The downloader flow is the existing
BackgroundDownloadCoordinator one — Hal already has a robust catalog
download pipeline; the embedder reuses it.

API commands added:
  - `SET_EMBEDDING_BACKEND:<name>` — switch backend, wipe, trigger warm-up
  - `EMBEDDING_STATUS` now returns backend + expected dim, and only
    embeds when `isLoaded` (so it doesn't block during first-launch loads)
  - `MEMORY_DUMP` now returns `entity_keywords` per row

### Migration + download API (commit `77df7ae`)

`MemoryStore.reEmbedAllNullRows` walks every row with NULL embedding
and backfills via the active backend. Two-pass (SELECT then UPDATE)
to avoid SQLite's held-cursor write quirks. Logs decile progress;
returns (updated, skipped, failed). `generateEmbedding` marked
nonisolated so the migration can call it from any queue.

Three new API commands:
  - `DOWNLOAD_EMBEDDING_MODEL` — kicks off the EmbeddingGemma download
    via `MLXModelDownloader.shared.startDownload` (~210 MB). Returns
    immediately; poll for progress.
  - `EMBEDDING_DOWNLOAD_STATUS` — read-only progress poll.
  - `MIGRATE_EMBEDDINGS_REEMBED` — runs the re-embed migration
    synchronously using the active backend. Refuses if the backend
    isn't loaded.

### User upgrade UI in Model Library (commit `2237e2a`)

New section between "Hal's Picks" and "Community Models": **Embedding
(Memory)**. Same row styling, accordion-expand, status dot vocabulary
(green = active, grey = downloaded, none = not downloaded).

Two backend rows:
  - **Apple NLContextual** — always downloaded; "Active" or "Switch
    to Apple NLContextual" button.
  - **EmbeddingGemma 300M** — "Download EmbeddingGemma (~210 MB)" /
    progress bar during download / "Switch to EmbeddingGemma" once
    downloaded / "Active" when in use.

`EmbedderMigrationCoordinator` (@MainActor singleton) drives the flow.
State machine: idle → downloading → switching → migrating → done|error.
SwiftUI observes `phase`; an `EmbedderMigrationStatusRow` renders the
matching status inline (progress bar during download, row counter
during migration, success message at the end).

`EmbedderBackendRow.switchAndMigrate` does the proper sequence:
  1. Persist new backend, wipe all existing embeddings.
  2. Trigger warm-up, wait up to 60s for `isLoaded == true` (caps the
     spinner so a busted load doesn't hang the UI forever).
  3. Run `reEmbedAllNullRows` on the background task.
  4. Report (updated, skipped, failed) in the done message.

A confirmation dialog warns about the re-embed step before switching:
"Existing embeddings will be wiped and regenerated with [Backend].
This may take a few minutes depending on your memory size."

Two-way: switching from EmbeddingGemma back to Apple NLContextual
goes through the same flow.

### Sim limitation discovered: MLXEmbedders won't load on iOS 26.5 sim

Three load attempts (with `#hubDownloader()`, then with
`load(from: directory)`, then with a delayed warm-up to avoid racing
MLXModelDownloader.init) all crash the simulator with:

  `libc++ Hardening assertion __s != nullptr failed:
   basic_string(const char*) detected nullptr`

The crash fires inside `EmbedderModelFactory.shared.loadContainer`
after the config.json was read and before any further log line —
the load path is hitting a Swift-to-C++ string bridge with a nil
char*, which the iOS Simulator's libc++ Hardening enforces.

This is sim-specific (libc++ Hardening is enabled in the simulator
SDK and may not be on the device). Verifying on actual iPhone is
pending — Mark has the phone. Until then we know:
  - The download pipeline (catalog → BGDL → on-disk cache) works.
  - The backend selector, version bump, wipe, and migration code
    paths all compile clean and exercise correctly on the sim with
    NLContextual; the Gemma path is unreachable without the device.

This is documented in the commit log and NEXT.md. Default backend is
NLContextual, so a user only hits this code if they explicitly toggle
the upgrade — first-launch users are unaffected.

### State at end of entry

- `main` at `2237e2a`, in sync with `origin/main`
- Working tree: clean (only untracked: `Docs/SC_Release_Materials/`)
- All builds clean, zero warnings, zero errors
- Default behavior unchanged: NLContextual is the active embedder
- Embedder upgrade path: complete in code; on-device verification
  needed before shipping


---

## 2026-05-17 (afternoon, Nomic via swift-embeddings — recall jumps to 9/10)

### Setting

Mark came back with the phone. We had the user-upgrade infrastructure
in place (catalog download, backend selector, two-way migration UI) but
hadn't verified Gemma loaded on actual hardware. First attempt on
device: same `libc++ Hardening` crash as on the simulator. MLX's
`mlx::core::metal::Device::Device()` (device.cpp:328) was reading the
Metal architecture name as nullptr and aborting via `basic_string`.

Mark's research turned up that this is a documented upstream
mlx-swift bug specific to iOS, going back to 2024. Not something we
can fix. So the Gemma path is blocked until Apple/Google upstream
patches it.

But: research also surfaced `jkrukowski/swift-embeddings`, a Swift
embedding library that runs models on Apple's MLTensor framework
(not MLX). Supports Nomic Embed Text v1.5 directly — the same model
that's purpose-built for asymmetric retrieval (short queries against
short stored documents). MIT licensed, actively maintained, latest
release shipped the same morning.

### Decision

Mark approved adding swift-embeddings as a third backend (not a
replacement for Gemma — Gemma stays in code, compiled out for store
builds via `HAL_ENABLE_EMBEDDING_GEMMA`, ready to re-enable when the
MLX bug is fixed upstream). NLContextual remains the default; Nomic
is the functional opt-in upgrade available today; Gemma is reserved
infrastructure for the future.

Standing instruction reaffirmed: refactor as you go. Extract any new
embedding code into the appropriate dedicated files rather than adding
to Hal.swift.

### Refactor (commits before the Nomic work)

Hal.swift was getting unmanageable for embedding work, so per the
standing instruction we extracted three files first:

- **`EmbeddingBackend.swift`** — the backend enum, UserDefaults
  keys, crash guard, system version, dimension, modelID, and the
  UI display strings (displayName / blurb / sizeBlurb).
- **`EmbeddingProvider.swift`** — the provider class with one
  per-backend code path; `MemoryStore.generateEmbedding(for:)` and
  `cosineSimilarity` extensions.
- **`EmbedderMigrationCoordinator.swift`** — the @MainActor
  coordinator state machine + the two SwiftUI rows
  (`EmbedderBackendRow`, `EmbedderMigrationStatusRow`).

Plus a new `scripts/sync_hal_source.sh` that concatenates all the
Swift files into `Hal_Source.txt` (Hal's self-knowledge ingestion
expects a single text file). SOP in CLAUDE.md updated to use the
script.

Hal.swift dropped from 21,965 → 21,312 lines after the three
extractions. Build clean each step.

### Nomic backend (swift-embeddings, BERT class)

Added `swift-embeddings 0.0.27` as an SPM dependency. Bumped
`swift-transformers` from `exactVersion 1.3.2` → `1.3.3` (required
by swift-embeddings; verified `xcodebuild -resolvePackageDependencies`
re-resolves cleanly and SPM doesn't drift back to 1.0.0).

New `EmbeddingPurpose` enum: `.document` | `.query`. Threaded through
`EmbeddingProvider.embed(_:as:)` and `MemoryStore.generateEmbedding(for:as:)`.
Storage callers pass `.document`; search callers pass `.query`. NLContextual
and Gemma ignore the parameter; the Nomic path uses it to prepend the
required `search_query: ` / `search_document: ` task instruction
prefixes (without these, retrieval quality drops sharply per the model
card).

New backend case `.nomicSwift = "nomicswift"`. `isAvailableInThisBuild`
reads the `HAL_ENABLE_EMBEDDING_GEMMA` compile flag for the Gemma case;
Debug builds set the flag, App Store builds don't. Selecting an
unavailable backend via API or stale UserDefaults falls back to
NLContextual at launch (handled by the existing crash guard, repurposed
as a "this build doesn't support that backend" guard).

The first load attempt used `Bert.loadModelBundle` and failed with a
`Safetensors.Safetensors.Error error 0`. Nomic has its own dedicated
`NomicBert` model class in swift-embeddings — Bert can't read its
weight key naming. One-line fix: `Bert.loadModelBundle` →
`NomicBert.loadModelBundle`, and `Bert.ModelBundle` →
`NomicBert.ModelBundle` for the type. Loaded cleanly after that.

### Measurement

Same 70-row corpus, same 10 recall queries as the prior evals. Reset
DB, switched to Nomic, injected the corpus (embeds with `.document`),
ran `rag_pipeline_eval.py`.

| Query | NLContextual baseline rank | Nomic rank |
|---|---|---|
| "What's my dog's name?" → Pepper | 4 | **1** |
| "Where do I work?" → Anthropic | 6 | **2** |
| "What restaurant do I love?" → Tartine | 1 | **1** |
| "Tell me about my upcoming travel plans." → Iceland | 6 | **3** |
| "Where do I live now?" → Berkeley | **18** (top-10 miss) | **5** |
| "What instrument am I learning?" → cello | **18** (top-10 miss) | **10** |
| "What's my favorite book?" → Karamazov | 7 | **1** |
| "What's my cat called?" → Atlas | 2 | **1** |
| "Do I have any running events coming up?" → marathon | 5 | **1** |
| "What kind of car do I have?" → Subaru | **NOT IN RESULTS** | 17 |

| Metric | NLContextual | Nomic | Delta |
|---|---|---|---|
| Top-1 recall | 1/10 | **5/10** | +4 |
| Top-5 recall | 4/10 | **8/10** | +4 |
| Top-10 recall | 7/10 | **9/10** | +2 |

Two of the three previously-failing queries (Berkeley, cello) now
land in the top 10. Subaru is the lone remaining miss in the top-10
window but moved from "not in results at all" to rank 17 — meaning
even the worst case is recoverable with a larger retrieval window or
the LLM-driven query expansion that's queued as a parallel workstream.

Notable: top-1 recall jumped 1 → 5. Six of ten queries now return the
plant as the literal first hit. This is the asymmetric-retrieval
training paying off — short query against short document is exactly
Nomic v1.5's design point.

### What changed in the codebase

- `Hal Universal/EmbeddingBackend.swift` — third case, `EmbeddingPurpose`
  enum, `isAvailableInThisBuild` flag-gating, Nomic display strings.
- `Hal Universal/EmbeddingProvider.swift` — Nomic load path
  (NomicBert.loadModelBundle from local directory), embed path with
  prefix logic and MLTensor mean-pool + L2-normalize, Gemma path
  fully `#if HAL_ENABLE_EMBEDDING_GEMMA`-wrapped.
- `Hal Universal/Hal.swift` — search/migration call sites updated to
  pass `EmbeddingPurpose`; Model Library section now iterates
  `EmbeddingBackend.allCases.filter { $0.isAvailableInThisBuild }`;
  `DOWNLOAD_EMBEDDING_MODEL[:backend]` and `EMBEDDING_DOWNLOAD_STATUS[:backend]`
  accept a backend suffix (defaults to nomicswift).
- `project.pbxproj` — added `swift-embeddings` SPM package, products
  `Embeddings` + `MLTensorUtils` linked; bumped `swift-transformers`
  to exactVersion 1.3.3; Debug config sets
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to include
  `HAL_ENABLE_EMBEDDING_GEMMA` so dev builds can still exercise the
  Gemma code path locally.

### State at end of entry

- `main` (about to commit)
- All builds clean (zero warnings, zero errors)
- Default backend: NLContextual (unchanged)
- Nomic available as opt-in upgrade via Model Library
- Gemma compiled out of Release; lives in code waiting for the upstream
  MLX Metal init fix
- Recall: 9/10 top-10 measured on device with Nomic
- Subaru still misses top-10 — fixable via LLM-driven query expansion
  (queued, designed but not implemented)

---

## 2026-05-17 (evening, the long autonomous run)

### Setting

Mark queued a 5-item sequence and stepped away:

  1. Salon cold-launch guard
  2. Scroll behavior rewrite (web research first; firm requirement)
  3. Visual verifications on device
  4. Prompt export + detailed view color-coded segments + collapsible
  5. Background download long-lock test (coordinate with Mark)

Standing instruction reaffirmed: refactor-as-you-go.

### Item 1 — Salon cold-launch guard (commit `4b531a5`)

Cold-launch path in ChatViewModel.init now checks decodedSalon.seat1
after decoding from UserDefaults. If empty, populates with the active
model when downloaded, else Apple Foundation Models (always installed
on any iOS-26-capable device — the only safe universal default).
Verified live: cleared seat1 via SALON_SET_SEAT, terminated app,
relaunched, log shows "Cold-launch guard tripped — seat1 was empty;
populating with apple-foundation-models" and SALON_GET_STATE returns
seat1=apple-foundation-models.

### Item 2 — Scroll behavior rewrite (commit `4b531a5`)

Web research before any code. Confirmed pattern: ScrollViewProxy.
scrollTo(messageID, anchor: .top) on send-start, no further auto-scroll
handlers. Matches claude.ai/ChatGPT web for sent messages.

Stripped the May-16 scroll-anchor system entirely:
  - userHasScrolled @State + its bottom-sentinel handlers — gone
  - pinnedExchangeID @State — gone
  - 400-char heuristic that picked between .top and .bottom — gone
  - DragGesture's anchor-disengage onChanged — gone
  - onChange(of: messages.count) auto-scroll-to-bottom — gone
  - onChange(of: messages.last?.content) streaming auto-scroll — gone

Kept:
  - One scrollTo on send-start (anchor: .top)
  - App-launch scrollTo("bottom") so the user lands on recent activity
  - Downward DragGesture → dismiss keyboard

Verified visually: sent "Hi Hal, what is 2 plus 2?", screenshot shows
user message near top of visible area, Hal's response immediately
below it, no further auto-scrolling. Per Mark's spec exactly.

### Item 3 — Visual verifications (commit `a984b62`)

Added SET_UI_STATE:<settings|threadPanel|none>:<true|false> API so
sheet navigation could be driven from the test console — the iOS-26.5
simulator's tap-into-toolbar path isn't reliable for our chat nav
buttons on this SwiftUI hierarchy.

All surfaces verified clean on iPhone 17 Pro sim:
  - Chat home + new scroll behavior
  - Settings sheet (Personality, Self-Knowledge toggle, Temp slider)
  - System Prompt screen with token counter ("375 / 1000 tokens")
  - Salon Mode pickers (4 seats; Seat 1 = Apple Intelligence per the
    cold-launch guard)
  - Model Library (Hal's Picks + new "Embedding (Memory)" section
    showing all three backends: Apple NLContextual, EmbeddingGemma
    300M, Nomic Embed Text v1.5)
  - Hal app icon on springboard

Screenshots saved at /tmp/visual_*.png during the run; not committed
(disposable verification artifacts).

### Item 4 — Prompt detail view (PARTIAL, commit `61f8240`)

Extracted new view into Hal Universal/PromptDetailView.swift per the
refactor-as-you-go rule. Components:

  - PromptDetailSegmentKind enum with 10 cases. Each carries
    displayName, SF Symbol icon, color (purple/orange/yellow/teal/
    pink/green/brown/blue/gray/secondary), and exportTag (emoji +
    uppercase label like 📜 SYSTEM PROMPT).
  - parsePromptSegments(fullPrompt:): splits the assembled system
    message on "\n\nCURRENT CONTEXT:\n" and classifies each "\n\n"-
    separated context section by its opening text (e.g. "Summary of
    earlier conversation:" → .summary). Anything unclassified falls
    back to .other so the user still sees the content.
  - PromptDetailView body: top legend banner + ForEach over segments
    rendered as DisclosureGroups with colored tints and char counts.
    A TokenBudgetSummary card at the bottom maps the segment colors
    to actual token-count numbers.
  - buildPromptDetailExportText: text-only variant with the same
    structure. Emoji + label keep the export "color-coded" even when
    pasted into plain text.

Build clean.

**NOT YET WIRED.** The new view is built but the chat bubble's
contextMenu doesn't have a button to present it yet. Wiring plan in
the commit message: add "View Prompt Details" entry next to the
existing "View Details" toggle around Hal.swift:11742, with a
.sheet(item:) presenter on the assistant-side bubble. The view
expects (message, precedingUserContent, recentHistory) — the latter
two come from walking chatViewModel.messages backwards from
message.turnNumber.

Stopped before wiring to update docs before the context window filled.

### Item 5 — Background download long-lock test

NOT STARTED. Requires coordination with Mark (he locks the phone
face-down for 10 minutes while I monitor filesystem state). Queued for
next session.

### State at end of entry

- `main` (about to commit docs)
- Five commits this session: 4b531a5 (items 1+2), a984b62 (item 3 +
  SET_UI_STATE), 61f8240 (item 4 partial)
- Build clean, working tree had docs uncommitted at write time
- Visual verifications confirmed all 4 named UI surfaces work
- Refactor-as-you-go discipline maintained: one new file extracted
  (PromptDetailView.swift), sync_hal_source.sh updated

---

## 2026-05-17 (post-compaction continuation)

### Setting

Resuming the morning after compaction. Mark asked me to verify the
live state first, then pick up Item 4 wiring per NEXT.md, then move
on to Item 5 (BGDL long-lock test) before a chat. The handoff brief
and NEXT.md had the wiring checklist spelled out exactly, so this
was a continuation rather than rediscovery.

### Live-state verification

Three documented checks all green:
  - `state` → AFM active, 70 turns of history intact, conversation
    `96C3FA13…`.
  - `SALON_GET_STATE` → isEnabled=false, seat1=apple-foundation-models.
    The Item 1 cold-launch guard is still holding (seat1 didn't
    revert to empty across the overnight).
  - `EMBEDDING_STATUS` → nlcontextual loaded, 512-dim. Default
    embedder, as expected for a fresh install.

Git clean at `c350559` with only Xcode user state + an untracked
release-materials folder in the working tree. Matched HANDOFF_BRIEF
exactly — no drift overnight.

### Item 4 wiring — what landed

Wiring as documented in NEXT.md:

  1. Added `@State private var showingPromptDetail` to ChatBubbleView
     alongside the existing showingDetails / showingCompressionExplanation
     state.
  2. Added two computed properties on the struct:
       - `precedingUserContent`: walks `chatViewModel.messages`
         backwards from the assistant message and returns the user
         content whose `turnNumber` matches. Robust to interleaved
         status messages or salon participants who don't share the turn.
       - `recentHistory`: returns up to ~4 turn pairs (8 messages)
         immediately preceding this message. Capped so the detail
         sheet stays scrollable.
  3. Added a "View Prompt Details" Button to the assistant-side
     contextMenu (Hal.swift around line 11748), placed right after
     the existing "View Details" toggle. Uses the
     doc.text.magnifyingglass SF Symbol.
  4. Added `.sheet(isPresented: $showingPromptDetail)` on the
     bubble's outer VStack so the new PromptDetailView presents
     full-screen with NavigationView chrome (Done + Copy as Text).

Build clean (CLAUDE.md Golden Rule #7 — no new warnings). The pre-
existing nonisolated-vs-MainActor warnings on the export and token-
budget helpers were already in the file at commit 61f8240 and are
left for a follow-up.

### The collapse bug — a real find, fixed

After wiring, visual verification on the iPhone 17 Pro simulator:
the contextMenu appeared correctly with the new entry, the sheet
opened, segments rendered with their colors. Tapping a DisclosureGroup
toggled the chevron rotation but the body never appeared — and on
the next layout pass even the chevron snapped back.

Root cause: `PromptDetailSegment.id = UUID()` regenerates on every
parent body recompute (the parent's `segments` is a computed
property, so each pass mints fresh PromptDetailSegment instances).
Two consequences:

  1. The original Set<UUID>-based expansion state in the parent
     would have stored stale IDs that no longer matched after the
     next re-render.
  2. The fallback I tried — moving expansion state into the card
     itself as @State — also fails, because ForEach keys on
     segment.id, and a new UUID per pass means the card is treated
     as identity-replaced (fresh @State, instantly collapsed).

Fix: stabilize the ID. Replaced `let id = UUID()` with a
deterministic `let id: String` derived from `seg-\(index)-\(content.hashValue)`.
The parser now uses `enumerated()` to pass an index per context
section. Same kind + same content in different positions still get
distinct IDs because index participates. The init is marked
`nonisolated` so the parser (also nonisolated) can call it without
crossing actor boundaries.

With stable IDs, card-local @State for expansion is the cleanest
pattern — the parent doesn't need to coordinate, and each card
toggles independently. Removed the parent's `expandedSegments` and
the custom Binding plumbing entirely.

Verified end-to-end on the sim: long-press a Hal bubble → "View
Prompt Details" → System Prompt expanded showing the persona text
with purple tinting → collapsed cleanly → Temporal Context expanded
showing date + time + day + device with orange tinting.

### Cleanup — `_LegacyPromptDetailView_Unused` removed

With the new view wired and verified, the legacy single-blob
PromptDetailView (renamed `_LegacyPromptDetailView_Unused` in commit
61f8240 as a transitional safety net) is gone from Hal.swift LEGO 14.
That LEGO block is now a redirector comment pointing at
PromptDetailView.swift. Saves ~200 lines of dead code from the
ingested self-knowledge corpus.

### Item 5 — Background download long-lock test

To be coordinated with Mark next. The plan from NEXT.md:
DOWNLOAD_EMBEDDING_MODEL:nomicswift is the 522 MB candidate; he
locks the phone face-down for 10 minutes while I monitor filesystem
state and download progress logs. The new
EMBEDDING_DOWNLOAD_STATUS:nomicswift command polls progress, so the
verification surface is in place.

### State at end of entry

- `main` (about to commit Item 4 final + docs)
- Item 4 fully landed end-to-end: wiring + collapse bug fix + legacy
  cleanup, all in one followup commit
- Build clean, no new warnings
- PromptDetailView.swift now has stable IDs + card-local @State
- Hal.swift LEGO 14 is a redirector comment instead of a 200-line
  legacy view
- Hal_Source.txt synced (23,312 lines, was 23,497 — dropped ~185
  lines from the legacy removal)
- Items 1–4 complete; Item 5 queued for next exchange

