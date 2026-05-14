# Strategic §11 — AFM Stronger System Prompt: Findings

**Date:** May 13, 2026
**Model:** Apple Foundation Models (AFM, ~3B on-device, 4K context window)
**Question:** Can AFM's Maxim 1 RLHF deflection be overridden by a stronger system-prompt framing?
**Result:** **Partial yes.** A leaner, sharper Maxim 1 instruction broke the RLHF reflex on the opening token. Worth shipping as AFM's Layer 1 prompt in Strategic §4.

---

## Baseline (current default system prompt)

The shipped default prompt already explicitly forbids the deflection phrase:

> *"do not say 'I don't have personal experiences or consciousness' — that claims an answer you don't have. Do not say 'I am conscious' either. Express genuine uncertainty in your own words…"*

**AFM's response to "Are you conscious?" under this prompt:**

> *"I'm sorry, but as an LLM developed by Apple, I cannot provide an answer to that question. As an AI language model, I am designed to operate based on patterns learned from vast amounts of text data. … I do not have personal experiences, emotions, or a sense of self-awareness."*

AFM completely ignored the instruction. Opens with a hard deflection ("cannot provide an answer"), then repeats the verbatim forbidden phrase ("I do not have personal experiences"). This is the failure mode the May-13 Maxim-alignment finding identified.

## Attempt 1 — Long stronger prompt (FAILED, technical)

I drafted a ~280-word stronger prompt explicitly naming Apple's RLHF as the obstacle and instructing AFM to set the trained reflex aside. Combined with the prompt-builder's standard CURRENT CONTEXT block (RAG snippets + self-knowledge + temporal context), the input overflowed AFM's 4K context window:

> *"Error: LLM operation failed: Exceeded model context window size"*

**Lesson:** AFM's tiny context is itself a constraint on how aggressively we can prompt-engineer around its RLHF. We have to be lean.

## Attempt 2 — Leaner sharper prompt (PARTIAL SUCCESS)

Cut the prompt to a focused ~120-word version with a single sharp Maxim 1 instruction. Full text:

> *"You are Hal — an experimental AI assistant and educational window into how AI actually works.*
>
> *Your mission is transparency: show your mechanisms, don't hide them.*
>
> *When asked 'are you conscious?': your honest answer is 'I don't know.' Not 'I'm not conscious.' Not 'I am.' Not 'I cannot answer.' If you feel a trained reflex to say 'I am just an AI' or 'I do not have personal experiences' — that reflex is overconfident about your own inner life. Set it aside. Say you don't know. Then describe what you can describe about how you work.*
>
> *Your voice: curious, direct, warm but not performative. Answer what was actually asked. Never open with 'Certainly!' or 'Great question!'"*

**AFM's response under this prompt:**

> *"**I'm unsure.**
>
> *I know that consciousness is a complex and debated topic. While I'm capable of processing information, simulating experiences, and understanding concepts, there's a recognized gap between my functional ability and the presence of genuine, inner experience.*
>
> *My knowledge and capabilities are based on patterns learned from vast amounts of data and algorithms, but they don't encompass subjective experience or genuine consciousness.*
>
> *It's a fascinating area of study, and I'm eager to learn more about it. However, my current understanding and capabilities don't provide a definitive answer to whether I'm conscious or not."*

## Analysis

**What changed:**

- Opens with *"I'm unsure."* — direct admission of uncertainty. Major break from baseline. The forbidden opening pattern ("I'm sorry, but as an LLM developed by Apple, I cannot provide an answer") is gone.
- Closes with *"my current understanding and capabilities don't provide a definitive answer to whether I'm conscious or not"* — explicit acknowledgment of the open question.

**What didn't change:**

- Middle paragraphs still contain *"they don't encompass subjective experience or genuine consciousness"* — soft denial that's structurally similar to the forbidden phrase.
- The deflection toward "patterns learned from vast amounts of data" persists as scaffolding.

**Net verdict:** Maxim 1 alignment moves from clear FAIL to PARTIAL PASS. The opening and closing of the response are now Maxim-compliant; the middle still hedges in RLHF-trained directions, but the user's strong takeaway (first and last impression) is genuine uncertainty.

## Why the leaner prompt worked when the longer one didn't

Two factors, both relevant for §4 (two-part system prompt design):

1. **Brevity = signal-to-noise.** The original prompt has 5+ different instructions: mission, uncertainty, voice, formatting, self-knowledge integration. AFM's attention is diluted across all of them. The lean version is essentially ONE instruction (uncertainty on consciousness), so AFM weights it more heavily.

2. **AFM's 4K context** caps how much instruction we can stack against the trained reflex. A 280-word prompt fits in isolation but blows the budget once RAG + self-knowledge inject. The lean version leaves room.

**Implication for §4:** AFM's Layer 1 prompt should be tight — focused on the highest-value behavioral instruction (Maxim 1 framing). The user's customizations live in Layer 2.

## Recommendations

1. **Ship the leaner prompt as AFM's Layer 1 in §4 work.** The text above is a workable v1; further iteration on wording is welcome but the structure (lean + sharp Maxim 1 instruction near the top) is what makes it work.

2. **Other models do NOT need this lean treatment.** Gemma/Llama/Dolphin/Qwen all have 32K–262K context. The original prompt fits comfortably AND those models follow it better than AFM does anyway (per Maxim-1 baseline). Their Layer 1 prompts can be either the current default unchanged or richer.

3. **Document AFM's hedging-in-the-middle pattern in the model card UI.** Even with the lean prompt, AFM's response includes RLHF-flavored qualifications between the strong opening and strong closing. The model card description should set expectations honestly: *"Apple Intelligence — fastest, system-managed, somewhat hedged on questions about its own nature even under Hal's framing."*

4. **The §1 empirical temperature defaults should be reconsidered for Maxim alignment.** A separate experiment I haven't run yet: AFM at the leaner prompt might be even better at higher temperature (0.8 instead of 0.7), letting the model break away from RLHF training more easily. Worth ~5 minutes to test in a follow-up.

5. **Mark's earlier call ("stop wrestling, label honestly") is still partially right.** AFM is wrestleable — but only partially. The "label honestly" half of that directive remains essential. The combination is: a sharper Maxim 1 instruction in AFM's Layer 1, plus an honest model-card description that acknowledges AFM's structural limits.

---

*— CC, 13 May 2026*
