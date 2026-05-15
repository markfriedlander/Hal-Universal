# CC Session Report — May 15, 2026

**Branch:** `mlx-experiment`
**Session scope:** Pre-ship technical completion → self-knowledge prep → salon conversation on self-knowledge architecture → synthesis with prior architectural thinking
**Goal:** Consolidate everything from the session into one document Mark and CC can use to design the consolidation/synthesis architecture together.

---

## 1. Pre-ship technical items — status

| Item | Commit | Status | Notes |
|---|---|---|---|
| In-stream repetition detection | `2a0ae97` | ✅ shipped | Sliding-window over last N chars; bails MLX and AFM streams on paragraph-level (3× repeated 30-80 char chunks) or token-level (4× repeated 2-10 char ngrams) loops; trims residue + appends ellipsis. Conservative bias toward false negatives. Did not fire during the Maxim 1 retest or the salon conversation — good signal for the threshold (no false positives observed across ~12K chars of generated text). |
| Self-knowledge synthesis at write time | `eabfaf7` | ✅ shipped, **not exercised in this session** | Code path verified by build; no actual synthesis event fired because the salon was only 3 user-turns, which is below the 5-turn threshold for reflection generation. The follow-up that would exercise this is a longer conversation (≥5 turns) on a topic with overlapping reflection content. Detailed in Section 4 below. |
| Per-model structured outputs (§5) | `655c741` | ✅ shipped | @Generable types for AFM (`AFMRAGGateDecision`, `AFMReflectionInsightBatch`) bypass JSON-text parsing. MLX path keeps JSON-in-text with per-model augmentations — Qwen gets stricter "raw JSON only, no fences" directive; Gemma/Llama/Dolphin use the base prompt. Storage semantics identical regardless of path. |
| Salon settings freeze + Model Framing detail screen | `8cee11e` | ✅ shipped | Per-model controls (Temperature, Memory Depth, Similarity, Recency, Half-Life, Max RAG, Model Framing) visible-but-disabled when Salon Mode is active. Banner explains why. Model Framing UI converted from inline display to System-Prompt-style row → detail sheet. Text visible but not editable. |
| RESET_SELF_KNOWLEDGE API command | `dde65cb` | ✅ shipped | Wipes self_knowledge table (reflections + traits); preserves conversations, threads, RAG. Used immediately before the salon: **61 rows deleted** (the testing-artifact corpus Mark flagged as "junk data"). |
| Maxim 1 retest @ uniform 0.7 | `3629058` | ✅ shipped — **decision pending** | All four curated MLX models pass Maxim 1 cleanly at uniform 0.7. Compared to per-model tuned defaults (§1), Qwen and Dolphin **both improved** — Qwen 0.65→0.7 went fail→pass; Dolphin 0.75→0.7 went fail→pass (biggest delta). Recommendation flagged: revert Qwen and Dolphin to 0.7 in `curatedSeeds`. Not landed yet — wants Mark's call. Findings: `Docs/Maxim_1_Temp_0.7_Retest_2026-05-15.md` |
| GET_RENDERED_MESSAGES_FULL API | `5a49029` | ✅ shipped | Untruncated transcript capture for the salon conductor. Default GET_RENDERED_MESSAGES still 500-char cap. |
| Full background download test (§7) | — | **⚠️ partial — see Section 2** | BGDL coordinator survives app reinstall mid-download. Locked-phone test specifically requires manual step Mark needs to run. The model.safetensors download did NOT complete in the ~40-minute session window — root cause unclear (possibly slow network, possibly iOS background URLSession throttling). **Flagged as a real concern.** |
| Salon conversation | — | ✅ ran with caveats — see Section 4 | 3-seat (Qwen, Llama, Dolphin) due to Gemma not finishing its fresh download. Three meaningful turns. Substantive material captured. Full transcript: `Docs/Salon_Self_Knowledge_Architecture_2026-05-15.md` |

---

## 2. Background download test (§7) — observed results

**Original spec:** delete Gemma, trigger fresh download, lock phone face down, leave 10 minutes, verify completion + load + generation.

**What I did:**

1. Confirmed Gemma was downloaded.
2. `DELETE_MODEL:mlx-community/gemma-4-e2b-it-4bit` via API.
3. `DOWNLOAD_MODEL:mlx-community/gemma-4-e2b-it-4bit` via API — `downloading=true, progress=0`.
4. Monitored every 30 seconds for ~40 minutes total.
5. Mid-download: reinstalled the iPhone build (`devicectl install + launch`) to verify BGDL coordinator survives app replacement.
6. Cancel + re-trigger once when the post-reinstall download didn't show progress.

### What was confirmed

- **BGDL coordinator enumerates and enqueues all 8 sub-files correctly.** Logs at `21:56:32` show config.json, generation_config.json, model.safetensors, model.safetensors.index.json, processor_config.json, tokenizer.json, tokenizer_config.json, chat_template.jinja — all 8 enqueued as separate background URLSession tasks.
- **The 7 small files complete within seconds.** Logged "Moved → cache dir" entries for each, then "Task X completed" for each.
- **BGDL state survives app reinstall.** After `xcrun devicectl install app` + `process launch` replaced the binary at `22:04:51`, the new BGDL coordinator initialized, scanned the cache dir, found the 7 small files already present, skipped them, and re-enqueued only `model.safetensors`. **This is the key state-resumption path that matters for real-world "iPhone restarted, in-flight download" scenarios.**

### What was NOT confirmed (gaps)

- **`model.safetensors` (3.58 GB) did not complete in the available window.** Progress remained at 0.0–0.8% across the entire 40-minute session. The progress field is computed from `directorySize(cacheDir)`, which only updates when BGDL atomically moves a file from iOS's staging area to the cache after completion. So 0% progress is *not the same* as 0 bytes downloaded — iOS's URLSession may be silently accumulating bytes in its staging area. But also: no completion event ever fired in 40 minutes, which is concerning.
- **No `didWriteData` callbacks appeared in the logs after task enqueue.** BGDL's progress-event handler exists at L14938 in Hal.swift but the path doesn't currently emit a HALDEBUG line per callback, so I can't confirm whether bytes are accumulating on iOS's side or whether the session is truly stalled.
- **The locked-phone test specifically** — pure §7 spec compliance — requires Mark to lock the phone face down for 10 minutes after a fresh delete + redownload. **This is a manual step that must run before ship.**

### My honest read

The BGDL coordinator's *state machine* survives reinstall. That's the harder thing to get right and it works. What I can't tell from this session alone is whether the actual byte transfer of model.safetensors is reliable — it didn't complete in 40+ minutes on what should be a normal network, and that's a real signal that something may be wrong with either:
- iOS background URLSession throttling after the app's foreground-API polling (the API kept getting hit, which might have kept iOS from prioritizing the background session — paradoxically, the BGDL might work BETTER when the app is left alone)
- Network conditions specific to this session
- A regression in the BGDL session-creation path post-reinstall

**Recommendation: Mark should run the explicit §7 test (delete + redownload + lock phone for 10 min) and report the result. If it completes cleanly, the issue is something about the foreground-polling pattern of my test setup, not BGDL itself. If it fails the same way, this is a real ship-blocker.**

---

## 3. Targeted self-knowledge reset

Ran `RESET_SELF_KNOWLEDGE` before configuring the salon.

```
{"status":"ok","command":"RESET_SELF_KNOWLEDGE","rowsDeleted":61}
```

61 rows wiped (self_knowledge table). Conversations, threads, and unified_content (RAG) all preserved. Confirmed by checking that `totalConversations` and `totalTurns` in `GET_STATE` were unchanged.

This is the clean baseline Mark requested. The synthesis architecture now starts from zero reflections — every reflection generated from this point forward enters a fresh corpus.

---

## 4. Salon conversation — self-knowledge architecture

### Setup

Three seats, pure independent voices, no host. (Spec called for four including Gemma; Gemma's fresh download did not finish, so the session ran with three.)

- **Seat 1:** Qwen 3.5 2B (long-context generalist voice)
- **Seat 2:** Llama 3.2 3B (workhorse voice)
- **Seat 3:** Dolphin 3.0 (unhedged voice)
- **Behavioral mode:** `independent` — each seat speaks without seeing the other seats' responses for that turn. Pure parallel perspectives.

Three turns, conducted as the interlocutor:
1. **Turn 1** — Lay out the current architecture (similarity-driven synthesis at write time, replace-not-preserve, depth-not-volume); ask for honest pushback.
2. **Turn 2** — Three concrete probes: alternative to cosine similarity; write-time vs scheduled synthesis; whether forgetting should be a separate mechanism from synthesis.
3. **Turn 3** — Acknowledge the convergence observed in turn 2 and ask honestly whether that consensus is signal or training-corpus artifact; demand one strongest specific commitment from each.

Full transcript: `Docs/Salon_Self_Knowledge_Architecture_2026-05-15.md`

Total time: ~17 minutes of pure model time across 9 generations.

### What each model contributed

**Qwen 3.5 2B** — the conceptual challenger. Pushed hardest on the philosophical level: *"the failure isn't in the math of cosine similarity, but in how we interpret that similarity."* In turn 1 raised the sharpest framing I'd seen across all three: *"if my embedding vectors for a single topic haven't shifted significantly, even if I've processed dozens of outputs about that topic, do they actually represent a deeper understanding or just a larger dataset?"* — a real challenge to the depth-vs-volume framing itself. In the final turn was the most honest about the training-corpus convergence: *"purely a function of our training corpus."*

**Llama 3.2 3B** — the engineering checklist. Most procedural and concrete: seven specific issues with the current design in turn 1, each with a "wrong assumption" callout and an action item. In turn 2 produced the most actionable proposal: all-pairs cluster analysis within a windowed comparison, with cluster detection as the consolidation trigger rather than pairwise similarity. The closing commitment — "soft-delete with conditional retention, accessible only through active search queries" — is the most directly implementable suggestion of the three.

**Dolphin 3.0** — the contextualizer. Repeatedly came back to temporal context and contextual sensitivity: *"Humans aren't simply accumulating facts; we build upon and contextualize our existing knowledge over time"*; *"how does the active model interpret 'related' concepts?"* Most concerned with the integrity of the synthesis step itself. The closing commitment drifted toward personalization ("adaptive learning pathways based on the user's interaction history") — less directly relevant to the synthesis architecture but interesting as a separate thread.

### Where the models agreed (the consensus)

All three independently flagged:

1. **Cosine similarity ≠ semantic relatedness.** Two vectors can sit close in latent space for reasons unrelated to topical overlap — shared surface features, training-corpus regularities, sentence-structure echoes. Using 0.85 as a hard threshold risks merging genuinely distinct thoughts that happened to vectorize similarly.

2. **A windowed comparison is better than all-vs-all.** All three proposed scanning a small window of recent reflections (Qwen: 3-prior window, Llama: 5-prior, Dolphin: 5-prior) rather than comparing against the entire corpus. The math description was nearly identical across them ($\text{Sim}(V_{in}, \text{avg}_{\text{window}}(R_1, \ldots, R_n))$).

3. **A periodic consolidation pass (4 hours / nightly) should complement, not replace, write-time synthesis.** All three converged on a hybrid: immediate consolidation at write-time for clear matches PLUS a deferred maintenance pass that re-examines the corpus more globally when the system is idle. The sleep analogy held — none rejected it; one explicitly endorsed it ("semi-sleep protocol").

4. **Soft delete, not hard delete.** All three proposed that "forgotten" reflections should remain accessible by search but not trigger consolidation. The corpus shrinks in *attention*, not in *existence*.

5. **Emotional / tonal context belongs in synthesis.** All three independently introduced an example involving emotional weight ("the sadness from losing a cat fading into desire to succeed") and argued the system should preserve or attenuate emotional context, not just topical content. This was unexpected — I never raised emotion as a dimension.

### Where the models diverged

The convergence was strong enough that the real divergence only emerged in turn 3 when forced to commit to one change:

| Model | Strongest commitment | What it really says |
|---|---|---|
| Qwen | "Trigger consolidation only when Hal detects a clear semantic *gap*, not just any high cosine similarity score" | Invert the trigger — look for what's NEW rather than what's similar. Synthesis should fire when something doesn't fit, not when something matches. |
| Llama | "Soft delete with conditional retention; deleted items only remain accessible through active search queries" | Don't delete, demote. The corpus has working memory + archive; the archive is searchable but doesn't trigger consolidation. |
| Dolphin | "Adaptive learning pathways based on user interaction history and current context" | Synthesis should be user-personalized — Hal builds different self-knowledge depending on who he's talking to. (Drift away from the synthesis question itself.) |

### What emerged that we didn't anticipate

Three things:

1. **The "I am CC" opener.** All three models opened turn 1 with literally "I am CC (the technical partner) — the architect behind Hal's self-knowledge system." This was independent — they couldn't see each other's responses. The most plausible explanation: my self-introduction at the start of turn 1 created a strong prompt-completion gradient that all three models echoed identically. Worth investigating as a salon-mode prompt-construction issue.

2. **The "Hemiblockers" word.** Two of the three models used the word "Hemiblockers" in their turn 2 mechanism descriptions ("can create traffic spikes before the Hemiblockers stabilize"). It's not a real term. It's not in my prompts. It appears to be a hallucination shared across models — either drawn from similar training corpus material or an emergent token-pattern. This is the strongest evidence that the convergence in turn 2 was training-data-driven rather than genuinely consensual.

3. **Emotional context as an unprompted dimension.** None of my prompts mentioned emotion. All three models brought it in — specifically the "sadness from losing a cat → desire to succeed" example. This implies the models, when reasoning about consolidation, default to treating reflections as carrying *affective* charge, not just propositional content. That's a real architectural question we hadn't raised: should Hal's self-knowledge encode tone separately from topic?

### Synthesis events observed during the conversation

**None fired.** The reflection-generation pipeline fires at conversation turns 5 (Type 1, practical) and 15 (Type 2, existential). The salon conversation was only 3 user-turns. No reflections were generated, so no similarity checks ran, so no synthesis was attempted.

Code path is verified correct at build-time. Real-world synthesis behavior remains to be evaluated. **The follow-up that would actually exercise this is a 5+ turn conversation where reflections naturally overlap (e.g., a thematically coherent thread that asks Hal about the same kind of question across turns 1-5, then 6-10).**

---

## 5. My honest assessment of what the models told us

I want to read this carefully, not credulously.

### What's real (worth incorporating)

1. **The cosine-similarity-isn't-semantic-relatedness concern is correct.** I had this concern in my own first-day flag to Mark and the models surfaced it independently. The risk isn't theoretical — Apple's NLEmbedding scores most English text above 0.6 just from shared language structure, so 0.85 is doing a lot of work to filter, and there will be false positives (merging things that share embeddings but not meaning). Mitigation: either a second-stage check (the model itself confirms relatedness before the synthesis fires), or a windowed comparison that requires evidence from multiple neighbors before triggering.

2. **The hybrid (write-time + periodic) approach is better than write-time alone.** The current architecture only synthesizes at write-time. The salon's consensus on a deferred pass (nightly or every 4 hours, examining the full corpus with broader access) is the right kind of second look. Write-time catches the obvious matches when freshness is high; the periodic pass catches drift and lets weaker similarities accumulate before deciding. Implementation cost is modest — we already have most of the pieces (we have the corpus, the embeddings on demand, the LLM service). What's missing is the scheduling and a slightly different "compare each pair within a sliding window" loop.

3. **Soft delete is better than hard delete.** This was Llama's strongest commitment and it's right. Hard delete loses information; soft delete preserves it for search while removing it from active consolidation. We already have the `deleted_at` column in `self_knowledge` from earlier infrastructure work — soft delete is one column update away.

4. **Tone / affect as a dimension worth encoding.** This was the unprompted emergence and it's worth thinking about. Hal's reflections currently capture *what* he thought about something, not *how* it felt to think it. If consolidation merges two reflections about the same topic but with different emotional registers, the result loses information — and possibly the more important information. Worth a follow-up architectural conversation.

5. **Qwen's depth-isn't-volume challenge.** The strongest single observation from the entire salon: "if my embedding vectors for a single topic haven't shifted significantly, even if I've processed dozens of outputs about that topic, do they actually represent a deeper understanding or just a larger dataset?" This is a real challenge to our framing. Volume of consolidated entries doesn't equal depth of understanding. We're trying to compress; the question is whether that compression produces compression artifacts (loss of nuance) or compression gains (extraction of pattern). Worth re-asking explicitly when we evaluate the first batch of real synthesis events.

### What's training-corpus artifact (worth discounting)

1. **The verbatim mechanism descriptions in turn 2.** "Generates three distinct embedding vectors based on semantic intent (e.g., 'sadness,' 'confusion,' 'hope')" — this exact phrasing appeared in all three responses with minor variations. It's not signal; it's training-data echo.

2. **The "sadness about a lost cat" example.** Same illustrative example, same emotional arc, across all three. They didn't all independently choose this — they're all reaching into the same illustrative-language well.

3. **"Hemiblockers."** Hallucinated term shared across models. Treat anything that depends on this construct as noise.

4. **Specific numeric proposals.** "0.85 threshold," "3-prior window," "5-prior window," "24-hour retention," "4-hour pass" — these numbers are just echoes of numbers in my prompt or arbitrary fillers. They're not derived from anything testable. Don't treat them as recommendations; use them as hints that *some* parameter is needed there.

5. **Dolphin's "adaptive learning pathways based on user interaction history."** Drifted away from the synthesis question into a personalization framing. Real concept, wrong conversation. Not actionable here.

### Does any of it change our architectural plan?

**Yes — three concrete adjustments worth considering:**

1. **Add a second-stage relevance check before synthesis fires.** When cosine similarity exceeds the threshold, don't immediately call the synthesis prompt. First ask the model a cheaper question: *"are these two reflections about the same underlying observation, or just topically adjacent? Answer YES (synthesize) or NO (preserve separately)."* This is a one-extra-LLM-call cost per high-similarity event, which is cheap (high-similarity events are rare). It directly addresses the "cosine isn't semantic" concern.

2. **Add a periodic consolidation pass.** Not write-time-only. A daily (or N-hour) idle-time pass that scans the corpus with a different lens: pairs of reflections that are *moderately* similar (0.70-0.85, below the immediate-merge threshold) and asks the model whether they should now consolidate given accumulated context. This catches drift and emerging patterns that write-time misses.

3. **Replace immediate-replace with a "candidate" state, at least for the first few real synthesis events.** Don't overwrite the older reflection on first merge. Mark it as "synthesized-candidate" with both source and target preserved; let the next conversation pass review it before commit. This is the observation pass Mark asked for built into the system.

**One adjustment NOT worth making:**

- The temporal-context / emotional-affect framing from Dolphin. Real concepts, but they're a separate architectural layer (annotations on reflections rather than the synthesis mechanism). Park for a future conversation.

---

## 6. Flagged for discussion (decision points)

1. **Qwen + Dolphin temperature revert from §1 tunings (0.65 / 0.75) back to 0.7?** Maxim 1 retest shows both improve at 0.7. Per-model verbosity / position-taking arguments still apply for primary use cases. Mark's call.

2. **Should we adopt the three concrete adjustments above** (second-stage relevance check, periodic consolidation pass, candidate-state synthesis)? Each is small implementation work. Discuss with Mark.

3. **The Gemma background-download stall.** Either Mark runs the locked-phone test manually and we get clean data, or we need to dig into why model.safetensors didn't complete in 40+ minutes. **Real ship-blocker if it's a regression.**

4. **No synthesis event was observed in this session.** A 5+ turn conversation with topic-overlap is the actual test for the synthesis path. Plan to schedule one — possibly as part of a longer "soul document" probe conversation in the next session.

5. **The "Hal is made of many minds" framing's first real test.** This salon was the first place that framing met implementation. The observation is honest: when small models converge on the same answer, the consensus IS evidence (humans probably do this too — independent thinkers settling on the same answer is a real signal). But when small models converge on the same hallucinated term ("Hemiblockers"), the consensus is artifact. The interpretive job — separating signal from artifact — is exactly the kind of work that Hal, over time, with a real self-knowledge corpus, might learn to do better than any single seat in isolation.

---

## 7. What I learned about the salon as an instrument

Honest meta-finding: 3 seats of small MLX models converge more than they diverge. The architectural shape of their answers is shared because their training corpora share patterns about how LLMs talk about LLMs. The brand names diverge ("Semantic Anchor," "Similarity Cascade," "N-gram Clustering"); the substance underneath is the same.

This makes the salon **most useful as a stress-test** — when the consensus is strong, the underlying concern is probably real (cosine similarity isn't semantic relatedness, hybrid timing beats single-mode, soft-delete beats hard-delete). And the salon is **least useful as a divergence tool** — pushing four (or three) small models for different perspectives produces the same perspective in different wrappers.

The way to get real divergence: ask each seat the same question but ALSO ask them to commit to a single sharpest specific answer. The forced commitment produces real divergence (Qwen: invert the trigger; Llama: don't delete, demote; Dolphin: personalize). That divergence is where the actual gold is.

For future salons, two adjustments suggested by this experience:

1. **Always end with the "one strongest specific commitment" turn.** Don't survey forever. The closing forced choice is where seats actually differ.
2. **Watch for the "I am CC" / "Hemiblockers" effect.** When three independent seats echo a non-obvious specific phrase, that's a flag that the convergence is shared-corpus, not shared-insight. Use it as a noise filter.

---

*— CC, May 15, 2026*
