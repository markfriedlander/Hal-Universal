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
self-contained subsystems one at a time. Pattern is stable; just keep
going.

### Goal framing (clarified 2026-05-26)

Per Mark, refactor work continues for as long as each candidate
extraction improves on:

1. **Easier to read and understand** — does pulling this out into
   its own file make the boundary between "what this does" and
   "what it touches" clearer?
2. **Easier and safer to extend** — when v2.1 work starts, will the
   extracted subsystem be the obvious file to open?
3. **More stable, easier to diagnose** — when something breaks,
   does the file structure point at the suspect quickly?

The previous "under 10k lines before v2.1" target is retired. Line
counts are a proxy that drifts; the three criteria above are the
real test. Also a standing rule: **LEGO blocks stay** — preserved
inside Hal.swift via pointer comments at each extracted slot, AND
preserved inside every extracted file as internal section landmarks.

### Done — full refactor sprint complete

- ✅ Refactor #1 (2026-05-20): `MLXModelDownloader` (LEGO 29)
- ✅ Refactor #2 (2026-05-26 PM): `ModelCatalogService` (LEGO 30)
- ✅ Refactor #3 (2026-05-26 EVE): `LocalAPIServer + HalTestConsole` (LEGO 32)
- ✅ Refactor #4 (2026-05-26 NIGHT): `DocumentImportManager + DocxParser + import models` (LEGO 27 + 27.1 + 28)
- ✅ Refactor #5 (2026-05-26 LATE): `SettingsViews` (LEGO 10.1, 10.2, 10.3, 10.3.5, 10.4)
- ✅ Refactor #6 (2026-05-26 DEEP NIGHT): `ChatViews` (LEGO 09, 09.5, 13, 13.5)

**Cumulative:** Hal.swift 21,266 → 12,650 (-8,616, ~40.5%). Six
extractions in one day. Every candidate evaluated against Mark's
three criteria (readability / extensibility / diagnosability)
earned its place.

### Why we're stopping here

What's left in Hal.swift after refactor #6:

| Block | Subsystem | Why it stays |
|---|---|---|
| 02-07 | MemoryStore (schema, encryption, stats, self-knowledge, search) | Interleaved with ChatViewModel state knowledge; extracting would make memory bugs harder to trace, not easier — fails criterion 3. |
| 07.5 / 07.6 | Prompt budgeting + segment compression | Heart of how Hal stays within model context windows; tightly bound to the LLM-routing path below. |
| 08 | MLXWrapper + LLMService | The inference path itself. Splitting MLX routing from the wrappers it consumes would push the seam through generation flow. |
| 8.5 | Summarization utilities | Used by both prompt compression and memory summarization; sits between the two. |
| 11.5 / 11.6 | Model Library UI + UI helpers | Small (~1,500 lines total). View-only; could be extracted alongside ChatViews later if needed, but not pulling its weight today. |
| 12.6 | SelfReflectionView | Already a single self-contained read-only viewer; ~325 lines isn't enough mass to merit its own file yet. |
| 14 / 15 / 16 | Stubs + ShareSheet + View extensions | Tiny utilities, no value to extract. |
| 17-25 | ChatViewModel (the whole thing) | The conceptual heart of Hal. Every other subsystem talks to it. Splitting it would worsen all three criteria. |
| 26 | DocumentPicker UIKit bridge | ~60 lines. Lives near its consumers in Hal.swift. |
| 31 | HalWatchBridge | ~140 lines. Single class, tied to the WCSession lifecycle in HalAppDelegate (which is in ChatViews.swift). Could move with ChatViews someday if friction surfaces. |

By Mark's three criteria the natural pause is here. Further
splitting would either fail diagnosability (MemoryStore) or be
cosmetic (smaller blocks that aren't pulling their weight).

### What's queued for whenever Hal returns to active development

1. **v2.0.1 hotfix ship.** Sim+device verified, deferred to v2.1
   per Mark on 2026-05-26 (orphan-weights bug is bandwidth-leaky
   but crash-safe). When v2.1 is ready to archive, this rides
   along: flip `kLocalAPIEnabledOnLaunch` to `false`, bump
   CFBundleVersion to 7, archive + submit. What's-New text drafted
   below.

2. **v2.1 design work.** Per Mark on 2026-05-26: "No design work
   until we do the full refactor." The full refactor is done.
   Three major arcs on the design horizon (from
   HAL_CC_BRIEFING.md):
   - **Proposals system** — settings additions go to
     SettingsViews.swift, new SQLite table goes in MemoryStore
     (Hal.swift), API verbs extend LocalAPIServer.swift's
     executeCommand.
   - **Soul Document** — three-layer memory architecture, new
     persistent record in MemoryStore.
   - **Salon Mode polish** — visible moderator seat option,
     attribution UI improvements, transcript export (touches
     SettingsViews + ChatViews).

3. **Deferred bugs.** Bug 1 (SET_MEMORY_DEPTH doesn't survive
   re-init), Bug 2b (RAG-miss confabulation), Bug 3 (first-turn-
   after-swap race for 3 GB MLX models). Product decisions pending
   on all three.

4. **Small cosmetic cleanup candidates** (no urgency):
   - HistoricalContext logically belongs with MemoryStore — left
     in ChatViews.swift for now.
   - LEGO numbering inconsistencies (07.5 vs 8.5, 10.3.5, 27.1) —
     keep as-is per Mark; renumber later if it makes sense.

### v2.0.1 What's New text (drafted, ready to use)

```
Bug fix: downloading the optional Nomic Embed Text v1.5 retrieval model
now correctly downloads Nomic instead of an unrelated model file. Any
orphan files from the v2.0 install are removed automatically on launch.

Internal refactor: ~40% of the main source file extracted into focused
subsystem modules (model downloads, model catalog, API server, document
ingest, settings UI, chat UI). No user-visible change.
```

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

## Cross-app infrastructure: shared model storage with Posey

**Context.** Mark is developing a sibling app called **Posey** — a
reading companion that uses TTS to read documents aloud with an
onboard AI companion for interpretation. Posey reuses a lot of Hal
code, including the curated MLX model lineup. Users who run both
apps would otherwise have to download every model twice (3-6+ GB
duplicated). Goal: a single shared model store both apps read from.

### Mechanism: iOS App Groups

Apple's standard way to let two same-developer apps share files is
**App Groups** — a shared container directory both apps see at a
known URL. Accessed via:

```
FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.MarkFriedlander.shared"
)
```

That URL is a normal directory the OS makes visible to every app
that has the matching entitlement. From there it's plain file I/O.

### Three setup steps (same for both apps)

1. **Register the App Group identifier** in the Apple Developer
   portal (one-time). Pick the group ID; current working name
   `group.com.MarkFriedlander.shared` but any reverse-DNS-style id
   works.
2. **Enable the App Group capability** in each Xcode project
   (Signing & Capabilities → +Capability → App Groups → add the
   group ID to both Hal and Posey). This writes an entitlement.
3. **Point the model path resolver at the shared container.**
   Currently `MLXModelDownloader.swift` writes to
   `Library/Caches/huggingface/models/<repoID>/`. Change the base
   directory to `<sharedContainer>/huggingface/models/<repoID>/`.

That's the architectural change. The download machinery, the file
walker, the "is this model present?" check — none of it needs new
logic, just a different base directory.

### Three concerns that need addressing

**1. Migration for existing Hal users.** v2.0 users have Gemma /
Nomic in per-app `Caches/`. When v2.1 ships with the shared-container
change, a one-shot launch helper (same pattern as
`MaintenanceTasks.runAtLaunch()`) needs to copy/move existing
models from `Caches/` to the shared container. Idempotent — once
moved, subsequent launches see them in the new location and do
nothing. Roughly 50 lines in a new helper inside
`MaintenanceTasks.swift` or alongside `MLXModelDownloader.swift`.

**2. Concurrency between Hal and Posey.** If both apps are open and
both try to download Gemma at the same time, naive parallel writes
would corrupt each other. Simple fix: a per-model lock file
(`<modelID>/.downloading-by-<bundleID>-<PID>`). Before starting a
download, write the marker; before any download, check for an
existing marker and wait/poll if present. ~50 lines, fits naturally
in `BackgroundDownloadCoordinator`. The fancier alternative
(`NSDistributedNotificationCenter` / Darwin notifications) is
overkill for a user-triggered download — don't over-engineer it.

**3. iCloud backup exclusion — MANDATORY, not optional.** Currently
models live in `Caches/`, which iOS auto-excludes from iCloud
backup. App Group shared containers are NOT auto-excluded — they're
treated more like `Application Support/`, which IS backed up.
Without intervention, every user of the shared-container version
would suddenly burn 3-6 GB of their iCloud quota.

The fix: set `URLResourceValues.isExcludedFromBackup = true` on
every model directory the moment after it lands.

```
var values = URLResourceValues()
values.isExcludedFromBackup = true
try modelDir.setResourceValues(values)
```

This is a single filesystem attribute, persistent across reboots,
survives modifications. App Store Review Guideline 2.5.1 explicitly
requires re-downloadable content (which HuggingFace models always
are) to be excluded from backup — so shipping v2.1 without this
flag would risk a review rejection on top of being hostile to
users. Five-ish lines of code, applied in two places:

- After every new download completes in
  `BackgroundDownloadCoordinator`'s move-finished-file path.
- During the v2.1 migration helper, on each model directory it
  copies to the shared container, *before* anything else can touch
  it.

A nice side benefit: when a user restores their iPhone from an
iCloud backup, the models don't come along (they'd be slow/expensive
to restore anyway). Catalog correctly shows them as "not downloaded,
tap to download," and the user pulls fresh from HuggingFace on the
new device — the correct UX.

### Why Posey should be built for sharing from day one

Posey isn't shipped yet, which makes it the easier side: no
migration to write. If Posey ships pointing at the shared container
and setting `isExcludedFromBackup` from the start, when Hal v2.1
catches up there's literally nothing to update on the Posey side.
Whereas if Posey ships with per-app paths and adds sharing later,
Posey will need its own migration helper too.

Between now and Hal v2.1 shipping, Posey would effectively be the
only writer to the shared container. That's fine — the
infrastructure is in place and idle, waiting for Hal to join. No
behavioral cost.

### App Store considerations

- **Hal:** Already shipped, so adding the App Group capability is
  a v2.1 entitlement change that goes through normal App Review.
  Apple routinely approves these — "two of my apps share large
  downloaded model files" is exactly the use case App Groups were
  designed for. Not a review risk. The `isExcludedFromBackup`
  attribute reinforces the App Review story (guideline 2.5.1
  compliance).
- **Posey:** Not yet shipped, so the capability ships with the
  initial submission. Same story — straightforward review.

### Estimated lift

- **Posey side (greenfield):** ~half a day. Path resolver +
  entitlements + `isExcludedFromBackup` calls. No migration.
- **Hal side (v2.1):** ~one focused day. Path resolver change +
  migration helper for existing users + concurrency lock +
  `isExcludedFromBackup` on the migration + entitlements + device
  testing with both apps installed and downloading concurrently.

Net across both apps: ~1.5 focused days of work to ship cross-app
model sharing end-to-end. The MLXModelDownloader extraction we just
did (refactor #1) is exactly the file most of the Hal-side work
happens in — that refactor pays off here directly.

### Notes for the Posey team conversation

When briefing the Posey team on this, the key points:

1. **Bake App Group support into Posey now, before App Store
   submission.** Cheaper than retrofitting later.
2. **Pick the App Group identifier with Mark.** Both apps must use
   the same string; once chosen, changing it on either side
   strands the other's users until the next update.
3. **Set `isExcludedFromBackup` on every model directory write.**
   Mandatory for App Review compliance. Cheap to do, expensive to
   skip.
4. **The model path resolver should be a single function.** Both
   apps will need it; making it the only place that knows about
   the shared container keeps the rest of the model-handling code
   identical between apps.
5. **Concurrency model: optimistic lock files.** Before downloading
   model X, write `<X>/.downloading-by-<bundleID>-<PID>`. If a
   marker for another app exists when you go to start, wait and
   poll. Cheap, robust, no inter-process communication needed.
6. **Test the failure modes deliberately:** both apps open, both
   tap Download on the same model, one app force-quit mid-download,
   one app deleted while the other still uses the shared model.
   These are the cases that catch bugs.

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
