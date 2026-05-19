# Sim-captured screenshots — 2026-05-19 FINAL

Captured with the iPhone 17 Pro simulator after all five Mark-
directed fixes landed:
1. Salon scroll/flash fix (Bug 4)
2. Document RAG chunking fix (Bug 2a)
3. First-turn-after-swap race fix (Bug 3)
4. Version bump to 2.0 build 6
5. Fresh screenshots (this folder)

Build: Debug, project version 6, with both memory entitlements.
Chat populated with real AFM conversation about octopuses, color
preferences, and Borges/Calvino book recommendations.

## ASC submission assets

| # | File | Subject |
|---|---|---|
| 1 | `01_main_chat_AFM.png` | Main chat with Apple Intelligence — shows the "favorite color" + book-recommendation exchange |
| 2 | `02_settings_sheet.png` | Settings sheet entry — Personality section + Hal's Self Model link + Temperature |
| 3 | `03_self_model_viewer.png` | Self Model viewer — privacy toggle, Reflections section, Traits with category/key/JSON/confidence/reinforcement count |
| 4 | `04_model_library.png` | Model Library — Hal's Picks tier with the four MLX models + AFM + embedding backends |
| 5 | `05_prompt_details_viewer.png` | Prompt Details Viewer — 5 color-coded segments + Token Budget breakdown |
| 6 | `06_power_user.png` | Power User detail — Memory Depth slider, Recency Weight, Memory Half-Life, Max RAG Retrieval, Identity Half-Life |

## Caveats (same as the earlier sim batch)

- Debug build → `04_model_library.png` shows the EmbeddingGemma
  row because `HAL_ENABLE_EMBEDDING_GEMMA` is set in Debug. Release
  build hides it.
- All chat is AFM. The sim has no MLX runtime, so a "Main chat
  with an MLX model" screenshot is impossible from sim. Mark
  captures that one from device.
- Conversation is sparse compared to a real long-running thread.
  Mark may want richer captures from his actual device usage.

## Bug 4 fix proof

`proof_salon_fix_before.png` and `proof_salon_fix_after.png` show
the Settings sheet before and immediately after tapping Multi LLM
in the Power User Mode picker. Power User Mode label sits at
y=746 in both screenshots — position is identical, confirming
the scroll/flash artifact no longer fires. (Pre-fix the same
toggle pushed the Power User picker off the bottom of the screen
by ~150 pixels because the conditional banner "Individual model
settings are locked..." was added/removed from the Personality
section, growing it by one row-height.)
