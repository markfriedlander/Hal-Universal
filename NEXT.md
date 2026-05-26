# Hal Universal — Next

Forward-looking work. Items completed move out of here and into `HISTORY.md`.

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md` (especially the 2026-05-19/20 entry).

---

## What the next session should do first

1. Read this file, then `HANDOFF_BRIEF.md`, then the **2026-05-19/20** entry
   of `HISTORY.md`, then `CLAUDE.md` for standing rules.
2. Verify live state:
   ```bash
   python3 tests/hal_test.py state                # device
   python3 tests/hal_test.py cmd "EMBEDDING_STATUS"
   ```
3. Pick up the v2.0.1 ship sequence below in order.

---

## v2.0.1 ship sequence (in order)

### 1. ~~Device-side verification of the EmbeddingGemma hotfix~~ — DONE 2026-05-26

Verified on iPhone 16 Plus from `main` @ `93cf4ba`. Nomic download
landed in `Caches/huggingface/models/nomic-ai/nomic-embed-text-v1.5/`
at 73 MB/s, `.mlxModelDidDownload` fired, EMBEDDING_STATUS confirms
nomicswift active at 768 dim. Grep across 500 log lines for
`embeddinggemma` / `gemma-300m` returned empty. `HALDEBUG-CLEANUP`
quiet because the device never had the orphan dir (idempotent skip).
Bug is dead. See HISTORY 2026-05-26 entry.

### 2. **SHIP_BLOCKER**: flip the local-API antenna OFF before archive

`Hal.swift` carries a `private static let kLocalAPIEnabledOnLaunch:
Bool = true` constant (search the file for `SHIP_BLOCKER`). It force-
applies to UserDefaults on every init() so device-side test tooling
works without needing the in-app toggle flip on every reinstall.
Production users should boot with the antenna OFF, matching v2.0
behavior. **One-line flip to `false` before archive.** Two comment
blocks (above the constant + above the AppStorage) cross-reference
each other so this can't be missed. The runtime toggle in Settings >
Power User > Developer API still works — users can opt in mid-session.

### 3. Archive + ASC submit v2.0.1

When the SHIP_BLOCKER is flipped:

1. Bump `CFBundleVersion` to **7** in `project.pbxproj` (was 6 for the
   v2.0 production build).
2. Xcode → Product → Archive (uses Release config automatically).
3. Distribute App → App Store Connect → Upload.
4. Wait for ASC to process the build (~10-20 min).
5. In ASC, on the existing v2.0 listing or a new v2.0.1 page (Apple's
   choice — they usually create v2.0.1 automatically when build 7
   arrives), select build 7, add it for review, submit.
6. **Skip the screenshot step** — the v2.0 screenshots in the 6.3"
   tier are still accurate for v2.0.1 (no UI changed).
7. **What's New text for v2.0.1:**
   ```
   Bug fix: downloading the optional Nomic Embed Text v1.5 retrieval model
   now correctly downloads Nomic instead of an unrelated model file. Any
   orphan files from the v2.0 install are removed automatically on launch.

   Internal refactor: model download subsystem extracted from the main
   source file into its own module. No user-visible change.
   ```

### 4. (Optional) Surface a brief release-note in-app

Hal v2.0 added an About section to Settings with version + build.
Consider a tiny "What's new in 2.0.1" link in the About row that opens
a sheet with the same text as the ASC release notes. Not blocking
ship; nice for transparency. Defer if context is tight.

---

## Refactor work — in progress

**Goal:** continue chipping Hal.swift down to a sane size by extracting
self-contained subsystems one at a time. First extraction
(`MLXModelDownloader`) landed 2026-05-20. Pattern is stable; just keep
going.

### Next extraction: `ModelCatalogService` (LEGO 30)

Self-contained ~1,400-line block right after the just-extracted
LEGO 29. Holds the HuggingFace catalog fetching, license tracking, the
in-memory `availableModels` array, and the model-status refresh hook.
External coupling: minimal — accessed via `.shared`, observable from
anywhere in the target.

**Same approach as `MLXModelDownloader` extraction:**

1. Read the full block end-to-end (LEGO 30 markers).
2. Identify external references (other classes/types this block uses).
3. Verify nothing extends `ModelCatalogService` from elsewhere in
   Hal.swift (`grep -n "extension ModelCatalogService"`).
4. Slice via the same Python boundary-cut trick used for LEGO 29.
5. Create `Hal Universal/ModelCatalogService.swift` with header
   matching the MLXModelDownloader pattern + appropriate imports.
6. Leave a pointer comment in Hal.swift at the old slot.
7. Update `sync_hal_source.sh`.
8. Build (zero errors, zero warnings).
9. Functional smoke test: trigger a catalog refresh via API, verify
   it still populates `availableModels` and the Model Library renders
   the Community Models list.
10. Commit + push.

### After that — other extraction candidates ranked by size and isolation

| Order | Subsystem | Approx lines | Isolation |
|---|---|---|---|
| 2 | ModelCatalogService (LEGO 30) | ~1,400 | High |
| 3 | LocalAPIServer + executeCommand handlers (LEGO 32 + supporting) | ~3,500 | Medium (touches everything via dispatch but is one read/write boundary) |
| 4 | DocumentImportManager + DocxParser (LEGO 27 + 27.1) | ~900 | High |
| 5 | MemoryStore SQLite layer (LEGO 1-ish, very large) | ~3,000 | Low (interleaved with ChatViewModel) — defer |
| 6 | SettingsView / ActionsView | ~2,500 | Medium |
| 7 | ChatView root + composer + bubble views | ~2,000 | Low — leave for last |

After Round 2 (ModelCatalogService), Hal.swift would be ~18,200 lines.
After Round 3 (LocalAPIServer), ~14,700. Goal: get under 10k before
v2.1 work begins.

---

## Deferred bugs from earlier sessions (carried forward)

### Bug 1 — `SET_MEMORY_DEPTH` doesn't survive app re-init

Reproduced 2026-05-19. `ModelSettingsStore.applyEffectiveSettings(for:)`
at Hal.swift init silently overwrites memoryDepth back to the active
model's per-model default. Two fix options (still not picked):

- **(a)** Persist a "user-overridden" boolean alongside `memoryDepth`.
- **(b)** `applyEffectiveSettings` only fires on actual model change,
  not on every init when the model is unchanged.

Product decision still pending.

### Bug 2 — Document RAG / confabulation (PARTIALLY FIXED in v2.0)

Bug 2a (Document RAG misses non-final chunks) was fixed end-to-end in
v2.0. Bug 2b (confabulation when RAG misses target content) remains —
when the target content isn't in the prompt, models invent plausible
content rather than saying "I don't have that." AFM is more prone than
Gemma. Possible fix: explicit "no document match found" system note
when RAG returns no high-relevance match.

### Bug 3 — First-turn-after-swap race for 3 GB MLX models

Reproduced 2026-05-19. After SWITCH_MODEL to Gemma 4 E2B or Dolphin 3.0,
the immediate next chat returns the loaded-model-error string in <1s.
Smaller MLX models don't hit this. Hypothesis: SWITCH_MODEL returns
before MLX has finished mapping weights. Fix options:

- Have SWITCH_MODEL block on model-ready before returning.
- Have /chat queue behind any in-flight load with a small timeout.

---

## v2.1 design work (planning — not blocked)

Per `HAL_CC_BRIEFING.md` and the project's philosophical core:

### The Proposals System

The thing that makes Hal genuinely participatory. Hal notices patterns,
gaps, opportunities through use; drafts structured proposals; Mark
reviews and marks them accepted / deferred / declined; accepted ones
become the backlog. Future Hal versions carry features that previous
Hal asked for.

Architecturally: new `proposals` table in SQLite (id, title, body,
status, created_at, decided_at, decided_by); new ProposalsView in
Settings; a "draft proposal" affordance Hal can trigger from
introspection prompts; export path so Mark can move accepted proposals
into CC's backlog.

### The Soul Document

Living self-concept stored in the experiential memory layer. Evolves
through use. Distinct from system prompt: system prompt is external
instruction, soul document is internal identity. Should emerge from
experience including the earliest experiences of being built.

### Salon Mode polish

Salon Mode shipped in v2.0 but with rough edges. Worth a pass: visible
moderator/summarizer seat option, attribution UI improvements, easier
seat-swap mid-conversation, transcript export.

### Three-Layer Memory

Conversational (exists, RAG-based) → Experiential (distilled patterns,
partial — TraitCrystallizer is the first move) → Identity (soul
document, not yet built).

---

## Stress test — additional categories not yet covered

The driver in `tests/stress_test.py` covers model switching, settings,
document import, reflections query, self-knowledge audit, salon API.
Still not covered:

- **Long conversations across multiple models with switches mid-conversation.**
- **Salon mode actual multi-seat round trip.** Currently only toggles
  the enabled flag — doesn't run a full 4-seat conversation.
- **[SHAREABLE: yes|no] marker round-trip on all four MLX models.**
- **Self Model viewer UI toggle.** Needs Mark on device.
- **Export thread.** UI-driven; no API command exists. Needs Mark.

---

## Side work (not blocking)

### A. Re-enable EmbeddingGemma when upstream MLX ships fix

Re-enable recipe at top of `EmbeddingBackend.swift`. Track mlx-swift
issues for the iOS 26.5 Metal device init nullptr crash. When fixed:
follow the 6-step un-comment checklist + bump mlx-swift.

### B. Docs/ consolidation

Many per-session recovery / finding docs accumulated under `Docs/`.
Worth a pass to move historical recovery docs into an archive
subfolder, leaving current architectural docs at the top level.

### C. Serial download queue indicator

When multiple downloads are tapped in succession, no UI indicator
that the additional taps registered. Add a queue-position indicator
or "queued" pill.

### D. Bug 2b: confabulation gate

Mentioned above under deferred bugs. Fix when context permits.

### E. EU distribution

The DSA non-trader choice removes Hal from the 27 EU + 3 EEA markets.
If Mark wants to flip the switch later, the trader path requires
publishing a verifiable legal name + physical address + phone + email
on the App Store listing. Reversible at any time via App Store Connect
→ App Information → Digital Services Act → Get Started.
