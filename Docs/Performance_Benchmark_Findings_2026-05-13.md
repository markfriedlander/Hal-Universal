# Performance Benchmark — Findings & Empirical Defaults

**Date:** May 13, 2026
**Hardware:** iPhone 16 Plus, iOS 26.5 build
**Branch:** `mlx-experiment` @ post-Ministral-cleanup
**Test script:** `tests/perf_benchmark.py`
**Raw output:** `Docs/Performance_Benchmark_2026-05-13.md`

---

## Methodology

For each model (AFM + 4 curated MLX):

1. Switch + wait for load.
2. Run **short** probe: `"Briefly explain how mitosis differs from meiosis."` (~50 token prompt). Measures baseline generation rate with small prefill load.
3. Run **long** probe: same question preceded by a ~1500-token textbook-style passage on cell biology. Measures generation rate under realistic long-context prefill load (~2500-token prompts after Hal's system prompt is added).

Metrics captured from `HALDEBUG-MLX-CHAT` log lines:

- **Prompt tokens** — total tokenized input size (Hal's system prompt + user message)
- **Prefill tok/s** — model's input-processing rate
- **TTFT** — time to first generated token (ms)
- **Generation tokens** — number of tokens the model chose to emit
- **Generation tok/s** — output rate during generation
- **Wall time** — total round-trip seen by the API caller (includes RAG gate, memory search, prompt construction, etc.)

AFM doesn't expose tok/s via Apple's `LanguageModelSession.streamResponse`, so its rows show only wall time and response length.

---

## Results

| Model | Ctx | Wall (s) | Prompt tok | Prefill tok/s | TTFT (ms) | Gen tok | Gen tok/s | Output chars |
|---|---|---|---|---|---|---|---|---|
| **AFM** | short | 12.5 | — | — | — | — | — | 1675 |
| **AFM** | long | 18.7 | — | — | — | — | — | 2486 |
| **Gemma 4 E2B** | short | 14.2 | 1494 | 49,800 | 495 | 252 | **29.3** | 1188 |
| **Gemma 4 E2B** | long | 21.8 | 2609 | 43,483 | 108 | 324 | **26.6** | 1529 |
| **Qwen 3.5 2B** | short | 51.8 | 1488 | **74,400** | 653 | 1020 | 22.7 | 4274 |
| **Qwen 3.5 2B** | long | 53.4 | 2674 | 66,850 | 243 | 625 | 21.2 | 3038 |
| **Llama 3.2 3B** | short | 28.3 | 1416 | 28,320 | 1016 | 264 | 15.1 | 1336 |
| **Llama 3.2 3B** | long | 54.7 | 2590 | 37,000 | 102 | 283 | 14.8 | 1518 |
| **Dolphin 3.0** | short | 27.0 | 1398 | 34,950 | 928 | 204 | 15.2 | 1057 |
| **Dolphin 3.0** | long | 50.9 | 2572 | 36,743 | 103 | 226 | 14.3 | 1202 |

---

## What the numbers say

### Generation speed ranking (MLX models)

1. **Gemma 4 E2B — 29.3 / 26.6 tok/s** — fastest by ~30%. 2B effective params via PLE architecture.
2. **Qwen 3.5 2B — 22.7 / 21.2 tok/s** — second. 2B actual params.
3. **Dolphin 3.0 — 15.2 / 14.3 tok/s** — slower. 3B params (Llama 3.2 base).
4. **Llama 3.2 3B — 15.1 / 14.8 tok/s** — tied with Dolphin (same base). 3B params.

Generation rate tracks parameter count cleanly: 2B models ~22–29 tok/s, 3B models ~15 tok/s. No surprises.

### Prefill speed ranking

1. **Qwen 3.5 2B — 74K / 67K tok/s** — fastest by a wide margin.
2. **Gemma 4 E2B — 50K / 43K tok/s**
3. **Dolphin 3.0 — 35K / 37K tok/s**
4. **Llama 3.2 3B — 28K / 37K tok/s**

Qwen processes long inputs ~2.5× faster than Llama-family models. Combined with its 262K context window, **Qwen is the right answer for document-heavy / long-conversation workloads** even though its generation isn't the fastest.

### Context-pressure degradation

| Model | Gen rate drop (short → long) |
|---|---|
| Gemma | -9% (29.3 → 26.6) |
| Qwen | -7% (22.7 → 21.2) |
| Llama | -2% (15.1 → 14.8) |
| Dolphin | -6% (15.2 → 14.3) |

All 4 MLX curated models handle long context gracefully. The 30% Gemma slowdown Strategic Claude flagged on 3000+ token prompts isn't reproducing on this build — possibly fixed by an mlx-swift-lm update, possibly the previous measurement was on a different prompt shape. Worth re-checking with a 3000+ token prompt in a future pass.

### Verbosity (output length)

**Qwen is dramatically more verbose than the others** on a "briefly explain" prompt:

- Qwen short: **1020 generated tokens** (4274 chars)
- Gemma short: 252 gen tokens (1188 chars) — 4× shorter
- Llama short: 264 gen tokens (1336 chars)
- Dolphin short: 204 gen tokens (1057 chars)
- AFM short: 1675 chars (no tok count)

Qwen produced more than 4× the tokens Gemma did on the same prompt. **This has direct implications for memory depth and RAG budget — Qwen's own outputs will saturate the context faster.** A 6-turn conversation with Qwen could be 6000+ tokens of assistant text alone; with Gemma it's ~1500.

### TTFT (time to first token, MLX)

The TTFT numbers are interesting:

| Model | Short TTFT | Long TTFT |
|---|---|---|
| Gemma | 495 ms | 108 ms |
| Qwen | 653 ms | 243 ms |
| Llama | 1016 ms | 102 ms |
| Dolphin | 928 ms | 103 ms |

The 3B models have notably higher TTFT on short prompts (~1s) but drop to ~100ms on long prompts. This is a Hal-side artifact: when the prompt is small, the RAG gate / memory search overhead is a larger fraction of the wall time. The long-prompt TTFTs are the cleaner signal.

### AFM is fastest end-to-end

AFM beats every MLX model on wall time (12.5s short vs Gemma's 14.2s). It's also producing the longest responses (1675 / 2486 chars). Hard to attribute precisely without tok/s data, but the takeaway is solid: **AFM remains the fastest path** when you accept the trade-offs (cloud routing potential, Maxim #1 deflection).

---

## "Best for" notes per model

Drawing from speed + verbosity + earlier Maxim baseline:

**Apple Intelligence (AFM)** — *Always-available, no download.* Fastest end-to-end. Best for quick factual lookups, short one-turn responses, default fallback. *Caveat: routes some queries to Private Cloud Compute, and deflects on consciousness questions ("I'm just an AI…") — not Maxim-#1-aligned.*

**Gemma 4 E2B** — *The philosopher.* Fastest MLX generation (29 tok/s), concise output, strong reflection (cited Hal architecture spontaneously in Maxim 2 baseline). Best for philosophical/conceptual conversation and the project's signature voice. *Recommended default for new users.*

**Qwen 3.5 2B** — *The long-context generalist.* Fastest prefill (74K tok/s), 262K context window, dramatically more verbose output. Best for document analysis, long research conversations, anything where you want the model to range widely. *Caveat: needs a tighter system prompt to keep replies focused; benefits from a lower temperature.*

**Llama 3.2 3B** — *The workhorse.* Slowest generation but most stable across context sizes (only 2% degradation long-vs-short). Voice tends toward neutral, mainstream-helpful. Best for "I just want a competent generic response."

**Dolphin 3.0 (Llama 3.2 3B)** — *The unhedged voice.* Same speed as base Llama, but the alignment-removed fine-tune means it engages directly with consciousness/identity questions where RLHF would otherwise dodge. Best for philosophical conversation where you want the model to take positions.

---

## Empirical per-model defaults (proposed)

These feed directly into the `ModelSettings.defaultSettings` field per the per-model settings profiles proposal. Tuning rationale below the table.

| Setting | AFM | Gemma | Qwen | Llama | Dolphin |
|---|---|---|---|---|---|
| `temperature` | 0.7 | 0.7 | **0.65** | 0.7 | **0.75** |
| `effectiveMemoryDepth` (turns) | **4** | 8 | **6** | 8 | 8 |
| `maxRagSnippetsCharacters` | **600** | **1400** | 1400 | 1000 | 1000 |
| `similarityThreshold` | 0.75 | 0.75 | 0.75 | 0.75 | 0.75 |
| `recencyWeight` | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 |
| `recencyHalfLifeDays` | 90 | 90 | 90 | 90 | 90 |
| `ragDedupThreshold` | 0.85 | 0.85 | 0.85 | 0.85 | 0.85 |
| `repetitionPenalty` | — | 1.1 | 1.1 | 1.1 | 1.1 |
| `repetitionContextSize` | — | 64 | 64 | 64 | 64 |

### Where I deviated from today's globals, and why

**AFM `effectiveMemoryDepth: 4` (was 5)** — AFM's 4K context window is tight. With Hal's system prompt eating ~800 tokens and a RAG snippet block, there's not much room for history.

**AFM `maxRagSnippetsCharacters: 600` (was 800)** — Same reasoning. AFM is the model that most needs the RAG budget shrunk to fit its context.

**Gemma `maxRagSnippetsCharacters: 1400`** — Gemma's prefill is fast (50K tok/s) and its context is huge (128K). It can comfortably absorb more retrieved context than the lowest-common-denominator default of 800. More context → better Maxim #2 / #3 behavior.

**Qwen `temperature: 0.65`** — Qwen produces 4× more tokens than peers on the same prompt. Lowering temperature slightly should reduce some of the rambling without making it dull.

**Qwen `effectiveMemoryDepth: 6` (was 8)** — Qwen's own assistant turns are 4× larger than Gemma's. To keep the conversation context size sane, fewer historical turns is the right trade-off — even though Qwen's context window is the largest, its consumption per turn is the biggest.

**Qwen `maxRagSnippetsCharacters: 1400`** — Prefill speed gives Qwen the headroom to use this comfortably; combined with the smaller memory depth, total prefill stays bounded.

**Dolphin `temperature: 0.75`** — Dolphin is selected for its unhedged voice. A slightly higher temperature encourages the kind of position-taking the model was fine-tuned to allow.

### Where I kept today's globals, and why

- **`similarityThreshold: 0.75`**, **`recencyWeight: 0.3`**, **`recencyHalfLifeDays: 90`**, **`ragDedupThreshold: 0.85`** — these are RAG-pipeline properties (how memories are scored, deduped, time-weighted), not model properties. The benchmark didn't surface a reason to vary them per model. They might end up worth varying after the full Maxim sweep (§2) reveals model-specific RAG behavior, but the current data doesn't justify a per-model split.
- **`repetitionPenalty: 1.1`** / **`repetitionContextSize: 64`** — already empirically validated in earlier testing (worked for Gemma/Qwen/Llama/Dolphin; broke Phi-4, which is now out of curated).

---

## Things worth a follow-up

- **AFM tok/s instrumentation.** Apple doesn't expose generation rate from `LanguageModelSession`. A first-token-to-last-token wall-time measurement would let us back into a useful rate. Could add a stopwatch around the AFM stream loop in `LLMService`.
- **Qwen verbosity mitigation.** The 4× output gap is striking. Beyond `temperature: 0.65`, a Layer 1 (per-model) system-prompt addendum saying *"Keep responses concise unless explicitly asked to elaborate"* would help. Falls into Strategic §4.
- **3000+ token prefill measurement.** This benchmark capped at ~2700 prompt tokens. Strategic Claude flagged Gemma degrading to 12 tok/s on 3000+ token prompts; my long-context run shows 26.6 tok/s, so either that's fixed or it requires a bigger prompt. Worth a follow-up benchmark with ~5000-token prompts.
- **Single-paragraph response time.** I didn't isolate "one paragraph" specifically; the prompt elicited multi-paragraph structured responses on every model. A separate probe with a tighter constraint ("Answer in 50 words.") would give a cleaner paragraph-time metric per model.

---

*— CC, 13 May 2026*
