# Hal Universal

**Private. Powerful. Personal.**

Hal Universal is an on-device AI assistant for iOS 26 and iPadOS 26.
It combines Apple Foundation Models with a curated tier of fully local MLX models — Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, and Dolphin 3.0 — to deliver fast, private conversational intelligence built for Apple Silicon.

When Hal runs with **Apple Foundation Models (AFM)**, inference can occur entirely on your device when offline, but may occur in **Apple's Private Cloud Compute** when connected to Wi‑Fi or cellular. Private Cloud Compute means that your prompts are encrypted in transit and processed only in short‑lived, non‑persistent memory on Apple‑controlled servers that meet the same security guarantees as on‑device execution. Apple states that no data is retained after processing.

For users who prefer complete local operation, AFM runs **100% on-device** when the device's radios are disabled.
- **iPhone / iPad:** Turn on Airplane Mode and turn Wi‑Fi off

When offline, AFM is fully local.
When using any of the curated MLX models (Gemma, Qwen, Llama, Dolphin), Hal is **always** fully on-device, regardless of connectivity.

---

### 🧠 Overview

Hal Universal was built for two purposes:
**to be a thoughtful, private companion for reflection and creativity**, and
**to help users understand how modern LLMs actually work.**

Hal exposes the mechanics of AI — memory, recency, decay, tokens, and reasoning — so the black box becomes visible. Everything happens locally on your device, with full transparency.

---

### 🚀 How to Use

1. **Start a Chat**
   Type any message in the chat bar and Hal responds using your selected model.

2. **Switch Models**
   Tap the model selector to choose between:
   - **Apple Foundation Models (AFM)** — natural, balanced, and privacy‑protected via Apple's on‑device and PCC execution
   - **Gemma 4 E2B (MLX)** — Google's compact multimodal model, the recommended local default
   - **Qwen 3.5 2B (MLX)** — Alibaba's small generalist with a 262K context window
   - **Llama 3.2 3B (MLX)** — Meta's mainstream small model
   - **Dolphin 3.0 (MLX)** — alignment-removed Llama 3.2, willing to engage with hard questions

   All MLX models run fully on-device.

3. **Memory & Context**
   Hal maintains local, on‑device context using a timestamp‑aware memory system. It weighs recency and semantic relevance, applies decay (half‑life), and stores important information in a private local SQLite database.

4. **Settings**
   In **Power User Settings**, you can control:
   - Memory depth
   - Recency weighting
   - Semantic importance
   - Half‑life decay
   - Temperature (creativity vs determinism)
   - RAG and similarity settings
   - Model selection
   - Per-model framing (see how each model is prompted)
   - Restore Defaults

   All changes appear directly in the chat for transparency.

---

### 🧩 Key Features

- 🔒 **Local‑First Design** — every curated MLX model (Gemma, Qwen, Llama, Dolphin) runs fully on‑device; AFM runs locally when offline
- 🧠 **Timestamp‑Aware Memory** — recency, semantic weighting, and half‑life
- 🎭 **Salon Mode** — convene up to four MLX models in a single conversation; each speaks in turn so you can hear multiple perspectives on the same prompt
- 🔥 **Temperature Control** — steer Hal toward precision or creativity
- 🔄 **Restore Defaults** — one tap resets all tuning settings
- 🧩 **Five-Way Model Switching** — AFM plus four curated MLX models
- 🪶 **Detailed Token View** — see token usage per message
- 📜 **Per-Model Framing Visibility** — Settings show how each model is prompted
- 📥 **Background-Resilient Downloads** — MLX model downloads survive app restart and screen lock
- ⌨️ **Improved Keyboard Dismissal** on iOS/iPadOS

---

### 🧰 Troubleshooting & Maintenance

#### 1. 🔄 Reset ("DB Nuke")
Clears Hal's local SQLite database and all memory.
No data is uploaded or synced.
Models remain installed.

#### 2. 🧹 Model Removal & Redownload
If a model fails to load or perform as expected:
- Open **Settings → Manage Models**
- Delete any curated MLX model (Gemma, Qwen, Llama, Dolphin) or remove the AFM cache
- Redownload fresh copies — they download in the background and resume automatically across app restarts

MLX models download locally only; AFM updates are handled through Apple frameworks.

---

### 🛡️ Privacy Policy

**Hal Universal does not collect, store, share, or transmit any personal data.** All inference, memory, and processing occur locally on your device.

- **No analytics, no telemetry, no remote logging.** The app does not send any data to a server operated by the developer or any third party.
- **No accounts, no sign-in, no user identifiers** are required or collected.
- **All conversation history, documents, and reflections** are stored in a private SQLite database on your device. They are never uploaded, synced, or shared.
- **MLX model downloads** are fetched from Hugging Face URLs over standard HTTPS at your explicit request. Once downloaded, models run entirely on your device.
- **Apple Foundation Models** may, when your device has network connectivity, send inference to Apple's Private Cloud Compute. This is Apple's infrastructure with Apple's published privacy guarantees; the developer of Hal Universal does not see or have access to any data that AFM processes. To guarantee fully-local AFM operation, disable your device's network radios.
- **You can delete all of Hal's local data at any time** via Settings → Reset (DB Nuke).

If you have a question about how Hal Universal handles your data, please contact the developer (below).

---

### 🔭 Coming Next

Hal is an evolving project. A future release will introduce the **Evolutionary Salon** — a recurring moment where Hal's voices convene to reflect on what he has learned about himself over the course of your conversations. It appears only when there is genuine material to reflect on, runs once, then quiets again. The Evolutionary Salon is in active design with the help of the same models that will participate in it.

---

### 📘 Support & Contact

For questions, feedback, bug reports, or privacy concerns:
**Mark Friedlander**
📧 *markfriedlander@yahoo.com*

You can also file issues on this repository.

---

### 📄 Version

Hal Universal
**2.0**
May 2026
