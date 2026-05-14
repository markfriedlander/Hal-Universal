# Per-Model Settings Profiles — Implementation Proposal

**Author:** CC
**Date:** May 13, 2026
**Branch:** `mlx-experiment`
**Status:** Proposal — awaiting Mark sign-off before implementation
**Related:** Mark's directive (May 13 autonomous-mode handoff); per-model `repetitionPenalty` already landed in ModelConfiguration

---

## 1. Why this exists

Right now every runtime setting in Hal — temperature, memory depth, every RAG knob, and (newly) the repetition penalty — is treated one of two ways:

- **Genuinely global** (`@AppStorage` keys like `temperature`, `effectiveMemoryDepth`, `similarityThreshold`, etc.), which means whatever the user tuned for Gemma yesterday is now silently affecting Dolphin today.
- **Hard-coded per-model in code** (the new `repetitionPenalty` / `repetitionContextSize` fields on `ModelConfiguration`), which can't be overridden by the user.

Both ends of that spectrum are wrong for a multi-model product. Gemma genuinely wants different temperatures and different RAG snippet budgets than Qwen or Dolphin do. The product promise of a "curated tier of models, each with its own voice" implicitly promises that each model is configured well for itself — and that the user's tuning for one model doesn't bleed into another.

**Goal:** every relevant setting becomes per-model. Each curated model ships with its own tuned defaults (baked into `ModelConfiguration`). The user can override those defaults; their overrides are persisted **per model ID**. Switching models restores that model's last-known state. Salon Mode automatically uses each seat's model-specific settings.

---

## 2. Which settings move

In scope (everything that materially affects how a model responds or how memory is fed to it):

| Setting | Current storage | Notes |
|---|---|---|
| `temperature` | `@AppStorage("temperature")` | Generation; differs meaningfully by model |
| `effectiveMemoryDepth` | `@AppStorage("memoryDepth")` | STM size; Gemma can hold more turns than Qwen comfortably |
| `similarityThreshold` | `@AppStorage("similarityThreshold")` | RAG; tighter for Phi-style reasoners, looser for chatty models |
| `recencyWeight` | `@AppStorage("recencyWeight")` | RAG |
| `recencyHalfLifeDays` | `@AppStorage("recencyHalfLifeDays")` | RAG |
| `maxRagSnippetsCharacters` | `@AppStorage("maxRagSnippetsCharacters")` | RAG budget; smaller models benefit from less |
| `ragDedupThreshold` | `@AppStorage("ragDedupThreshold")` | RAG |
| `selfKnowledgeEnabled` | `@AppStorage("selfKnowledgeEnabled")` | Some models handle self-knowledge injection better than others |
| `repetitionPenalty` | New per-model field on `ModelConfiguration` | Already landed (May 13) |
| `repetitionContextSize` | New per-model field on `ModelConfiguration` | Already landed (May 13) |

Out of scope (genuinely app-level — should stay global):

- API port, API auth state, telemetry preferences
- License-acceptance state per model
- Active conversation ID
- Anything about *which* model is active (that's the layer above per-model settings)

---

## 3. Proposed architecture

### 3.1 A new `ModelSettings` value type

```swift
struct ModelSettings: Codable, Equatable {
    var temperature: Double?
    var effectiveMemoryDepth: Int?
    var similarityThreshold: Double?
    var recencyWeight: Double?
    var recencyHalfLifeDays: Double?
    var maxRagSnippetsCharacters: Int?
    var ragDedupThreshold: Double?
    var selfKnowledgeEnabled: Bool?
    var repetitionPenalty: Float?
    var repetitionContextSize: Int?
}
```

Every field is **optional**. `nil` means "use the model's default." This matters for forward-compatibility: new settings added later read as nil from old persisted data and fall back to defaults transparently.

### 3.2 Defaults live on `ModelConfiguration`

Extend `ModelConfiguration` with a single new field:

```swift
let defaultSettings: ModelSettings
```

Each curated model's static let gets explicit default values tuned for that model. The two repetition-penalty fields currently sitting on `ModelConfiguration` directly are **moved into `defaultSettings`** — same architectural shape, less surface clutter, and one source of truth.

Example shape after the change (Gemma):

```swift
static let gemma4E2B4bit = ModelConfiguration(
    id: "mlx-community/gemma-4-e2b-it-4bit",
    displayName: "Gemma 4 E2B",
    // ... unchanged metadata ...
    defaultSettings: ModelSettings(
        temperature: 0.7,
        effectiveMemoryDepth: 8,
        similarityThreshold: 0.75,
        recencyWeight: 0.3,
        recencyHalfLifeDays: 90,
        maxRagSnippetsCharacters: 1200,   // Gemma handles bigger context well
        ragDedupThreshold: 0.85,
        selfKnowledgeEnabled: true,
        repetitionPenalty: 1.1,
        repetitionContextSize: 64
    )
)
```

I'll tune these per-model values empirically (this is part of §1 benchmarking — short and long context measurements give us the data to set memory depth and RAG budgets sensibly).

### 3.3 Persisted user overrides keyed by model ID

One new `@AppStorage`:

```swift
@AppStorage("modelSettingsOverrides") private var modelSettingsOverridesData: Data = Data()
```

Decodes to `[String: ModelSettings]` — keyed by model ID, value is the user's override delta for that model. JSON-encoded so it's introspectable and dump-able.

### 3.4 Effective-settings resolution

A single lookup function lives next to the model catalog:

```swift
func effectiveSettings(for model: ModelConfiguration) -> ModelSettings {
    let overrides = loadOverrides()[model.id] ?? ModelSettings()
    return model.defaultSettings.merged(with: overrides)
}
```

`merged(with:)` is a non-destructive overlay: any non-nil field in `overrides` wins; anything nil falls through to the default. Used everywhere generation and RAG read settings today.

### 3.5 Model-switch hook

In `LLMService.setupLLM(for:)`, after the model is loaded, resolve and apply effective settings to the live `@Published` values that drive UI and behavior. This is the "switching models restores that model's last-known state" piece — when the user goes from Gemma → Dolphin and back, both transitions trigger the same lookup and both restore each model's persisted state cleanly.

### 3.6 API command rewiring

All existing settings-mutation API commands (`SET_TEMPERATURE`, `SET_MEMORY_DEPTH`, etc.) re-target: instead of writing the old global `@AppStorage` key, they write an override for the **currently active model**. The API surface doesn't change shape — only the storage backing does. Test scripts and existing CC tooling keep working without modification.

A new command for completeness: `RESET_MODEL_SETTINGS <model_id>` — clears overrides for that model, restoring its defaults. Useful for testing and for the eventual "Reset to defaults" button in UI.

### 3.7 Salon integration

Already-architected: each salon seat has a model assigned. The seat's `runSalonSeat` already calls `setupLLM(for: seatModel, keepMlxResident: true)`. We add one line — after the model is loaded, `setupLLM` is already going to apply that model's effective settings (from §3.5). Salon seats get their model's settings for free with zero salon-specific code.

This is the elegant part. The per-model-settings architecture and salon are orthogonal — fix the foundation and salon inherits the right behavior automatically.

### 3.8 UI changes

Minimal for v1.x:

- Settings screen header changes from "Settings" to **"Settings for [Active Model Name]"** — makes the scope visible.
- One new button at the bottom: **"Reset to defaults for [Model Name]"** — clears overrides for the active model.
- Optionally (nice-to-have, not required for the feature to ship): a subtle "modified from default" dot next to each slider whose value differs from the model's default.

No new controls. No reorganization. Existing controls just rebind transparently.

---

## 4. Migration path

When the user updates to a version with this change, there's old global `@AppStorage` data sitting in their preferences. Two options for what to do with it:

**(A — recommended)** Treat the old global values as an initial override for the **currently active model only**. Other models start at their own defaults. Reasoning: the user tuned those values while running a specific model; carrying them forward as an override for that model preserves their tuning effort. Other models had nothing real to inherit from.

**(B)** Discard the old global values. Every model starts at its defaults. Cleaner code, slight UX cost — power users who tuned their settings lose those tweaks.

I'd ship with (A). The migration runs once on first launch of the new build, then the old global keys can sit dormant or be cleared. Total migration code: ~15 lines.

---

## 5. Risk surface

| Risk | Mitigation |
|---|---|
| **Salon Mode regressions** — settings flowing wrong between seats | Salon test pass (all 5 maxims, 2-seat AFM+Gemma) after landing. Strategic §6 is happening soon anyway. |
| **First-launch confusion** — user expects their old settings | Migration option (A) covers the most-common case. UI header makes scope visible. |
| **Per-model setting bleed via stale `@Published` values** | One source of truth: a `currentEffectiveSettings: ModelSettings` `@Published` property on the LLMService, written only by `applyEffectiveSettings(for:)`. UI binds to it; runtime code reads it; no other state to drift. |
| **The `repetitionPenalty` field currently directly on ModelConfiguration** | Move it into `defaultSettings` in the same commit. Update the single consumer (`MLXWrapper.generateChatStream`). ~10-line change. |
| **AppStorage size growth** — one entry per model | Negligible. JSON dictionary of ~6 model-IDs × 10 fields = under 2KB persisted. |

---

## 6. Implementation plan (after sign-off)

Estimated 2-3 focused hours, one commit per step so each is reversible:

1. **`ModelSettings` + `merged(with:)`** — pure value type, no behavior changes. (~30 lines)
2. **Migrate the two existing per-model fields** (`repetitionPenalty`, `repetitionContextSize`) into `defaultSettings`. Update Gemma/Qwen/Llama/Dolphin/Ministral/Phi-4 static lets. Update `generateChatStream` to read from `defaultSettings` for now. (~50 lines, no user-visible change)
3. **Override persistence + lookup** — `modelSettingsOverrides` AppStorage, `loadOverrides()`, `effectiveSettings(for:)`. (~50 lines)
4. **Apply on model switch** — `applyEffectiveSettings(for:)` in `setupLLM`. (~15 lines)
5. **Rewire existing settings-mutation API commands** to write overrides for active model. (~30 lines across the command handler)
6. **Migration** — option (A). (~15 lines, gated on a `migratedToPerModelSettings` flag)
7. **UI** — header text + reset button. (~15 lines)
8. **Add `RESET_MODEL_SETTINGS` API command** for testing. (~10 lines)
9. **Test pass** — switch between all 5 curated models, change a setting on each, verify isolation. Salon test pass. (~30 min of testing)

Total: roughly 200 lines of new/changed code spread across 8 surgical commits.

---

## 7. Open questions for Mark

**Q1.** Are the settings I listed in §2 the right scope? In particular: should `selfKnowledgeEnabled` really be per-model, or do you see it as a global "yes I want self-knowledge in all conversations" toggle?

**Q2.** UI scope for v1.x: header text + reset button only, or do you want the "modified from default" indicators in this release too?

**Q3.** Migration: A or B? I lean strongly toward A (preserve current-model tuning), but I want explicit confirmation before throwing away anyone's saved tweaks.

**Q4.** Do you want the per-model defaults I bake in to be **tuned empirically** (i.e., I'll do this as part of §1 benchmarking and report the values back to you) or **conservative copies of the current globals** (i.e., everyone starts with what we have today as their default, and you/I tune later)?

My preference: tuned empirically — the §1 benchmarking is going to surface the right values naturally, and shipping a curated tier with hand-tuned per-model defaults is part of what "curated" means.

---

## 8. What I will NOT do without explicit approval

- I will not touch the existing global `@AppStorage` keys until migration option is confirmed.
- I will not change the API command shapes (only the storage they write to).
- I will not modify the salon turn loop beyond what's needed to make it call into the same `applyEffectiveSettings` hook.
- I will not bake any per-model default values into `defaultSettings` other than the two existing repetition-penalty values, until you confirm the empirical-vs-conservative question in §7.

---

*Awaiting sign-off.*
