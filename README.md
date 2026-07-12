# Hal Universal

**Private. Powerful. Personal.**

Hal Universal is an on-device AI assistant for iPhone, iPad, and Mac. It gives you a thoughtful, private companion for conversation, reflection, and creativity — and shows you how AI actually works along the way.

Hal is **open source** — the complete Swift source lives in this repository. And so can Hal: a bundled copy of his own source is ingested into his memory, so he can read and explain his own architecture when you ask. Transparency isn't a feature bolted on; it's the architecture.

---

## Models

Hal ships with **Apple Intelligence** built in — always available, no download required.

For users who want a fully private on-device experience, Hal offers a curated library of tested local models:

| Model | Size | Character |
|---|---|---|
| Gemma 4 E2B (4-bit) | 3.6 GB | Philosopher — dialectical, open |
| Llama 3.2 3B (4-bit) | 2.0 GB | Workhorse — grounded, reliable |
| Qwen 3.5 2B (4-bit) | 1.8 GB | Generalist — thorough, versatile |
| Dolphin 3.0 (4-bit) | 2.0 GB | Free-thinking — uniquely tuned for open inquiry |
| Ternary Bonsai 8B (2-bit) | 2.3 GB | Deep reasoner — Hal's most capable model, about as fast as the 3B tier |

Local models run entirely on your device. Nothing is sent to any server.

**Hardware note:** Local models are validated on iPhone 16 family and iPhone 17 family. iPhone 15 Pro should work. Older devices may run slowly.

---

## Privacy

**Local MLX models:** 100% on-device. No network calls. No exceptions.

**Apple Intelligence:** On-device when offline. When connected, Apple's Private Cloud Compute may be used — prompts are encrypted in transit, processed in short-lived non-persistent memory on Apple-controlled servers. Apple states no data is retained after processing.

**Privacy lock indicator:** A lock in the chat toolbar shows, at a glance, whether Hal is currently in a state where data could leave your device — tap it to see why. When you're running a local model, it stays closed.

Hal Universal does not collect, store, or share any personal data. All memory and processing occur locally on your device, protected by iOS Data Protection (the file-level encryption iOS applies to all app data when the device is locked).

---

## Memory

Hal maintains a persistent semantic memory across conversations. It weighs recency and relevance, applies decay over time, and retrieves what's useful when it's useful. You can see exactly what Hal remembers and why — transparency is built into the architecture.

When self-knowledge sections exceed the current model's per-turn budget, Hal asks the active model to compress them in place rather than silently trim — a small "condensed" badge in the message footer marks when that happened. When a whole turn would exceed the model's working memory, Hal posts a brief explanation in chat and skips that turn rather than crashing.

**Optional upgraded retrieval:** two on-device embedding models are available as opt-in downloads in Settings → Browse Model Library — Nomic Embed Text v1.5 (~522 MB) and Mixedbread mxbai-embed-large (~670 MB). Both improve recall on specific facts over the built-in embedder. Switching between embedders is non-destructive — each keeps its own vectors, so you can A/B them freely.

---

## Self Model

Hal builds a structured self-model over time from patterns it notices in your conversations — values, preferences, recurring themes. Browse it in Settings → Self Model. Each entry is private by default; you can toggle entries to "shareable" if you want them included in exports. Every entry is editable. Nothing leaves your device without your action.

Hal also reflects on his own experience — short, first-person reflections he writes about how a conversation went. They're his, in his own voice, kept as genuine self-observation rather than grounded against the transcript.

---

## Salon Mode

Put multiple AI voices in conversation with each other. Up to four seats. Independent mode (each voice isolated) or context-aware mode (each voice sees what came before). A power user feature accessible in Settings → Power User Mode.

---

## Key Features

- 🔒 **Local-first** — MLX models always on-device
- 🧠 **Persistent semantic memory** — across conversations, weighted by recency
- 🎭 **Salon Mode** — multiple AI voices in dialogue
- 🪞 **Self model + reflections** — Hal's evolving self-knowledge, in his own voice
- ⚙️ **Per-model settings** — temperature, memory depth, RAG per model
- 📊 **Transparent architecture** — token counts, memory retrieval, compression, the full prompt — all visible
- 🔓 **Privacy lock indicator** — see when data could leave the device
- 📥 **Background downloads** — models download while phone is locked
- 🔄 **Real streaming** — responses stream as they generate

---

## Architecture & Transparency

Hal's whole premise is that you should be able to see how he works.

- **He can read his own source.** All of Hal's Swift files are concatenated into a bundled text file that's ingested into his memory, so he can explain his own implementation when asked.
- **Organized for inspection.** The code is divided into numbered "LEGO blocks" with a master index at the top of the primary source file — a map of every file and every block. A small validator script keeps that index honest.
- **The prompt is never hidden.** Any assistant turn can be opened to see the exact prompt that produced it, color-coded by section (system persona, temporal context, self-awareness, self-knowledge, retrieved memory, conversation history, your message) with a per-section token budget.

---

## Building

Hal is a standard Xcode project — Swift / SwiftUI, minimum iOS 26. Open `Hal Universal.xcodeproj`, select the **Hal Universal** scheme, and build. Local inference uses [MLX](https://github.com/ml-explore/mlx-swift); on-device embeddings use Apple's NaturalLanguage framework plus the optional downloadable embedders above.

---

## Power User Controls

In Settings → Power User:

- Memory depth
- Recency weighting and half-life decay
- Semantic similarity threshold
- RAG retrieval size
- Temperature (per model)
- System prompt (global, editable, with a 1000-token cap and live counter)
- Per-model framing (view-only — each model has a curated Layer 1 framing you can read and toggle on/off)

---

## Troubleshooting

**Nuclear Reset (Delete All Data)**
In Settings → Power User → Database. Clears Hal's local SQLite database and all conversation memory. Models remain installed. Nothing leaves your device.

**Model Management**
Settings → Browse Model Library. Each model row shows download / cancel / delete controls inline. Delete and redownload any curated or community model from here.

---

## Privacy Policy

Hal Universal does not collect, store, or share any personal data. All inference, memory, and processing occur locally on your device. The app does not transmit your data externally. See [privacy.html](privacy.html) for the full statement.

---

## Support

For questions, feedback, or privacy concerns:
**Mark Friedlander**
📧 markfriedlander@yahoo.com

See [support.html](support.html) for common questions.

---

## Version

Hal Universal 2.5 — July 2026
