# Hal Universal — Next

Forward-looking work. Items completed move out of here and into `HISTORY.md`.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-19 entry).

---

## What the next session should do first

1. Read this file, then `HANDOFF_BRIEF.md`, then the 2026-05-19 entry
   of `HISTORY.md`, then `CLAUDE.md` for standing rules.
2. Verify live state:
   ```bash
   python3 tests/hal_test.py state
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"
   ```
3. Pick up an item below. Bugs that block ship come first.

---

## Bugs to fix before ship

### Bug 1 — `SET_MEMORY_DEPTH` doesn't survive app re-init

Reproduced isolated 2026-05-19. The chain:
- User SET_MEMORY_DEPTH:N → vm.memoryDepth = N, @AppStorage persists.
- App relaunches (terminate + launch, or iOS jetsam + auto-restart).
- ChatViewModel init fires `ModelSettingsStore.shared.applyEffectiveSettings(for: initialModel)`
  at Hal.swift:11402.
- That call silently overwrites memoryDepth back to the active
  model's per-model default (Gemma's is 5).
- Next chat runs at the default, not the user's set value.

Smoking gun log line: `HALDEBUG-SETTINGS: Applied effective settings
for Gemma 4 E2B: ... depth=5` fires during init.

Two reasonable fixes — **product decision needed**:

- **(a) Persist a "user-overridden" boolean alongside `memoryDepth`.**
  Init only fires `applyEffectiveSettings` for parameters whose
  override flag is false. Defensible but adds a flag for every
  settable parameter that has a per-model default (temperature, RAG
  width, recency weight, etc.).

- **(b) `applyEffectiveSettings` only fires on actual model *change*,
  not on every init/relaunch when the model is unchanged from the
  previous run.** Cleaner architecturally but changes the init
  semantics for fresh-default boots.

### Bug 2a — Document RAG misses non-final chunks

Reproduced 2026-05-19 via `tests/hal_test.py` after importing a
test document `hal_doc_test.txt` (devicectl copy into app data
container, then `IMPORT_DOCUMENT:` against the device path).
Document is 5 paragraphs, chunked into 2. The chunks are stored
(`LIST_DOCUMENTS` shows 2 chunks), but `MEMORY_SEARCH_DEBUG` for
unique words from the first paragraph (`Berkenia`, `Veldros`,
`periwinkle`, `armadillo`) returns only generic conversation
snippets — none of the document chunks. Only the word `lighthouse`
(in the *last* paragraph) actually surfaces the document at rank 1.

Hypothesis: the second chunk made it into FTS but the first didn't.
Or chunk-1's content was overwritten by chunk metadata. The
`unifiedRows=23, ftsRows=23` from FTS_DIAG suggests parity in counts
but only one chunk is actually queryable.

Effect: if a user imports a document, only roughly the last
third of it can be retrieved by lexical query. Catastrophic for
real document Q&A use case. Ship-blocker for the "imported docs
as RAG" feature.

### Bug 2b — Confabulation when RAG misses target content

Reproduced same session. With Bug 2a active (RAG doesn't surface
the document chunk that contains "periwinkle armadillo"), asked
Hal "What is periwinkle armadillo?":

- **Gemma 4 E2B:** hedged appropriately ("I need some context
  to tell you what that refers to").
- **Apple Intelligence:** confidently invented an entire scenario
  about a magical creature appearing in the story, with paragraphs
  about narrative function and how to incorporate it.

The combination is the ship-blocker: RAG silently misses content,
then the model confidently fabricates. AFM is more prone than
Gemma but both can do it (Item 1 reactive run also caught Gemma
hallucinating "cinnamon and ginger" recipe at turn 10).

Fix vector: when RAG returns no high-relevance match for the
distinctive terms in a query, the chat path should either (a)
make that fact visible to the model via an explicit "no document
match found" system note, or (b) be more aggressive about telling
the user "I don't have that in my context window." Currently the
prompt just doesn't include the relevant chunk and the model
fills the void with plausible-sounding content.

### Bug 3 — First-turn-after-swap race for 3 GB MLX models

Reproduced in stress test 2026-05-19. After `SWITCH_MODEL:gemma-4-e2b-it-4bit`
(or Dolphin 3.0), the immediate next `/chat` returns the friendly
"Error: The selected language model could not be loaded or is not
available" string in <1 second. Smaller MLX models (Llama 3.2 3B,
Qwen 3.5 2B) don't hit this — they load faster than the chat starts.

Hypothesis: `SWITCH_MODEL` returns before MLX has finished mapping
the weights, and the immediate chat hits the not-loaded gate.

Fix options:
- Have `SWITCH_MODEL` block on model-ready before returning. Breaks
  the fire-and-forget convention but is the cleanest.
- Have `/chat` queue behind any in-flight load with a small timeout.
  Preserves the convention but adds queue logic.

### Bug 4 — Salon toggle scroll/flash ✓ FIXED + VERIFIED

v3 (banner relocation, 2026-05-19 late afternoon):
Banner moved from top of Personality section to a conditional
footer inside the Power User Mode section, below the picker. No
dead zone in single mode (the earlier opacity-reserved version
left visible empty space) and no shift of the picker when
toggling (banner is below picker in the same section, so toggle-
adding/removing it doesn't move the picker). Verified Power User
Mode label stable at y=746 across multiple toggles on iPhone 17
Pro sim. Plus: System Prompt now visually dimmed in salon mode
to match the banner's "individual model settings are locked"
promise. "Model framing for X" renamed to just "Model framing"
to match the naming of other rows.

Original investigation (v1, kept for historical reference):

### Bug 4 — Salon toggle scroll/flash (v1 investigation log)

Reproduced 2026-05-19 on iPhone 17 Pro simulator via the UI
picker tap (NOT via the API `SALON_SET_ENABLED:` command — that
path doesn't trigger it). Visual evidence:
`Docs/sim_screenshots_2026-05-19/repro_salon_before_toggle.png`
vs `repro_salon_after_single.png`. Scroll position shifts up by
~one row-height when toggling Multi LLM → Single LLM.

**Root cause** (Hal.swift:7127-7170 + 7272-7276): the AI Model
section row content changes shape between Salon Mode and Active
Model variants:
- Salon Mode row: Text + Spacer + HStack(person.2.fill icon +
  seat-summary text)
- Active Model row: Text + Spacer + HStack(status-dot Circle +
  model-name text)

The two variants have slightly different intrinsic heights. Plus
the explanatory caption text below the picker changes ("Advanced
settings for single model operation" vs "Configure multiple
models for collaborative conversations") — same .font, but
different content length can force a different wrap. When
salonConfig.isEnabled toggles, List/Form re-layouts and the
scroll position adjusts.

**Fix vector:** stabilize the row content height. Options:
- Wrap both row variants' trailing HStack in a fixed `.frame(height: ...)`
  so the intrinsic height doesn't differ.
- Use a stable `.frame(minHeight: ...)` on the row's HStack.
- Move the conditional caption to a position that doesn't
  trigger List re-layout.

Code change is small but needs visual diff verification — run the
same before/after toggle sequence after the fix and confirm scroll
position stays stable.

### Bug 5 — PromptDetailView wiring confirmation ✓ VERIFIED on sim

Verified on iPhone 17 Pro simulator 2026-05-19. Long-press on a
Hal response bubble opens the context menu including "Prompt
Details Viewer." Tapping it opens the sheet which renders 5
color-coded segment cards correctly:
- System Prompt (purple) — 1,894 chars
- Temporal Context (orange) — 196 chars
- Self-Awareness (cyan) — 1,660 chars
- Conversation History (blue) — 838 chars
- User Message (gray) — 33 chars

Plus the Token Budget breakdown at the bottom (System Prompt
375, Conversation Summary 0, Memory Snippets (RAG) 0, Short-Term
History 0, User Input 8, Prompt-in 383, Completion-out 252, Total
635 / 4096, Window Usage 15.5%).

Visual evidence:
`Docs/sim_screenshots_2026-05-19/05_prompt_details_viewer.png`.

Still useful for Mark to do a real-device verification with a
richer conversation (the sim test had ~4 messages), but the
wiring is confirmed working on the structural level.

### Bug 7 — Case-sensitive catalog lookup is a footgun

Hal's `ModelCatalogService.getModel(byID:)` is case-sensitive,
but HuggingFace URLs aren't. The catalog stores Dolphin as
`mlx-community/dolphin3.0-llama3.2-3B-4Bit` (lowercase d/l,
capital B — this IS HF's canonical form, but unusual relative
to other catalog entries). Any tooling that uses HF's friendlier
casing (`Dolphin3.0-Llama3.2-3B-4bit`) silently misses the
catalog and falls into the community-model code path, which
then fails with a confusing "size couldn't be determined from
its repository" error even when the model is downloaded.

Found 2026-05-19 while investigating why the overnight stress
test reported Dolphin failing — turned out my probe was using
the wrong case and Hal was correctly refusing.

Small fix: make `getModel(byID:)` do a case-insensitive
comparison when the exact lookup misses. (Should never affect
correctness — IDs are unique across cases on HF.) Defense in
depth: also normalize the catalog's Dolphin entry to match the
naming convention of the other four MLX models
(`Dolphin3.0-Llama3.2-3B-4bit`) so direct lookups don't need
the special-case understanding.

### Bug 6 — Stress test probe assertion fixes

The stress test driver has three false-positive failure assertions
that aren't real Hal bugs:
- `settings:SET_MEMORY_DEPTH` — should assert `set == clamped`, not
  `set == expected` (AFM's clamp at 3 is correct behavior).
- `doc_import` — writes file to Mac `/tmp` but `IMPORT_DOCUMENT:`
  expects a path in Hal's device sandbox. Needs a different path
  strategy (probably can't be tested fully via API).
- `reflections_shareable_decided` — only relevant when MLX-generated
  reflections exist. Needs a "trigger a reflection-cycle" precursor
  before asserting on shareability.

Easy cleanups in `tests/stress_test.py`.

---

## Item 1 follow-up — unscripted reactive depth tuning

Per SC's original directive and Mark's confirmation: now that the
scripted-arc data is in (no meaningful depth difference for 2-5
within a 30-turn arc), do the realism check — drive a real
multi-turn improvised conversation at depth 5 (the recommended
default) and again at depth 2 (the most-restrictive), see if the
scripted finding holds under genuine human conversational flow.

Best done by Mark on the phone (the "real human" pass) rather than
by CC improvising LLM-style.

---

## Stress test — additional categories not yet covered

The driver in `tests/stress_test.py` covers model switching,
settings, document import, reflections query, self-knowledge
audit, salon API. Not yet covered:

- **Long conversations across multiple models with switches mid-conversation.**
  Driver currently does one chat per model in isolation.
- **Salon mode actual multi-seat round trip.** Currently only
  toggles the enabled flag — doesn't run a full 4-seat conversation.
- **[SHAREABLE: yes\|no] marker round-trip on all four MLX models.**
  Needs first to trigger MLX reflection-cycles per model, then
  inspect the resulting reflections for the marker.
- **Self Model viewer UI toggle.** Visual; needs Mark on device.
- **Export thread.** UI-driven; no API command exists. Needs Mark.

---

## App Store ship items (gated on Mark)

### Screenshots — 6 iPhone screenshots

Required: 6.7" display (iPhone 16 Plus or 17 Pro). Subjects:
- Main chat with AFM
- Main chat with an MLX model (recommend Gemma now that entitlements
  unblock it)
- Self Model viewer
- Model Library
- Settings (Power User)
- Salon mode (or PromptDetailView)

CC cannot capture device screenshots.

### ASC metadata

Two drafts side-by-side:
- `Docs/ASC_v2.0_Paste_Ready.md` — original
- `Docs/ASC_v2.0_REVISED.md` — overnight rewrite that demotes
  the over-promised "memory compression" framing and adds Self
  Model + per-turn pre-flight + Nomic retrieval

Mark picks which one ships.

### README / privacy.html / support.html

`README.md` updated 2026-05-19 with corrected Memory + new Self
Model sections. `privacy.html` and `support.html` need to live at
the GitHub Pages URLs referenced in the ASC submission.

### GitHub Pages verified

Confirm GitHub Pages is enabled on the Hal-Universal repo. URLs
in the ASC submission must resolve publicly (return 200).

### Version bump, fresh archive, upload, submit

Mechanical sequence:
1. Bump `CFBundleVersion` to 6 (currently 5) in `project.pbxproj`.
2. Build clean for Release.
3. Archive in Xcode → upload to ASC via Organizer.
4. Apply metadata to the v2.0 draft.
5. Submit for review.

**Gated on:** Bug 1 (or accept-as-known), Bug 2 (or accept-as-known
with caveat in description), screenshots captured, metadata staged,
Mark sign-off.

---

## Side work (not blocking)

### A. Re-enable EmbeddingGemma when MLX-swift ships fix

Track mlx-swift issues for the iOS Metal device init nullptr
crash. When fixed: bump mlx-swift, flip `HAL_ENABLE_EMBEDDING_GEMMA`
into Release config, verify on device.

### B. Default-on Nomic for new installs ✓ SETTLED

Mark's directive: "default stays as NLContextual. Nomic remains
opt-in via the Model Library. The 522 MB makes it unreasonable as
a forced default for new users." May revisit later.

### C. Docs/ consolidation

Many per-session recovery / finding docs accumulated under `Docs/`.
Worth a pass to move historical recovery docs into an archive
subfolder, leaving current architectural docs at the top level.

### D. Serial download queue indicator

When multiple downloads are tapped in succession, no UI indicator
that the additional taps registered. Add a queue-position
indicator or "queued" pill.
