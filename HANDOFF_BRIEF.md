# Hal Universal — Handoff Brief
**Updated:** May 19, 2026 (overnight autonomous session)
**Branch:** `main` (4 commits ahead of pre-session `b33d2de`)
**Working tree:** clean

## Where Hal is right now

The overnight session landed three things that move ship readiness
forward and produced two deferred-work items that need decisions
before the next push.

### Landed

1. **Memory entitlements — Gemma 4 E2B is now actually usable.**
   Commit `b286429`. Added
   `Hal Universal/Hal Universal.entitlements` with Increased Memory
   Limit + Extended Virtual Addressing, registered the capabilities
   via Xcode UI, wired into both Debug and Release configs of the
   Hal Universal target. Pre-entitlements: Gemma had ~100-200 MB
   headroom and the per-turn pre-flight refused almost every chat.
   Post-entitlements: ~6100 MB headroom, Gemma sustains ~30-turn
   conversations before the pre-flight kicks in. This is the real
   fix that unblocks Gemma as a viable MLX model.

2. **Item 2 — Nomic synthesis threshold calibrated.** Commit
   `7439d4a`. Added `EMBED_SIM` / `EMBED_SIM_BATCH` API + the
   `tests/nomic_calibration_probe.py` driver. Measured on device
   (NLContextual SAME 0.73-0.93, RELATED 0.71-0.83 — bands overlap)
   and set `recommendedSynthesisThreshold` for Nomic to **0.85**.
   Code comment in `EmbeddingBackend.swift:206-232` documents the
   measured distribution and the reasoning.

3. **Item 1 — Gemma memory-depth tuning done.** 8 runs total
   (4 depths × 2 replicates). Methodology rebuilt twice after
   two false starts (see HISTORY for the chronicle). All 8 runs
   hit the same 30-turn ceiling. Memory recall doesn't track
   depth meaningfully: depth 2 = 3/16, depth 3 = 2/16, depth 4 =
   2/16, depth 5 = 4/16. **Recommendation: keep current default
   of 5.** Full results table:
   `tests/gemma_depth_results_2026-05-19.md`.

4. **ASC v2.0 metadata + README rewrite.** Commit `157196b`.
   `Docs/ASC_v2.0_REVISED.md` is side-by-side with the existing
   paste-ready — Mark picks which ships. Demotes the over-promised
   "memory compression" framing, adds Self Model + per-turn
   pre-flight + Nomic retrieval as real v2.0 features.

5. **Stress test ran (20 / 25 PASS).** Real ship-relevant fails:
   first-turn-after-switch fails for Gemma + Dolphin (3 GB MLX
   models — race between MLX load and chat send). Smaller MLX
   models (Llama, Qwen) and AFM are fine. See Deferred below.

### Deferred — needs decisions or hands

**Ship-blockers found late-night reactive testing:**

- **Bug 2a — Document RAG misses non-final chunks.** Imported 2-chunk
  document; unique words from earlier chunk (Berkenia, Veldros,
  periwinkle, armadillo) return zero document hits in semantic search;
  only words from the LAST chunk (lighthouse) surface the document.
  Real users importing docs will only get the last third retrievable.

- **Bug 2b — Confabulation when RAG misses target.** When the target
  content isn't in the prompt, Hal makes up plausible content rather
  than saying "I don't have that." AFM does this more confidently
  than Gemma. Combination with 2a is the ship-blocker for documents.

**Carried over:**

- **Bug 1 — `SET_MEMORY_DEPTH` persistence.** SET to N, app re-inits,
  silently reverts to per-model default via applyEffectiveSettings.
  Two proposed fixes in NEXT.md, both product calls.

- **Bug 3 — First-turn-after-swap race for 3 GB MLX models.** Gemma +
  Dolphin reliably fail the first chat after SWITCH_MODEL. Fix
  options in NEXT.md.

- **Bug 4 — Salon toggle scroll/flash.** Visual artifact, needs
  reproduction on device + video for targeted fix.

- **Bug 5 — PromptDetailView visual verification.** Code-side healthy;
  Mark to confirm classification on real device.

- **Bug 6 — Stress test probe-assertion bugs.** Three false-positives
  in `tests/stress_test.py`; cleanup task.

- **Item 1 unscripted-reactive — partial.** CC ran a reactive pass at
  depth=5 (12 turns) and depth=2 (6 turns) catching the confabulation
  failure mode the scripted probes missed. Mark to do a genuine
  human-driven pass for the realism final check.

- **Screenshots, version bump, archive, ASC submit.** Mechanical,
  gated on Mark + Xcode UI. See NEXT.md.

---

## File layout

```
Hal Universal/
├── Hal Universal.entitlements         — NEW (b286429): memory caps
├── EmbeddingBackend.swift             — backend enum + thresholds
│                                          (Nomic synthesis threshold
│                                          calibrated tonight)
├── EmbeddingProvider.swift            — 3-backend dispatch
├── EmbedderMigrationCoordinator.swift — migration state machine
├── QueryExpansion.swift               — async query expansion
├── PromptDetailView.swift             — color-coded segments viewer
├── SelfKnowledgeEngine.swift          — self-knowledge CRUD + reflection
├── TraitCrystallizer.swift            — Phase 2 reinforcement-promotion
├── ProcessMemoryGuard.swift           — Item 11: os_proc_available_memory
└── Hal.swift                          — everything else (~19.7k lines)

tests/
├── hal_test.py                        — HTTP+file API test runner
├── nomic_calibration_probe.py         — NEW: SAME/RELATED/UNREL probe
├── gemma_depth_probe.py               — NEW: per-depth conversation driver
│                                          with ground-truth verification
├── gemma_depth_all.sh                 — NEW: 8-replicate orchestrator
├── gemma_depth_summary.py             — NEW: per-run results parser
├── gemma_depth_results_2026-05-19.md  — NEW: Item 1 final results table
└── stress_test.py                     — NEW: multi-model + settings + RAG +
                                          salon probe (5 real findings, see
                                          HISTORY for breakdown)

scripts/
└── sync_hal_source.sh                 — concatenates all .swift into
                                          Hal_Source.txt (run after any
                                          source change)
```

---

## Build + Deploy (iPhone 16 Plus)

```bash
xcodebuild build \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" \
  -configuration Debug

xcrun devicectl device install app --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  "/Users/markfriedlander/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"

xcrun devicectl device process launch --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 com.MarkFriedlander.Hal-Universal
```

- iPhone 16 Plus: `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
- API host: `marks-bigger-ass-fon-16.local` (mDNS — phone awake + on WiFi)
- API port: 8766
- API token: `e9ee9ec5b315467fa655bd4296873f43` (in `tests/.hal_api_config.json`)
- iPhone 17 Pro sim UDID: `10C6DB49-2723-4F95-8F81-AECB9CD72BD0`
  - sim token: `950c39cf55574c3180734785ec3c52da` (in `tests/.hal_api_config_sim.json`)

For sim runs: `HAL_API_CONFIG=.hal_api_config_sim.json python3 tests/hal_test.py …`

---

## SOP (unchanged — refactor-as-you-go is mandatory)

1. **After any change to Hal's source, sync `Hal_Source.txt`:**
   ```bash
   ./scripts/sync_hal_source.sh
   ```
2. **Significant changes to a section of Hal.swift → extract into a
   dedicated file.** Use any of the existing extracted files as a
   template.
3. New enum case → sweep all switches.
4. New AppStorage key → `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`.
5. App build number bump happens at App Store submission (currently 5).
6. Never `NUCLEAR_RESET` between plant and recall in a memory test.
7. **Update HISTORY/HANDOFF/NEXT as work lands** (CLAUDE.md Golden Rule #8).
8. **Warnings = errors** (CLAUDE.md Golden Rule #7).
9. **API > asking the human** — expand the API if a question can't be
   answered through it.
10. **Don't bail on a probe based on ambiguous telemetry.** Add
    instrumentation, not exit doors. (Lesson from tonight.)
11. **Confirm any deviation from a stated directive before executing
    it.** (Lesson from tonight — scripted-vs-improvised.)

---

## New diagnostic / API commands this session

| Command | Purpose |
|---|---|
| `EMBED_SIM:<t1>\|\|\|<t2>` | Cosine sim between two texts under active backend |
| `EMBED_SIM_BATCH:<t1a>\|\|\|<t2a>~~~<t1b>\|\|\|<t2b>~~~…` | Batched form |
| `GET_LOGS:<N>` | Pull the last N HALDEBUG-* lines from the in-process buffer |

(Tonight's probes also lean heavily on the already-existing
`HALDEBUG-CHAT … depth=N` log line at Hal.swift:12910 as ground
truth for what depth a chat actually ran at.)

---

## Known caveats

- **EmbeddingGemma is compile-out in Release builds** — upstream MLX
  Metal init crash on iOS 26.5. Code stays behind
  `HAL_ENABLE_EMBEDDING_GEMMA` ready to re-enable.
- **Nomic load takes ~10–15 s on iPhone 16+** (MMAP-loading 546 MB
  safetensors + tokenizer JSON). Subsequent embeds are fast (~80 ms).
- **`SET_MEMORY_DEPTH` doesn't survive app re-init** — see
  Deferred above. Workaround: re-SET after every relaunch (the
  probe drivers do this).
- **First chat after SWITCH_MODEL to Gemma/Dolphin fails reliably** —
  see Deferred above. Workaround: wait 10-15 s before sending,
  or send a chat that's OK to throw away.
- **`xcrun devicectl device process launch` does NOT unload MLX
  weights** — iOS keeps the prior process state warm. To actually
  free memory, hard `terminate --pid <pid>` first, then launch.
  (The probe drivers do this.)
