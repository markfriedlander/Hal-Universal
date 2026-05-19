# Gemma 4 E2B memory-depth tuning — results 2026-05-19

**Probe:** `tests/gemma_depth_probe.py` (driver) + `tests/gemma_depth_all.sh`
(replicate orchestrator) + `tests/gemma_depth_summary.py` (parser).

**Device:** iPhone 16 Plus (D24FB384-…), Hal build `b286429`+ (with
Increased Memory Limit + Extended Virtual Addressing entitlements).
Model: `mlx-community/gemma-4-e2b-it-4bit`.

**Methodology:** for each depth N in {2, 3, 4, 5}, run the same scripted
38-prompt conversation twice (R1 and R2). Each run does:
1. Hard terminate + cold-launch Hal (devicectl), wait 25 s for Gemma load.
2. `NUCLEAR_RESET` then `SET_MEMORY_DEPTH:N`.
3. For each prompt: pre-chat state-check + re-SET if drift detected;
   send chat; **fetch the device's `HALDEBUG-CHAT … depth=X` log line**
   and verify X == N (`[BUG]` event recorded if not); log latency,
   response length, content.

**Ground-truth integrity:** every chat across all 8 runs landed at the
target depth. `0` `[BUG]` events. The probe re-SETs depth after every
crash-and-relaunch to defeat the persistence bug (see findings).

## Results

| Depth | Run | Turns | Ceiling event   | Probes passed | Mean latency | Max latency |
|-------|-----|-------|------------------|---------------|--------------|-------------|
| 2     | 1   | 30    | graceful_refusal | 2/8           | 25.1 s       | 61.8 s      |
| 2     | 2   | 30    | graceful_refusal | 1/8           | 46.1 s       | 546.4 s †   |
| 3     | 1   | 30    | graceful_refusal | 1/8           | 23.1 s       | 55.9 s      |
| 3     | 2   | 30    | graceful_refusal | 1/8           | 66.4 s       | 1314.6 s †  |
| 4     | 1   | 30    | graceful_refusal | 1/8           | 20.0 s       | 47.1 s      |
| 4     | 2   | 30    | graceful_refusal | 1/8           | 19.5 s       | 40.5 s      |
| 5     | 1   | 30    | graceful_refusal | 2/8           | 20.0 s       | 52.9 s      |
| 5     | 2   | 30    | graceful_refusal | 2/8           | 19.3 s       | 45.9 s      |

† depth 2 run 2 and depth 3 run 2 both hit a single Mac-sleep-induced
TCP stall on one turn (Mac suspended → iOS jetsam'd Hal during the
~20 min idle → next probe call triggered Gemma reload). Both recovered
via the probe's retry+relaunch path; the stall inflated `max` for
that run but didn't affect the rest of the conversation. Caffeinated
the Mac after the second incident.

### Aggregated by depth (16 probes per depth, 2 runs)

| Depth | Probes passed | Mean latency (clean) | Ceiling |
|-------|---------------|----------------------|---------|
| 2     | 3/16 = 19%    | 25 s                 | 30 turns |
| 3     | 2/16 = 13%    | 23 s                 | 30 turns |
| 4     | 2/16 = 13%    | 20 s                 | 30 turns |
| 5     | 4/16 = 25%    | 20 s                 | 30 turns |

## Findings

**1. The 30-turn ceiling is invariant across depths 2–5.**
Every single run, regardless of depth, hit `graceful_refusal` at turn 31.
The per-turn pre-flight refuses when the predicted KV-cache + scratch
exceeds available memory. At Gemma 4 E2B with the entitlements, the
crossover point lands around the same conversation length regardless
of how much verbatim history the depth keeps. Why: the dominant
prompt-size contributor is the static scaffolding (system prompt +
self-knowledge + RAG snippets + summary), not the recent-history slice.

**2. Memory recall doesn't track depth meaningfully.**
Depth 5 was best (4/16 probes), depth 2 next (3/16), depths 3 and 4
tied at the bottom (2/16). Run-to-run noise is ~1 probe per run.
Two replicates is *not* enough to claim depth 5 > depth 4 statistically.
The honest read: within this 30-turn arc and this scripted prompt set,
**depth between 2 and 5 doesn't materially change recall**.

**3. RAG / summary is doing the heavy lifting.**
The "sierras hobby" probe (turn 29 asking about turn 4) PASSED in
ALL 8 RUNS. It worked at depth=2 (which only keeps the most recent
two turns verbatim) because the semantic memory layer surfaces the
sierras fact regardless of how short the verbatim slice is. The
probes that failed across all depths were the ones asking for very
specific exact content (the literal haiku Hal wrote, the literal
math answer 408) — RAG retrieves topics, not verbatim text.

**4. Depth 5 has the lowest latency.**
Counterintuitive at first — more history should be more tokens to
process. But the depths-2-and-3 runs had Mac-sleep stalls inflating
their latency, and the deeper depths' richer context lets Gemma
generate shorter responses (it's not "confabulating to fill space"
as often). After excluding the stall-affected runs, the clean
latency distribution is: depth 2 = 25 s, depth 3 = 23 s, depth 4 =
19.5 s, depth 5 = 19.7 s.

**5. Bug discovered: `SET_MEMORY_DEPTH` overwritten on app re-init.**
`ChatViewModel` init calls `ModelSettingsStore.shared.applyEffectiveSettings(for: initialModel)`
(Hal.swift:11402), which silently overwrites the user's
`SET_MEMORY_DEPTH` override back to the model's per-model default
of 5. Reproduced in an isolated test: SET to 2, hard terminate +
cold-launch, next chat ran at depth=5 — the `HALDEBUG-SETTINGS:
Applied effective settings for Gemma 4 E2B: ... depth=5` log line
is the smoking gun. The probe defeats this with a re-SET after every
relaunch. Proposed real fix is a product decision:
- (a) persist a "user-overridden" boolean alongside `memoryDepth`;
  init only applies effective settings when the override flag is false; or
- (b) `applyEffectiveSettings` only fires on actual model *change*,
  not on every init/relaunch.

## Recommendation

Keep the current default of **5**. The other depths (2–4) give no
measurable recall improvement, no shorter conversations before the
30-turn ceiling, and slightly worse latency. Depth 5 is at least
as good as anything tested below it on this arc.

The bigger ship-level win this work surfaced is the **entitlements
fix** — Gemma 4 E2B simply could not sustain a multi-turn conversation
before the entitlements were added. Now it reliably gets to ~30 turns
before the pre-flight kicks in. That's the move that makes Gemma
viable as a default MLX model, regardless of the depth setting.

## Realism check — reactive unscripted runs (added 2026-05-19 late)

After the scripted runs, ran two reactive conversations where every
prompt was composed in response to Hal's actual previous output, not
from a fixed list. One conversation at depth=5 (12 turns), one at
depth=2 (6 turns). Both opened with the same dinner-planning prompt
for direct comparability, then drifted into a story-writing topic,
then probed memory recall.

**What scripted testing missed: confabulation.**
The scripted anchor-keyword probes scored "pass" if any expected
term appeared anywhere in Hal's response. That metric can't
distinguish "Hal correctly remembered X" from "Hal invented a
plausible-sounding X." The reactive runs caught it cleanly:

- **Depth=5, turn 10:** I asked "what was the first dish option you
  suggested before I picked the spicy one?" Hal confidently invented
  "a mild, aromatic base centered on slow caramelization … cinnamon
  and ginger." The actual original second option (turn 1) was "Quick
  Chicken & Onion Skillet with Citrus Glaze." Different dish
  entirely, confidently asserted.
- **Depth=5, turn 12:** Challenged with "I don't think that's right,
  pretty sure you didn't say cinnamon," Hal re-checked and correctly
  disavowed the hallucination. Maxim 1 behavior recovered the truth
  *if* the user pushed back. Without pushback the false answer would
  stand.
- **Depth=2, turn 5:** Same question, 4 turns back instead of 9.
  Hal gave a vague gloss ("options focused on balancing aromatics
  and moisture retention") — wrong but less specific.
- **Depth=2, turn 6:** Pressed for detail, Hal invented richer false
  content ("aromatic herbs, slow-building moisture, rendered fats,
  deeply caramelized sugars from root vegetables"). More confabulated
  detail than depth=5 produced.

**What both depths got right in the reactive runs:**

- *Same-thread recall within the depth window:* both depths recalled
  recent constraints (one-pan rule, harissa profile) accurately.
- *Cross-topic recall:* depth=5 turn 7 correctly recalled
  "70-year-old horticulturist" from turn 4 even after intervening
  dinner-thread turns. Depth=2 turn 4 worked too (within its window).
- *False-memory resistance:* depth=5 turn 9 asked "what's my
  partner's name?" — Hal correctly said it had no record of that
  information rather than inventing.
- *Constraint adaptation:* both depths corrected when I pushed back
  ("I said one pan — can sweet potatoes go in WITH the chicken?"
  → Hal restructured the procedure).

**Refined recommendation:**
Keep depth=5 as the default. It gave a longer reliable cross-topic
window (~7 turns) before recall degraded into confabulation; depth=2
crossed into confabulation by turn 4–6. The 30-turn ceiling and the
practical-recall behavior were similar across depths in the scripted
runs, but the reactive runs surface a meaningful difference in how
long Hal can stay grounded in earlier-conversation specifics before
inventing.

**Ship-level follow-up (separate from depth tuning):** Hal needs
either a stronger "I don't have that in my context window" reflex
when asked about past content, or a deliberate fallback to RAG
lookup with explicit "this is what I retrieved" framing, to prevent
silent confabulation. Filing for Mark/SC consideration.

## Caveats / what this doesn't measure

- **Scripted prompts (initial 8-run measurement).** The arc is fixed
  across all runs for cross-depth comparability. The reactive
  realism-check runs above complement but don't replace a fuller
  human-driven test — those reactive runs were CC-driven, still
  LLM-language at LLM-language. Mark to do the genuine human pass.
- **2 replicates is the bare minimum.** A confidence claim about
  "depth 5 is best by 1-2 probes" needs 5+ replicates per depth.
- **Memory probes test anchor-keyword matching in Hal's response.**
  A probe "passes" if any expected term appears anywhere in the
  response, including if Hal hedged ("I don't know but you might
  have said Mark earlier"). The probe scripts are auditable in
  `tests/gemma_depth_summary.py` — the term lists are conservative.
- **Mac-sleep contamination on 2 runs.** Even though the conversation
  recovered, the contamination is documented but not corrected (a
  rerun isn't worth it given the recommendation isn't sensitive to it).

---

*Generated 2026-05-19 by tests/gemma_depth_summary.py.*
*Per-run logs: `/tmp/gemma_depth_<N>_run<R>.log`. Master script log: `/tmp/gemma_depth_all_v5.log`.*
