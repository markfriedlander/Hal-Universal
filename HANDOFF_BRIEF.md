# Hal LMC — Handoff Brief
**Written:** March 2026
**For:** Next Claude Code instance
**Written by:** Current CC instance

---

## Standing Practice: Document After Every Move

After any significant code change, build, or test run — update this file and MEMORY.md before continuing. Things that get lost in compaction: bug root causes, exact format findings, SOP results, what was tried and why it failed. Write it down immediately.

---

## Strategic Direction (READ FIRST)

**Project has pivoted.** The philosophical Hal (multi-model, Salon Mode, consciousness exploration) is frozen on GitHub. Development continues as **Hal LMC (Logic Memory Center)** — a private, on-device memory layer app.

**What Hal LMC is:** Persistent personal memory, fully private, no data leaving the device. The memory architecture (RAG, summarization, entity tracking) IS the product.

**What is NOT happening:** Cloud API (cost/privacy/differentiation problems), multi-model inference, Salon Mode, HelPML, source code self-knowledge as a user-facing feature.

**What IS kept:** Full memory layer, core AFM conversation, Watch app (needs timeout fix), power user memory settings, self-knowledge layer behind dev toggle.

**Long-term path (different project, different day):** Mac Mini M4/M5 + Ollama + Tailscale. Same architecture, better model. Don't build toward this now.

---

## Current Work State: Phase 1 Strip — COMPLETE ✓

Strip executed March 2026. Build clean. ~13,126 lines → ~10,000 lines.

### What was stripped:
- Deleted: Block 10.4 (SalonModeView), 11.5 (Model Library UI), 19 (MLX Model Management), 29 (MLX Downloader), 30 (Model Catalog Service — after rescuing ModelSource + ModelConfiguration + .appleFoundation → Block 07.5)
- Block 08: MLXWrapper removed, LLMService simplified to AFM-only (no-arg init)
- Block 17: Salon structs removed, switchToModel() removed, selectedModel = always .appleFoundation, init simplified
- Block 21: runSalonTurn() + runSalonSeat() removed, sendMessage() calls runSingleModelTurn() directly
- Block 10.1: modelSection, PowerUserMode enum, mode toggle removed, powerUserSection simplified
- Block 10.2: cacheManagementSection removed, mlxDownloader env obj removed
- Block 8.5: useRecencyWeighting Salon variant removed, single prompt path kept
- Block 01: MLX framework imports removed (MLX, MLXLLM, Hub, MLXLMCommon, Tokenizers, HubApi extension)

### Bugs fixed during strip:
- Added `maxMemoryDepth` to HalModelLimits (was accidentally missing from original)
- Added `isInSettingsFlow` back to ChatViewModel (swept in Block 17 surgery)
- Fixed closing brace of ActionsView that was lost in Block 10.1 surgery
- Fixed stray `.onAppear {}` wrapping sheet modifiers (Block 10.1 surgery artifact)

### Next: Phase 2 — Stabilize
1. **System prompt rewrite** for Hal LMC identity — needs new prompt text
2. **End-to-end test** of memory stack (STM, RAG, summarization) with clean install
3. **Settings audit** — review what remains, whether any labels need updating

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

# 3. Run a test (HTTP mode — see Test Runner section below for setup)
python3 tests/hal_test.py state
```

**Container pref plist:** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Library/Preferences/com.MarkFriedlander.Hal-Universal.plist`
**Mac destination ID:** `00008112-0010193C3A88C01E`
**Harness dir (file-mode legacy):** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/Data/Documents/hal_test/`

---

## Test Runner — USE THIS, NEVER WRITE HARNESS FILES DIRECTLY

**`tests/hal_test.py`** is the single durable test runner. No reinvention. Two transport modes — HTTP (preferred) and file-polling (fallback).

### HTTP Mode Setup (one-time, preferred)

1. In Hal: Settings → Advanced → Developer API → toggle ON
2. Copy the IP:port and token shown in the UI
3. Run: `python3 tests/hal_test.py setup <ip> 8765 <token>`
4. Config saved to `tests/.hal_api_config.json` — auto-used on all future runs

HTTP mode is **synchronous and reactive** — each `send_turn()` call blocks until Hal responds. No polling, no timing races. Enables genuine conversation testing where each message is written in response to what Hal actually said.

### File-Mode Fallback (legacy)

Used automatically when `tests/.hal_api_config.json` doesn't exist. Requires:
- Test console enabled in Hal (Settings → Advanced → Pipeline Test Console → Start)
- mtime polling on `output_latest.json` (2s interval, 90s timeout)

### Commands

```bash
# From project root:
python3 tests/hal_test.py setup <ip> 8765 <token>    # One-time HTTP config
python3 tests/hal_test.py reset                       # Nuclear reset + fresh start
python3 tests/hal_test.py new                         # New thread (keep memory/settings)
python3 tests/hal_test.py turn "Hello"                # Single turn, prints response
python3 tests/hal_test.py cmd SET_TEMPERATURE:0.8     # Any harness command
python3 tests/hal_test.py state                       # Print current state
python3 tests/hal_test.py run tests/conversations/quality_test.txt  # Scripted file
python3 tests/hal_test.py chat                        # Interactive REPL (reactive)
```

### HTTP API Endpoints (Block 32 LocalAPIServer, port 8765)

```
POST /chat      {"message": "..."}           → full diagnostic JSON
POST /command   {"command": "NUCLEAR_RESET"} → JSON result
GET  /state                                  → settings state JSON
All require: Authorization: Bearer <token>
```

Token stored in Keychain, displayed in Hal Settings → Advanced → Developer API.

**Conversation files** live in `tests/conversations/`:
- `quality_test.txt` — 23-turn personality + voice + memory assessment
- `memory_test.txt` — STM, summarization, RAG gate, retrieval verification
- `settings_test.txt` — harness commands, settings persistence, reset behavior

**Conversation file format:**
```
# comment
CMD: NUCLEAR_RESET          <- harness command (CMD: prefix)
CMD: SET_TEMPERATURE:0.9    <- any SET_* works
Hello, I'm new here.        <- conversation turn
What's my name?             <- waits for prior response before sending
```

Report written to `<filename>_report.json` after each `run`.

---

## Current Memory Architecture (as of March 2026, pre-strip)

### CONVERSATION_FACTS — FULLY REMOVED
Everything removed: DB table, CRUD functions, Pass 2 extraction, Priority 3.5 injection, GET_FACTS harness command.

### RAG Exclusion — Fixed (Block 07, `buildExclusionClause`)
Surgical STM-only exclusion using `turn_number IN (excludeTurns)`. Earlier turns from same conversation are RAG-searchable.

### RAG Gate — Reworked (Block 20.1, `decideTools`)
YES/NO gate with actual STM context + rolling summary. Structured bullet rules for personal possessives. Temperature 0.1. Uses `effectiveMemoryDepth * 2` messages.

### Summary Persistence — Fixed (Block 20.1)
`injectedSummary` injected on every turn once set (`!injectedSummary.isEmpty`). Persists until thread reset or next summarization cycle. `pendingAutoInject` flag no longer gates injection.

### Summarization Blocks Next Response (Block 18 + Block 21)
`generateAutoSummary()` stores task as `self.summarizationTask`. `runSingleModelTurn()` awaits it before `buildPromptHistory`. Shows "Reflecting on our earlier conversation..." during wait.

### Cosine Similarity Dedup (Block 20.1)
Before RAG snippet loop: reference embedding from `shortTermText + injectedSummary`. Each snippet compared. Threshold `ragDedupSimilarityThreshold` (default 0.85, AppStorage). Sequential `partIndex` labels.

---

## Key Environment Facts

- **Container:** `~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/`
- **DB:** `~/Library/Containers/.../Data/Documents/hal_conversations.sqlite`
- **Harness dir:** `~/Library/Containers/.../Data/Documents/hal_test/`
- **Nuclear reset:** `rm -rf ~/Library/Containers/68B65A35-9706-4B97-B34C-43E2F6C8DA20/`
- **SOP harness:** Always use Python scripts with hardcoded absolute paths. Bash variable expansion breaks in multi-line tool calls.
- **mtime-based polling:** Poll `output_latest.json` modification time (not file numbers).

---

## Open Items After Strip

1. **System prompt rewrite** for Hal LMC identity (Phase 2)
2. **Watch app timeout** — investigate and fix (Phase 4)
3. **iCloud integration** — design first, then implement (Phase 3)
4. **Power user settings audit** — after strip, review what settings remain and whether UI needs reorganization

---

## Bugs Still Open (from pre-pivot work, may become irrelevant after strip)

- **Progress indicator jump**: `sizeGB` may be nil at download start — MOOT after strip (MLX gone)
- **Model name logging bug in harness**: logs `selectedModel.id` not `llmService.activeModelID` — MOOT after strip (single model)

---

## Hal-ness Behavioral Notes

When Hal doesn't have something in memory that a user references, acknowledge the gap honestly. "I don't have that — could you remind me?" not confabulated recall. This is a trust principle.

Self-knowledge layer: kept but behind `enableSelfKnowledge` dev toggle. Not marketed in Hal LMC but not deleted. The SelfReflectionView (Block 12.6) stays accessible for users who find it.
