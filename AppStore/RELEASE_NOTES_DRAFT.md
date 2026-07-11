# App Store Release — Review, What's New, Changelog (DRAFT)

**Status:** DRAFT for Mark's review. Nothing has been entered into App Store Connect.
CC could not reach ASC this session (the Claude-in-Chrome extension wasn't connected), so
the **live-text review still needs to happen together** — this doc is the prep so it's fast.

**Release facts (current repo state):**
- Live on the App Store: **v2.0, build 6** (since 2026-05-19). Non-EU markets only (DSA non-trader).
- Upcoming: **build 7**, version **v2.5** (decided by Mark 2026-07-11).
- Min iOS: **26.0** (Apple-Intelligence-capable devices only).
- Not yet done (the ship sequence): SHIP_BLOCKER flip (`kLocalAPIEnabledOnLaunch`→false),
  CFBundleVersion 6→7, ASC upload + submit.

---

## 1. "What's New" — user-facing draft (goes in the ASC What's New field)

> Written for users (benefits, not internals). Trim to taste. Naming/emphasis is Mark's call.

```
Hal keeps getting more capable — and more honest about how he works.

• Ternary Bonsai 8B — Hal's deepest on-device model yet. An 8-billion-parameter reasoner
  that runs entirely on your iPhone, about as fast as the smaller models.

• A privacy lock you can see. A lock in the toolbar shows at a glance whether Hal is in a
  state where data could leave your device. Tap it to understand why.

• Sharper memory. More accurate long-term recall, an optional new embedding model, and
  rebalanced search so the right memories surface — and recent ones are weighted correctly.

• Download models once. Models are shared with our companion app, so you don't re-download.

• A more honest Hal. His self-reflections are now written in his own first-person voice,
  and his Self Model screen reads like plain language instead of raw data. When Hal doesn't
  have something in memory, he tells you — instead of guessing.

• Smoother and steadier: faster model switching and loading, and settings that stick.
```

**Decisions applied to the What's New:**
- "our companion app" stays **generic** (Mark, 2026-07-11 — don't name Posey for now).
- Apple Watch removal: NOT mentioned (it never shipped working). Still verify the live
  listing doesn't advertise a Watch app anywhere (see §3).

---

## 2. Full changelog since v2.0 (reference — everything that changed)

**New features / models**
- **Ternary Bonsai 8B** — first 8B and first 2-bit model (Qwen3-8B arch, 2.32 GB, 65k ctx);
  the "deep reasoner." Ships curated.
- **Privacy Lock indicator** — toolbar lock/lock.open glyph + explainer popover; shows when
  data could leave the device (network + active model + salon config).
- **Multi-embedder memory** — added Mixedbread **mxbai-embed-large** alongside Apple
  NLContextual (default) and Nomic Embed v1.5; switching is non-destructive (each backend
  keeps its own vectors). Retrieval fusion (RRF) rebalanced for better real-world recall.
- **Cross-app model sharing (Posey)** — shared on-device model store via App Group; download
  a model once and both apps use it; refcount-safe deletes; legacy downloads migrated in.

**Honesty / self-model (the philosophical core)**
- Reflections are now genuine **first-person** and no longer "grounded" against the
  conversation (grounding was collapsing them into quote-collages). Summaries stay grounded.
- **Self Model** screen humanized — readable labels/values instead of raw JSON; self-knowledge
  shown in pink; inline prompt-detail coloring matches the prompt viewer.
- Source-code self-knowledge corrected (Hal no longer miscounts his own architecture / names
  a removed model). Internal "DNA cleanup": source blocks renumbered + a master index +
  a validator; comments scrubbed of stale/dead-feature references. (Internal — not user-facing.)

**Reliability / bug fixes**
- Recency scoring reconnected to retrieval (fresh memories rank correctly again).
- Per-model settings persist correctly.
- Confabulation gate: when a memory search returns nothing, Hal says he doesn't have it
  instead of inventing.
- Reload-on-demand: chatting to an unloaded local model reloads it instead of erroring.
- Model-switch disk-truth fix (a model present in the shared store now loads reliably).
- Model Library UX: clearer active-model delete, snappier model selection, "Add" vs
  "Download" wording aligned to on-disk truth.

**Removed**
- **Apple Watch companion fully excised** (the watch→phone relay is impossible under iOS
  background-compute limits). No Watch app ships.

---

## 3. ASC metadata review checklist (do together / when the extension reconnects)

Go field by field. The recurring risk is **stale references to things no longer in the app.**

**Hunt-and-remove across ALL text fields (name, subtitle, promo text, description, keywords, What's New):**
- [ ] **"Phi" / "Phi-3" / "Phi-4"** — Phi models are no longer shipped. Remove/replace anywhere.
- [ ] **Apple Watch / "Watch app" / "on your wrist"** — the companion was removed. Remove any claim.
- [ ] **Specific model lists** — if the copy names the bundled models, update to the current
      lineup: Apple Intelligence, Gemma 4 E2B, Qwen 3.5 2B, Llama 3.2 3B, Dolphin 3.0,
      Ternary Bonsai 8B (+ embedders: Apple NLContextual, Nomic Embed v1.5, mxbai-embed-large).
- [ ] **Architecture claims / block counts** ("32 blocks", "single file", etc.) — remove; Hal's
      self-description is now count-free, the marketing copy should be too.
- [ ] **iOS version** — if any text states a minimum, it's **iOS 26** now (was 18).
- [ ] **EU availability** — copy must not imply EU availability (we're non-EU only; that's set
      in Availability, but don't contradict it in text).

**Field-by-field:**
- [ ] **App Name** — unchanged? ("Hal Universal" / current name.)
- [ ] **Subtitle** (30 chars) — still accurate to the app's pitch (transparency / on-device AI)?
- [ ] **Promotional Text** (170 chars, editable without a new binary) — good place to tease
      Bonsai 8B / privacy lock. This one field CAN be updated on the live version independently.
- [ ] **Description** — read top to bottom for the stale items above; make sure the
      feature list matches what ships now (Salon Mode, Self Model, Privacy Lock, model sharing).
- [ ] **Keywords** (100 chars) — drop "phi"/"watch" if present; consider adding terms like
      on-device, private AI, local LLM, transparency, memory. (Can't see current keywords —
      review live.)
- [ ] **What's New** — paste the §1 draft (only on the new version).
- [ ] **Support URL / Marketing URL** — resolve and are current? (Promo webpage is a separate
      to-do per NEXT.md.)
- [ ] **Screenshots** — replace the 6.5" set with the six new ones in
      `AppStore/screenshots/6.5-inch/` (recaptured, real status bar, corrected Hal). Confirm
      there are **no Apple Watch screenshots** in any slot. **6.5" slot only** (Mark,
      2026-07-11 — not doing the 6.9" slot this release).
- [ ] **App Privacy / data-collection answers** — unchanged (fully on-device; no new data
      collection added this cycle). Verify nothing needs updating.

**Which edits need a new version vs. can be done now:**
- **Promotional Text** and (for a live app) some metadata can be edited without a new build.
- **What's New** and **screenshots** attach to the **new version** — so they require creating
  the version 7 record in ASC and submitting. Per Mark's instruction, those are "write it
  down, don't enter" until we do it together / at submit time.

---

## 4. Decisions (settled by Mark, 2026-07-11)
1. **Version = v2.5.**
2. **Keep Posey generic** ("our companion app") for now.
3. **6.5" slot only** (no 6.9" this release).
