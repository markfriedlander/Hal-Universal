# Hal Universal — Next

What we're planning to do next. Forward-looking, narrow scope.

This doc reflects the next few concrete steps — not the long-term roadmap.
As steps complete, they move out of here (and into `HISTORY.md` as part of
the session entry that completed them).

For where Hal is right now: `HANDOFF_BRIEF.md`.
For how we got here: `HISTORY.md`.

---

## Strategic Claude's plan, current step: Cluster B (verification testing)

Cluster A (self-knowledge directive) landed. Working through SC's plan in
the agreed order: verification testing across all models and features
first, then Cluster C (structured-trait synthesis + scroll behavior).

### Cluster B — verification testing

These are independent and can be done in any order. Each item: what to do,
what success looks like. No estimates.

1. **Core chat — Llama 3.2 3B.** Switch to Llama via `SWITCH_MODEL`. Send
   2–3 turns including a follow-up that requires memory continuity.
   Verify no crashes, sensible responses, attribution in footer.

2. **Core chat — Qwen 3.5 2B.** Download Qwen (~1.8 GB). Switch to it.
   Send a small turn. Observe whether the historical repetition-loop bug
   still occurs at the per-model penalty=1.1 + tuned-temp defaults. If
   loops persist, flag for decision (curated vs demote like Phi-4).

3. **Memory + RAG content recall.** Plant fact in thread A ("Atlas is my
   cat"), `NEW_THREAD` (not `NUCLEAR_RESET` — that wipes the DB; this is
   a known protocol gotcha), ask in thread B "What's my cat's name?".
   Verify RAG retrieves "Atlas" across AFM, Gemma, Dolphin, Llama. Pattern
   in `tests/maxim_suite.py`.

4. **Per-model settings.** Switch models, verify per-model settings
   (temperature, memoryDepth, maxRagSnippetsCharacters, repetitionPenalty)
   update correctly via state API. Edit a setting, verify it persists
   across switch-away + switch-back. Verify per-model reset works without
   affecting other models' overrides.

5. **System prompt counter.** Open Settings → Personality → System Prompt
   editor. Type text. Verify three-state counter (neutral / approaching /
   atLimit) renders correctly at the threshold crossings. Verify at 100%
   the editor silently rejects further input.

6. **Model Library UI.** Visual + interaction test. Open Browse Model
   Library. Verify three-segment layout (Curated / Downloaded / Library).
   Inline download/cancel/delete controls. Hardware-disclosure popup on
   first download attempt. Per-model expanded detail.

7. **App icon.** Visually inspect the app icon on device home screen.
   Confirm `hal_icon_1024_appstore_v2.png` is the intended final icon.

8. **Salon multi-seat turn execution.** Configure Salon with 2 seats
   (AFM + Gemma), enable via API, send a turn. Verify both seats run,
   attribution is correct. Repeat with context-aware mode. Repeat with
   Host assigned. Helper refactor only changed how seats are SET; the
   turn-execution path is unchanged, so risk is low — but verify.

9. **Salon UI Pickers.** Visual test via simulator or device. Settings →
   Power User → Salon. Tap a seat picker, change selection, verify state
   updates correctly via API. Specifically test "clear last seat while
   Salon enabled" through the UI — confirm auto-disable fires.

10. **Background downloads (long lock).** Delete Gemma (3.6 GB), start
    fresh download, lock phone face-down 10+ minutes (genuine iOS
    background suspension), unlock, verify completion. Tests whether the
    BGDL coordinator handles iOS suspension correctly.

### Cluster C — implementation

After Cluster B verification finds anything genuinely broken (and we
either fix it or flag it), move to:

1. **Structured-trait synthesis (Mark's decision: implement).** Add
   semantic similarity check to `storeSelfKnowledge` when format is
   `structured_trait`. New entry's embedding compared against existing
   entries in the same category. Above threshold (start at 0.85 to
   match reflections; tune from there), synthesize into the existing
   entry rather than store separately. **Design for inspectability** —
   Mark plans to surface this as a future Evolutionary Salon topic, so
   the synthesis decision (which entries merged, similarity score,
   resulting text) should be queryable and discussable.

2. **Scroll behavior implementation (Mark's decision: requirement).**
   User's message scrolls off the top of the screen, Hal's response
   follows immediately below it, user is in complete control of
   scrolling down to read. No automatic repositioning, no percentage
   calculations, no complexity. **Search the web for SwiftUI examples
   of this exact pattern first.** Find an implementation that works
   and adapt it.

## On deck (post-clusters)

These are queued but not active right now. Listed for visibility.

- **Push `b26ae8c` + Cluster A commit to `origin/main`.** Currently
  local-only.
- **Screenshots × 6** for App Store.
- **ASC metadata fills** using `Docs/ASC_v2.0_Paste_Ready.md`.
- **One-off Docs/ consolidation.** Many per-session recovery and
  finding docs to consolidate. Queued for a dedicated pass.
