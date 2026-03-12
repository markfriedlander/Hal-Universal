# Hal Universal — Handoff Brief
**Written:** March 2026
**For:** Next Claude Code instance
**Written by:** Current CC instance, end-of-context

---

## Standing Practice: Document After Every Move

After any significant code change, build, or test run — update this file and MEMORY.md before continuing. Things that get lost in compaction: bug root causes, exact format findings, SOP results, what was tried and why it failed. Write it down immediately.

---

## Autonomous Build + Test Loop — FULLY CLOSED

```bash
# 1. Build
xcodebuild build \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=00008112-0010193C3A88C01E" \
  -configuration Debug \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# 2. Install + Launch (requires Xcode open with project loaded)
osascript << 'EOF'
tell application "Xcode"
    stop active workspace document
    delay 2
    run active workspace document
end tell
EOF
sleep 22   # Wait for app to boot and console to auto-start

# 3. Verify console alive
echo "GET_STATE" > "/Users/markfriedlander/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_test/commands.txt"
sleep 6
cat "/Users/markfriedlander/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_test/state.json"
```

**Container pref plist:** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Library/Preferences/com.MarkFriedlander.Hal-Universal.plist`
**Mac destination ID:** `00008112-0010193C3A88C01E`
**Harness dir:** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_test/`

---

## Current Architecture — RAG + Memory (as of March 2026)

### What Changed This Session (Strategic Direction Shift)

Three days of testing proved CONVERSATION_FACTS extraction does not work reliably across models. **CONVERSATION_FACTS is fully removed.** The new approach trusts RAG to do what RAG is designed for.

### CONVERSATION_FACTS — FULLY REMOVED

Everything related to CONVERSATION_FACTS has been deleted:
- `conversation_facts` DB table (Block 03 schema)
- `storeConversationFact()`, `getConversationFacts()`, `getConversationFactsFull()` (Block 07)
- Pass 2 extraction + parser + debug file writes in `generateAutoSummary()` (Block 18)
- Priority 3.5 injection block in `buildPromptHistory` (Block 20.1)
- `GET_FACTS` command + `writeFactsJSON()` in HalTestConsole (Block 32)
- `clearAllConversationData()` always returns 0 for facts count (correct — table gone)

**Zero references to `conversation_facts`, `getConversationFacts`, `storeConversationFact` remain in the codebase.** Confirmed by grep.

### RAG Exclusion — Fixed (Block 07, `buildExclusionClause`)

**Old (broken):** excluded entire current conversation from RAG by `source_id`. Made within-conversation recall impossible once a fact fell out of STM.

**New (correct):** surgical exclusion of STM-verbatim turns only.
```swift
private func buildExclusionClause(conversationId: String, excludeTurns: [Int]) -> String {
    guard !conversationId.isEmpty, !excludeTurns.isEmpty else { return "" }
    let escapedId = conversationId.replacingOccurrences(of: "'", with: "''")
    let turnList = excludeTurns.map { String($0) }.joined(separator: ",")
    return " AND NOT (source_type='conversation' AND source_id='\(escapedId)' AND turn_number IN (\(turnList)))"
}
```
`excludeTurns` comes from `getShortTermTurns()` (Block 22) — logical turn numbers currently in STM. Only those turns are excluded; earlier turns from the same conversation are fully RAG-searchable.

### RAG Gate — Reworked (Block 20.1, `decideTools`)

**Old:** sent raw user query + long JSON rules list, parsed JSON response, many hardcoded exclusion rules.

**New:** YES/NO gate with actual STM context + rolling summary.
- Builds recent excerpt using `effectiveMemoryDepth * 2` messages (matching the real STM window)
- Includes `injectedSummary` if `pendingAutoInject` is true
- Prompt: "Does answering this question require looking up specific facts from past conversations or uploaded documents — information that would NOT be available in the recent conversation above or from general knowledge? Answer only YES or NO."
- Parsing: `answer.hasPrefix("YES")` → `memory_search`; anything else → no tools
- Temperature: 0.1 for determinism
- `idx` variable kept in for loop for dedup logging; `partIndex` tracks sequential output labels

**Key property used:** `effectiveMemoryDepth` = `min(memoryDepth, maxMemoryDepth)` — the runtime-clamped value used everywhere else in the app. Gate now sees exactly the same STM window as the prompt builder.

### Summarization Blocks Next Response (Block 18 + Block 21)

**Old:** `generateAutoSummary()` fired as detached `Task` after the turn's response was stored. Used `DispatchQueue.main.async` for completion. Next turn's `buildPromptHistory` could run before summarization finished — summary wasn't available, `pendingAutoInject` still false.

**New:**
1. `generateAutoSummary()` now uses `await MainActor.run {}` instead of `DispatchQueue.main.async {}`. State is guaranteed set before the task returns.
2. `generateAutoSummary()` clears `self.summarizationTask = nil` on completion (success or failure).
3. Trigger stores the task: `self.summarizationTask = Task { await self.generateAutoSummary() }` (inside `MainActor.run`).
4. `runSingleModelTurn()` awaits it at the start of its `do {}` block, before "Reading your message..." status:
```swift
if let task = summarizationTask {
    if let i = messages.firstIndex(where: { $0.id == pid }) {
        messages[i].content = "Reflecting on our earlier conversation..."
    }
    await task.value
    // summarizationTask cleared inside generateAutoSummary()
}
```
New property on `ChatViewModel`: `var summarizationTask: Task<Void, Never>? = nil`

### Cosine Similarity Dedup (Block 20.1)

Before injecting RAG snippets, computes a reference embedding from `shortTermText + injectedSummary`. Each snippet is compared via `memoryStore.cosineSimilarity()`. Snippets above threshold are skipped with `HALDEBUG-RAG: Dedup dropped snippet N` log.

- **Threshold:** `@AppStorage("ragDedupSimilarityThreshold") var ragDedupSimilarityThreshold: Double = 0.85`
- **Reference:** `memoryStore.generateEmbedding(for: referenceText)` — uses `NLEmbedding.sentenceEmbedding` primary, hash fallback
- **Labels:** Sequential `partIndex` counter ensures dropped snippets don't create gaps ([1],[2],[3] not [1],[3],[5])
- **When reference is empty** (first turn, no STM, no summary): dedup is skipped entirely

### Auto-Summarization — Architecture (unchanged, model-agnostic)

`generateAutoSummary()` — Pass 1 prose summary only (Pass 2 fact extraction removed entirely).
- Trigger: `shouldTriggerAutoSummarization()` checks `(currentTurns - lastSummarizedTurnCount) >= effectiveMemoryDepth`
- Fires after the turn's response is stored (inside `MainActor.run` at end of `runSingleModelTurn`)
- Now stored as `summarizationTask` — next turn awaits it
- Confirmed model-agnostic: trigger is in the shared post-turn path, not AFM-specific

---

## Key Environment Facts

- **Container:** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/`
- **DB:** `~/Library/Containers/.../Data/Documents/hal_conversations.sqlite`
- **Harness dir:** `~/Library/Containers/.../Data/Documents/hal_test/`
- **Downloaded models:** Llama-3.2-3B-Instruct-4bit, Phi-3-mini-128k-instruct-4bit, Qwen2.5-1.5B-Instruct-4bit
- **Llama 3.2 3B:** NOT viable on 8GB with Xcode running — memory starvation ~404s, PERMANENTLY RETIRED
- **Emma contamination:** 8+ conversation IDs in DB contain "Emma". Any Emma test needs nuclear reset or unique fact.
- **Nuclear reset:** `rm -rf ~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/`
- **SOP harness:** Always use Python scripts with hardcoded absolute paths. Bash variable expansion breaks in multi-line tool calls.
- **mtime-based polling:** Poll `output_latest.json` modification time (not file numbers).

---

## Open Items — Ready for Testing

The new architecture (no CONVERSATION_FACTS, surgical RAG exclusion, YES/NO gate, summarization blocking, cosine dedup) has never been end-to-end tested. Testing priorities:

1. **Within-conversation recall:** After a fact falls out of STM, can RAG retrieve it from the current conversation? (This was previously impossible with whole-conversation exclusion.)
2. **Gate behavior:** Is the YES/NO gate correctly deciding when to search? Check HALDEBUG-TOOLS logs.
3. **Summarization blocking:** Does "Reflecting on our earlier conversation..." appear correctly when summarization is in flight?
4. **Cosine dedup:** Are HALDEBUG-RAG dedup drops appearing? Is threshold 0.85 too aggressive or too loose?

---

## Bugs Still Open

- **Progress indicator jump**: `sizeGB` may be nil at download start. Add `HALDEBUG-PROGRESS` print to confirm.
- **Model name logging bug in harness**: `output_NNNN.json` shows `apple-foundation-models` even when MLX runs. Fix: log `vm.llmService.activeModelID` instead of `vm.selectedModel.id`.

---

## Hal-ness Behavioral Notes

When Hal doesn't have something in memory that a user references, he should acknowledge the gap honestly rather than confabulate. "I don't have that — could you remind me?" not "I remember you mentioned..." when he doesn't. This applies to RAG retrieval, STM, and summaries. Confabulation is a trust violation. Capture in system prompt or soul document when those are built.
