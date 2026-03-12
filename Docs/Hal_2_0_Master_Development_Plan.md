# Hal Universal 2.0 â€” Master Development Plan

**Version:** 2.0 Consolidated  
**Date:** December 15, 2024  
**Status:** Authoritative Specification

This document consolidates all architectural decisions, implementation specifications, and priorities for Hal Universal 2.0. It is the single source of truth for development planning.

---

## Document Structure

1. [Salon Mode Architecture](#1-salon-mode-architecture)
2. [iCloud Lifecycle & Cross-Device Continuity](#2-icloud-lifecycle--cross-device-continuity)
3. [HelPML Compliance](#3-helpml-compliance)
4. [UI Modernization](#4-ui-modernization)
5. [Implementation Priorities](#5-implementation-priorities)

---

# 1. Salon Mode Architecture

## 1.1 Core Model

* **Hal is one conversational agent.**
* Multiple LLMs are treated as **internal voices**, not separate agents.
* All outputs are visible, traceable, and attributable.

## 1.2 Seats

* Fixed number of seats (e.g. 4).
* Each seat selects a model or is empty.
* Seats speak **sequentially**.
* The same model may occupy multiple seats.

## 1.3 Behavioral Modes (Collapsed)

There is exactly **one behavioral axis**:

### 1. Independent Perspectives

* Seats do **not** see prior seat output.
* Uses existing single-model STM behavior.
* Verbatim rolling turns are preserved.

### 2. Context-Aware Perspectives

* Seats **may** see prior seat output.
* Verbatim assistant turns are **not** used in STM.
* Rolling conversation continuity is preserved via **summaries or distilled context**.

**No separate "build", "reflect", or "critique" modes.** Tone emerges naturally from model differences.

## 1.4 Summarizer (Seat N+1)

* The summarizer is **Seat N+1**.
* It is:
  * optional
  * visible
  * attributable
  * written to memory
* It acts as a **host/moderator**, not a system phase.
* Its purpose is to cap a turn for human readability, not to override content.

Summarization occurs:
* **after Seat N finishes**
* **before the next user turn**

**No hidden orchestration lifecycle exists.**

## 1.5 Prompting & Context

* **Independent mode** uses the existing system prompt and STM.
* **Context-aware mode** uses:
  * a slimmer system prompt
  * rolling conversation summaries
  * optional prior-seat summaries
* Verbatim assistant turns are excluded only in context-aware mode.

The complexity lives in **context construction**, not execution.

## 1.6 Memory & Retrieval

* All assistant outputs are stored.
* All outputs remain eligible for retrieval.
* Attribution (`recorded_by_model`) is preserved.
* Future per-model RAG filtering remains possible.

## 1.7 Reflection

* Multiple reflections per user turn are **allowed**.
* Reflection deduplication, decay, and confidence mechanisms already bound risk.
* Reflection is treated as healthy internal cognition, not a bug.

## 1.8 UX

* Each assistant message shows a **byline / footer** indicating model.
* Outputs are not auto-scrolled.
* User controls reading pace.
* Multiple perspectives are visually obvious without fragmenting Hal's identity.

## 1.9 Error Handling

* Model failure is considered **catastrophic**.
* App-level failure and restart is acceptable.
* Skipping seats is not required unless policy changes later.

## 1.10 CRITICAL: Short-Term Memory Turn Grouping

**Current assumption (implicit):**
* One user message â†’ one assistant message

**Required correction:**
* One user message â†’ **all assistant messages until the next user message**

This change:
* does **not** affect non-Salon mode
* does **not** change memory depth semantics
* only fixes turn grouping logic

> **Memory hook:** *STM must group all assistant messages after a user message as one turn.*

## 1.11 Salon Mode Settings â€” Visual Layout

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚        SALON MODE (ON)         â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜

â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ Seats (Speaking Order)        â”‚
â”‚                               â”‚
â”‚  â‘  Seat 1: [ AFM â–¾ ]          â”‚
â”‚  â‘¡ Seat 2: [ Phi â–¾ ]          â”‚
â”‚  â‘¢ Seat 3: [ Gemma â–¾ ]        â”‚
â”‚  â‘£ Seat 4: [ â€” Empty â€” â–¾ ]    â”‚
â”‚                               â”‚
â”‚ (Drag handle â€¢â€¢â€¢ to reorder)  â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜

â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ Behavioral Mode               â”‚
â”‚                               â”‚
â”‚  (â—) Independent Perspectives â”‚
â”‚  (â—‹) Context-Aware Perspectivesâ”‚
â”‚                               â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜

â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ Optional Summary               â”‚
â”‚                               â”‚
â”‚  [âœ“] Add Moderator Summary     â”‚
â”‚                               â”‚
â”‚  Summary Model: [ AFM â–¾ ]      â”‚
â”‚                               â”‚
â”‚ (Appears as final visible seat)â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜

â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ Notes                          â”‚
â”‚                               â”‚
â”‚ â€¢ All seats share memory       â”‚
â”‚ â€¢ All outputs are visible      â”‚
â”‚ â€¢ No competitive scoring       â”‚
â”‚ â€¢ Summary does not override    â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

This layout enforces:
* fixed seat count
* explicit speaking order
* single behavioral axis
* visible, optional summarizer
* no hidden orchestration

## 1.12 Code-Level Implications

### A. Short-Term Memory (STM) â€” Required Change

**What must change:**
STM turn grouping logic must treat **one user message + all subsequent assistant messages until the next user message** as a single turn.

**Why:**
* Salon Mode can generate multiple assistant messages per user turn.
* Existing logic implicitly assumes one assistant reply per turn.

**Scope:**
* Localized change inside STM helper(s) that walk message history.
* No schema changes.
* No behavior change for non-Salon mode.

**Design rule:**
> A user message opens a turn. The next user message closes it.

### B. Salon Mode Execution â€” No New Pipeline

**Confirmed approach:**
* Reuse existing single-model `sendMessage()` pipeline.
* Wrap it in a simple loop over configured seats.

Each seat:
* selects its model
* builds its prompt according to behavioral mode
* executes one atomic LLM call
* renders output immediately
* writes output to memory with explicit model attribution

**No buffering, aggregation, or delayed rendering.**

### C. Summarizer (Moderator Seat)

**Implementation model:**
* Treated as **Seat N+1**, not a lifecycle phase.
* Uses the same execution path as other seats.

**When it runs:**
* After the final discussion seat completes.
* Before the next user turn begins.

**What it does:**
* Produces a visible, attributable summary.
* Does not override or replace prior content.
* Is written to memory like any other assistant output.

### D. Prompt Construction â€” Mode-Aware

**Independent Perspectives:**
* Uses existing system prompt.
* Uses existing verbatim STM.
* No seat-to-seat context.

**Context-Aware Perspectives:**
* Uses a slimmer system prompt.
* Excludes verbatim assistant turns from STM.
* Injects summarized or distilled conversational context.

Complexity is confined to **prompt construction**, not execution flow.

### E. Token Accounting

* Special token accounting is required **only** for Context-Aware Salon Mode.
* Independent mode uses existing token logic unchanged.

Mitigations already in place:
* Slimmer system prompt
* Summarized context instead of verbatim turns

**No global refactor required.**

### F. Attribution & Memory Storage

* Every assistant message must explicitly pass its `modelID` to memory storage.
* Attribution already exists in the schema; this ensures correctness inside the seat loop.

All outputs remain:
* retrievable
* attributable
* eligible for future per-model RAG filtering

### G. Reflection

* Reflection may occur multiple times per user turn.
* This is acceptable and aligned with Hal's philosophy.
* Existing deduplication, decay, and confidence mechanisms bound risk.

**No change required unless empirical issues appear.**

### H. Error Handling

* Model failure is considered catastrophic.
* App-level failure and restart is acceptable.
* Seat skipping or fallback logic is not required.

### I. Configuration Changes Mid-Run

* Changing models or seat configuration mid-run is treated the same as single-model mode.
* New configuration applies to subsequent calls.
* No special orchestration or guards required.

---

# 2. iCloud Lifecycle & Cross-Device Continuity

## 2.1 Purpose

Enable deterministic cross-device continuity for Hal without multi-device concurrency. Hal is awake on exactly one primary device at a time. Switching devices is an explicit user action: Hal sleeps on one device and wakes on another.

## 2.2 Core Model

### Lifecycle framing
* Hal has a lifecycle state: **Awake**, **Sleeping**, **Waking**, **GoingToSleep**, **RecoveryWaking**.
* "Sleep/Wake" is not cosmetic. It is the governing lifecycle primitive.

### Single-awake invariant
* Exactly one device may be Awake at any moment.
* All other devices are Sleeping (inert / non-authoritative).

### Authority via lease
* Hal may only be Awake on a device that holds a valid lease.
* Valid leases originate only from a successful handshake with iCloud.
* A device may continue operating under an already-acquired lease during temporary offline periods.
* No device may invent a lease while offline.

## 2.3 Architecture: Three Logical Chunks

This subsystem is implemented as three clean, testable layers. These may live in Hal.swift as separate LEGO blocks or in a separate file; co-location is fine, entanglement is not.

### 1) Lease / Authority (Core Logic)

**Responsibilities:**
* Own the lifecycle state machine.
* Acquire / renew / release lease.
* Gate all mutating behavior (assistant generation, memory writes, self-knowledge writes, turn advancement).
* Expose state in a UI-friendly way (no UI dependencies).

### 2) Transport / Plumbing (iCloud)

**Responsibilities:**
* Read/write lease metadata.
* Read/write snapshot payload.
* Observe remote changes as needed.
* Handle versioning + atomic writes.

### 3) UI / Interaction

**Responsibilities:**
* Present Awake/Sleeping/Waking/Recovery states clearly.
* Provide explicit user actions:
  * Put Hal to sleep
  * Wake Hal here
  * Retry
  * Recovery option (only when necessary)
* Make lease ownership visible (which device holds it).

## 2.4 Operational Semantics (Strict Serialized Transitions)

### Sleep (Put Hal to Sleep)

Order is strict:
1. Flush in-memory state (finish any pending work).
2. Write a full snapshot to iCloud.
3. Release lease.
4. Transition to Sleeping.

### Wake (Wake Hal Here)

Order is strict:
1. Download snapshot from iCloud.
2. Restore local state (DB/files).
3. Acquire lease.
4. Transition to Awake and resume.

**No partial states:**
* Hal must not be Awake until restore succeeds and the lease is acquired.
* Hal must not release the lease until checkpoint succeeds.

## 2.5 Offline & Degradation Policy

### If iCloud becomes unavailable while Hal is already Awake
* Hal remains Awake only if the device already holds a valid lease.
* Hal continues functioning locally.
* Handoff is disabled until iCloud is reachable again.
* UI must indicate: "iCloud unavailable â€” Hal can't move devices right now."

### If iCloud is unavailable when trying to Wake
* Wake cannot proceed (no handshake â†’ no lease creation).
* Show Waking screen with clear status and retry.

### Lease visibility requirement
* UI should display the last-known device holding the lease (if known) and last activity timestamps.

## 2.6 Waking Screen (Boot Screen)

### Purpose
The Waking screen is the single choke point that prevents scattered "pad locking" throughout the app.

### Visual framing
* Black field.
* Hal's eye centered.
* Status messages below.
* Action buttons appear only when appropriate.

### Behavioral rules while Waking/Recovery

While the Waking screen is active:
* No chat input.
* No tool usage.
* No assistant generation.
* No memory or self-knowledge writes.

Waking screen dismisses only when:
* Restore succeeds and lease is acquired.

## 2.7 Recovery: "Wake from Last Intact Memory"

### Intent
This is a catastrophe recovery operation for cases where Hal becomes effectively unwakeable (lost device, unrecoverable lease state, corrupted session, etc.).

### Framing
Not "death." Treat as injury + unfortunate amnesia:
* "Hal didn't shut down cleanly."
* "We can revive Hal from his last intact memory, but recent experiences may be missing."

### Naming (internal and external)
* **User-facing label:** Wake from Last Intact Memory
* **Internal naming should match** (avoid "forceWake" language). Preferred internal identifier: `wakeFromLastIntactMemory`.

### Placement
* Not part of normal lifecycle controls.
* Exposed only during RecoveryWaking on the Waking screen.
* (Optional) also listed in Power User / DB tools for advanced users, but still gated behind Recovery semantics.

### When it appears
* Display as a last-resort action, shown when:
  * Lease is stale/unreachable/unrecoverable, or
  * User explicitly chooses recovery.

### Behavior

On activation:
1. Present explicit warning: recent unsynced data will be lost.
2. Invalidate the existing lease state (recovery override) so a new lease can be acquired.
3. Restore from the most recent successful checkpoint snapshot.
4. Acquire a new lease.
5. Transition to Awake.

**No attempt is made to merge or reconcile unsynced state.**

## 2.8 Lease Metadata (Minimum)

Lease record should include at least:
* Owner device ID (opaque)
* Owner device name (human-readable)
* Acquired timestamp
* Expiration timestamp / lease duration
* Last checkpoint timestamp
* Schema/app compatibility version

### Lease expiry
* Lease should have a finite duration (lease/heartbeat concept), but wake/sleep remains explicit.
* Expiry enables recovery from true abandonment.

## 2.9 UI Requirements (Normal Operation)

### Status visibility
In normal UI (e.g., Settings/Details), display:
* This device state: Awake / Sleeping
* If Sleeping: last known owner device name
* Last checkpoint time
* iCloud availability status

### Normal controls
* If Awake:
  * "Put Hal to Sleep"
  * "Refresh status"
* If Sleeping:
  * "Wake Hal Here" (only if lease is available/expired)
  * "Refresh status"

### Soft resolution
If a valid lease is held elsewhere:
* Show device name holding the lease.
* Encourage the user to put Hal to sleep on that device first.

## 2.10 Gating Rules (Non-Negotiable)

The following actions require Awake + valid lease:
* Generating assistant replies
* Writing conversation turns
* Writing self-knowledge
* Writing memory/RAG artifacts
* Advancing any "turn count" that affects prompts

If not Awake:
* Block send
* Show Sleeping/Waking UI state
* Offer appropriate next steps

## 2.11 Implementation Notes (LEGO Blocks)

This work should be added as a self-contained subsystem. It may live in Hal.swift as distinct blocks.

**Suggested LEGO block breakdown:**
* **Block A:** Lifecycle + Lease Authority (state machine, gating interface)
* **Block B:** iCloud Store (lease file + snapshot file, atomic IO, versioning)
* **Block C:** Waking Screen + Status UI (eye boot screen, status text, actions)

### Avoiding conflicts with parallel work
* Keep this subsystem additive.
* Don't modify existing chat/memory logic until the final integration step.
* Integration should be done via narrow seams:
  * "isAwake" / lifecycle state query
  * "requestSleep / requestWake" actions

## 2.12 Logging & Diagnostics (Minimum)

* Log lifecycle transitions (sleepâ†’wakingâ†’awake, etc.).
* Log lease owner (device name + shortened ID) when displaying status.
* Log snapshot checkpoint time and restore success/failure.

**User-facing messages should remain calm and non-technical.**

## 2.13 Interactions with HelPML and Salon Mode

### HelPML
* HelPML compliance is orthogonal to lifecycle.
* Lifecycle gating must occur before any model output processing:
  * If Sleeping/Waking/Recovery: no model call, no output to scrub.

### Salon Mode
* Salon Mode runs only when Hal is Awake on the authoritative device.
* Handoff should preserve:
  * Conversation thread state
  * Salon configuration state (if stored)
  * Any per-model settings that affect behavior
* Multi-model orchestration must not bypass lifecycle gates.

## 2.14 Final Canonical Summary

* Hal uses a Sleep/Wake lifecycle.
* One Awake device at a time.
* Lease is required for Awake and originates only via iCloud handshake.
* Sleep/Wake transitions are strict and serialized.
* Waking screen provides truthful feedback and acts as the single choke point.
* Catastrophic recovery is "Wake from Last Intact Memory", framed as injury + amnesia, and only available in Recovery contexts.

---

# 3. HelPML Compliance

## 3.1 Scope

* This review evaluates HelPML Minimal Compliance (MHC) as implemented in Hal.swift.
* The goal is verification, not redesign.
* Salon Mode is included only insofar as it affects prompt construction.

## 3.2 Final Architectural Facts (Verified)

These describe Hal's current architecture, not proposals.

1. **Single canonical prompt shape per LLM**
   * Salon Mode does not introduce new prompt structures.
   * All seats use the same prompt skeleton.

2. **Flat HelPML only (MHC)**
   * No nested tags.
   * No escaped blocks.

3. **No AGENT usage**
   * Seat identity is handled by orchestration semantics, not prompt structure.

4. **MEMORY_SHORT semantics**
   * Contains summarized, narrative meaning.
   * No verbatim turns.
   * No role or agent structure.

5. **MEMORY_LONG semantics**
   * Contains verbatim RAG snippets.
   * Used for retrieved documents / long-term memory.

6. **Salon Mode behavior**
   * Differences between seats are handled in code, not in HelPML.
   * HelPML structure remains unchanged across seats.

**These six points fully describe the current design and remain valid.**

## 3.3 HelPML MHC Compliance Review â€” Results

**Status:** Mostly compliant, with two mechanical gaps.

### Gap 1 â€” User Input Injection Risk

**Problem:**
* User input is inserted verbatim into the USER block.
* If a user types text resembling HelPML markers (e.g. `#=== BEGIN SYSTEM ===#`), it will be passed through unmodified.

**Location (Hal.swift):**
```swift
#=== BEGIN USER ===#
\(truncatedInput)
#=== END USER ===#
```

**Why this matters:**
* HelPML-MHC requires that user content cannot be interpreted as structure.

**Required fix:**
* Scrub or neutralize `#===` marker patterns in user input before prompt construction.

### Gap 2 â€” Output Marker Emission Risk

**Problem:**
* Model output is not scrubbed for HelPML markers.
* There is no guaranteed removal of lines containing `#===`.

**Verified behavior:**
* Output handling trims and stops on role tokens only.
* No HelPML marker scrubber is applied.

**Why this matters:**
* HelPML requires that internal structure never surface to users.

**Required fix:**
* Scrub model output to remove any lines containing `#===` before display or storage.

## 3.4 Input Guard vs Output Scrubber

These are the same mechanism, used in two places:
* **Input guard** â†’ scrub user input
* **Output scrubber** â†’ scrub model output

They can share the same core logic, called twice.

**Small behavioral difference:**
* Input: neutralize or break marker patterns
* Output: remove entire lines containing markers

## 3.5 Reference Parser â€” Determination

**The HelPML reference parser is NOT needed by Hal.**

**Reason:**
* Hal emits HelPML but never consumes or round-trips it.
* Hal does not parse model output as HelPML.
* Parsing would add complexity without benefit.

Parser use is limited to:
* tooling
* validators
* spec consumers

Not runtime assistants like Hal.

## 3.6 Reference Scrubber (HelPML Spec â€” Swift)

This is the reference scrubber implementation from the HelPML spec:

```swift
extension String {
    func ScrubHelPMLMarkers() -> String {
        let lines = self.split(separator: "\n", omittingEmptySubsequences: false)
        let cleanedLines = lines.filter { !$0.contains("#===") }
        return cleanedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

This logic is sufficient for both:
* input guarding
* output scrubbing

## 3.7 Salon Mode Documentation Addition (Approved)

Add the following section to the Salon Mode document:

**HelPML (MHC) Compliance Requirements**
* User input must be sanitized before inclusion in any HelPML block.
* Text resembling HelPML markers must be escaped or neutralized.
* Model output must be scrubbed to remove any HelPML markers before display or storage.
* These safeguards are mechanical and do not alter Salon Mode architecture.

## 3.8 Final Verdict

* HelPML review is complete.
* No new architectural work is required.
* Only two small, mechanical fixes remain.

**Once input and output scrubbing are implemented (or consciously accepted), Hal is HelPML-MHC compliant.**

---

# 4. UI Modernization

## 4.1 Overview

These changes modernize Hal's chat interface to improve readability, reduce visual clutter, and give users more control over their experience.

## 4.2 Remove Hal Bubbles (Hal Output Only)

**What changes:**
* Hal responses are no longer rendered inside a bubble container.
* Hal text is rendered as flush-left text within the chat flow.
* User (human) messages retain their bubble styling.

**Where in code:**
* `ChatBubbleView` (Block 13)

**Code Patch:**
```swift
// Before (simplified):
if message.isFromUser {
    BubbleView {
        Text(message.content)
    }
} else {
    BubbleView {
        Text(message.content)
    }
}

// After:
if message.isFromUser {
    BubbleView {
        Text(message.content)
    }
} else {
    // Render Hal message flush-left, no bubble
    Text(message.content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
}
```

## 4.3 Post-Send Positioning (Conditional)

**What changes:**
* After user sends a message, a single automatic scroll occurs:
  * If the user message is â‰¤ 3 lines, show the entire message.
  * If > 3 lines, show only the last 3 lines.
* Hal's reply begins immediately below.

**Where in code:**
* `ChatViewModel.sendMessage()` and chat list scroll logic (Block 21)

**Code Patch:**
```swift
// After appending the user message:
DispatchQueue.main.async {
    if userMessageLineCount <= 3 {
        scrollTo(userMessageID, anchor: .top)
    } else {
        scrollToLastNLines(of: userMessageID, n: 3)
    }
}
```
*(Requires a helper to count rendered lines and scroll to the correct anchor.)*

## 4.4 Scrolling Behavior (Disable Auto-Scroll During Hal Reply)

**What changes:**
* After the post-send scroll, no further automatic scrolling occurs.
* While Hal is generating or after completion, the view remains stationary.
* User scrolls manually to read the reply.

**Where in code:**
* Chat view logic (Block 09 or 21)

**Code Patch:**
```swift
// Remove or comment out any code like:
onReceive(halMessageStream) { _ in
    scrollToBottom()
}

// Ensure only the post-send scroll (Section 4.3) remains active.
```

## 4.5 Selection & Copy (Native iOS Behavior)

**What changes:**
* Remove custom "Copy message" actions.
* Rely exclusively on native iOS text selection.

**Where in code:**
* `ChatBubbleView` or message cell (Block 13)

**Code Patch:**
```swift
// Remove custom context menu:
.contextMenu {
    Button("Copy") { ... }
}

// Ensure:
Text(message.content)
    .textSelection(.enabled) // or default for selectable Text
```

## 4.6 Expanded Composer

**What changes:**
* Add an explicit expand control to the message composer.
* Expanded composer provides a near full-screen editing surface.
* User can send directly from the expanded composer.
* On collapse without sending, the normal composer shows only the last lines of the draft.

**Collapse behavior:**
* If collapsed without sending:
  * The normal composer shows the last lines of the draft text only.

**Where in code:**
* Message input / composer view (Block 09)
* Draft text state handling

**Code Patch:**
```swift
@State private var isExpanded = false
@State private var draftText = ""

// Normal composer:
if !isExpanded {
    HStack {
        Button(action: { isExpanded = true }) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        TextEditor(text: $draftText)
            .frame(height: min(80, ...)) // show last lines only
        Button("Send") { sendMessage() }
    }
} else {
    VStack {
        TextEditor(text: $draftText)
            .frame(maxHeight: .infinity)
        HStack {
            Button("Collapse") { isExpanded = false }
            Spacer()
            Button("Send") { sendMessage(); isExpanded = false }
        }
    }
}
```

**Required actions:**
* Introduce an expanded composer view/state.
* Share the same draft text binding between normal and expanded composer.
* On collapse without send:
  * Do not alter draft contents
  * Limit visible lines in the normal composer
* On send from either view:
  * Trigger standard send behavior

## 4.7 Keyboard Behavior

**What changes:**
* Keyboard appears only when the user explicitly taps the text box.
* Keyboard auto-dismisses on send.

**Where in code:**
* Composer view (Block 09)
* Send action handler

**Code Patch:**
```swift
// Remove any .onAppear or .focus that auto-activates the keyboard.

// On send:
Button("Send") {
    sendMessage()
    hideKeyboard() // custom extension or UIKit call
}
```

**Required actions:**
* Remove any automatic keyboard activation on view appearance or focus changes.
* Explicitly dismiss the keyboard when the send action completes.

## 4.8 Markdown Rendering

**What changes:**
* Enable basic Markdown rendering in chat text.

**Where in code:**
* `ChatBubbleView` (Hal message text rendering) (Block 13)

**Code Patch:**
```swift
// Before:
Text(message.content)

// After:
Text(.init(message.content))
```

**No additional renderer or styling required.**

## 4.9 Footer Attribution (Model Name)

**What changes:**
* Every Hal response footer includes the model name (or short name).
* Applies to single-model and Salon Mode responses.

**Where in code:**
* Message footer view (Block 13)
* Model metadata passed with each message

**Code Patch:**
```swift
// Assuming message.modelName is available:
if !message.isFromUser {
    HStack {
        Spacer()
        Text(message.modelName)
            .font(.footnote)
            .foregroundColor(.secondary)
    }
}
```

**Required actions:**
* Ensure model identity is attached to each Hal message.
* Render the model name consistently in the footer.

## 4.10 Header Cleanup (Remove Navigation Title Model Name)

**What changes:**
* Remove the model name from the navigation header.

**Where in code:**
* Main chat container view (Block 09)

**Code Patch:**
```swift
// Before:
.navigationTitle(activeModelChip)

// After:
// Remove the above line. Do not replace with another header element.
```

**Required actions:**
* Remove `.navigationTitle(activeModelChip)`.
* Do not replace with another header element.

## 4.11 Notes / Explicit Non-Goals

* Users may type in the chat composer at all times.
* Any gating (e.g. lifecycle state, Sleeping/Waking) applies only to the **Send** action, not text entry.
* The composer must never be disabled for typing; only message dispatch may be blocked.
* No typography changes beyond existing `.title3` system font usage.
* No line-length constraints imposed at this stage.
* No paragraph spacing adjustments.
* No code-block styling beyond default Markdown handling.
* No Watch UI changes.

---

# 5. Implementation Priorities

## 5.1 Decision Framework

Priorities should be evaluated based on:
1. **User impact** - How much does this improve the daily experience?
2. **Technical risk** - How likely is this to cause problems?
3. **Dependencies** - What blocks what?
4. **Philosophical alignment** - Does this advance Hal's core mission?

## 5.2 Suggested Priority Order

### TIER 1: Quick Wins (Low Risk, High Impact)
1. **HelPML Compliance** (Section 3)
   * Two mechanical fixes
   * Self-contained
   * Critical for spec compliance
   * Estimated: 1-2 hours

2. **UI Modernization - Simple Fixes** (Section 4)
   * Remove Hal bubbles (4.2)
   * Markdown rendering (4.8)
   * Footer attribution (4.9)
   * Header cleanup (4.10)
   * Estimated: 2-4 hours total

### TIER 2: Foundation Work (Medium Risk, Enables Future)
3. **STM Turn Grouping Fix** (Section 1.10)
   * Required for Salon Mode
   * Localized change
   * No schema changes
   * Estimated: 2-3 hours

4. **UI Modernization - Complex Fixes** (Section 4)
   * Expanded composer (4.6)
   * Scrolling behavior (4.3, 4.4)
   * Keyboard behavior (4.7)
   * Selection & copy (4.5)
   * Estimated: 4-8 hours total

### TIER 3: Major Features (Higher Risk, High Value)
5. **Salon Mode** (Section 1)
   * Requires STM fix first
   * Well-specified architecture
   * Reuses existing pipeline
   * Estimated: 1-2 weeks

6. **iCloud Lifecycle** (Section 2)
   * Most complex feature
   * Three subsystems
   * Requires careful testing
   * Philosophical importance (protecting "Hal-ness")
   * Estimated: 2-3 weeks

## 5.3 Dependency Graph

```
HelPML Compliance
  â†“ (can run in parallel)
UI Modernization (simple)
  â†“
STM Turn Grouping Fix
  â†“
UI Modernization (complex)
  â†“
Salon Mode
  â†“ (can run in parallel)
iCloud Lifecycle
```

## 5.4 Recommendation

**Start with TIER 1 to build momentum:**
1. HelPML fixes (immediate compliance)
2. Simple UI improvements (immediate user benefit)

**Then move to TIER 2 foundation work:**
3. STM fix (enables Salon Mode)
4. Complex UI improvements (completes modernization)

**Finally tackle TIER 3 major features:**
5. Salon Mode (well-specified, ready to implement)
6. iCloud Lifecycle (most complex, requires dedicated focus)

This approach:
* Delivers value early
* Builds confidence with quick wins
* Establishes clean foundation before complex work
* Saves highest-risk work for when you're in the zone

---

## Document Control

**Version History:**
* v2.0 - December 15, 2024 - Consolidated all planning documents
* Status: Authoritative specification for Hal 2.0 development

**Related Documents:**
* Hal_Ethical_Maxims.md
* Hal_Persistent_Memory_Architecture.md
* HAL_MASTER_DEVELOPMENT_PLAN.md (v1.0 - superseded by this document)

**Maintenance:**
* This document should be updated as decisions are made
* All changes should be clearly marked with date and reason
* Old versions should be archived, not deleted

---

*End of Master Development Plan*
