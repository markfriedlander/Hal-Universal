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

### Phase 2 (resume here) — TraitCrystallizer.swift + reinforcement-based promotion

Spec: `Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md`. Pre-decided:

  - Background task deferred via `Task { ... }` after render
  - Trait-generator uses active model (AFM gate enforces MLX-only)
  - Per-category reinforcement threshold (AppStorage-tunable)
  - Reinforcement-only mechanism for v1 (no pattern clustering, no
    periodic LLM mining)

Concrete work for Phase 2:

  1. Create `Hal Universal/TraitCrystallizer.swift`. Add to
     `sync_hal_source.sh` FILES array.
  2. Define per-category reinforcement thresholds (struct or
     constants). Starting values per spec: value=2, preference=3,
     behavior_pattern=3, capability=2, learned_trait=3, evolution=2,
     meta_cognition=4, existential_observation=4.
  3. Implement `processTraitCandidates(llmService:)` — the background
     task that runs after a turn renders. Scans reflections where
     `reinforcement_count >= category_threshold` AND
     `promoted_to_trait_id IS NULL` (not yet promoted).
  4. For each candidate: run the trait-generator LLM prompt (Qwen
     template, see spec section "The trait-generator prompt (v1)"
     — including the **reversal** of Qwen's "forbid meta-commentary"
     constraint).
  5. INSERT new trait. SET `promoted_to_trait_id` on source
     reflection(s).
  6. AFM gate at the call site in the chat path. Same pattern as
     yesterday's audit: `if selectedModel.source == .appleFoundation
     { halLog skip } else { Task { await ... } }`.
  7. Test path: write enough similar reflections to trip the
     threshold; verify trait gets created with correct lineage.

Should land as a single commit titled "Phase 2: TraitCrystallizer
+ reinforcement-based promotion". Build clean, verified on device.

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
