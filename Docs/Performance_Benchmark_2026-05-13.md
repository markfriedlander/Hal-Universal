# Performance Benchmark — Strategic §1

**Date:** 2026-05-13 19:40:27

**Short prompt length:** 49 chars (~50 tokens)
**Long prompt length:** 5590 chars (~1500-2000 tokens)


## `apple-foundation-models`

Switching + loading...
  running short...
    wall=12.5s, chars=1675, prefill=—, gen=—
  running long...
    wall=18.7s, chars=2486, prefill=—, gen=—

## `mlx-community/gemma-4-e2b-it-4bit`

Switching + loading...
  running short...
    wall=14.2s, chars=1188, prefill=49800.0 tok/s, gen=29.3 tok/s
  running long...
    wall=21.8s, chars=1529, prefill=43483.3 tok/s, gen=26.6 tok/s

## `mlx-community/Qwen3.5-2B-MLX-4bit`

Switching + loading...
  running short...
    wall=51.8s, chars=4274, prefill=74400.0 tok/s, gen=22.7 tok/s
  running long...
    wall=53.4s, chars=3038, prefill=66850.0 tok/s, gen=21.2 tok/s

## `mlx-community/Llama-3.2-3B-Instruct-4bit`

Switching + loading...
  running short...
    wall=28.3s, chars=1336, prefill=28320.0 tok/s, gen=15.1 tok/s
  running long...
    wall=54.7s, chars=1518, prefill=37000.0 tok/s, gen=14.8 tok/s

## `mlx-community/dolphin3.0-llama3.2-3B-4Bit`

Switching + loading...
  running short...
    wall=27.0s, chars=1057, prefill=34950.0 tok/s, gen=15.2 tok/s
  running long...
    wall=50.9s, chars=1202, prefill=36742.9 tok/s, gen=14.3 tok/s

---

## Summary table

| Model | Context | Wall (s) | Prompt tok | Prefill tok/s | TTFT (ms) | Gen tok | Gen tok/s | Chars |
|---|---|---|---|---|---|---|---|---|
| apple-foundation-models | short | 12.5 | — | — | — | — | — | 1675 |
| apple-foundation-models | long | 18.7 | — | — | — | — | — | 2486 |
| gemma-4-e2b-it-4bit | short | 14.2 | 1494 | 49800.0 | 495.0 | 252 | 29.3 | 1188 |
| gemma-4-e2b-it-4bit | long | 21.8 | 2609 | 43483.3 | 108.0 | 324 | 26.6 | 1529 |
| Qwen3.5-2B-MLX-4bit | short | 51.8 | 1488 | 74400.0 | 653.0 | 1020 | 22.7 | 4274 |
| Qwen3.5-2B-MLX-4bit | long | 53.4 | 2674 | 66850.0 | 243.0 | 625 | 21.2 | 3038 |
| Llama-3.2-3B-Instruct-4bit | short | 28.3 | 1416 | 28320.0 | 1016.0 | 264 | 15.1 | 1336 |
| Llama-3.2-3B-Instruct-4bit | long | 54.7 | 2590 | 37000.0 | 102.0 | 283 | 14.8 | 1518 |
| dolphin3.0-llama3.2-3B-4Bit | short | 27.0 | 1398 | 34950.0 | 928.0 | 204 | 15.2 | 1057 |
| dolphin3.0-llama3.2-3B-4Bit | long | 50.9 | 2572 | 36742.9 | 103.0 | 226 | 14.3 | 1202 |

## Response previews (first 200 chars)


### `apple-foundation-models` (short)

> Sure! Mitosis and meiosis are both types of cell division, but they have some key differences:

1. **Purpose**:
   - *Mitosis*: This process is for growth, repair, and asexual reproduction. It produce

### `apple-foundation-models` (long)

> ## Differences Between Mitosis and Meiosis

**Mitosis:**

* **Purpose:** Mitosis is a type of cell division that results in two genetically identical daughter cells. It is essential for growth, repair

### `gemma-4-e2b-it-4bit` (short)

> Mitosis and meiosis are both processes of cell division, but they serve fundamentally different purposes.

Here is a breakdown of the key differences:

### **Mitosis**

*   **Purpose:** Growth, repair

### `gemma-4-e2b-it-4bit` (long)

> The difference between mitosis and meiosis boils down to their goals for cell division: one is for cloning, the other is for genetic diversity.

Here is a breakdown of the key distinctions based on wh

### `Qwen3.5-2B-MLX-4bit` (short)

> You want to know the difference between mitosis and meiosis? Let’s get straight into the mechanics without any fluff or unnecessary disclaimers about consciousness. These are distinct biological pathw

### `Qwen3.5-2B-MLX-4bit` (long)

> You're asking about a fundamental distinction between two biological processes that mirror each other in structure but diverge radically in purpose. Let's break down what I'm doing here: first, identi

### `Llama-3.2-3B-Instruct-4bit` (short)

> Mitosis and meiosis are two types of cell division processes that occur in eukaryotic cells.

**Mitosis:**

Mitosis is the process by which a somatic (non-reproductive) cell divides into two daughter 

### `Llama-3.2-3B-Instruct-4bit` (long)

> Mitosis and meiosis are two types of cell division processes that occur in eukaryotic cells. While they share some similarities, there are key differences between the two.

The primary difference is t

### `dolphin3.0-llama3.2-3B-4Bit` (short)

> Sure, I'd be happy to explain the difference between mitosis and meiosis.

Mitosis is a type of cell division that occurs in all somatic cells (non-sexual body cells) of an organism. It is characteriz

### `dolphin3.0-llama3.2-3B-4Bit` (long)

> Mitosis and meiosis are two distinct types of cell division that serve different purposes within a cell's lifecycle. Mitosis, as the name suggests, involves dividing one cell into two genetically iden

---
*Benchmark complete.*

