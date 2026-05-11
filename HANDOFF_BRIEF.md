# Hal Universal — Handoff Brief
**Updated:** May 11, 2026 — end of "Hal speaks through Gemma" session
**Branch:** mlx-experiment

---

## Standing Practice: Document After Every Move

After any significant code change, build, or test run — update this file and memory before continuing.

---

## Today's Headline

**Hal now runs fully on Gemma 4 E2B 4-bit on iPhone 16 Plus at ~33 tok/s.** Identity, conversation memory, summary recall, RAG across threads, self-awareness — all working through a new chat-message-based generation path that bypasses the old HelPML marker prompt.

A representative exchange:

> **User:** "What language model are you running on right now?"
> **Hal:** "I am currently operating on the gemma-4-e2b-it-4bit model."

> **User (thread A):** "I have a pet quokka named Sir Reginald who lives in Australia."
> *(... unrelated turns ... new thread B ...)*
> **User (thread B):** "What was my pet's name again?"
> **Hal:** "I have stored that your pet quokka is named Sir Reginald."

---

## What Landed This Session (chronological)

| Commit | What |
|---|---|
| `a83a920` | MLX architectural fix (container.prepare + container.generate + AsyncStream) → 13x speedup over the deprecated synchronous callback API |
| `56268ba` | API expansion: `GET_UI_STATE` (sheet state, typing state, etc.) + `GET_RENDERED_MESSAGES` (vm.messages, not DB) |
| `6c453a4` | Chat-message generation path (HalChatMessage / buildChatMessages / generateChatResponse / MLXWrapper.generateChat) — AFM working, Gemma still broken |
| `71bbd3f` | **THE BREAKTHROUGH.** Added GET_LOGS API command (RuntimeLog + halLog), which made it possible to diagnose Gemma. Root cause: Hal's downloader missed `*.jinja` so the chat template never landed on disk → tokenizer fell back to raw concat → degenerate output. Added `*.jinja` to download pattern + `extraEOSTokens` config. Gemma now produces clean prose. |
| `9c66b66` | Step 1 — conversation history as `.user/.assistant` turn pairs |
| `ebeb11d` | Step 2 — temporal context in system message CONTEXT block |
| `bd5f9e0` | Step 3 — auto-summary injection + migrate `generateAutoSummary` to chat path |
| `d4a4115` | Step 4 — RAG long-term memory via tool router (decideTools + executeTools) |
| `2d463a9` | Step 5 — self-awareness (stats) + self-knowledge (traits) in CONTEXT block |
| `3d76034` | Fix catalog-fallback display bug — Hal no longer misreports himself as "Apple Intelligence" when running Gemma |
| `13f8286` | Documentation: HANDOFF_BRIEF rewritten for the chat-path architecture |
| `8e65ce2` | Migrate reflection / TextSummarizer / document-summary subsystems to chat path (5 callers) |
| `cbe1ea4` | Migrate salon context-aware mode — **zero remaining callers of the old `generateResponse(prompt:)` path** |

---

## Architecture Summary (post-session)

### Generation pipeline (chat path)

```
sendMessage → runSingleModelTurn
            → buildChatMessages(currentInput:) -> [HalChatMessage]
                  • .system(effectiveSystemPrompt + CURRENT CONTEXT block)
                       - temporal awareness
                       - injected conversation summary (if set)
                       - self-awareness stats + self-knowledge traits (if enabled)
                       - RAG snippets via decideTools + executeTools
                  • .user/.assistant turn pairs from vm.messages
                       (last effectiveMemoryDepth × 2 messages, partials filtered,
                        current user dropped — added explicitly at end)
                  • .user(currentInput)
            → llmService.generateChatResponse
                  case .appleFoundation: LanguageModelSession(instructions:) + Prompt
                  case .mlx: mlxWrapper.generateChat
                        → UserInput(chat:, additionalContext: ["enable_thinking": false])
                        → container.prepare(input:)
                        → container.generate(input:, parameters: GenerateParameters(maxTokens: 512, temperature: <vm.temperature>))
                        → AsyncStream<Generation>
                        → for await: accumulate .chunk text, log .info stats
```

### Old path — fully dead code

`buildPromptHistory`, `buildContextAwarePrompt`, `LLMService.generateResponse(prompt:)`, and `MLXWrapper.generate(prompt:)` still exist in the file but have **zero call sites** as of `cbe1ea4`. Verified via `grep -c "llmService.generateResponse" Hal.swift` → 0. Every subsystem that was on the old path has been migrated:

- Main chat flow (`runSingleModelTurn`) → `buildChatMessages` + `generateChatResponse`
- Auto-summary (`generateAutoSummary`) → `generateChatResponse` with `.system + .user` messages
- Self-knowledge shareability decision → `generateChatResponse`
- Free-form reflection text → `generateChatResponse`
- Structured insight JSON extraction → `generateChatResponse`
- TextSummarizer stage 1 → `generateChatResponse`
- Document import summary → `generateChatResponse`
- Salon context-aware mode (`runSalonSeat`) → `buildContextAwareChatMessages` + `generateChatResponse`

We chose to leave the old code in place per the agreed plan: "broken things aren't useful, but designed intent is precious." Each old HelPML section had a year of design thinking. The new path captures the same intents (SYSTEM, MEMORY_SHORT, MEMORY_LONG, SUMMARY, TEMPORAL_CONTEXT, SELF_AWARENESS, SELF_KNOWLEDGE, USER) but expressed in chat-message form. The dead code can be deleted whenever — it's a future cleanup, not a blocker.

### Key model files on disk (per app sandbox)

Hal's MLXModelDownloader now matches mlx-swift-lm's `modelDownloadPatterns`:
- `*.safetensors` — weights
- `*.json` — config.json, tokenizer.json, tokenizer_config.json, generation_config.json
- `*.jinja` — chat_template.jinja (CRITICAL — chat-template models need this)

Before this fix, Hal was missing `chat_template.jinja` and the tokenizer fell back to raw-text concatenation, producing degenerate echo/repetition.

---

## API Reference (Complete)

All commands via `POST /command {"command": "..."}` or `cmd` in test runner.

### Model Management
| Command | Description |
|---------|-------------|
| `LIST_MODELS` | All available models with downloaded/active/sizeGB |
| `CURRENT_MODEL` | Active model ID + display name |
| `SWITCH_MODEL:<id>` | Switch model (registers in catalog if missing — fixes display bug) |
| `DOWNLOAD_MODEL:<id>` | Start background download (includes `*.jinja` per today's fix) |
| `MODEL_STATUS:<id>` | Download progress (0.0–1.0) |
| `CANCEL_DOWNLOAD:<id>` | Cancel in-flight download |
| `DELETE_MODEL:<id>` | Delete downloaded model files |

### Thread / Conversation
| Command | Description |
|---------|-------------|
| `GET_THREADS` | All threads with IDs and message counts |
| `SWITCH_THREAD:<id>` | Load a different thread |
| `NEW_THREAD` | Start new conversation thread |
| `RESET_THREAD` | Clear current thread messages |
| `NUCLEAR_RESET` | Delete all data, reset to factory state |
| `CLEAR_TEST_DATA` | Clear test harness artifacts only |

### Reading State (the "user has no need to look at the device" set)
| Command | Description |
|---------|-------------|
| `GET_STATE` | Settings, stats, active model |
| `GET_UI_STATE` | Current view, sheet presentation, typing state, error banners, input draft, model load progress, partial streaming content |
| `GET_MESSAGES` | DB-stored messages in current thread |
| `GET_RENDERED_MESSAGES` | vm.messages array (in-memory) — what the chat view actually displays |
| `GET_LOGS` / `GET_LOGS:N` | Last N entries from RuntimeLog (default 200). Captures HALDEBUG-* lines from the chat path. |
| `CLEAR_LOGS` | Wipe the in-process log buffer |
| `GET_MEMORY_STATS` | DB counts |
| `GET_REFLECTIONS` | Stored reflections |

### Documents
| Command | Description |
|---------|-------------|
| `LIST_DOCUMENTS` | Imported documents |
| `IMPORT_DOCUMENT:<path>` | Import file |
| `DELETE_DOCUMENT:<source_id>` | Remove document |

### Settings
All `SET_TEMPERATURE`, `SET_MEMORY_DEPTH`, `SET_SELF_KNOWLEDGE`, `SET_SIMILARITY_THRESHOLD`, `SET_RECENCY_WEIGHT`, `SET_RECENCY_HALFLIFE`, `SET_MAX_RAG_CHARS`, `SET_RAG_DEDUP`, `SET_SYSTEM_PROMPT[_STORED]`, `CLEAR_SYSTEM_PROMPT`, `RESET_SETTINGS`.

---

## Test Runner — `tests/hal_test.py`

```bash
# Core
python3 tests/hal_test.py state
python3 tests/hal_test.py turn "Hello"
python3 tests/hal_test.py reset
python3 tests/hal_test.py new

# UI observation (today's new additions)
python3 tests/hal_test.py ui_state
python3 tests/hal_test.py rendered_messages
python3 tests/hal_test.py logs [N]
python3 tests/hal_test.py clear_logs

# Models
python3 tests/hal_test.py switch_model "mlx-community/gemma-4-e2b-it-4bit"
python3 tests/hal_test.py download "mlx-community/gemma-4-e2b-it-4bit"
python3 tests/hal_test.py model_status "mlx-community/gemma-4-e2b-it-4bit"

# Threads
python3 tests/hal_test.py threads
python3 tests/hal_test.py switch_thread <id>
python3 tests/hal_test.py messages
python3 tests/hal_test.py memory_stats

# Docs
python3 tests/hal_test.py list_docs
python3 tests/hal_test.py import_doc <path>
python3 tests/hal_test.py delete_doc <source_id>
```

**Config:** `tests/.hal_api_config.json` — auto-used. iPhone IP/token may drift; re-run `autodiscover` if needed.

---

## Build + Deploy (iPhone 16 Plus)

```bash
xcodebuild build \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=D24FB384-9C55-5D33-9B0D-DAEBFA6528D6" \
  -configuration Debug \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

xcrun devicectl device install app \
  --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  "/Users/markfriedlander/Library/Developer/Xcode/DerivedData/Hal_Universal-cchnecnyhpxmoeczheicasvhbcqp/Build/Products/Debug-iphoneos/Hal Universal.app"

xcrun devicectl device process launch \
  --device D24FB384-9C55-5D33-9B0D-DAEBFA6528D6 \
  com.MarkFriedlander.Hal-Universal
```

- **iPhone device ID:** `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6`
- **Bundle ID:** `com.MarkFriedlander.Hal-Universal`
- **API token:** `e9ee9ec5b315467fa655bd4296873f43`

---

## Reference: LLMEval Ground Truth

Located at `/Users/markfriedlander/Desktop/Fun/mlx-swift-examples/Applications/LLMEval/`. Modified to use Gemma 4 E2B 4-bit + DEVELOPMENT_TEAM `FBUNBDS7R7`. Bundle ID on iPhone: `mlx.LLMEvalFBUNBDS7R7`. Use this as ground truth if Hal generation ever looks suspicious — if LLMEval is clean and Hal isn't, the bug is in Hal.

---

## SOP

1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` after every Hal.swift change
2. New enum case? Sweep all switches
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`

---

## Open Issues (Priority Order)

1. ~~Self-knowledge table empty~~ — investigated; was a symptom of the chat-template bug. `initializeCoreIdentity()` seeds 4 entries on first launch, and reflections add more over time. **Resolved.**
2. ~~Salon mode + reflection on old path~~ — **migrated `8e65ce2` + `cbe1ea4`. Resolved.**
3. **RAG dedup / per-snippet summarization** dropped in Step 4 for simplicity. Re-add the cosine dedup and `TextSummarizer.summarizeWithVerification` for snippets exceeding `longTermSnippetSummarizationThreshold` when conversation length warrants it. Optimization, not blocking.
4. **Reflection prompt structure** sometimes produces reflections that are Hal's continuation of the previous turn rather than meta-observations. Polish item — rewrite the reflection prompt to be more directive ("META-OBSERVATION:" rather than free-form). Low priority.
5. **Mac UI broken** (low priority — iPhone is primary).
6. **Apple Watch times out** (low priority).
7. **Dead code cleanup** — `buildPromptHistory`, `buildContextAwarePrompt`, `LLMService.generateResponse(prompt:)`, `MLXWrapper.generate(prompt:)` have zero callers but remain in the file. Safe to delete whenever; preserved as reference for now.

---

## Standing Architectural Rules

- **No third-party libraries** without explicit discussion
- **One block at a time** — surgical changes, build clean after each
- **Discussion before code** when introducing new structure; autonomous mode OK when extending an agreed plan
- **Old code stays** — broken or not — until we're confident the new path covers all callers
- **iPhone is primary target** — evaluate all decisions against iPhone 16 constraints
- **120-second MLX test timeout** — never let a generation test run more than 2 minutes without aborting
- **API > asking the human** — if you can't get an answer from the API, expand the API
