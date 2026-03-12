# Salon Mode â€” Finalized Architecture & Decisions

This document captures the **agreedâ€‘upon design**, **explicit decisions**, and **one required code change** so nothing is lost.

---

## 1. Core Model

- **Hal is one conversational agent.**
- Multiple LLMs are treated as **internal voices**, not separate agents.
- All outputs are visible, traceable, and attributable.

---

## 2. Seats

- Fixed number of seats (e.g. 4).
- Each seat selects a model or is empty.
- Seats speak **sequentially**.
- The same model may occupy multiple seats.

---

## 3. Behavioral Modes (Collapsed)

There is exactly **one behavioral axis**:

1. **Independent Perspectives**

   - Seats do **not** see prior seat output.
   - Uses existing singleâ€‘model STM behavior.
   - Verbatim rolling turns are preserved.

2. **Contextâ€‘Aware Perspectives**

   - Seats **may** see prior seat output.
   - Verbatim assistant turns are **not** used in STM.
   - Rolling conversation continuity is preserved via **summaries or distilled context**.

No separate â€œbuildâ€, â€œreflectâ€, or â€œcritiqueâ€ modes. Tone emerges naturally from model differences.

---

## 4. Summarizer

- The summarizer is **Seat N+1**.
- It is:
  - optional
  - visible
  - attributable
  - written to memory
- It acts as a **host/moderator**, not a system phase.
- Its purpose is to cap a turn for human readability, not to override content.

Summarization occurs:

- **after Seat N finishes**
- **before the next user turn**

No hidden orchestration lifecycle exists.

---

## 5. Prompting & Context

- **Independent mode** uses the existing system prompt and STM.
- **Contextâ€‘aware mode** uses:
  - a slimmer system prompt
  - rolling conversation summaries
  - optional priorâ€‘seat summaries
- Verbatim assistant turns are excluded only in contextâ€‘aware mode.

The complexity lives in **context construction**, not execution.

---

## 6. Memory & Retrieval

- All assistant outputs are stored.
- All outputs remain eligible for retrieval.
- Attribution (`recorded_by_model`) is preserved.
- Future perâ€‘model RAG filtering remains possible.

---

## 7. Reflection

- Multiple reflections per user turn are **allowed**.
- Reflection deduplication, decay, and confidence mechanisms already bound risk.
- Reflection is treated as healthy internal cognition, not a bug.

---

## 8. UX

- Each assistant message shows a **byline / footer** indicating model.
- Outputs are not autoâ€‘scrolled.
- User controls reading pace.
- Multiple perspectives are visually obvious without fragmenting Halâ€™s identity.

---

## 9. Error Handling

- Model failure is considered **catastrophic**.
- Appâ€‘level failure and restart is acceptable.
- Skipping seats is not required unless policy changes later.

---

## 10. **One Required Code Change (The Only Exception)**

### Shortâ€‘Term Memory Turn Grouping

**Current assumption (implicit):**

- One user message â†’ one assistant message

**Required correction:**

- One user message â†’ **all assistant messages until the next user message**

This change:

- does **not** affect nonâ€‘Salon mode
- does **not** change memory depth semantics
- only fixes turn grouping logic

> Memory hook: *STM must group all assistant messages after a user message as one turn.*

---

## 11. Salon Mode Settings â€” Visual Layout (ASCII)

The following ASCII layout represents the **final, revised Salon Mode settings sheet** as agreed.

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
â”‚  (â—‹) Contextâ€‘Aware Perspectivesâ”‚
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

- fixed seat count
- explicit speaking order
- single behavioral axis
- visible, optional summarizer
- no hidden orchestration

---

## 12. Code-Level Implications & Required Changes

This section captures the **specific code implications**, updated to reflect all final design decisions.

---

### A. Short-Term Memory (STM) â€” Required Change

**What must change:**

STM turn grouping logic must treat **one user message + all subsequent assistant messages until the next user message** as a single turn.

**Why:**

- Salon Mode can generate multiple assistant messages per user turn.
- Existing logic implicitly assumes one assistant reply per turn.

**Scope:**

- Localized change inside STM helper(s) that walk message history.
- No schema changes.
- No behavior change for non-Salon mode.

**Design rule:**

> A user message opens a turn. The next user message closes it.

---

### B. Salon Mode Execution â€” No New Pipeline

**Confirmed approach:**

- Reuse existing single-model `sendMessage()` pipeline.
- Wrap it in a simple loop over configured seats.

Each seat:

- selects its model
- builds its prompt according to behavioral mode
- executes one atomic LLM call
- renders output immediately
- writes output to memory with explicit model attribution

No buffering, aggregation, or delayed rendering.

---

### C. Summarizer (Moderator Seat)

**Implementation model:**

- Treated as **Seat N+1**, not a lifecycle phase.
- Uses the same execution path as other seats.

**When it runs:**

- After the final discussion seat completes.
- Before the next user turn begins.

**What it does:**

- Produces a visible, attributable summary.
- Does not override or replace prior content.
- Is written to memory like any other assistant output.

---

### D. Prompt Construction â€” Mode-Aware

**Independent Perspectives:**

- Uses existing system prompt.
- Uses existing verbatim STM.
- No seat-to-seat context.

**Context-Aware Perspectives:**

- Uses a slimmer system prompt.
- Excludes verbatim assistant turns from STM.
- Injects summarized or distilled conversational context.

Complexity is confined to **prompt construction**, not execution flow.

---

### E. Token Accounting

- Special token accounting is required **only** for Context-Aware Salon Mode.
- Independent mode uses existing token logic unchanged.

Mitigations already in place:

- Slimmer system prompt
- Summarized context instead of verbatim turns

No global refactor required.

---

### F. Attribution & Memory Storage

- Every assistant message must explicitly pass its `modelID` to memory storage.
- Attribution already exists in the schema; this ensures correctness inside the seat loop.

All outputs remain:

- retrievable
- attributable
- eligible for future per-model RAG filtering

---

### G. Reflection

- Reflection may occur multiple times per user turn.
- This is acceptable and aligned with Halâ€™s philosophy.
- Existing deduplication, decay, and confidence mechanisms bound risk.

No change required unless empirical issues appear.

---

### H. Error Handling

- Model failure is considered catastrophic.
- App-level failure and restart is acceptable.
- Seat skipping or fallback logic is not required.

---

### I. Configuration Changes Mid-Run

- Changing models or seat configuration mid-run is treated the same as single-model mode.
- New configuration applies to subsequent calls.
- No special orchestration or guards required.

---

## 13. Pseudocode â€” Salon Mode Execution (Grounded in Existing Code)

This pseudocode shows **exactly how Salon Mode fits into the current Hal.swift architecture**, using real concepts, function names, and state that already exist.

It reflects all final decisions from this thread.

---

### A. Entry Point (ChatViewModel)

```swift
func sendMessage() async {
    let trimmed = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    isAIResponding = true
    thinkingStart = Date()

    // Store user message (opens a new turn)
    appendUserMessage(trimmed)

    if settings.isSalonModeEnabled {
        await runSalonTurn(userInput: trimmed)
    } else {
        await runSingleModelTurn(userInput: trimmed)
    }

    isAIResponding = false
}
```

---

### B. Salon Turn Loop

```swift
func runSalonTurn(userInput: String) async {
    let seats = salonConfiguration.orderedSeats

    for seat in seats {
        guard let model = seat.model else { continue }

        activeModelID = model.id
        await switchToModel(model)

        let prompt = buildSalonPrompt(
            userInput: userInput,
            mode: salonConfiguration.behavioralMode,
            seatIndex: seat.index
        )

        await sendModelResponse(
            prompt: prompt,
            modelID: model.id
        )
    }

    if salonConfiguration.isSummaryEnabled {
        await runModeratorSummary()
    }
}
```

---

### C. Prompt Construction (Mode-Aware)

```swift
func buildSalonPrompt(
    userInput: String,
    mode: SalonBehavioralMode,
    seatIndex: Int
) -> String {

    let systemPrompt = (mode == .contextAware)
        ? slimSalonSystemPrompt
        : defaultSystemPrompt

    let history: [ChatMessage]

    if mode == .independent {
        history = getShortTermMessages() // unchanged behavior
    } else {
        history = getSummarizedConversationState()
    }

    return buildPromptHistory(
        systemPrompt: systemPrompt,
        history: history,
        userInput: userInput
    )
}
```

---

### D. Sending and Storing a Seat Response

```swift
func sendModelResponse(prompt: String, modelID: String) async {
    let placeholderID = appendAssistantPlaceholder(modelID: modelID)

    let output = await llmService.generate(
        prompt: prompt,
        modelID: modelID
    )

    finalizeAssistantMessage(
        placeholderID: placeholderID,
        content: output,
        modelID: modelID
    )

    memoryStore.storeTurn(
        conversationID: currentConversationID,
        content: output,
        isFromUser: false,
        recordedByModel: modelID
    )
}
```

---

### E. Moderator / Summarizer (Seat N+1)

```swift
func runModeratorSummary() async {
    let model = salonConfiguration.summaryModel
    activeModelID = model.id

    await switchToModel(model)

    let summaryPrompt = buildSummaryPrompt(
        conversationID: currentConversationID
    )

    await sendModelResponse(
        prompt: summaryPrompt,
        modelID: model.id
    )
}
```

---

### F. Required STM Grouping Fix (Conceptual)

```swift
// Pseudocode only â€” illustrates grouping rule
// One user message opens a turn
// All assistant messages until the next user message belong to that turn

func getShortTermMessages() -> [ChatMessage] {
    var result: [ChatMessage] = []
    var currentTurnMessages: [ChatMessage] = []

    for message in allMessages {
        if message.isFromUser {
            if !currentTurnMessages.isEmpty {
                result.append(contentsOf: currentTurnMessages)
            }
            currentTurnMessages = [message]
        } else {
            currentTurnMessages.append(message)
        }
    }

    if !currentTurnMessages.isEmpty {
        result.append(contentsOf: currentTurnMessages)
    }

    return result
}
```

---

## 14. Pseudocode â†’ Hal.swift Mapping (Implementation Guide)

This section maps each piece of Salon Mode pseudocode to the **exact existing functions and blocks in Hal.swift**, so implementation can proceed without reinterpretation.

---

### A. Entry Point â€” Message Send

**Pseudocode concept:**

- Branch between single-model and Salon Mode execution.

**Existing function:**

- `ChatViewModel.sendMessage()`

**LEGO block:**

- `// ==== LEGO START: 21 ChatViewModel (Send Message Flow) ====`

**Implementation note:**

- No structural change required.
- Salon Mode branch wraps existing logic; non-Salon mode remains untouched.

---

### B. Salon Seat Loop

**Pseudocode concept:**

- Loop over configured seats.
- Switch models.
- Build prompt.
- Execute one atomic LLM call per seat.

**Existing functions / state:**

- `switchToModel(_:)`
- `activeModelID`
- `llmService.generate(...)`

**LEGO blocks:**

- Model selection and execution blocks already present.

**Implementation note:**

- This is a thin wrapper around the existing pipeline.
- No buffering or aggregation logic is introduced.

---

### C. Prompt Construction

**Pseudocode concept:**

- Mode-aware prompt building (Independent vs Context-Aware).

**Existing function:**

- `buildPromptHistory(...)`

**LEGO block:**

- Prompt construction block (existing).

**Implementation note:**

- Independent mode passes existing STM unchanged.
- Context-Aware mode passes summarized/distilled context instead of verbatim assistant turns.
- No changes to `buildPromptHistory` itself; only to its inputs.

---

### D. Sending & Storing Assistant Output

**Pseudocode concept:**

- Create placeholder.
- Stream/finalize output.
- Store to memory with explicit model attribution.

**Existing functions / patterns:**

- `appendAssistantPlaceholder(...)`
- `finalizeAssistantMessage(...)`
- `MemoryStore.storeTurn(...)`

**Implementation note:**

- Ensure `recordedByModel` (or equivalent) is explicitly passed per seat.
- Attribution already exists in schema; this makes it explicit in Salon Mode.

---

### E. Summarizer (Moderator Seat)

**Pseudocode concept:**

- Optional Seat N+1.
- Visible, attributable, one-shot call.

**Existing utilities:**

- Existing summarizer prompt + LLM execution path.

**Implementation note:**

- Implemented as a normal seat call after Seat N.
- No lifecycle phase, no hidden orchestration.

---

### F. **Required Code Change â€” STM Turn Grouping**

**This is the only mandatory code modification.**

**Existing function:**

```swift
ChatViewModel.getShortTermMessages(turns: [Int])
```

**LEGO block:**

- `// ==== LEGO START: 22 ChatViewModel (Short-Term Memory Helpers) ====`

**Problem:**

- Current logic assumes one assistant message per user turn.

**Required behavior:**

- One user message opens a turn.
- All assistant messages until the next user message belong to that turn.

**Implementation guidance:**

- Modify grouping logic only.
- No schema changes.
- No change in non-Salon behavior.

> Memory hook: *STM must group all assistant messages after a user message as one turn.*

---

### G. Reflection

**Existing behavior:**

- Reflection may trigger multiple times.

**Decision:**

- Multiple reflections per user turn are allowed and intentional.
- No code change required.

---

### H. Token Accounting

**Existing behavior:**

- Token estimation per prompt.

**Decision:**

- Special handling only in Context-Aware Salon Mode.
- No immediate refactor required.

---

### I. Error Handling

**Decision:**

- Model failure is catastrophic.
- App restart is acceptable.
- No fallback logic required.

---

## 15. Final Status

This document is the **authoritative implementation guide** for Salon Mode.

It is safe to hand to another model with the instruction:

> "Please implement the following exactly."

- Architecture: **Validated**
- Simplifications: **Correct**
- External feedback: **Incorporated**
- Open work: **One small STM grouping fix**

This document is the authoritative snapshot of Salon Mode design decisions.

