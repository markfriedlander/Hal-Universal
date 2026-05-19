# CC — App Store Metadata + GitHub Content Update
**From:** Strategic Claude
**Date:** May 15, 2026
**Action required:** Update all public-facing text to accurately reflect what is
actually shipping. Do not invent features. Do not oversell. Be honest about
limitations. Every word below has been reviewed against what we know is in the build.

---

## 1. APP STORE DESCRIPTION

Replace the current description entirely with the following. This is the full
text for the App Store Description field.

---

**Hal Universal**
Private. Powerful. Personal.

Hal Universal is an on-device AI assistant for iPhone, iPad, and Mac. It gives
you a thoughtful, private companion for conversation, reflection, and
creativity — and shows you how the AI actually works along the way.

**Multiple AI Voices**
Hal ships with Apple Intelligence built in — always available, no download
required. For users who want a fully private, on-device experience, Hal offers
a curated library of tested local models including Gemma 4 E2B, Llama 3.2 3B,
Qwen 3.5 2B, and Dolphin 3.0. Each has a distinct voice and character. Download
any or all — they run entirely on your device, with nothing sent to any server.

**Genuinely Private**
When you use a local MLX model, your conversations never leave your iPhone.
No network calls. No server. No exceptions. When using Apple Intelligence,
inference occurs on-device when offline. When connected, Apple's Private Cloud
Compute may be used — your prompts are encrypted in transit and processed in
short-lived, non-persistent memory on Apple-controlled servers. Apple states
no data is retained after processing.

**Memory That Persists**
Hal remembers. A semantic memory system stores what matters across
conversations, weighted by recency and relevance, and retrieved when it's
useful. You can see exactly what Hal remembers and why — transparency is
built into the architecture, not bolted on.

**Salon Mode**
Put multiple AI voices in conversation with each other. Gemma and Dolphin
discussing the same question from different perspectives. Llama and Qwen
in dialogue. Each voice responds independently or builds on what came
before — you choose the mode. A power user feature accessible in
Settings → Power User Mode.

**Transparency as Architecture**
Hal doesn't hide how it works. Token counts, memory retrieval, model
identity, inference timing — all visible. When Hal remembers something,
it tells you how. When it doesn't know something, it says so.

**Power User Controls**
Tune memory depth, recency weighting, semantic similarity, half-life decay,
temperature, and RAG settings. Per-model settings — each AI voice remembers
your preferences independently.

**For Users Who Want to Understand AI**
Hal is an educational window into how large language models actually work.
Not a black box. A transparent system you can inspect, tune, and learn from.

---

Note on hardware: Local MLX models are validated on iPhone 16 family and
iPhone 17+. iPhone 15 Pro should work. Older devices may run slowly or
not at all. A hardware disclosure appears on first download attempt.

---

## 2. APP STORE SUBTITLE (30 characters max)

Current: "Private AI Assistant"
Proposed: "Private AI with Memory"

(If that's too long at 22 chars, confirm it fits — it should.)

---

## 3. KEYWORDS (100 characters max, comma-separated)

Proposed:
AI,assistant,private,on-device,memory,local,LLM,Gemma,MLX,chat,transparent,salon

(Check character count — trim if needed. Prioritize: private, on-device,
memory, local, AI, assistant.)

---

## 4. WHAT'S NEW (Version Release Notes)

Version 2.0

This is a significant update. Here is what changed:

- Four curated local AI models now available: Gemma 4 E2B, Llama 3.2 3B,
  Qwen 3.5 2B, and Dolphin 3.0. Each runs entirely on your device.
- Salon Mode: put multiple AI voices in conversation with each other.
  Independent and context-aware modes. Up to four seats.
- Per-model settings: temperature, memory depth, and RAG configuration
  are saved independently for each model.
- Privacy fix: the memory retrieval gate now routes through whichever
  model you have selected. Previously it always used Apple Intelligence
  regardless of your choice.
- Real token streaming: responses now stream as they generate rather than
  appearing all at once.
- Background downloads: model downloads continue while the app is
  backgrounded or the phone is locked.
- Unified model status dots: one dot, one meaning across all screens.
- Significant performance improvements throughout.

---

## 5. README.md (GitHub — replaces current content entirely)

```markdown
# Hal Universal

**Private. Powerful. Personal.**

Hal Universal is an on-device AI assistant for iPhone, iPad, and Mac.
It gives you a thoughtful, private companion for conversation, reflection,
and creativity — and shows you how AI actually works along the way.

---

## Models

Hal ships with **Apple Intelligence** built in — always available, no
download required.

For users who want a fully private on-device experience, Hal offers a
curated library of tested local models:

| Model | Size | Character |
|---|---|---|
| Gemma 4 E2B (4-bit) | 3.6 GB | Philosopher — dialectical, open |
| Llama 3.2 3B (4-bit) | 2.0 GB | Workhorse — grounded, reliable |
| Qwen 3.5 2B (4-bit) | 1.8 GB | Generalist — thorough, versatile |
| Dolphin 3.0 (4-bit) | 2.0 GB | Free-thinking — uniquely tuned for open inquiry |

Local models run entirely on your device. Nothing is sent to any server.

**Hardware note:** Local models are validated on iPhone 16 family and
iPhone 17+. iPhone 15 Pro should work. Older devices may run slowly.

---

## Privacy

**Local MLX models:** 100% on-device. No network calls. No exceptions.

**Apple Intelligence:** On-device when offline. When connected, Apple's
Private Cloud Compute may be used — prompts are encrypted in transit,
processed in short-lived non-persistent memory on Apple-controlled servers.
Apple states no data is retained after processing.

Hal Universal does not collect, store, or share any personal data.
All memory and processing occur locally on your device.

---

## Memory

Hal maintains a persistent semantic memory across conversations. It
weighs recency and relevance, applies decay over time, and retrieves
what's useful when it's useful. You can see exactly what Hal remembers
and why — transparency is built into the architecture.

---

## Salon Mode

Put multiple AI voices in conversation with each other. Up to four
seats. Independent mode (each voice isolated) or context-aware mode
(each voice sees what came before). A power user feature accessible
in Settings → Power User Mode.

---

## Key Features

- 🔒 **Local-first** — MLX models always on-device
- 🧠 **Persistent semantic memory** — across conversations, weighted by recency
- 🎭 **Salon Mode** — multiple AI voices in dialogue
- ⚙️ **Per-model settings** — temperature, memory depth, RAG per model
- 📊 **Transparent architecture** — token counts, memory retrieval, all visible
- 📥 **Background downloads** — models download while phone is locked
- 🔄 **Real streaming** — responses stream as they generate

---

## Power User Controls

In Settings → Power User:

- Memory depth
- Recency weighting and half-life decay
- Semantic similarity threshold
- RAG retrieval size
- Temperature (per model)
- System prompt (per model, with per-model framing layer)

---

## Troubleshooting

**Reset (DB Nuke)**
Clears Hal's local SQLite database and all conversation memory.
Models remain installed. Nothing leaves your device.

**Model Management**
Settings → Browse Model Library → Downloaded section.
Delete and redownload any model from here.

---

## Privacy Policy

Hal Universal does not collect, store, or share any personal data.
All inference, memory, and processing occur locally on your device.
The app does not transmit your data externally.

---

## Support

For questions, feedback, or privacy concerns:
**Mark Friedlander**
📧 markfriedlander@yahoo.com

---

## Version

Hal Universal 2.0 — May 2026
```

---

## 6. APP STORE PRIVACY QUESTIONNAIRE

The following answers reflect what is actually in the build. Do not change
these without checking with Mark first.

**Data Not Collected** — confirm this is still accurate. Hal does not:
- Collect any user data
- Use analytics
- Use advertising identifiers
- Track users across apps or websites
- Send any data to external servers

The only caveat is Apple Intelligence's Private Cloud Compute when connected,
which is Apple's infrastructure, not ours, and is already disclosed in the
description.

If the ASC privacy form asks about third-party SDKs or frameworks that collect
data, the answer is none — we use Apple frameworks only.

---

## 7. SUPPORT URL

Current: https://github.com/markfriedlander/Hal-Universal/blob/main/README.md
Proposed: Same — the README serves as support page. Confirm this is still
the URL in ASC and that it matches after the README update.

---

## 8. PRIVACY POLICY URL

Current: https://github.com/markfriedlander/Hal-Universal/blob/main/README.md
Proposed: Same — the Privacy Policy section of the README serves this role.
No changes needed beyond the README update above.

---

## 9. SCREENSHOTS

Most screenshots are already taken. Two things needed:

- Remove any screenshots that show Phi-4 or reference Phi anywhere in the UI
- Add screenshots showing the new Model Library UI (the three-segment
  curated/downloaded/library design) and the Salon Mode footer with seat
  and model attribution

Do not replace screenshots in ASC yourself — prepare the set and flag
which ones are ready and which need to be swapped. Mark will do the
actual upload in ASC.

---

## YOUR ACTIONS

1. Replace the README.md on the mlx-experiment branch with the content in
   section 5 above. Commit and push.

2. When the branch merges to main, the live GitHub README will update
   automatically.

3. For App Store Connect fields (sections 1-4 and 6): prepare these for
   Mark to review and paste into ASC himself. Do not submit to ASC
   directly — Mark will do the actual submission. Your job is to have
   the text ready and accurate.

4. Flag anything in this document you believe is inaccurate based on
   what you know is actually in the build. Accuracy is more important
   than polish.
