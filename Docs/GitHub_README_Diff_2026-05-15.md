# GitHub README — Diff + Draft Replacement

**File:** `/Users/markfriedlander/Desktop/Fun/Hal Universal/README.md`
**Role:** Both the **Support URL** (ASC) and the **Privacy Policy URL** (ASC App Privacy section) point at this file via `https://github.com/markfriedlander/Hal-Universal/blob/main/README.md`. So it's serving two distinct App Store contracts, in addition to being the public face of the repo.
**Current state:** Last touched 2025-11-13 in commit `ac481fa` ("Hal Universal v1.5 Release Prep"). Version footer says "1.5 / November 2025."

---

## What's stale (relative to mlx-experiment)

| Section | Issue |
|---|---|
| Para 2 (intro) | `"...with the fully local MLX Phi-3 model..."` — Phi-3 removed from curated tier |
| Para 4 ("When offline...") | `"When using Phi (MLX), Hal is always fully on-device..."` — Phi-3 |
| Section "🚀 How to Use" → "Switch Models" | Only mentions AFM + Phi-3; curated tier is now 5 models |
| Section "🧩 Key Features" → Local-First Design | `"Phi-3 always runs fully on-device"` |
| Section "🧩 Key Features" → "AFM + Phi Model Switching" | Should reference the curated tier |
| Section "🧰 Troubleshooting" → "Model Removal" | `"Delete Phi-3 or remove AFM cache"` — wrong model names |
| Section "🛡️ Privacy Policy" | Currently 3 lines — could probably be a bit more thorough for App Store compliance |
| Section "📘 Support & Contact" | Has Mark's email; verify it's the address you want for v1.6 support |
| Section "📄 Version" footer | Says "1.5 / November 2025" — will need bump when v1.6 ships |
| Throughout | No mention of Salon Mode (Easter egg, may or may not want to highlight in README) |

---

## A draft replacement — adopt, edit, or use as a starting point

Below is a candidate v1.6 README. **It's a draft, not a commit** — saved here for review. Once you OK the copy (or hand me an edited version), I'll replace `README.md` and push as its own commit.

I deliberately:
- Kept the structure, emoji palette, and voice of the existing README
- Replaced Phi-3 with the curated tier
- Made the Privacy Policy section a bit more substantive (since this URL is serving as the formal App Store privacy policy)
- Left a placeholder for the v1.6 version footer
- Left Salon Mode out of the main features list (it's an Easter egg by design; you may want to add a "Hidden Features" subsection or leave it undescribed entirely)

---

```markdown
# Hal Universal

**Private. Powerful. Personal.**

Hal Universal is an on-device AI assistant for iOS 26, iPadOS 26, and macOS 26.
It combines Apple Foundation Models with a curated tier of fully local MLX models — Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, and Dolphin 3.0 — to deliver fast, private conversational intelligence built for Apple Silicon.

When Hal runs with **Apple Foundation Models (AFM)**, inference can occur entirely on your device when offline, but may occur in **Apple's Private Cloud Compute** when connected to Wi‑Fi or cellular. Private Cloud Compute means that your prompts are encrypted in transit and processed only in short‑lived, non‑persistent memory on Apple‑controlled servers that meet the same security guarantees as on‑device execution. Apple states that no data is retained after processing.

For users who prefer complete local operation, AFM runs **100% on-device** when the device's radios are disabled.
- **iPhone / iPad:** Turn on Airplane Mode and turn Wi‑Fi off
- **Mac:** Turn Wi‑Fi off and disconnect Ethernet

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
- 🔥 **Temperature Control** — steer Hal toward precision or creativity
- 🔄 **Restore Defaults** — one tap resets all tuning settings
- 🧩 **Five-Way Model Switching** — AFM plus four curated MLX models
- 🪶 **Detailed Token View** — see token usage per message
- 📐 **Cross‑Platform Parity** — unified behavior across iOS, iPadOS, and macOS
- 🪟 **Resizable Mac Window**
- 📄 **Clear Document Upload Status**
- ⌨️ **Improved Keyboard Dismissal** on iOS/iPadOS
- 📜 **Per-Model Framing Visibility** — settings show how each model is prompted

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
- Redownload fresh copies — they download in the background and survive app restart

MLX models download locally only; AFM updates are handled through Apple frameworks.

---

### 🛡️ Privacy Policy

**Hal Universal does not collect, store, share, or transmit any personal data.** All inference, memory, and processing occur locally on your device.

- **No analytics, no telemetry, no remote logging.** The app does not send any data to a server operated by the developer or any third party.
- **No accounts, no sign-in, no user identifiers** are required or collected.
- **All conversation history, documents, and reflections** are stored in a private SQLite database on your device. They are never uploaded, synced, or shared.
- **MLX model downloads** are fetched from Apple-hosted or Hugging Face URLs over standard HTTPS at your explicit request. Once downloaded, models run entirely on your device.
- **Apple Foundation Models** may, when your device has network connectivity, send inference to Apple's Private Cloud Compute. This is Apple's infrastructure with Apple's published privacy guarantees; the developer of Hal Universal does not see or have access to any data that AFM processes. To guarantee fully-local AFM operation, disable your device's network radios.
- **You can delete all of Hal's local data at any time** via Settings → Reset (DB Nuke).

If you have a question about how Hal Universal handles your data, please contact the developer (below).

---

### 📘 Support & Contact

For questions, feedback, bug reports, or privacy concerns:
**Mark Friedlander**
📧 *markfriedlander@yahoo.com*

You can also file issues on this repository.

---

### 📄 Version

Hal Universal
**1.6** *(or whatever final number you choose)*
*(release month) 2026*
```

---

## My recommendation for execution

1. **You read the draft above** and tell me what to change (especially the Salon Mode call — leave out, mention as Easter egg, or describe fully).
2. **I edit the actual README.md** with the approved copy.
3. **Commit as its own commit** so it can be reverted independently.
4. **Verify on GitHub** that the live page renders correctly (it's already in the same repo so will appear automatically).
5. **No ASC changes needed** to the privacy policy URL or support URL — both already point at this file, and the update will propagate automatically.

**Important:** If you change the privacy policy MATERIALLY (not just stylistically), App Store may want you to bump version or re-submit privacy declarations. The draft above is more thorough than the current version but doesn't change WHAT we collect (still nothing). That should be a stylistic upgrade rather than a material change — but worth confirming with Apple's guidelines.

---

*— CC, May 15, 2026*
