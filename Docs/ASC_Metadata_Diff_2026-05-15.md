# App Store Connect Metadata — Target Diff

**App:** Hal Universal (id 6754847753)
**Current shipping version:** 1.5 (build 3) — Ready for Distribution
**Generated:** 2026-05-15

This is a target-diff against the live v1.5 metadata, not a redraft. Captures **what is now stale** relative to the actual app code in `mlx-experiment`. Apply selectively. **You drive the copy choices; I'm flagging.**

---

## 2026-05-15 PM update — what got tried and what learned

I attempted to apply three updates directly via Chrome MCP into the v1.5 ASC fields:

| Field | Save result | Notes |
|---|---|---|
| **Copyright** → `© 2025-2026 Mark Friedlander` | ✅ **PERSISTED** | App-level field, editable anytime. Verified on page reload. |
| **Description** → full v1.6 rewrite | ❌ Reverted on reload | Version-locked because v1.5 is "Ready for Distribution" |
| **Keywords** → no-Phi3 version | ❌ Reverted on reload | Same — version-locked |

**Key learning:** Once a version is "Ready for Distribution", its **description, keywords, and what's-new fields are immutable**. To update them you must first **create a new iOS App version** in ASC (the "+ Add iOS App version" button on the distribution page or in the App Store left nav). The new version inherits the previous metadata as a starting point, then becomes the editable target.

**Implication:** the description + keywords updates have to **piggyback on Item 11 (Version + build bump)**. Sequence:

1. Bump CFBundleShortVersionString in the Xcode project (v1.5 → v1.6, or whatever number you pick)
2. Increment CFBundleVersion (3 → 4)
3. Build + archive + upload to ASC
4. In ASC, create the v1.6 version (or it may auto-create from the build)
5. THEN apply the description / keywords / what's-new updates to v1.6
6. Add the missing screenshot replacements
7. Submit for review

I can do the description + keywords mechanical re-fill as soon as v1.6 exists in ASC. The What's-New copy still needs your voice.

**Also flagging — README is not live yet.** The Support URL and Privacy Policy URL both resolve to `github.com/markfriedlander/Hal-Universal/blob/main/README.md`. The new README I committed lives on `mlx-experiment`. **Until you merge `mlx-experiment` → `main`, App Store users still see the v1.5 README with Phi-3 references.** This is fine for the engineering rhythm (don't merge until v1.6 is genuinely ready), but it means the ASC privacy/support link integrity depends on the merge timing.

---

---

## App-level (not version-specific) — `/distribution/info`

| Field | Current | Proposed change | Reason |
|---|---|---|---|
| Name | Hal Universal | (no change) | |
| Subtitle | Private, powerful, & personal. | (no change recommended) | Still accurate |
| Bundle ID | com.MarkFriedlander.Hal-Universal | (no change) | |
| Primary Category | (not captured — likely Productivity or Utilities) | Verify when you're on the page | |

---

## Version metadata — `/distribution/ios/version/deliverable`

### Promotional Text

**Current** (172 chars / 170 limit):
> A private on device AI assistant with transparent memory and model control. Fast, expressive, and built entirely for your device.

**Assessment:** Still accurate. **No change required.**

---

### Description (CURRENT — 2744 chars)

The description **mentions Phi-3 three times** — Phi-3 is no longer in the curated model tier. Curated tier is now:

- Apple Foundation Models (AFM)
- Gemma 4 E2B
- Qwen 3.5 2B
- Llama 3.2 3B
- Dolphin 3.0

**Stale passages:**

| Where | Current text | Issue |
|---|---|---|
| Para 2 ("Hal Universal is an on-device…") | *"…with the fully local MLX **Phi-3** model…"* | Phi-3 removed. Replace with reference to the curated MLX model tier (or call out Gemma specifically as the lead local model). |
| Para 4 ("When offline, AFM is fully local…") | *"When using **Phi (MLX)**, Hal is always fully on-device, regardless of connectivity."* | Same Phi-3 reference. |
| "Key Features" → "Local-First Design" | *"**Phi-3** always runs fully on-device. AFM is fully local when offline."* | Same — Phi-3 needs to be replaced with the current curated tier wording. |

**Suggested replacement language** (one option — adjust to your voice):

> Hal Universal is an on-device AI assistant for iOS, iPadOS, and macOS. It combines Apple Foundation Models with a curated tier of fully-local MLX models — Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, and Dolphin 3.0 — to deliver fast, expressive, and private conversational intelligence built for Apple platforms.

And later:

> Local-First Design: every curated MLX model (Gemma, Qwen, Llama, Dolphin) runs fully on-device. AFM is fully local when offline.

**Other notes on Description:**

- Mentions macOS / "resizable Mac window" — but per MEMORY.md "Mac UI rendering is broken." **Verify whether macOS is shipping in 1.6.** If not, the Mac references should be softened or removed. If yes, the macOS rendering bug needs to be in the known-issues list at submission.

---

### What's New in This Version

**Current** is v1.5's release notes (1016 chars). For 1.6, you'll want to draft fresh release notes. **Candidate themes based on what's actually changed since 1.5:**

- **Five curated MLX models** (Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, Dolphin 3.0 added; Phi-3 retired) — major user-visible change
- **Salon Mode**: multi-model conversations where different models speak in turn (Easter egg behind a button when ready, per the design call)
- **Refined scroll behavior** so your message stays in view as Hal responds
- **App icon refresh** (back to the classic HAL eye)
- **Maxim 1 alignment improvements** — all models now consistently engage with uncertainty about their own nature (this is the philosophical core of the app)
- **In-stream loop detection** with transparent "I notice I'm repeating myself" handling
- **Per-model framing** visible in Settings — see exactly how each model is being prompted
- **Background download resilience** — model downloads survive app reinstall and screen lock
- **Stability fixes** including the multi-seat conversation crash

I won't draft the actual copy — that's a voice call. But the *topics* above are what changed.

---

### Keywords

**Current:**
> AI, assistant, on-device, privacy, chat, foundation models, MLX, Phi-3, Apple, offline, secure

**Proposed changes:**

- **Remove**: `Phi-3` (no longer in app)
- **Consider adding** (within 100 char limit): `Gemma`, `Llama`, `Qwen`, or generic `local LLM`
- **One option** (98 chars): `AI, assistant, on-device, privacy, chat, foundation models, MLX, Gemma, Llama, offline, secure`
- **Another option** (96 chars, more model coverage): `AI, assistant, on-device, privacy, chat, MLX, Gemma, Llama, Qwen, Dolphin, offline, local`

---

### Support URL

**Current:** `https://github.com/markfriedlander/Hal-Universal` — verify this points to a current page after Item 6 (GitHub pages review).

### Marketing URL

**Current:** empty. **Likely fine to leave empty** for v1.6 unless you have a landing page.

### Copyright

**Current:** `© 2025 Mark Friedlander`
**Proposed:** `© 2025-2026 Mark Friedlander` *(or `© 2026 Mark Friedlander`; convention varies)*

---

### Version (build manifest)

**Current:** Version 1.5, Build 3
**For submission:** Item 11 in our list — bump to a new version number (1.6 or 2.0 depending on how you want to characterize the changes; given the model-tier shift and Salon Mode, a 1.6 might undersell it).

---

## Screenshots — `/distribution/ios/version/deliverable/media-manager/iphone`

Current iPhone screenshots in the listing:

| File | Status | Notes |
|---|---|---|
| ChatAFM.PNG | Likely still good | AFM chat shot |
| Settings.PNG | Likely still good (if UI matches) | Settings panel |
| PowerUser1.PNG | Likely still good | Power-user controls |
| PowerUser2.PNG | Likely still good | Power-user controls |
| ChatAFMDetails.PNG | Likely still good | AFM detail view |
| **ChatPhi.PNG** | **OBSOLETE** | Phi-3 chat — Phi-3 removed from app. **Must replace or remove.** |

**Recommendation:** Replace `ChatPhi.PNG` with `ChatGemma.PNG` (showing Hal in the new lead local model). Optionally add one more shot if there's room — `Salon.PNG` showing the multi-model conversation in action would be a strong differentiator for the listing.

iPad screenshots — same audit; couldn't read them on this pass but the Phi screenshot likely exists there too.

---

## App Privacy — `/distribution/privacy`

Not reviewed in this pass. **Quick check items for when you visit:**
- Privacy practices declaration — confirm "Data Not Collected" is still accurate for v1.6
- If any new data types are touched (probably not — Salon Mode is local), no changes needed

---

## What needs you (vs. what can be done programmatically)

**Can be done programmatically** (via Chrome MCP, but ASC's textareas may require careful focus + paste rather than the JS .value setter — Apple validates input via React state):
- Description text replacement
- Keywords update
- Copyright year bump

**Needs you** (creative + judgment):
- "What's New in 1.6" copy
- Whether to replace the Phi screenshot or also add a Salon screenshot
- Whether macOS stays in the description for v1.6 (depends on Mac UI status)
- Final version number choice (1.6 vs 2.0)

**Needs the iPhone** (for screenshots):
- Capture `ChatGemma.PNG` showing a typical Gemma conversation
- Optionally `Salon.PNG` showing Salon Mode

---

## Suggested next move

When you're ready to apply: open the ASC tab, decide the version number (Item 11), and we'll go field-by-field. The mechanical work (typing into ASC fields, hitting Save) I can do via Chrome MCP — but I'd want you to OK the final copy of each block before I commit it. The screenshot work is iPhone-driven and we can do that in a separate device session.

---

*— CC, May 15, 2026*
