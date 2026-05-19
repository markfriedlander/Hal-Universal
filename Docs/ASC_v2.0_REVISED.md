# Hal Universal v2.0 — App Store Connect Metadata (REVISED)

**For:** Mark, pasting into ASC
**From:** CC, autonomous overnight pass (2026-05-18)
**Status:** Draft for Mark's review. Compare to `ASC_v2.0_Paste_Ready.md`.

**Why this revision exists:** SC's directive noted the previous draft
"describes memory compression that no longer exists." Auditing against
the shipping code, the situation is more nuanced — *some* compression
infrastructure does ship (`compressed_segments` table + TextSummarizer
for self-knowledge sections, with a "condensed" footer badge). But the
previous draft over-promised it as a flagship behavior. This revision:

1. Demotes compression from a marquee feature to one sentence about
   how the Self Model viewer footer surfaces it.
2. Replaces it as a marquee with the **Self Model viewer + traits**
   (Phases 1-4 of v1 crystallization that actually landed in v2.0).
3. Acknowledges the **per-turn memory pre-flight** that lands gracefully
   instead of crashing (Item 11 fix) — this is what users see when a
   model's context fills up.
4. Mentions the **opt-in upgraded retrieval (Nomic)** since it's the
   biggest recall improvement in v2.0 and ships in the Model Library.
5. Trims marketing fluff and stays closer to "what users will actually
   experience the first time they use the app."

---

## 1. App Name

**Hal Universal** *(no change)*

---

## 2. Subtitle (30 chars max)

```
Private AI with Memory
```

22 chars. *(No change.)*

---

## 3. Promotional Text (170 chars max)

```
On-device AI with persistent memory, multiple model voices, and full transparency about how it works. Nothing leaves your device when running local models.
```

154 chars. *(Rewrote: focus on the on-device nature and what's actually new.)*

---

## 4. Description (REVISED)

```
Hal Universal

Private. Powerful. Personal.

Hal Universal is an on-device AI assistant for iPhone, iPad, and Mac. A thoughtful, private companion for conversation, reflection, and creativity — and a window into how AI actually works.

Multiple AI Voices

Hal ships with Apple Intelligence built in — always available, no download required. For users who want a fully private on-device experience, Hal offers a curated library of tested local models: Gemma 4 E2B, Llama 3.2 3B, Qwen 3.5 2B, and Dolphin 3.0. Each has a distinct voice. Download any or all — they run entirely on your device, with nothing sent to any server.

Genuinely Private

When you use a local MLX model, your conversations never leave your iPhone. No network calls. No server. When using Apple Intelligence, inference is on-device when offline; when connected, Apple's Private Cloud Compute may be used (encrypted in transit, processed in non-persistent memory on Apple-controlled servers).

Memory That Persists

Hal remembers across conversations. A semantic memory system weighted by recency and relevance retrieves what's useful when it's useful. The optional Nomic retrieval upgrade dramatically improves recall on specific facts (opt-in in the Model Library, 522 MB).

When a turn's context would exceed the active model's window, Hal posts a brief explanation in the conversation rather than silently dropping content. When self-knowledge sections are compressed to fit, a small "condensed" badge appears in the message footer.

Self Model

Hal builds a structured self-model over time from patterns it notices in your conversations — values, preferences, themes. You can browse the Self Model viewer to see what Hal has crystallized about you, and toggle each entry between private (visible only to you) and shareable (available for export). Every entry is editable. Nothing leaves your device without your action.

Salon Mode

Put up to four AI voices in conversation. Independent mode (each voice isolated) or context-aware (each builds on what came before). Accessible in Settings → Power User Mode.

Transparency as Architecture

Hal shows you the work. Token counts, memory retrieval, model identity, inference timing, compression events — all visible. When Hal remembers something, it tells you how. When it doesn't know something, it says so.

Power User Controls

Tune memory depth, recency weighting, semantic similarity, half-life decay, temperature, and RAG settings. Per-model settings: each AI voice remembers your preferences independently.

For Users Who Want to Understand AI

Hal is an educational window into how large language models actually work. Not a black box. A transparent system you can inspect, tune, and learn from.

Hardware note: Local MLX models are validated on iPhone 16 family and iPhone 17 family. iPhone 15 Pro should work. Older devices may run slowly or not at all. A hardware disclosure appears on first download attempt.
```

**Changes from prior draft:**
- Removed the "Hal asks that model to condense its own self-knowledge"
  framing that overstated the mechanism. Replaced with the actual
  behavior: graceful pre-flight refusal + per-segment "condensed"
  footer badge.
- Added a **Self Model** section (real v2.0 feature, was missing).
- Mentioned the **Nomic retrieval upgrade** as an opt-in in Model
  Library.
- Trimmed two paragraphs that were marketing prose more than
  description.

---

## 5. Keywords (100 char max)

```
AI,assistant,private,on-device,memory,local,LLM,Gemma,MLX,chat,transparent,salon
```

79 chars. *(No change.)*

---

## 6. What's New in This Version (REVISED)

```
Version 2.0 — significant update.

- Four curated local AI models now available: Gemma 4 E2B, Llama 3.2 3B, Qwen 3.5 2B, and Dolphin 3.0. Each runs entirely on your device.
- Self Model: Hal now builds a structured self-model of you over time from patterns in conversation. Browse and edit it in Settings → Self Model. Each entry is private by default.
- Salon Mode: put up to four AI voices in conversation. Independent and context-aware modes.
- Per-model settings: temperature, memory depth, RAG configuration saved independently for each model.
- Upgraded retrieval (optional): Nomic Embed Text v1.5 available as an opt-in via Model Library — significantly better recall on specific facts than the default. 522 MB.
- Per-turn memory pre-flight: when a turn would exceed the active model's working memory, Hal explains why in chat rather than crashing.
- Real token streaming: responses stream as they generate.
- Background downloads: model downloads continue while the app is backgrounded or the phone is locked.
- Unified model status dots: one dot, one meaning across all screens.
- Significant performance and stability improvements.
```

**Changes:**
- Added Self Model (real, landed in v2.0).
- Added Nomic retrieval (real, opt-in, landed).
- Added per-turn memory pre-flight (real, Item 11 fix).
- Removed the "compression as flagship feature" bullet (kept the
  reality in the description body instead).
- Removed the "privacy fix" bullet (legacy framing — that fix
  predates v2.0's Self Model / pre-flight architecture).

---

## 7. Support URL

```
https://markfriedlander.github.io/Hal-Universal/support.html
```

*(No change. Same GitHub Pages prerequisite as before.)*

---

## 8. Privacy Policy URL

```
https://markfriedlander.github.io/Hal-Universal/privacy.html
```

*(No change. Same GitHub Pages prerequisite.)*

---

## 9. Copyright

```
© 2025-2026 Mark Friedlander
```

*(No change.)*

---

## 10. Screenshots

**To capture (6 total per submission spec):**
- Main chat with Apple Intelligence
- Main chat with an MLX model (Gemma 4 E2B)
- Self Model viewer (v2.0 marquee)
- Model Library (Hal's Picks tier)
- Settings — Power User
- Salon mode (or PromptDetailView if Salon is hard to capture)

CC cannot capture device screenshots — Mark needs to take these from
the device.

---

## 11. Privacy Questionnaire

*(No change from prior draft.)*

- Data Not Collected — confirm. Hal does not collect any user data,
  use analytics, use advertising identifiers, track users across apps
  or websites, or send any data to external servers operated by the
  developer.
- Third-party SDKs that collect data: None.
- Apple Intelligence / Private Cloud Compute is Apple's infrastructure,
  not ours, and is disclosed in the description.

---

## 12. Pre-Submit Sequence

*(Same as prior draft.)*

1. Version 2.0 (5) in project.pbxproj. Bump CFBundleVersion if needed.
2. Mark archives in Xcode (Product → Archive) and uploads via Organizer.
3. ASC auto-creates v2.0 draft once the build processes.
4. Enable GitHub Pages on Hal-Universal repo (Settings → Pages →
   branch `main` / `/`). Test both URLs return rendered HTML.
5. Merge any pending branch → main so README/privacy.html/support.html
   are live at the URLs ASC will reference.
6. Mark or CC (via Chrome MCP) fills v2.0 metadata.
7. Mark captures and uploads screenshots.
8. Mark answers privacy questionnaire.
9. Mark hits Submit for Review.

---

*— CC, 2026-05-18 (overnight autonomous pass)*
