# UX Specification: Chat Scroll Behavior
**Status:** Queued for implementation post-current sprint
**Priority:** High — affects all streaming responses across all models
**Date captured:** May 13, 2026

---

## The Problem

Real token streaming at 30+ tokens per second renders text faster than a
human can read. The current behavior auto-scrolls to follow the bottom of
the incoming response, which means:

- The beginning of the response disappears above the fold before the user
  can read it
- The user must manually scroll back up after generation completes
- The reading experience feels like chasing a moving target
- The technical improvement (real streaming) paradoxically creates a worse
  user experience than the previous fake typewriter animation

---

## The Desired Behavior

**Reference implementation:** Claude.ai (claude.ai) — Mark's personal favorite
and the clearest existing example of this pattern done well.

When the user sends a message and a response begins streaming:

1. The view scrolls so the user's outgoing message sits just below the
   top navigation chrome — pinned there, readable, not flying off screen
2. The assistant's response begins rendering immediately below the user's
   message and grows downward
3. The scroll position is anchored to the TOP of the exchange (the user's
   message), not the BOTTOM of the incoming response
4. The user has a fixed reading origin — their question — and the answer
   unfolds below it naturally, the way you'd read a page
5. Nothing disappears above the fold mid-stream
6. If the user manually scrolls during generation, auto-scroll stops
   immediately and the user retains control
7. When generation completes, no forced scroll occurs — the user is
   wherever they chose to be

---

## What This Is NOT

This is distinct from the simpler "bottom anchor" pattern where the view
continuously scrolls to keep the last token visible. That pattern causes
the firehose problem described above.

This is also distinct from "no auto-scroll" where nothing moves at all
and the user must manually scroll to see new responses.

---

## Industry Terminology

No single canonical UX term exists for this exact pattern, but the
closest established terms are:

- **Scroll anchor / Chat scroll anchor** — general term for the mechanism
  (Apple's SwiftUI API uses `ScrollAnchorRole`)
- **Outgoing message anchoring** — the specific variant where the user's
  sent message, not the bottom of the response, is the anchor point
- **Exchange-level scroll anchoring** — anchoring to the top of the
  current user/assistant exchange rather than the bottom of the stream

The Vercel AI SDK implements a simpler `ChatScrollAnchor` (bottom anchor
with user-scroll interrupt). What we want is one step more sophisticated:
the anchor point is the user's outgoing message, not the bottom.

---

## SwiftUI Implementation Notes

Apple provides native APIs for this in iOS 17+:

- `ScrollAnchorRole` — defines what role a view plays as a scroll anchor
- `scrollPosition` modifier — programmatically control scroll position
- The implementation should: on response start, scroll the user's outgoing
  message bubble to `ScrollAnchorRole` top (just below navigation chrome),
  then hold that position for the duration of streaming
- User scroll interrupt: if `onScrollGeometryChange` detects user-initiated
  scroll during streaming, disengage the anchor immediately

---

## Secondary Consideration: Render Pacing

Even with correct scroll anchoring, 30+ tok/s may feel like a firehose
visually. Consider whether a subtle render pacing layer makes sense —
not fake slowdown, but smooth progressive rendering that doesn't feel
jarring. Claude.ai handles this well. This is secondary to the scroll
anchor fix and should be evaluated after the anchor behavior is correct.

---

## Scope

This affects:
- All models (AFM and all curated MLX)
- Single model chat (primary impact)
- Salon Mode (each seat's response has the same issue)

This is a global fix to the chat scroll view, not a per-model change.

---

## When to Implement

After the current sprint (settings profiles, Maxim testing, host
architecture). This is a UX polish pass, not a functional bug. However
it significantly affects the perceived quality of the streaming
improvement that was already shipped, so it should not be deferred
to post-release if avoidable.

Tag for CC: implement as a dedicated commit, test across all four
curated models and AFM, verify the user-scroll interrupt works correctly
(user scrolls up mid-stream → auto-scroll stops → user retains control).
