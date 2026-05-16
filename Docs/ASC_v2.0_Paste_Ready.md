# Hal Universal v2.0 — App Store Connect Paste-Ready Metadata

**For:** Mark, pasting into ASC
**From:** CC, with audit corrections applied
**Date:** 2026-05-16
**Source of truth this was built from:**
  - `Docs/SC_Release_Materials/CC_AppStore_And_GitHub_Update.md` (SC's draft)
  - Audit corrections from this morning's review (see CC's flags in chat for 1-3 + 5)

Every block below is paste-ready. The corrections from SC's draft are
folded in. Read each section carefully before pasting — these go live
the moment you save.

---

## 1. App Name

**Hal Universal** *(no change)*

---

## 2. Subtitle (30 chars max)

```
Private AI with Memory
```

22 characters. Fits comfortably.

---

## 3. Promotional Text (170 chars max)

```
A private on-device AI assistant with transparent memory and model control. Fast, expressive, and built entirely for your device.
```

130 characters. *(Carried forward from v1.5 — still accurate.)*

---

## 4. Description

```
Hal Universal

Private. Powerful. Personal.

Hal Universal is an on-device AI assistant for iPhone, iPad, and Mac. It gives you a thoughtful, private companion for conversation, reflection, and creativity — and shows you how the AI actually works along the way.

Multiple AI Voices

Hal ships with Apple Intelligence built in — always available, no download required. For users who want a fully private, on-device experience, Hal offers a curated library of tested local models including Gemma 4 E2B, Llama 3.2 3B, Qwen 3.5 2B, and Dolphin 3.0. Each has a distinct voice and character. Download any or all — they run entirely on your device, with nothing sent to any server.

Genuinely Private

When you use a local MLX model, your conversations never leave your iPhone. No network calls. No server. No exceptions. When using Apple Intelligence, inference occurs on-device when offline. When connected, Apple's Private Cloud Compute may be used — your prompts are encrypted in transit and processed in short-lived, non-persistent memory on Apple-controlled servers. Apple states no data is retained after processing.

Memory That Persists

Hal remembers. A semantic memory system stores what matters across conversations, weighted by recency and relevance, and retrieved when it's useful. You can see exactly what Hal remembers and why — transparency is built into the architecture, not bolted on. When a model's context window is smaller than Hal's full memory, Hal asks that model to condense its own self-knowledge for the turn — never silently trim.

Salon Mode

Put multiple AI voices in conversation with each other. Gemma and Dolphin discussing the same question from different perspectives. Llama and Qwen in dialogue. Each voice responds independently or builds on what came before — you choose the mode. A power user feature accessible in Settings → Power User Mode.

Transparency as Architecture

Hal doesn't hide how it works. Token counts, memory retrieval, model identity, inference timing, and compression events — all visible. When Hal remembers something, it tells you how. When it doesn't know something, it says so.

Power User Controls

Tune memory depth, recency weighting, semantic similarity, half-life decay, temperature, and RAG settings. Per-model settings — each AI voice remembers your preferences independently.

For Users Who Want to Understand AI

Hal is an educational window into how large language models actually work. Not a black box. A transparent system you can inspect, tune, and learn from.

Hardware note: Local MLX models are validated on iPhone 16 family and iPhone 17+. iPhone 15 Pro should work. Older devices may run slowly or not at all. A hardware disclosure appears on first download attempt.
```

**Changes from SC's draft:**
- Added sentence on compression to "Memory That Persists" section ("When a model's context window is smaller… never silently trim.") — accurate to what v2.0 ships.
- Added "and compression events" to "Transparency as Architecture" bullet list of visible mechanisms.

---

## 5. Keywords (100 char max)

```
AI,assistant,private,on-device,memory,local,LLM,Gemma,MLX,chat,transparent,salon
```

79 characters.

---

## 6. What's New in This Version

```
Version 2.0 — significant update.

- Four curated local AI models now available: Gemma 4 E2B, Llama 3.2 3B, Qwen 3.5 2B, and Dolphin 3.0. Each runs entirely on your device.
- Salon Mode: put multiple AI voices in conversation with each other. Independent and context-aware modes. Up to four seats.
- Per-model settings: temperature, memory depth, and RAG configuration are saved independently for each model.
- Privacy fix: the memory retrieval gate now routes through whichever model you have selected. Previously it always used Apple Intelligence regardless of your choice.
- Real token streaming: responses now stream as they generate rather than appearing all at once.
- Background downloads: model downloads continue while the app is backgrounded or the phone is locked.
- Memory compression: when a model's context window is smaller than Hal's full memory, that model now condenses its own self-knowledge for the turn rather than silently dropping content. The response footer shows when condensing happened.
- Unified model status dots: one dot, one meaning across all screens.
- Significant performance improvements throughout.
```

**Changes from SC's draft:** Added the "Memory compression" bullet — this is a flagship v2.0 architectural change that should be surfaced. Otherwise unchanged.

---

## 7. Support URL

```
https://markfriedlander.github.io/Hal-Universal/support.html
```

**ACTION REQUIRED BEFORE THIS GOES LIVE:** Enable GitHub Pages on the
`markfriedlander/Hal-Universal` repo. Settings → Pages → Source: deploy
from branch `main` / `/` (root). Pages will serve any HTML file at the
URL pattern above. The HTML lives at `support.html` in the repo root
(committed alongside this doc).

---

## 8. Privacy Policy URL

```
https://markfriedlander.github.io/Hal-Universal/privacy.html
```

Same GitHub Pages prerequisite. The HTML lives at `privacy.html` in the
repo root.

---

## 9. Copyright

```
© 2025-2026 Mark Friedlander
```

*(Already updated to this on 2026-05-15; verify it persisted in ASC.)*

---

## 10. Screenshots

**To replace before submit:**
- `ChatPhi.PNG` — obsolete (Phi-3 no longer in app). Replace with `ChatGemma.PNG`.

**To add (optional but recommended):**
- `Salon.PNG` — multi-model conversation with seat/model attribution in the footer. Strong differentiator.
- `ModelLibrary.PNG` — Settings → Browse Model Library, showing Hal's Picks + Community Models. Shows the curated tier visually.

Capture these from your iPhone. Mark uploads via ASC; CC can't capture device screenshots.

---

## 11. Privacy Questionnaire

If ASC asks during submission:

- **Data Not Collected** — confirm. Hal does not:
  - Collect any user data
  - Use analytics
  - Use advertising identifiers
  - Track users across apps or websites
  - Send any data to external servers operated by the developer
- **Third-party SDKs or frameworks that collect data:** None. Apple frameworks only.
- The Apple Intelligence / Private Cloud Compute caveat is Apple's infrastructure, not ours, and is already disclosed in the description.

---

## 12. Pre-Submit Sequence

The order to do these:

1. **Bump done.** Version is 2.0 (4) in project.pbxproj. Confirmed via the diff in this commit.
2. **You archive in Xcode** (Product → Archive) and upload to ASC via Xcode Organizer.
3. **ASC auto-creates v2.0 version draft** once the build processes.
4. **Enable GitHub Pages** on the Hal-Universal repo (Settings → Pages → branch `main` / `/`). Test both URLs return rendered HTML before you paste them into ASC. (Takes a couple minutes to propagate after enabling.)
5. **Merge `mlx-experiment` → `main`** so README, privacy.html, and support.html are live at the URLs ASC will link to. Fast-forward merge, no conflicts expected. `git checkout main && git merge mlx-experiment && git push origin main`.
6. **CC fills v2.0 metadata via Chrome MCP** — description, keywords, what's-new, subtitle, URLs, copyright — using the blocks above. You approve each block before save.
7. **You capture + upload screenshots** from iPhone. Remove `ChatPhi.PNG`. Add `ChatGemma.PNG` (and optionally `Salon.PNG` / `ModelLibrary.PNG`).
8. **You answer the privacy questionnaire** in ASC using the answers in §11 above.
9. **You hit Submit for Review.**

CC does not submit to ASC directly. CC drives Chrome MCP for the metadata text fills only.

---

*— CC, 2026-05-16*
