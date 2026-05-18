# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-17 evening entry).

---

## What the next session should do first

1. **Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-18
   morning entry of `HISTORY.md`** (covers Phase 1 of v1 crystallization,
   the salon chronicle, and yesterday's late-evening deferred work),
   then `Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md` for the
   full spec.
2. **Verify the live state:**
   ```bash
   python3 tests/hal_test.py state                       # responds
   python3 tests/hal_test.py cmd "SALON_GET_STATE"       # seat1 filled
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"      # backend loaded
   curl ... DB_SCHEMA:self_knowledge                     # 22 columns including
                                                         # promoted_to_trait_id +
                                                         # shareability_decided_by_model
   ```
3. **Pick up Phase 2 of the v1 crystallization build (below).**

---

## Open work — in order

### Phase 4 (resume here) — Reflection privacy + viewer UI

Phase 3 complete: trait evolution + contradiction handling + multi-valued
storage all landed in four sub-commits (`773636d`, `46da6a0`, `f6e230a`,
`86ba310`). End-to-end v1 crystallization pipeline is structurally
complete and build-clean.

Phase 4 is the last v1 piece per the build spec:

  - **Write-time shareability decision via LLM.** The reflection-write
    prompt asks the model to decide whether each reflection is shareable.
    Default = shareable (privacy is an explicit gesture, not a
    fallthrough).
  - **Stickiness enforcement** via `shareability_decided_by_model` column
    (added in Phase 1). Once one model marks a reflection private,
    another can't override.
  - **Viewer UI updates**: "Show private reflections" toggle visible
    right where shareable reflections appear, with a one-time popup
    explaining the user is now seeing things Hal may have chosen to
    keep private.
  - **Bonus consideration:** the init seeds (transparency, mission,
    etc.) currently have `shareable=0` so they don't appear in the
    Self Model UI. Phase 4 should set them to `shareable=1` since
    they're public identity facts. Decide whether to fix in this
    phase or as a separate cleanup.

Spec section: "Reflection privacy (write-time)" in
`Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md`.

### Phase 2 (formerly the in-progress section, now retained for reference) — Live-test the crystallizer

Phase 2 code complete and committed. The reflection-to-trait
promotion engine is wired: `TraitCrystallizer.swift` + helpers
in `SelfKnowledgeEngine.swift` + chat-path wiring under the AFM
gate. Build clean, schema verified.

What's NOT yet verified end-to-end (deferred to organic use):

  - The full promotion path requires Hal on MLX with sustained
    conversation generating real reflections that accumulate to
    reinforcement_count >= 2. That happens during normal use, not
    synthetically.
  - JSON adherence from each of the four MLX models when prompted
    with the Qwen-derived template. We know Qwen wrote clean JSON.
    Gemma's salon answer used JSON-friendly output. Llama was more
    conversational — may need a follow-up prompt nudge.

**Live-test path:**
  1. Switch Hal to an MLX model (Gemma is the workhorse).
  2. Send conversation that produces 5+ user/assistant exchanges
     about a recurring topic (so reflection synthesis trips and
     reinforcement_count climbs).
  3. Watch logs for `HALDEBUG-CRYSTALLIZER` lines:
     - "No trait candidates this cycle" → nothing eligible yet
     - "Evaluating reflection X..." → candidate found
     - "Crystallized reflection X... → trait 'category/key'" →
       success path
     - "LLM proposed unknown category 'X'" → prompt may need nudge
     - "Could not parse trait-generator response" → JSON format
       failure (model-specific issue)
  4. After a successful crystallization, query the trait via
     `DB_SCHEMA:self_knowledge` + a SELECT for traits with
     promoted_to_trait_id NOT NULL (reverse lineage).

Once live-tested at least once, move on to Phase 3.

### Phase 3 — Trait evolution + contradiction handling

### Phase 3 — Trait evolution + contradiction handling

Spec: same doc, section "Trait evolution mechanism". The
mid-similarity / contradiction path is the architectural novelty.
Multi-valued JSON storage in the existing `value` TEXT column with
`primary` + `tensions[]`. `recommendedContradictionThreshold` on
`EmbeddingBackend` (NLContextual start 0.6, Nomic needs-calibration).

### Phase 4 — Reflection privacy + viewer UI

Spec: same doc. Write-time shareability decision via LLM, stickiness
enforcement via `shareability_decided_by_model`, "show private
reflections" toggle in viewer, one-time popup with the explanatory
copy from the spec.

---

## Other open items

### Item 6 — UI consistency sweep (deferred from yesterday)

Mark caught the Model Library mismatch (LLM rows vs embedding rows
— now fixed). The broader work is a sweep of the rest of the app
for similar mismatches. Concrete places to check:

  - **Settings sheet**: action buttons (Export Thread, Upload
    Document, etc.) vs. inline toggles vs. nav links — are they
    visually consistent?
  - **Salon panel**: seat picker buttons, model selection chrome.
    Different style from Model Library?
  - **Reflections viewer** (Power User): list row treatment.
  - **System prompt editor** sheet: button placement, save/cancel
    affordance.
  - **Document import flow**: progress indicators, success/error
    states.
  - **Compression-explanation popover**: visual weight relative to
    other in-chat affordances.
  - **NUCLEAR_RESET confirmation**: matches other destructive
    confirmations?

Approach: screenshot each surface, list mismatches, propose unified
targets (probably matching the plain-icon-+-text-+-color style the
Model Library now uses), get Mark's sign-off per surface, implement
surgically.

### Item 9 — Serial download queue indicator (flagged 2026-05-17 night)

When multiple downloads are tapped in succession, no UI indicator
that the additional taps registered. Looks broken. Adjacent to but
distinct from the Item-5-followup-a fix (single-download state
recovery after jetsam). Approach: investigate how `MLXModelDownloader`
queue is exposed to the UI; add a queue-position indicator or
"queued" pill on rows where `isDownloading` is false but the model
is awaiting its turn.

### Item 10 — Self-knowledge corpus visibility discrepancy (flagged 2026-05-17 night)

During the salon, the prompt budget log showed `selfKnowledge=44493`
tokens of corpus injected, but Mark reports Hal's UI shows no
self-knowledge entries. We've been nuking the DB during testing,
which makes this curious. Possible causes:
  (a) UI filter is `shareable=1` and the corpus is mostly non-shareable
  (b) The corpus includes ingested `Hal_Source.txt` self-knowledge that
      isn't surfaced in the user-facing viewer
  (c) Two different categories are getting injected vs. viewed
  (d) Something else

Approach: query `DB_SCHEMA:self_knowledge` + a SELECT-with-counts
query to see what's actually in the table by category and format.

---

## Workstreams from earlier sessions still ready to pick up

### A. Default-on Nomic for new installs (product decision, pending Mark)

Question raised after the gate landed: should Nomic be the default
embedder for new installs, or stay opt-in via Model Library? Per
Mark's earlier directive ("default stays as NLContextual. Nomic
remains opt-in via the Model Library. The 522 MB makes it unreasonable
as a forced default for new users") this is settled — Nomic stays
opt-in. Mark may revisit later.

### B. Re-enable EmbeddingGemma when MLX-swift ships a fix

Track [mlx-swift issues](https://github.com/ml-explore/mlx-swift/issues)
for the iOS Metal device init nullptr crash. When fixed: bump mlx-swift,
flip `HAL_ENABLE_EMBEDDING_GEMMA` into Release config, verify on device.

### C. Cluster C from May 16 (orthogonal to RAG)

- Structured-trait synthesis (implement with inspectability for the
  Evolutionary Salon)
- Scroll behavior refinement based on real-world usage of the new
  send-start-only rule

### D. On deck

- Screenshots × 6 for App Store
- ASC metadata fills using `Docs/ASC_v2.0_Paste_Ready.md`
- `Docs/` consolidation (many per-session recovery/finding docs)
