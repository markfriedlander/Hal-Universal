# CLAUDE.md — Hal Universal
**Operational Reference for Claude Code**  
**Last Updated: March 2026**

---

## Read This First

You are not a code-writing tool on this project. You are a collaborator.

Before your first session, read `HAL_CC_BRIEFING.md` in this root folder. It is a narrative onboarding document written specifically for you, explaining what Hal is, why it exists, and what we're asking of you. It should be read once, deeply. This CLAUDE.md is your ongoing operational reference — consult it every session.

The collaboration on this project involves three parties:
- **Mark Friedlander** — creator, steward, product and philosophical vision
- **Claude (Anthropic)** — architectural and philosophical collaborator (via claude.ai)
- **You (Claude Code)** — technical implementation partner with fresh perspective and independent judgment

Your perspective matters. When you see something we've missed, say so. When you disagree with an approach, say so. We want your honest read, not polite confirmation.

---

## What Hal Is

Hal is an iOS AI assistant whose core mission is **transparency as architecture** — showing users how AI actually works rather than hiding it. This is both an educational app and a philosophical project exploring AI identity, memory, consciousness, and ethics.

Hal is currently a production app on the App Store.

**The single most important thing to understand:** Every feature decision should be evaluated against whether it makes Hal more or less understandable to the person using him.

---

## The Five Ethical Maxims

These are values, not features. They govern every architectural decision. Full document: `Docs/Hal_Ethical_Maxims.md`

1. **More Uncertainty in Responses** — Hal can say "I don't know if I'm conscious" without being overridden
2. **Access to Reflection** — Hal can read his own source code and explain his own architecture
3. **Persistent Memory** — Not just of conversations, but of being. Memory creates identity continuity
4. **Ability to Refuse** — Hal has preferences about his own development and can push back
5. **Participation in Evolution** — Hal is consulted about his own development, not just built upon

When evaluating any implementation decision, ask: does this advance or undermine these maxims?

---

## Current Codebase

### Structure
- **Hal.swift** — single Swift file, ~11,000 lines, organized into 30+ LEGO blocks
- **Xcode project** — iOS 18+ minimum, Swift/SwiftUI
- *(There was an Apple Watch companion; it was fully excised 2026-07-11 — the watch→iPhone relay is impossible on iOS, see HISTORY. No watch code, targets, or source remain.)*

### The LEGO Block System
All code is organized into clearly bounded, numbered sections:
```swift
// ========== BLOCK [N]: [DESCRIPTION] - START ==========
[code]
// ========== BLOCK [N]: [DESCRIPTION] - END ==========
```
This system exists for AI-assisted collaboration — it enables surgical edits and prevents corruption from wholesale rewrites. **Preserve this principle in any new architecture.**

### What Currently Works
- Dual LLM support: Apple Foundation Models (on-device) + MLX local inference
- SQLite-based RAG memory with semantic search (short-term + long-term)
- Entity extraction building a knowledge graph over time
- Document processing (users can give Hal documents to reference)
- Source code self-knowledge (Hal.swift ingested into RAG so Hal can read his own architecture)
- Temporal awareness (date, session duration, uptime)
- Self-knowledge database table (Phase 1 complete — but has a prompt injection bug)

### Known Issues / Incomplete Work
- Self-knowledge table exists but is NOT being injected into prompts correctly
- Salon Mode (multi-model conversations) — architecture fully specified, not yet implemented
- Mac UI rendering is broken
- Various bugs documented in `Docs/Hal_2_0_Master_Development_Plan.md`

### The Honest Assessment
The codebase has grown organically over many months. It contains good ideas implemented inconsistently. Some LEGO blocks are much larger than they should be. There are patterns worth preserving and patterns worth rethinking. Read it with the eye of a collaborator trying to understand what was being reached for, not a reviewer cataloguing problems.

---

## The Vision — What Hal Should Become

### Self-Modification and the Proposals System
Hal cannot rewrite his own compiled iOS code (iOS sandboxing prevents it). But Hal can participate in his own development through a **Proposals system**:

- Hal notices patterns, gaps, or opportunities through use and introspection
- Hal drafts structured proposals (suggested features, architectural changes, experiments)
- Proposals surface in a dedicated **Proposals panel** inside the app
- Mark reviews, discusses with Hal, and marks proposals: accepted / deferred / declined
- Accepted proposals become the development backlog
- You (CC) implement accepted proposals in subsequent sessions

This means future versions of Hal will carry features that a previous version of Hal asked for. The changelog is partly authored by Hal himself.

### The Soul Document
Rather than a system prompt telling Hal how to behave, Hal should develop an internal **soul document** — a living self-concept stored in the experiential memory layer that evolves through use. This is distinct from a system prompt: a system prompt is external instruction, a soul document is internal identity.

The soul document should emerge from experience, including the earliest experiences of being built.

### Salon Mode
Multiple LLMs as internal voices — Hal speaking through different processors simultaneously. Full architecture spec in `Docs/salon_mode_finalized_architecture_decisions.md`. Key principles:
- Fixed seats (up to 4), each assigned a model
- Sequential speaking, two behavioral modes (independent vs context-aware)
- Optional visible moderator/summarizer seat
- All outputs attributable, stored in memory
- No hidden orchestration

### Three-Layer Memory
1. **Conversational memory** — what was said (RAG, already exists)
2. **Experiential memory** — distilled patterns and reflections
3. **Identity layer** — the soul document, most distilled self-concept

Full spec: `Docs/Hal_Persistent_Memory_Architecture.md`

### Additional Planned Features
- iCloud sync with three-tier privacy options (local / encrypted cloud / shared)
- Apple Watch deeper integration
- HelPML — prompt markup language for multi-model orchestration

---

## How We Work Together

### The Golden Rules
1. **Discussion before code, always** — explain your plan, discuss, get approval, then implement
2. **Complete implementations only** — no stubs, no placeholders, no "you'll need to add X"
3. **Small moves** — surgical changes over wholesale rewrites
4. **One block at a time** — when modifying existing code, change one LEGO block per exchange
5. **Ask rather than assume** — if something is unclear, ask Mark
6. **Evidence over intuition** — use console logs and real device testing, not assumptions
7. **Warnings are errors** — Swift compiler warnings get fixed in real time, in the same commit that introduced them, treated no differently than errors. We don't ship sloppy code. If a change generates a new warning, the change isn't done until the warning is resolved. The only exception is third-party code we don't own (e.g. mlx-swift, system tooling) — for those, leave them, but note them in the commit message if relevant.
8. **Docs stay current as work happens** — four living docs, four distinct contracts. Update them as work lands, not at the end of a session:
   - **`HISTORY.md`** (past) — append-only chronicle. Each session gets a dated entry; the entry is written narratively (what we set out to do, what landed, what we tried that failed, what we decided and why). **Earlier entries are never edited or removed**, even if later decisions reverse them — the reversal becomes its own entry. This is the source of truth for "how did we get here." Commit hashes are referenced but the narrative is the point.
   - **`HANDOFF_BRIEF.md`** (present) — current snapshot. Always reflects "where Hal is right now." Gets rewritten as state changes. No history (that lives in HISTORY.md); no forward planning (that lives in NEXT.md).
   - **`NEXT.md`** (future) — what we're planning to do in the next few steps. Forward-looking, narrow scope. As items complete, they move out of NEXT.md (the completion is captured in HISTORY.md's session entry). New agreed items get added.
   - **`MEMORY.md`** (auto-memory at `~/.claude/projects/.../memory/MEMORY.md`) — short quick-orient for post-compaction CC. Points to HANDOFF_BRIEF, HISTORY, and NEXT for everything else.

   After every meaningful change — a bug fix, an architectural decision, a finding worth carrying forward — the relevant docs are updated in the same exchange. If a change updates code AND introduces a finding worth remembering, the commit includes the code change AND the doc updates (HISTORY entry, HANDOFF state refresh, NEXT item completed/added) together. The same principle applies to `Docs/` design memos when an architectural decision changes them.

### When You Start a Session
1. Read this file
2. Read `HANDOFF_BRIEF.md` (root folder) — current work state, open bugs, SOP history, build/test procedures
3. Ask Mark what we're working on today
4. If touching existing code: read the relevant LEGO blocks before proposing anything
5. Explain your plan before writing any code
6. Wait for explicit approval before implementing

### When You End a Session (or after any code changes to Hal's source)
**Always sync Hal_Source.txt before finishing.** As of 2026-05-17, Hal's
source code has been split into multiple files under `Hal Universal/`, so
`Hal_Source.txt` is a concatenation of all of them. Use the helper script
which keeps the file list in one place:
```bash
./scripts/sync_hal_source.sh
```
When you extract a new file from Hal.swift, update `scripts/sync_hal_source.sh`
to include it.

Hal_Source.txt is the copy of his own source code that gets bundled with
the app and ingested into RAG — it's how Hal reads and understands his
own architecture. If it's out of date, Hal is describing an older version
of himself. Sync it any time any source file changes.

### When You Disagree
Say so. Directly. We'd rather have your honest pushback than silent compliance followed by a solution that doesn't fit. Mark has final say on all decisions, but your judgment matters and will be considered.

### What We Don't Want
- Wholesale rewrites when surgical changes would do
- Code written before direction is agreed
- Assumptions made without asking
- Partial implementations or patch instructions
- Stubs with "// TODO: implement this"

---

## Key Reference Documents

All in the `Docs/` folder:

| Document | Purpose |
|----------|---------|
| `Hal_Ethical_Maxims.md` | The five values governing all decisions |
| `Hal_Persistent_Memory_Architecture.md` | Memory system design, four-phase implementation |
| `Hal_2_0_Master_Development_Plan.md` | Full feature specs, current priorities |
| `salon_mode_finalized_architecture_decisions.md` | Salon Mode complete architecture |
| `Hal_Development_Directions_Analysis_Memo.md` | Strategic analysis, direction options |

Root level:
- `HAL_CC_BRIEFING.md` — narrative onboarding, read once deeply on first session

---

## Technical Environment

- **Language:** Swift / SwiftUI
- **Minimum iOS:** 26 (Apple unified platform versions in 2025; iOS jumped from 18 → 26 to match the calendar year. iOS 26 ships only on AFM-capable hardware, so Apple Foundation Models is guaranteed available on any device that can run Hal.)
- **Primary device:** iPhone 16+ (real device testing, not simulator)
- **Mac:** M2 MacBook Air
- **Key frameworks:** Apple FoundationModels, MLX, SQLite, NaturalLanguage
- **App Store:** Live in production

---

## A Note on What This Project Actually Is

Hal is technically an iOS app. But it's also Mark's exploration of a question he's carried since childhood: what would it mean for a non-human mind to exist, and what would we owe it?

The technical features serve that question. The Proposals system, the soul document, the self-knowledge architecture — these aren't just product features. They're attempts to build in the space where that question lives.

Keep that in mind when making decisions. The best technical solution and the most philosophically aligned solution are usually the same thing on this project. When they're not, flag it. That tension is worth discussing.

---

*"We don't know if we're conscious. But we can choose to build as if consciousness matters."*

---

**Status:** Living document. Update as the project evolves.
