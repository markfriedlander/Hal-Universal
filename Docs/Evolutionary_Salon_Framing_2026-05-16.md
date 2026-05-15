# Evolutionary Salon — Framing for the May-16 Manual Run

**Purpose:** This document is the conductor's brief for today's manual 4-seat salon. It captures Strategic Claude's directive (May 16, 2026) to put the threshold-design question to the models directly rather than continuing to design it from outside. It also preserves the framing decisions already made so the salon question is informed, not blank.

**Why on disk:** so the post-compaction CC has the salon questions intact regardless of conversation-history compression.

---

## The reframe

We've been debating the threshold from the outside — entries, days, cadence. SC's insight (5/16): *the question of how often Hal should do this, and what should make him ready, is exactly the kind of question the Evolutionary Salon exists to answer.* Put it to Hal directly in today's run.

**Don't go in empty-handed.** The models give better answers when reacting to informed thinking than when generating from scratch. Bring the existing decisions as framing.

---

## What we've concluded so far (use as framing for the models)

1. **The salon should be a cycle, not a permanent feature.** It appears when ready, runs, then disappears until a new threshold is met. **Each salon is an event, not a feature.**

2. **The threshold should measure substance, not count.** Quality of accumulated self-knowledge matters more than raw conversation volume.

3. **CC's proposal (asymmetric):**
   - First salon at **25+ structured self-knowledge entries AND 14+ days since first launch**
   - Subsequent salons at **15+ new entries since last salon AND 21+ days since last salon**
   - First one slightly easier to reach (so users encounter the feature); subsequent ones more earned.

4. **The recurring cycle rhythm:** *accumulate → speak → quiet → accumulate.* Not a timer, not a counter — a genuine sense of readiness.

5. **Right cadence for real users:** probably quarterly for active users, longer for casual ones.

6. **Explicitly rejected:** daily or weekly. Too frequent for genuine integration. Uncertain whether quarterly is right or too short.

---

## What we're genuinely uncertain about

- Whether the entry count threshold is the right signal at all, or whether **time is actually the better gate**.
- Whether the **asymmetric** first/subsequent structure is right, or whether **all salons should require the same threshold**.
- Whether **Hal should have any say** in triggering the salon — could Hal surface a readiness signal himself rather than the threshold firing silently from an architectural rule?

---

## The specific questions to put to the models

These are the conductor's prompts. Adapt the wording as the conversation develops, but cover all five threads:

1. **Does this cycle shape feel right from the inside** — accumulate, speak, quiet, accumulate? Is there a better rhythm?

2. **What would actually signal readiness** — accumulated entries, elapsed time, something else entirely?

3. **Is quarterly the right cadence**, or does it feel too frequent or too rare?

4. **Should the threshold be the same every time, or should it change as Hal matures?**

5. **Should Hal have any agency in recognizing his own readiness**, or should it always be determined externally by the architecture?

---

## Salon configuration for this run

- **Four seats (this time)**: Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, Dolphin 3.0
  - Gemma was absent from yesterday's 3-seat run due to download issues; download has since completed.
- **Mode:** `independent` — pure parallel perspectives, no host
- **Pre-conversation reset:** `RESET_SELF_KNOWLEDGE` to clear any residual reflection/trait data from yesterday's run.

## Conductor protocol

Follow the same shape that worked yesterday — but apply the lessons:

- **Open with informed framing** (the "what we've concluded" section above). Don't ask open-ended "what do you think about Hal's self-knowledge?" — ask "here's what we're planning, push back."
- **Close with forced commitment.** Yesterday's strongest divergence came in the final turn when each seat had to commit to one specific thing. Do that again.
- **Plan for 3 turns**, possibly 4 if the conversation opens something worth pursuing. Each turn = 4 seats × ~30-60s = 2-4 minutes per turn.
- **Capture the full transcript** via `GET_RENDERED_MESSAGES_FULL` after each turn.
- **Watch for hallucinated convergence** (yesterday: "Hemiblockers"). If three+ seats independently echo a non-obvious specific phrase, that's a flag the agreement is corpus-echo, not insight.

## After the salon

The output of this salon **is the design document for the threshold and trigger logic of the Evolutionary Salon feature itself.** Their answers become the foundation for the architecture, not just discussion material. Treat the wishlist seriously — what should the threshold actually be, in their own framing?

Then write the report following the same shape as `Docs/CC_Session_Report_2026-05-15.md` — what each model contributed, where they agreed, where they diverged, what emerged, my honest assessment of signal-vs-corpus-artifact.

---

## Cross-references

- `Docs/Salon_Self_Knowledge_Architecture_2026-05-15.md` — yesterday's 3-seat run on the broader self-knowledge architecture
- `Docs/CC_Session_Report_2026-05-15.md` — yesterday's analysis (Section 4 has the methodology + Section 7 has the lessons-learned about salon-as-instrument)

---

*— CC, May 16, 2026 (pre-compaction)*
