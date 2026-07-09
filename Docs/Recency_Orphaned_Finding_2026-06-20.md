# Breadcrumb: the recency / age-decay scoring is ORPHANED (dead code)

> **✅ RESOLVED 2026-07-09.** Recency was reconnected at the RRF fusion in
> `searchUnifiedContent` via a multiply-blend by `recencyWeight`, and is now
> guarded by `tests/recency_regression.py` against silent re-orphaning.
> Device-verified on iPhone 16 Plus (old row decayed to 19.25% at
> weight 0.95; fresh row unchanged; fresh ranks above old). See HISTORY
> 2026-07-09. This doc is retained for the diagnostic record.

**Found 2026-06-20** (by CC, while studying Hal's memory model to port it into Posey).
**Revisit target (Mark):** around the model-sharing update.

## TL;DR

The recency / time-decay machinery you built is **wired at the UI but disconnected
from the live retrieval ranking.** It is not deleted — it is *orphaned*: the Settings
knobs still exist and still write their values, but nothing reads those values into the
ranking anymore. So recency currently has **zero effect on what gets retrieved** — the
only recency the model ever sees is a cosmetic `[3 days ago]` text label on each snippet.

This is almost certainly the result of a refactor of the retrieval path (the move to
RRF fusion) that dropped the one line that multiplied the recency weight into the score,
with no test asserting "recency still changes order" to catch the disconnect.

## Exact locations (all in `Hal Universal/Hal.swift` unless noted)

- **`calculateRecencyScore(...)` @ ~3005** — the half-life decay function. **Zero callers.**
  Verify: `grep -n "calculateRecencyScore" "Hal Universal/Hal.swift"` → only the definition.
- **The settings that feed it** (still live, still persisted, now inert):
  - `recencyWeight = 0.3`, `recencyHalfLifeDays = 90`, `recencyFloor = 0.15` (MemoryStore, ~@426–438)
  - The corresponding controls in the Settings screen (search `SettingsViews.swift` for
    "recency" — the UI is intact; that's why it *felt* shipped).
- **Where recency SHOULD re-enter but doesn't** — the RRF fusion @ ~2855–2856:
  ```
  if let r = sRank { rrf += 1.0 / (rrfKSemantic + Double(r)) }   // pure rank reciprocal
  if let r = bRank { rrf += 1.0 / (rrfKBM25 + Double(r)) }       // no recency multiply
  ```
  RRF combines semantic + BM25 by rank only. No time term is applied here or after.
- **The only recency that reaches the model** — a textual age label, @ ~2867–2868:
  ```
  let ageLabel = formatAgeLabel(timestamp: slot.timestamp)
  let labeledContent = "[\(ageLabel)]: \(slot.content)"
  ```
  `formatAgeLabel` (@ ~3021) renders "Just now" / "Yesterday" / "N days ago". The model
  can *read* freshness, but ranking is recency-agnostic.

## When you revisit

To bring recency back as an actual ranking factor, the clean spot is the RRF fusion
(@2855): blend a recency multiplier (or add a recency-ranked list as a third RRF input)
using the existing `recencyWeight` / `recencyHalfLifeDays` / `recencyFloor` settings, then
add a regression test that asserts a more-recent item with equal semantic+BM25 rank sorts
higher — so it can't silently orphan again.

(Posey deliberately does NOT port this — Posey is a document-scoped reading companion with
no temporal selfhood, so it uses no age label and no recency ranking. This finding is about
Hal only.)
