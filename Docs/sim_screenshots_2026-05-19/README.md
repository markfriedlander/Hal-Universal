# Sim-captured screenshots — 2026-05-19

**Source:** iPhone 17 Pro simulator, Debug build of `b286429`-era
Hal (with the new memory entitlements). All chats are AFM (sim
doesn't support MLX cleanly).

**Use:** **NOT** ASC submission assets — these are reference
captures showing the UI structure. Replace with real-device
captures before submitting. Specifically:
- `04_model_library.png` shows EmbeddingGemma row because Debug
  has `HAL_ENABLE_EMBEDDING_GEMMA`. Release will hide that row.
- The chat conversations are sparse (only a few back-and-forths
  about octopuses and jellyfish). Real device captures should
  have richer conversation content.

## Files

| File | ASC subject | Status |
|---|---|---|
| `01_main_chat_AFM.png` | Main chat with AFM | ✓ ready as reference |
| `02_settings_sheet.png` | Settings sheet (top) | ✓ |
| `03_self_model_viewer.png` | Self Model viewer (v2.0 marquee) | ✓ |
| `04_model_library.png` | Model Library | ⚠ has EmbeddingGemma row (Debug only) |
| `05_prompt_details_viewer.png` | PromptDetailView (color-coded segments) | ✓ — this also verifies Bug 5 fix |
| `06_settings_power_user.png` | Settings → Power User (Memory section) | ✓ |
| `repro_salon_before_toggle.png` | Salon scroll/flash repro — "before" | evidence |
| `repro_salon_after_single.png` | Salon scroll/flash repro — "after Single LLM tap" | evidence |

## Salon scroll/flash reproduction (Bug 4)

The two `repro_*` images are evidence of Bug 4 (Salon toggle
scroll/flash) reproduced via the iPhone 17 Pro simulator. Compare
them side-by-side:

- `repro_salon_before_toggle.png`: Multi LLM (Salon) is selected.
  The AI Model section shows a "Salon Mode" row with the people.2
  icon and "Apple Intelligence" badge.
- `repro_salon_after_single.png`: Single LLM is selected (after
  tapping the picker). The same row now shows "Active Model" with
  the status dot. Below the picker, a new caption appears:
  "Advanced settings for single model operation."

**Observable artifact:** the scroll position visibly shifts up by
~one row-height between the two captures. The top of the visible
area is "Self-Knowledge toggle" in `before` and the middle of the
Self-Knowledge description text in `after`. This is the
scroll/flash Mark observed on real device.

**Root cause** (Hal.swift:7127-7170 + 7272-7276): the AI Model
section row content changes shape between Salon Mode and Active
Model variants, and the explanatory caption below the picker
changes text length. List/Form re-layout fires on the @Published
salonConfig change, repositioning all rows above.

**Fix vector:** stabilize the row content height — either fix
both row variants to identical layout dimensions (e.g. consistent
trailing-icon-plus-text frame), or move the conditional caption
to a stable position outside the section that re-layouts.

Not implemented this session — needs code change + visual diff
verification cycle, and Mark to confirm on real device that the
fix takes.
