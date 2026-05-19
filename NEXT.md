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

### Bug 2 — First-turn-after-swap race for 3 GB MLX models

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

### Bug 3 — Salon toggle scroll/flash (carried over)

Still needs visual repro. Code review (2026-05-18) didn't surface
anything that obviously shifts layout. Mark to capture a video on
the next sighting so we can target precisely. Defensive option if
it recurs: cache the salon seat-count value at the chat-view body
level and pass it into ChatBubbleView as a value parameter to
break the @Published chain for non-salon changes.

### Bug 4 — PromptDetailView wiring confirmation (carried over)

Code-side is healthy: contextMenu hook (97c8a7a) + classifier
update (100168a). Mark to visually verify on phone with real
conversation content.

### Bug 5 — Stress test probe assertion fixes

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
