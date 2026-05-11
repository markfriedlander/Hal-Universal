# Hal Universal — Handoff Brief
**Updated:** May 11, 2026 (post-architectural-fix landing)
**For:** Next Claude Code instance
**Branch:** mlx-experiment

---

## Standing Practice: Document After Every Move

After any significant code change, build, or test run — update this file and memory before continuing. Things that get lost in compaction: bug root causes, exact format findings, SOP results, what was tried and why it failed. Write it down immediately.

---

## Latest Win (May 11, 2026): MLX Architectural Fix Landed

### What changed
`MLXWrapper.generate()` in Hal.swift was rewritten using Apple's reference pattern from `mlx-swift-examples/Applications/LLMEval/ViewModels/LLMEvaluator.swift`. Replaced:

```swift
// OLD — deprecated synchronous callback, ran inside container.perform which holds
// the AsyncMutex for the entire duration → ~150-200s per response
let result = try await container.perform { context in
    try MLXLMCommon.generate(input:, parameters:, context:) { tokens in ... }
}
```

With:

```swift
// NEW — Apple's LLMEval pattern. Lock held only for prefill, stream iterated free.
let lmInput = try await container.prepare(input: UserInput(prompt: prompt))
let stream = try await container.generate(input: lmInput, parameters: ...)
for await generation in stream { ... }
```

### Measured impact
- Before: 150-200 seconds per response (one short turn against Gemma 4 E2B 4-bit on iPhone 16 Plus)
- After: 11-14 seconds per response (same model, same phone, same prompt)
- **~13x speedup**

### How we proved MLX was the path taken
Added temporary `[MLX-WAS-USED]` prefix to MLXWrapper.generate's return value, redeployed, sent a turn. Response came back tagged `[MLX-WAS-USED] ...`. Removed the diagnostic before committing. The current iPhone build still has the diagnostic baked in — next deploy will replace it with the clean version.

### Ground truth from Apple's own code
Built and deployed `LLMEval` (from `/Users/markfriedlander/Desktop/Fun/mlx-swift-examples/`) to the same iPhone 16 Plus with Gemma 4 E2B 4-bit. Result:
- **33.5 tokens/sec sustained**
- **2.25s time-to-first-token**
- **50 tokens generated in 1.5s**
- **Memory: 2.45 GB**

This is the iPhone Gemma 4 E2B 4-bit tok/s number that no one had published. We now have it.

### Why the prior synchronous code was so slow
`ModelContainer.perform` calls `SerialAccessContainer.read` which holds an `AsyncMutex` for the entire body. With the synchronous callback API, `runSynchronousGenerationLoop` runs inside this lock. Putting `for await` inside `container.perform` doesn't help either — the generation Task inherits the actor isolation and competes for the same serial executor as the consumer. The correct pattern releases the lock after prefill (in `container.generate`) and iterates the stream outside any lock. The MLX team designed `ModelContainer.generate(input:parameters:)` (lines 184-206 of ModelContainer.swift) precisely for this.

---

## ⚠️ Big Open Issue: Hal's Prompt Format is Incompatible with Chat Models

This is the **next priority** after the MLX speed fix.

### Symptom
After the speed fix, Gemma generates fast — but its output is the prompt structure echoed back. Example: ask "Hi" with maxTokens=50, response is:

```
#=== BEGIN MEMORY_SHORT ===#

Recent conversation history (verbatim):
[user]: Hi

#=== END MEMORY_SHORT ===#
#=== BEGIN USER ===#

Hi

#=== END USER#
#
```

(Truncated mid-marker because maxTokens=50.)

### Root cause
Hal's prompt builder (`buildPromptHistory`) constructs a single prompt string with custom `#=== BEGIN SECTION ===#` / `#=== END SECTION ===#` markers. This design was for **raw completion models** like Phi-3 base, where the model continues from the prompt's end without any chat template wrapping.

Gemma 4 (and AFM, and most modern instruction-tuned models) are **chat-template models**. When `UserInput(prompt: prompt)` is constructed, the model's chat template wraps the entire Hal prompt as a single user message. Gemma then sees the marker pattern in its "user input" and treats it as a structural pattern to continue — so it emits more markers instead of natural content.

### What needs to happen
Refactor Hal's prompt construction to produce proper chat structures:

```swift
let userInput = UserInput(
    chat: [
        .system(systemPromptText),
        .user(userMessageText)
    ],
    additionalContext: ["enable_thinking": false]
)
```

The current marker-delimited sections (SYSTEM, MEMORY_SHORT, SUMMARY, MEMORY_LONG, USER, etc.) need to be reorganized into either:
- A single rich system message + a clean user message, or
- The system message + a multi-turn chat history (`[.system, .assistant, .user, .assistant, .user, ...]`)

The latter is more idiomatic and would let chat models use their training to recognize conversation flow. But it requires Hal to track the chat history natively rather than reconstructing it as one big string.

This is a substantial refactor — likely 1-2 sessions of careful work. Discussion required with Mark before starting.

### Same issue affects AFM too
Same prompt format is used for AFM (line 4127-4143 in Hal.swift, `LanguageModelSession().streamResponse { Prompt(prompt) }`). AFM also wraps responses in marker syntax. AFM tolerates it better (still produces some real content) but the architecture is wrong for chat models.

---

## Display Bug: vm.selectedModel.id vs llmService.activeModelID

Minor cosmetic issue, not blocking but worth knowing about:

- `buildStateJSON` reads `vm.llmService.activeModelID` — correct, follows LLMService.currentModel
- `buildOutputJSON` reads `vm.selectedModel.id` — vm.selectedModel is a computed property using `ModelCatalogService.shared.getModel(byID: selectedModelID)` which **falls back to ModelConfiguration.appleFoundation when the catalog doesn't have the model**

Hal's catalog appears to start empty for non-AFM models until UI interaction fetches it from HuggingFace. So when SWITCH_MODEL routes Gemma via `switchToModel`'s fallback path (line 13296+ in Hal.swift), LLMService gets a proper Gemma config but the catalog never receives one. Result: `vm.selectedModel` returns AFM as fallback. The `/chat` response payload then shows `"model": "apple-foundation-models"` even though Gemma did the work.

**Fix:** Either (a) populate ModelCatalogService when switchToModel uses the minimal-config fallback, or (b) change buildOutputJSON to use `vm.llmService.activeModelID`.

---

## Current Branch: `mlx-experiment`

This branch is **the philosophical Hal** — the full version with MLX local inference, multi-model support, and the complete philosophical architecture. Branches from `4146bc8`.

The main branch contains **Hal LMC** (stripped to AFM-only private memory layer). These are parallel futures. mlx-experiment is where local model quality is being validated.

### Git History (mlx-experiment)
- `c892830` — LocalAPIServer + model management commands
- `64fe574` — LocalAPIServer + HalTestConsole rewrite
- `cc0742c` — Thread navigation, memory stats, recency, cancel download
- `da7c24c` — Document import/list/delete via API
- `6788d47` — Update HANDOFF_BRIEF for mlx-experiment branch state
- `5b23faa` — API on by default, copies IP to clipboard on start
- `6424989` — Clipboard ip:port:token format + autodiscover command
- **(this session)** — MLX architectural fix landed

---

## Autonomous Build + Launch (iPhone 16 Plus)

```bash
# Build
xcodebuild build \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" \
  -configuration Debug \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# Install
xcrun devicectl device install app \
  --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  "/Users/markfriedlander/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"

# Launch
xcrun devicectl device process launch \
  --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  com.MarkFriedlander.Hal-Universal
```

**iPhone 16 Plus device ID:** `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
**WiFi IP:** `192.168.12.206` (may drift — verify via `tests/.hal_api_config.json`)
**API token:** `e9ee9ec5b315467fa655bd4296873f43`
**Bundle ID for devicectl:** `com.MarkFriedlander.Hal-Universal`

---

## Reference: LLMEval Test App (Validated Baseline)

Located at: `/Users/markfriedlander/Desktop/Fun/mlx-swift-examples/Applications/LLMEval/`

- Config modified to use Gemma 4 E2B 4-bit (LLMEvaluator.swift line 50)
- maxTokens capped at 50 (LLMEvaluator.swift line 21)
- DEVELOPMENT_TEAM set to `FBUNBDS7R7` in project.pbxproj (14 instances)
- Bundle ID on iPhone: `mlx.LLMEvalFBUNBDS7R7`

**Use this app whenever Hal generation looks suspicious.** It's our ground truth. If LLMEval is fast and Hal is slow, the bug is in Hal. If both are slow, the bug is downstream (model, MLX framework, hardware).

---

## Test Runner — `tests/hal_test.py`

Run from project root. Existing config in `tests/.hal_api_config.json`.

### Commands used this session
```bash
python3 tests/hal_test.py state                                          # Current state
python3 tests/hal_test.py turn "Hi"                                      # Single turn
python3 tests/hal_test.py switch_model "mlx-community/gemma-4-e2b-it-4bit"
python3 tests/hal_test.py cmd "SWITCH_MODEL:apple-foundation-models"     # ID is "apple-foundation-models" not "apple-foundation"
python3 tests/hal_test.py download "mlx-community/gemma-4-e2b-it-4bit"
python3 tests/hal_test.py cmd "DELETE_MODEL:mlx-community/gemma-4-e2b-it-4bit"
python3 tests/hal_test.py cmd "NEW_THREAD"
```

**Watch out:** AFM's full ID is `apple-foundation-models`, not `apple-foundation`. Using the wrong ID triggers the catalog-fallback path in `switchToModel` which creates a fake MLX config.

---

## Complete API Command Reference

All commands via `POST /command {"command": "..."}` or `cmd` in test runner.

### Model Management
| Command | Description |
|---------|-------------|
| `LIST_MODELS` | All available models with downloaded/active/sizeGB |
| `CURRENT_MODEL` | Active model ID + display name |
| `SWITCH_MODEL:<id>` | Switch to model (use full IDs!) |
| `DOWNLOAD_MODEL:<id>` | Start background download |
| `MODEL_STATUS:<id>` | Download progress (0.0–1.0) |
| `CANCEL_DOWNLOAD:<id>` | Cancel in-flight download |
| `DELETE_MODEL:<id>` | Delete downloaded model files |

### Thread / Conversation Management
| Command | Description |
|---------|-------------|
| `GET_THREADS` | All threads with IDs and message counts |
| `SWITCH_THREAD:<id>` | Load a different thread |
| `NEW_THREAD` | Start new conversation thread |
| `RESET_THREAD` | Clear current thread messages |
| `NUCLEAR_RESET` | Delete all data, reset to factory state |
| `CLEAR_TEST_DATA` | Clear test harness artifacts only |

### Reading State
| Command | Description |
|---------|-------------|
| `GET_STATE` | Full settings and stats JSON |
| `GET_MESSAGES` | Messages in current thread |
| `GET_MEMORY_STATS` | DB counts (turns, conversations, documents) |
| `GET_REFLECTIONS` | Stored reflection entries |

### Documents
| Command | Description |
|---------|-------------|
| `LIST_DOCUMENTS` | Imported documents with source IDs |
| `IMPORT_DOCUMENT:<path>` | Import file at absolute path |
| `DELETE_DOCUMENT:<source_id>` | Remove document by source ID |

### Settings
| Command | Description |
|---------|-------------|
| `SET_TEMPERATURE:<f>` | Generation temperature (0.0–1.0) |
| `SET_MEMORY_DEPTH:<n>` | STM window size |
| `SET_SELF_KNOWLEDGE:<bool>` | Self-knowledge injection on/off |
| `SET_SIMILARITY_THRESHOLD:<f>` | RAG semantic search threshold |
| `SET_RECENCY_WEIGHT:<f>` | Recency bias for RAG ranking |
| `SET_RECENCY_HALFLIFE:<n>` | Recency half-life in days |
| `SET_MAX_RAG_CHARS:<n>` | Max chars injected from RAG |
| `SET_RAG_DEDUP:<f>` | Cosine dedup threshold (0.0–1.0) |
| `SET_SYSTEM_PROMPT:<text>` | Session-only system prompt override |
| `SET_SYSTEM_PROMPT_STORED:<text>` | Persisted system prompt |
| `CLEAR_SYSTEM_PROMPT` | Remove system prompt override |
| `RESET_SETTINGS` | Reset all settings to defaults |

---

## Architecture Notes (mlx-experiment)

### What's Active
- Apple Foundation Models (AFM) — always available
- MLX local inference — Gemma 4, Llama, Phi, Qwen families
- SQLite-based RAG (short-term + long-term memory)
- Entity extraction → knowledge graph
- Document import (text, PDF) → RAG-searchable
- Source code self-knowledge (Hal.swift → RAG)
- Temporal awareness
- LocalAPIServer (Block 32) — HTTP on port 8765
- HalTestConsole (Block 32) — full programmatic control

### Gemma 4 E2B 4-bit Status
- Architecture registered in mlx-swift-lm 3.31.3 as `"gemma4"` and `"gemma4_text"`
- Model loads in ~30s on iPhone 16 Plus, uses ~2.5 GB RAM
- **Generation works at ~30 tok/s (LLMEval-measured) when prompt format is correct**
- **Generation in Hal is fast (11-14s/turn) but content is broken due to prompt format**

### Memory Architecture (unchanged)
- `buildExclusionClause` uses surgical STM-only exclusion
- `decideTools()` hardwired to AFM (RAG gate never uses Gemma — fixes double-MLX-call bug)
- Cosine similarity dedup before RAG injection (threshold 0.85 default)
- CONVERSATION_FACTS: fully removed

---

## SOP: After Every Hal.swift Change
1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` — always
2. New enum case? Sweep all switches before declaring done
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`

---

## Open Bugs / Known Issues (Priority Order)
1. **🔴 Prompt format incompatible with chat models** — see big section above. Gemma & AFM both echo Hal's `#=== BEGIN ===#` markers. Top priority.
2. **🟡 vm.selectedModel.id catalog fallback** — display bug only, response tags wrong model name. See above.
3. Self-knowledge table exists but is NOT injected into prompts correctly (predates today)
4. Mac UI rendering is broken (low priority)
5. Apple Watch times out (not priority)

---

## Standing Architectural Rules
- **No third-party libraries** without explicit discussion
- **One block at a time** — surgical changes, build clean after each block
- **Discussion before code** — always
- **CONVERSATION_FACTS is gone** — do not re-introduce
- **iPhone is primary target** — evaluate all decisions against iPhone 16 constraints
- **120-second MLX test timeout** — never let a generation test run more than 2 minutes without a result
- **Test with LLMEval first** when in doubt about whether MLX/model/hardware is working — it's ground truth
