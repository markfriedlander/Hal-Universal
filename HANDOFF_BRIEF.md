# Hal Universal — Handoff Brief
**Updated:** May 2026
**For:** Next Claude Code instance
**Written by:** CC instance, end-of-context (mlx-experiment branch)

---

## Standing Practice: Document After Every Move

After any significant code change, build, or test run — update this file and memory before continuing. Things that get lost in compaction: bug root causes, exact format findings, SOP results, what was tried and why it failed. Write it down immediately.

---

## Current Branch: `mlx-experiment`

This branch is **the philosophical Hal** — the full version with MLX local inference, multi-model support, and the complete philosophical architecture. It branches from commit `4146bc8` ("Freeze: Philosophical Hal — architecture complete, suspended pending better local model generation").

The main branch contains **Hal LMC** (stripped to AFM-only private memory layer). These are parallel futures. mlx-experiment is where local model quality is being validated.

### Git History (This Work)
- `c892830` — mlx-experiment: LocalAPIServer + model management commands
- `64fe574` — mlx-experiment: LocalAPIServer + HalTestConsole rewrite (fixes)
- `cc0742c` — mlx-experiment: Thread navigation, memory stats, recency, cancel download
- `da7c24c` — mlx-experiment: Document import/list/delete via API

---

## The Mission Right Now

Validate whether **Gemma 4 E2B 4-bit** (3.58 GB, `mlx-community/gemma-4-e2b-it-4bit`) can run on iPhone 16 and produce quality sufficient for the philosophical Hal use case.

**Primary target: iPhone 16.** Not Mac. If it doesn't run on iPhone, the philosophical branch doesn't work.

**Open question:** 4-bit at 3.58 GB may OOM on iPhone 16 (8GB RAM, iOS aggressive about memory). Community reports suggest ~40 tok/s, but it's tight. If it fails, the 2-bit path requires cloud conversion (~18GB RAM, Mark's 8GB Mac is insufficient).

**No 2-bit MLX Gemma 4 exists yet.** Only GGUF (Unsloth 2-bit UD-IQ2_M at 2.29 GB). GGUF requires an entirely separate inference engine — not currently supported, not recommended unless 4-bit definitively fails on iPhone.

---

## Autonomous Build + Launch

```bash
# Build
xcodebuild build \
  -project "/Users/markfriedlander/Desktop/Fun/Hal Universal/Hal Universal.xcodeproj" \
  -scheme "Hal Universal" \
  -destination "id=00008112-0010193C3A88C01E" \
  -configuration Debug \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# Install + Launch (requires Xcode open with project loaded)
osascript << 'EOF'
tell application "Xcode"
    stop active workspace document
    delay 2
    run active workspace document
end tell
EOF
```

**Mac destination ID:** `00008112-0010193C3A88C01E`  
**Container:** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/`  
**DB:** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_conversations.sqlite`  
**Nuclear reset:** `rm -rf ~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/`

---

## Test Runner — `tests/hal_test.py`

Single durable test runner. Never reinvent. Run from project root.

### First-Time HTTP Setup (one-time per device)
1. In Hal: Settings → Power User → Developer API → toggle ON
2. Copy the token shown in the UI
3. `python3 tests/hal_test.py setup <ip> 8765 <token>`
4. Config saved to `tests/.hal_api_config.json` — auto-used forever after

**Existing config:** `tests/.hal_api_config.json` with `{"host": "127.0.0.1", "port": 8765, "token": "6e03f0b11dd8497cb6bea95c004f34c1"}`  
(Token was copied from UI — verify it's still valid after any nuclear reset)

### Commands
```bash
python3 tests/hal_test.py setup <ip> 8765 <token>   # One-time HTTP config
python3 tests/hal_test.py state                      # Print full state
python3 tests/hal_test.py reset                      # Nuclear reset + fresh start
python3 tests/hal_test.py new                        # New thread (keep memory/settings)
python3 tests/hal_test.py turn "Hello"               # Single turn
python3 tests/hal_test.py cmd SET_TEMPERATURE:0.8    # Any command
python3 tests/hal_test.py chat                       # Interactive REPL (reactive — reads each response)

# Model management
python3 tests/hal_test.py models                     # List all models + download status
python3 tests/hal_test.py current_model              # Which model is active
python3 tests/hal_test.py download <model_id>        # Start download
python3 tests/hal_test.py model_status <model_id>    # Check progress (with bar)
python3 tests/hal_test.py switch_model <model_id>    # Switch active model
python3 tests/hal_test.py delete_model <model_id>    # Delete downloaded model
python3 tests/hal_test.py cancel_download <model_id> # Cancel in-flight download

# Thread management
python3 tests/hal_test.py threads                    # List all threads
python3 tests/hal_test.py switch_thread <id>         # Switch to thread
python3 tests/hal_test.py messages                   # Messages in current thread
python3 tests/hal_test.py memory_stats               # DB stats
python3 tests/hal_test.py reflections                # Stored reflections

# Documents
python3 tests/hal_test.py list_docs                  # List imported documents
python3 tests/hal_test.py import_doc <path>          # Import a document
python3 tests/hal_test.py delete_doc <source_id>     # Delete a document

# Scripted test files
python3 tests/hal_test.py run tests/conversations/quality_test.txt
```

---

## Complete API Command Reference

All commands via `POST /command {"command": "..."}` or `cmd` in test runner.

### Model Management
| Command | Description |
|---------|-------------|
| `LIST_MODELS` | All available models with downloaded/active/sizeGB |
| `CURRENT_MODEL` | Active model ID |
| `SWITCH_MODEL:<id>` | Switch to model (must be downloaded or AFM) |
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

## Pending Test Plan

**Step 1: Build and deploy**
```bash
xcodebuild build ... && osascript ...  # (see above)
```

**Step 2: Enable Developer API in app**
- Settings → Power User → Developer API → ON
- Verify token matches `tests/.hal_api_config.json`

**Step 3: Verify connection**
```bash
python3 tests/hal_test.py state
```

**Step 4: Download Gemma 4 E2B 4-bit**
```bash
python3 tests/hal_test.py download mlx-community/gemma-4-e2b-it-4bit
python3 tests/hal_test.py model_status mlx-community/gemma-4-e2b-it-4bit  # Poll until 1.0
```

**Step 5: Switch to Gemma and test**
```bash
python3 tests/hal_test.py switch_model mlx-community/gemma-4-e2b-it-4bit
python3 tests/hal_test.py chat
```

**Step 6: Quality evaluation**
- Philosophical depth — can it engage with questions about consciousness, identity, uncertainty?
- Coherence over a long conversation
- Does it respect the soul document / self-knowledge?
- Does it confabulate or hallucinate?

**Step 7: iPhone test**
- Deploy to iPhone 16 (not Mac)
- Does the model load without OOM?
- Is generation speed acceptable?

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
- Self-knowledge DB table (exists, but prompt injection has a known bug)
- LocalAPIServer (Block 32) — HTTP on port 8765
- HalTestConsole (Block 32) — full programmatic control

### Gemma 4 Architecture
- Registered in mlx-swift-lm 3.31.3 as `"gemma4"` and `"gemma4_text"` in LLMModelFactory
- Three API migration fixes were applied in an earlier session:
  - `loadContainer` signature update
  - `tokenIds:` rename
  - `CharacterSet` explicit type
- Build is clean — the architecture issue is resolved

### VincentGourbin vs Official
- Used **official** `mlx-swift-lm 3.31.3` from ml-explore (NOT VincentGourbin)
- VincentGourbin's Gemma4Swift was a pre-release proof-of-concept, superseded by official support
- Gemma 4 works natively in the official package

### Memory Architecture (unchanged from main)
- `buildExclusionClause` uses surgical STM-only exclusion (`turn_number IN (excludeTurns)`)
- `decideTools()` YES/NO RAG gate with real STM context
- `injectedSummary` persists across turns once set
- Summarization blocks the next response (`summarizationTask` awaited at turn start)
- Cosine similarity dedup before RAG injection (threshold 0.85 default)
- CONVERSATION_FACTS: **fully removed** — not in DB, not in code

---

## SOP: After Every Hal.swift Change
1. `cp "Hal Universal/Hal.swift" "Hal Universal/Hal_Source.txt"` — always
2. New enum case? Sweep all switches before declaring done
3. New AppStorage key? `defaults write com.MarkFriedlander.Hal10000 [key] "[value]"`

---

## Open Bugs / Known Issues
- Self-knowledge table exists but is **NOT injected into prompts correctly** (known bug, not fixed)
- Mac UI rendering is broken (low priority — iPhone is primary)
- Apple Watch times out (not priority for Phase 1)
- `sizeGB` may be nil at download start causing progress jump — add `HALDEBUG-PROGRESS` if needed

---

## If 4-bit Fails on iPhone

Option A: **Wait** — MLX community is actively working on 2-bit Gemma 4 MLX.

Option B: **Cloud conversion** — `mlx_lm.convert --hf-path mlx-community/gemma-4-e2b-it-4bit --quantize --q-bits 2` requires ~18GB RAM. Mark's M2 Mac has 8GB — insufficient. Needs cloud machine.

Option C: **GGUF** — Unsloth 2-bit Gemma 4 E2B exists at 2.29 GB. Requires entirely separate inference engine (llama.cpp). Not implemented. Only pursue if MLX path is definitively dead.

---

## Standing Architectural Rules
- **No third-party libraries** without explicit discussion
- **One block at a time** — surgical changes, build clean after each block
- **Discussion before code** — always
- **CONVERSATION_FACTS is gone** — do not re-introduce without full design discussion
- **iPhone is primary target** — Mac is secondary; evaluate all decisions against iPhone 16 constraints
