# Hal Universal

**Private. Powerful. Personal.**

Hal Universal is an on-device AI assistant for iOS 26, iPadOS 26, and macOS 26.  
It combines Apple Foundation Models with the fully local MLX Phi-3 model to deliver fast, private conversational intelligence built for Apple Silicon.

When Hal runs with **Apple Foundation Models (AFM)**, inference can occur entirely on your device when offline, but may occur in **Apple’s Private Cloud Compute** when connected to Wi‑Fi or cellular. Private Cloud Compute means that your prompts are encrypted in transit and processed only in short‑lived, non‑persistent memory on Apple‑controlled servers that meet the same security guarantees as on‑device execution. Apple states that no data is retained after processing.

For users who prefer complete local operation, AFM runs **100% on-device** when the device’s radios are disabled.
- **iPhone / iPad:** Turn on Airplane Mode and turn Wi‑Fi off  
- **Mac:** Turn Wi‑Fi off and disconnect Ethernet  

When offline, AFM is fully local.  
When using **Phi (MLX)**, Hal is **always** fully on-device, regardless of connectivity.

---

### 🧠 Overview

Hal Universal was built for two purposes:  
**to be a thoughtful, private companion for reflection and creativity**, and  
**to help users understand how modern LLMs actually work.**

Hal exposes the mechanics of AI—memory, recency, decay, tokens, and reasoning—so the black box becomes visible. Everything happens locally on your device, with full transparency.

---

### 🚀 How to Use

1. **Start a Chat**  
   Type any message in the chat bar and Hal responds instantly using your selected model.

2. **Switch Models**  
   Tap the model selector to choose between:  
   - **Apple Foundation Models (AFM)** — natural, balanced, and privacy‑protected via Apple’s on‑device and PCC execution  
   - **Phi‑3 (MLX)** — fast, efficient, and fully local on Apple Silicon

3. **Memory & Context**  
   Hal maintains local, on‑device context using a timestamp‑aware memory system.  
   It weighs recency and semantic relevance, applies decay (half‑life), and stores important information in a private local SQLite database.

4. **Settings**  
   In **Power User Settings**, you can control:
   - Memory depth  
   - Recency weighting  
   - Semantic importance  
   - Half‑life decay  
   - Temperature (creativity vs determinism)  
   - RAG and similarity settings  
   - Model selection  
   - Restore Defaults  

   All changes appear directly in the chat for transparency.

---

### 🧩 Key Features

- 🔒 **Local‑First Design** — Phi‑3 always runs fully on‑device; AFM runs locally when offline  
- 🧠 **Timestamp‑Aware Memory** — recency, semantic weighting, and half‑life  
- 🔥 **Temperature Control** — steer Hal toward precision or creativity  
- 🔄 **Restore Defaults** — one tap resets all tuning settings  
- 🧩 **AFM + Phi Model Switching**  
- 🪶 **Detailed Token View** — see token usage per message  
- 📐 **Cross‑Platform Parity** — unified behavior across iOS, iPadOS, and macOS  
- 🪟 **Resizeable Mac Window**  
- 📄 **Clear Document Upload Status**  
- ⌨️ **Improved Keyboard Dismissal** on iOS/iPadOS  

---

### 🧰 Troubleshooting & Maintenance

#### 1. 🔄 Reset (“DB Nuke”)
Clears Hal’s local SQLite database and all memory.  
No data is uploaded or synced.  
Models remain installed.

#### 2. 🧹 Model Removal & Redownload
If a model fails to load or perform as expected:
- Open **Settings → Manage Models**  
- Delete Phi‑3 or remove AFM cache  
- Redownload fresh copies from Apple’s model repository  

Phi‑3 downloads locally only; AFM updates are handled through Apple frameworks.

---

### 🛡️ Privacy Policy

Hal Universal does **not collect, store, or share any personal data.**  
All inference, memory, and processing occur locally on your device.  
The app does not transmit your data externally.

---

### 📘 Support & Contact

For questions, feedback, or privacy concerns:  
**Mark Friedlander**  
📧 *markfriedlander@yahoo.com*  

---

### 📄 Version

Hal Universal  
**1.5**  
November 2025
