# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-17 afternoon entry).

---

## What the next session should do first

1. **Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-17
   afternoon entry of `HISTORY.md`.** That's the full story on Nomic
   landing and the recall jump from 7/10 to 9/10.
2. **Verify the live state:**
   ```bash
   python3 tests/hal_test.py state                                       # responds
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"                      # backend=nomicswift or nlcontextual
   python3 tests/hal_test.py cmd "EMBEDDING_DOWNLOAD_STATUS:nomicswift"  # isDownloaded:true
   ```
3. **Decide which workstream to take next** (below).

---

## Workstreams ready to pick up

### A. LLM-driven query expansion (designed, not built)

**Why.** Subaru is the lone remaining top-10 miss with Nomic. Real users
will have queries with zero token overlap and weak semantic similarity
that Nomic alone can't bridge. LLM expansion gives every user (including
the AFM-default users who can't download an embedder upgrade) a
recall boost without any new model.

**Trigger threshold (concrete, picked from measured data).**
Trigger expansion when the post-RRF top-1 result satisfies:
```
top1.rrfScore < 0.020 AND top1.isEntityMatch == false
```
RRF's max single-list score is 1/(60+1) ≈ 0.0164. Both lists agreeing
yields ≈ 0.0328. The three failing queries (Berkeley/Subaru/cello pre-Nomic)
all sat at ≈ 0.0164 with `isEntityMatch=false` (semantic-only, no BM25).
The working seven topped at ≈ 0.0323 with `isEntityMatch=true`. The
0.020-plus-noBM25 gate separates them cleanly. Adjust based on real
usage data after shipping.

**Design.**
1. After hybrid retrieval, check trigger.
2. If tripped, ship the query + a structured prompt to the active LLM:
   "Extract 5-10 short related terms or concepts that might appear in
   stored memories related to this query. Output one term per line, no
   punctuation."
3. AFM: use `@Generable` for structured output. MLX: free-form, parse.
4. Append expansion terms to the sanitized FTS5 query:
   `(orig terms) OR (expansion terms)`. Re-run BM25, re-do RRF.
5. Cache by `SHA256(normalized query)` in SQLite. TTL: indefinite.
   Invalidate on model switch (different models extract different
   concepts).

**Constraints honored.**
- No hardcoded synonyms.
- No new dependency — uses the active LLM.
- Cached, so the same query doesn't re-trigger.
- Only fires on weak retrieval (the trigger gate).

**Critical AFM consideration.** AFM has a 4K window. Prompt + response
must stay tiny (~200 tokens total). Use `@Generable` with a length cap
of 10 terms per result.

**Where to extract this code (per the refactor-as-you-go rule).**
Probably a new file `Hal Universal/QueryExpansion.swift` plus extending
`searchUnifiedContent` with a hook. Don't add it to Hal.swift directly.

### B. Default-on Nomic for new installs (product decision)

**Why.** Recall is much better with Nomic and the user-facing UX is
already in place. Question: do we ship Nomic as the default OR as the
opt-in upgrade?

**Pro default-on.** 9/10 top-10 vs 7/10 is a real user-experience
upgrade. Users who never visit Model Library still benefit.

**Pro opt-in (current behavior).** 522 MB on first launch is a meaningful
download. Many users won't notice the difference between 9/10 and 7/10
in casual chat. Saving 522 MB matters for storage-constrained devices.

**Hybrid option.** Ship NLContextual default; gently surface the upgrade
recommendation after N chat turns when the user has accumulated enough
memories to benefit.

**Decision pending Mark.**

### C. Re-enable EmbeddingGemma when MLX-swift ships a fix

Track [mlx-swift issues](https://github.com/ml-explore/mlx-swift/issues)
for the iOS Metal device init nullptr crash. When fixed:
1. Bump mlx-swift dependency
2. Flip `HAL_ENABLE_EMBEDDING_GEMMA` into Release config too
3. Verify Gemma loads on device
4. Decide whether to keep both Gemma + Nomic or sunset one

---

## Cluster B remaining (visual + long-duration)

- **Salon UI Pickers**: visual verification on device or simulator.
- **System prompt counter**: visual verification.
- **Model Library UI**: visual verification of the new embedder section
  (now with 3 rows in Debug, 2 rows in Release).
- **App icon**: visual verification.
- **Background downloads long-lock test**: delete an LLM, start fresh
  download, lock phone face-down 10+ minutes, verify BGDL handles iOS
  suspension. Same flow now covers the Nomic 522 MB download — both
  use BGDL.

## Cluster C from May 16 (orthogonal to RAG)

- Structured-trait synthesis (Mark's decision: implement, design for
  inspectability so it can surface in a future Evolutionary Salon)
- Scroll behavior (Mark's decision: requirement — search SwiftUI examples
  on the web first, find a working pattern, adapt it)

## On deck

- Screenshots × 6 for App Store (the Model Library embedder section is
  now a clean feature to showcase)
- ASC metadata fills using `Docs/ASC_v2.0_Paste_Ready.md`
- `Docs/` consolidation (many per-session recovery/finding docs)
