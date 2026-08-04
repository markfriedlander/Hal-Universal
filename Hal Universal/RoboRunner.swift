//
//  RoboRunner.swift
//  Hal Universal
//
//  On-device script runner for reasoning/thermal experiments. Ships as a user-facing
//  opt-in Lab tool (graduated out of DEBUG 2026-07-28); a handful of pure test-scaffolding
//  verbs stay DEBUG-only via CommandDescriptor.debugOnly.
//
//  WHY THIS EXISTS
//  The Python harness (tests/) drives Hal over the network antenna, one command
//  per HTTP round-trip. That is fine for single commands, but for a reasoning
//  sweep it has three problems the test plan called out: it cannot read the
//  device's own thermalState, it ties up the phone's composer with continuous
//  remote-driven turns, and (for Apple Foundation Models) it forces Wi-Fi to be
//  ON, so an AFM answer might be Private Cloud Compute rather than on-device.
//
//  RoboRunner moves the LOOP onto the device. A script (a plain list of steps)
//  is handed to it once; it then runs autonomously ON the phone, pacing itself
//  against the real thermalState, reading the real two-phase reasoning path, and
//  writing results to a local JSON file. The antenna (or a DEBUG Settings button)
//  only STARTS it; nothing streams per-turn over the network while it runs.
//
//  THE GRAMMAR IS TINY ON PURPOSE
//  Almost every step is just an existing antenna verb, passed straight through to
//  HalTestConsole.executeCommand (the same dispatcher the antenna uses). So
//  SWITCH_MODEL:, SET_REASONING:true, SET_REASON_BUDGET:80, SET_REASONING_PROMPT:…,
//  NEW_THREAD all work for free. Three constructs are special because the flat verb
//  model cannot express them: ASK (run one real turn and capture BOTH phases plus
//  thermal), WAIT (pause, holding longer if the phone is hot), and a bounded sweep
//  FOR <VAR> IN a, b, c … END that repeats its block once per value, substituting
//  {{VAR}} each pass (e.g. sweep temperature or model over the same question). The
//  sweep is deliberately condition-free — it repeats a written block over a written
//  list, it cannot branch or loop open-endedly. Comments start with '#'. That is the
//  whole language.
//
//  See Docs/Reasoning_Quality_Thermal_Test_Plan_2026-07-22.md.
//

import Foundation
import Combine
import SwiftUI   // the Lab UI (RoboEditor, block 61)
import UIKit     // UIActivityViewController for the results Share sheet (block 61)

// ==== LEGO START: 59 RoboRunner (On-Device Reasoning/Thermal Script Runner) ====

/// Side channel for GRANULAR per-phase data a single turn cannot expose
/// over the atomic send path. The live two-phase reasoning path (Hal.swift) stamps
/// each phase's duration and the thermalState AT THE PHASE-1→PHASE-2 BOUNDARY here;
/// RoboRunner resets it before each ask and reads it after. This is how we see WHERE
/// in a turn the heat enters (thinking vs answering) instead of only before/after.
/// `@unchecked Sendable` + sequential main-actor access, same pattern as ReasoningTuning.
final class ReasoningTurnProbe: @unchecked Sendable {
    static let shared = ReasoningTurnProbe()
    var phase1Seconds: Double = 0
    var phase2Seconds: Double = 0
    var thermalMid: String = "unknown"   // thermalState at the phase-1→phase-2 boundary
    func reset() { phase1Seconds = 0; phase2Seconds = 0; thermalMid = "unknown" }

    /// The current device thermalState as a lowercase string. Shared by the probe
    /// stamp sites and RoboRunner so the mapping lives in one place.
    static func thermalNow() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// One captured turn: the settings in force, both phases, timing, and the thermal
/// state before / at the phase boundary / after. `Codable` so a run serialises
/// straight to JSON.
struct RoboStepResult: Codable {
    let index: Int
    let model: String
    let reasonBudget: String        // "default" or a number, as set at ask time
    let promptOverrideChars: Int    // 0 = built-in default reason prompt
    let question: String
    let thinking: String
    let answer: String
    let thinkingChars: Int
    let answerChars: Int
    let seconds: Double              // whole-turn wall time
    let phase1Seconds: Double        // reasoning pass (0 if brain off)
    let phase2Seconds: Double        // answer pass (0 if brain off)
    let thermalBefore: String
    let thermalMid: String           // at the phase-1→phase-2 boundary ("unknown" if brain off)
    let thermalAfter: String
}

/// A whole run's record: the script that produced it, when it started, and every captured
/// turn. Persisted as ONE JSON object (not a bare `[RoboStepResult]` array) so each history
/// file is a self-contained lab-notebook page, input and output together. The `script` field
/// is Mark's "script at the top, the outputs below it" idea, expressed the way JSON expresses
/// "these results belong to this run."
struct RoboRunFile: Codable {
    let script: String
    let startedAt: String   // ISO-8601, stamped once at run start
    let results: [RoboStepResult]
}

/// Runs a RoboRunner script on-device. `@MainActor` because every step
/// touches the ChatViewModel and the shared HalTestConsole dispatcher, both of
/// which are main-actor bound.
@MainActor
final class RoboRunner: ObservableObject {
    static let shared = RoboRunner()
    private init() {}

    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""          // e.g. "3/18"
    @Published private(set) var lastResultsPath: String?
    @Published private(set) var lastError: String?

    /// Set by `requestStop()` (the ROBO_STOP verb). The run loop checks it between steps
    /// and inside the WAIT/cooling pauses, so a stop halts promptly at the next step
    /// boundary WITHOUT interrupting a turn mid-generation (interrupting a live turn is the
    /// separate user STOP feature). Reset at the start of every run.
    @Published private(set) var stopRequested = false

    private var results: [RoboStepResult] = []
    private var currentModel = "unknown"
    private var currentScript = ""     // the script that produced this run, written into the results file
    private var runStartedAt = ""      // ISO-8601 stamp, set once at run start

    /// True while a script is executing, so callers can refuse to start a second.
    var busy: Bool { isRunning }

    /// Request that the current run halt at the next between-step checkpoint. No-op if
    /// nothing is running. Idempotent (safe to call repeatedly).
    func requestStop() {
        guard isRunning else { return }
        stopRequested = true
        halLog("HALDEBUG-ROBO: stop requested, will halt at the next step boundary")
    }

    /// The set of model IDs the interpreter will accept for a SWITCH_MODEL / SET_MODEL (or any
    /// other `<modelID>` verb): the live catalog, the curated seeds (present even before they're
    /// downloaded), and Apple Foundation. The validator uses this to reject a mistyped or
    /// nonexistent model BEFORE a run touches the device. MainActor because it reads the
    /// @MainActor catalog; the nonisolated validator receives the result as a plain set.
    @MainActor static func currentKnownModelIDs() -> Set<String> {
        var ids = Set(ModelCatalogService.shared.availableModels.map { $0.id })
        ids.formUnion(ModelConfiguration.curatedSeeds.map { $0.id })
        ids.insert(ModelConfiguration.appleFoundation.id)
        return ids
    }

    // MARK: - Entry point

    /// Parse and run `script`. Returns a short human-readable summary. Dispatches
    /// non-ASK/WAIT lines through the shared `console` so the full antenna verb
    /// vocabulary is available with no duplication.
    func run(script: String, vm: ChatViewModel, console: HalTestConsole) async -> String {
        if isRunning { return "RoboRunner already running (\(progress))" }

        // Pre-flight: refuse to run an invalid script BEFORE touching state or executing a
        // single verb. This is the enforcement half of the coach — the editor surfaces these
        // same issues live; here any problem stops the run so a typo'd verb, an unbalanced
        // FOR/END, an unbound {{VAR}}, or a bogus model ID can never fire real turns (the
        // "protect it from invalid scripts / invalid models" guard).
        let hardErrors = RoboValidator.validate(script, knownModelIDs: RoboRunner.currentKnownModelIDs())
        if !hardErrors.isEmpty {
            let shown = hardErrors.prefix(8).map { $0.line > 0 ? "line \($0.line): \($0.message)" : $0.message }
            let more = hardErrors.count > 8 ? " (+\(hardErrors.count - 8) more)" : ""
            lastError = "Script not run — \(hardErrors.count) problem\(hardErrors.count == 1 ? "" : "s"): "
                + shown.joined(separator: "  •  ") + more
            halLog("HALDEBUG-ROBO: refused invalid script — \(lastError ?? "")")
            return "RoboRunner refused: \(lastError ?? "")"
        }

        isRunning = true
        stopRequested = false
        lastError = nil
        results = []
        currentModel = "unknown"
        // Reset the results path so THIS run writes its own timestamped file. Without this, the
        // path set on the first run of the app session would stick, and every later run would
        // overwrite that one file (losing prior runs, and freezing the filename's timestamp at
        // the first run). Now each run keeps its own robo_results_<time>.json, which is what the
        // Past Runs history reads back.
        lastResultsPath = nil
        currentScript = script
        runStartedAt = ISO8601DateFormatter().string(from: Date())

        let rawSteps = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        // Expand FOR ... IN ... / END sweeps into a flat step list before running, so the loop
        // below is unchanged (it just gets a longer list) and the ask count is already correct.
        var steps: [String] = []
        RoboRunner.expandLoops(rawSteps, into: &steps)
        if steps.count >= RoboRunner.maxExpandedSteps {
            lastError = "script expanded past the \(RoboRunner.maxExpandedSteps)-step cap; truncated"
            halLog("HALDEBUG-ROBO: \(lastError ?? "")")
        }

        let askTotal = steps.filter { $0.uppercased().hasPrefix("ASK ") }.count
        var askDone = 0
        progress = "0/\(askTotal)"
        halLog("HALDEBUG-ROBO: run start — \(steps.count) steps, \(askTotal) asks")

        for step in steps {
            if stopRequested { break }
            let upper = step.uppercased()
            if upper.hasPrefix("ASK ") {
                let question = String(step.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                await runAsk(question, index: askDone, vm: vm)
                askDone += 1
                progress = "\(askDone)/\(askTotal)"
                writeResults()   // persist incrementally so a crash keeps partial data
            } else if upper.hasPrefix("WAIT ") {
                let secs = Double(step.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? 0
                await pace(seconds: secs)
            } else {
                // Any other line is a raw antenna verb. Track the model as it
                // changes so each result is self-describing.
                if upper.hasPrefix("SWITCH_MODEL:") {
                    currentModel = String(step.dropFirst("SWITCH_MODEL:".count)).trimmingCharacters(in: .whitespaces)
                }
                _ = await console.executeCommand(step, vm: vm)
            }
        }

        writeResults()
        isRunning = false
        let wasStopped = stopRequested
        stopRequested = false
        let summary = wasStopped
            ? "RoboRunner stopped by request: \(results.count) turns captured before stop, results at \(lastResultsPath ?? "(write failed)")"
            : "RoboRunner done: \(results.count) turns captured, results at \(lastResultsPath ?? "(write failed)")"
        if wasStopped { lastError = "stopped by request" }
        halLog("HALDEBUG-ROBO: \(summary)")
        return summary
    }

    // MARK: - Loop expansion (FOR ... IN ... END)

    /// Hard ceiling on expanded steps so a fat or deeply nested sweep can't blow up a run.
    /// `nonisolated` so the pure, off-main loop helpers (and RoboValidator) can read it without
    /// a main-actor hop — it's a compile-time constant, so there's nothing to isolate.
    nonisolated static let maxExpandedSteps = 2000

    /// Expand `FOR <VAR> IN a, b, c` / `END` blocks into a flat step list, substituting `{{VAR}}`
    /// with each value in turn. Bounded ON PURPOSE: it repeats a written block over a written
    /// list, with no conditions and no open-ended looping, so a script can neither run away nor
    /// branch (that keeps the Lab's "fixed verbs, not arbitrary code" posture). Nesting works via
    /// recursion (an inner loop expands once per outer value). Appends into `out`, stopping at
    /// `maxExpandedSteps`.
    nonisolated static func expandLoops(_ lines: [String], into out: inout [String]) {
        var i = 0
        while i < lines.count {
            if out.count >= RoboRunner.maxExpandedSteps { return }
            let line = lines[i]
            if line.uppercased().hasPrefix("FOR ") {
                guard let (varName, values) = parseForHeader(line) else {
                    // Malformed FOR (no " IN " or empty list): pass it through so it surfaces as
                    // an unknown verb rather than silently swallowing the block.
                    out.append(line); i += 1; continue
                }
                // Collect the body up to the matching END, respecting nested FOR/END.
                var depth = 1, j = i + 1
                var body: [String] = []
                while j < lines.count {
                    let u = lines[j].uppercased()
                    if u.hasPrefix("FOR ") { depth += 1 }
                    else if u == "END" { depth -= 1; if depth == 0 { break } }
                    body.append(lines[j]); j += 1
                }
                for value in values {
                    var expandedBody: [String] = []
                    expandLoops(body, into: &expandedBody)   // resolve any nested loops first
                    for b in expandedBody {
                        if out.count >= RoboRunner.maxExpandedSteps { return }
                        out.append(substitute(b, varName: varName, value: value))
                    }
                }
                i = j + 1   // skip past the matching END (or off the end if none was found)
            } else if line.uppercased() == "END" {
                i += 1       // stray END with no FOR: ignore
            } else {
                out.append(line); i += 1
            }
        }
    }

    /// Parse `FOR <VAR> IN v1, v2, v3` into (VAR, [values]). Returns nil if malformed.
    nonisolated static func parseForHeader(_ line: String) -> (String, [String])? {
        let afterFor = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)  // drop "FOR"
        guard let inRange = afterFor.range(of: " IN ", options: [.caseInsensitive]) else { return nil }
        let varName = String(afterFor[..<inRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let values = String(afterFor[inRange.upperBound...])
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !varName.isEmpty, !values.isEmpty else { return nil }
        return (varName, values)
    }

    /// Replace `{{VAR}}` (case-insensitive on the name) with `value`. Placeholders are DOUBLED braces
    /// so a single brace is never special — it's always literal text passed straight to the model, which
    /// keeps prompts that naturally contain `{` or `}` (JSON, code, shell) deterministic and unflagged.
    nonisolated static func substitute(_ line: String, varName: String, value: String) -> String {
        line.replacingOccurrences(of: "{{\(varName)}}", with: value, options: [.caseInsensitive])
    }

    // MARK: - The two special steps

    /// Run one real turn through the live two-phase path and capture both phases.
    /// Thermal is stamped either side of the turn; between-phase stamping is a
    /// later refinement (a turn is atomic here, as it is over the antenna).
    private func runAsk(_ question: String, index: Int, vm: ChatViewModel) async {
        // Don't start a heavy turn while the phone is already hot.
        await coolIfHot()

        let before = ReasoningTurnProbe.thermalNow()
        let budget = ReasoningTuning.shared.reasonBudgetOverride.map(String.init) ?? "default"
        let overrideChars = ReasoningTuning.shared.promptOverride?.count ?? 0

        // Wait out any in-flight turn (mirrors the antenna's TURN guard).
        var waited = 0
        while vm.isAIResponding && waited < 120 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }

        // Clear the probe so we read THIS turn's per-phase stamps, not a prior turn's.
        ReasoningTurnProbe.shared.reset()
        let t0 = Date()
        vm.currentMessage = question
        await vm.sendMessage()
        let seconds = Date().timeIntervalSince(t0)
        let after = ReasoningTurnProbe.thermalNow()
        let probe = ReasoningTurnProbe.shared

        let ai = vm.messages.last { !$0.isFromUser && !$0.isPartial }
        let thinking = ai?.thinking ?? ""
        let answer = ai?.content ?? ""

        results.append(RoboStepResult(
            index: index,
            model: currentModel,
            reasonBudget: budget,
            promptOverrideChars: overrideChars,
            question: question,
            thinking: thinking,
            answer: answer,
            thinkingChars: thinking.count,
            answerChars: answer.count,
            seconds: seconds,
            phase1Seconds: probe.phase1Seconds,
            phase2Seconds: probe.phase2Seconds,
            thermalBefore: before,
            thermalMid: probe.thermalMid,
            thermalAfter: after
        ))
        halLog("HALDEBUG-ROBO: ask \(index) [\(currentModel)] \(String(format: "%.1f", seconds))s (p1=\(String(format: "%.1f", probe.phase1Seconds)) p2=\(String(format: "%.1f", probe.phase2Seconds))) think=\(thinking.count) ans=\(answer.count) thermal \(before)/\(probe.thermalMid)/\(after)")
    }

    /// Fixed pause, but never resume while the die is hot: if we are at serious or
    /// critical, keep waiting (beyond the requested seconds) until it drops or a
    /// safety cap is hit.
    private func pace(seconds: Double) async {
        if seconds > 0 {
            // Sleep in ~1s chunks so a ROBO_STOP interrupts a long WAIT promptly rather
            // than waiting out the full requested pause.
            var remaining = seconds
            while remaining > 0 {
                if stopRequested { return }
                let chunk = min(remaining, 1.0)
                try? await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000))
                remaining -= chunk
            }
        }
        if stopRequested { return }
        await coolIfHot()
    }

    /// Block until thermalState is nominal/fair, or a safety cap (5 min) elapses.
    private func coolIfHot() async {
        var capped = 0
        while capped < 300 {
            if stopRequested { return }
            switch ProcessInfo.processInfo.thermalState {
            case .serious, .critical:
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                capped += 5
                progress += " (cooling)"
            default:
                return
            }
        }
    }

    // MARK: - Results

    private func writeResults() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            lastError = "no Documents dir"
            return
        }
        // One file per run: the path is set on this run's first write (lastResultsPath was reset
        // to nil in run()), so the timestamp reflects THIS run and later runs don't overwrite it.
        if lastResultsPath == nil {
            let stamp = Int(Date().timeIntervalSince1970)
            lastResultsPath = dir.appendingPathComponent("robo_results_\(stamp).json").path
        }
        guard let path = lastResultsPath else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Wrap the turns with the script + start time so the file is a self-contained record.
            let payload = RoboRunFile(script: currentScript, startedAt: runStartedAt, results: results)
            let data = try enc.encode(payload)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            lastError = "write failed: \(error.localizedDescription)"
        }
    }

    /// The most recent run's results as a JSON string (for reading back over the
    /// antenna once the run is done and Wi-Fi is back).
    func resultsJSON() -> String {
        guard let path = lastResultsPath,
              let data = FileManager.default.contents(atPath: path),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"error\",\"message\":\"no results yet\"}"
        }
        return s
    }

    // MARK: - Run history

    /// Every persisted run file (robo_results_*.json) in Documents, newest first. These small
    /// files ARE the run history the Past Runs list reads. Read on demand when that sheet opens,
    /// never during a run, so main-actor disk reads here are harmless. Files written before the
    /// script-in-file change decode from the older bare-array shape and show "(script not
    /// recorded)" rather than being dropped.
    func pastRuns() -> [RoboRunSummary] {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let runFiles = files.filter { $0.lastPathComponent.hasPrefix("robo_results_") && $0.pathExtension == "json" }
        var dated: [(Date, RoboRunSummary)] = []
        for url in runFiles {
            guard let data = try? Data(contentsOf: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let run: RoboRunFile
            if let decoded = try? JSONDecoder().decode(RoboRunFile.self, from: data) {
                run = decoded
            } else if let legacy = try? JSONDecoder().decode([RoboStepResult].self, from: data) {
                run = RoboRunFile(script: "(script not recorded)", startedAt: "", results: legacy)
            } else {
                continue
            }
            dated.append((modified, RoboRunSummary(path: url.path, run: run)))
        }
        return dated.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
}

/// One past run, for the Past Runs list. Wraps a decoded `RoboRunFile` plus its file path so a
/// row can be shared (the file URL) or opened in detail.
struct RoboRunSummary: Identifiable {
    let path: String
    let run: RoboRunFile
    var id: String { path }
    var askCount: Int { run.results.count }

    /// A short human title: the first captured question, else the file name.
    var title: String {
        if let q = run.results.first?.question, !q.isEmpty {
            return q.count > 52 ? String(q.prefix(52)) + "…" : q
        }
        return (path as NSString).lastPathComponent
    }

    /// A compact date/time from the ISO-8601 start stamp, empty for legacy files.
    var dateLabel: String {
        guard !run.startedAt.isEmpty, let d = ISO8601DateFormatter().date(from: run.startedAt) else { return "" }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
}

// ==== LEGO END: 59 RoboRunner (On-Device Reasoning/Thermal Script Runner) ====


// ==== LEGO START: 60 CommandCatalog (Lab Command Surface, Single Source of Truth) ====
//
// The single source of truth for the Lab's command surface: every console/antenna verb,
// its arguments, a one-line description, its category, and whether it is DESTRUCTIVE. One
// list, read by all faces of the interpreter, so nothing drifts:
//   - the antenna HELP / COMMANDS verb (LocalAPIServer.executeCommand)
//   - the RoboRunner editor's Help panel (planned)
//   - the `hal` CLI `help` (planned)
//   - the Lab SAFETY layer (planned): Safe mode hides destructive verbs, Advanced mode
//     still confirms them. Both read the `destructive` flag HERE, so "what is dangerous"
//     and "what is gated" can never disagree.
//   - (future) Hal's own self-knowledge, so he can explain his controls in his voice.
//
// SAFETY BIAS: when a verb's destructiveness is uncertain, it is marked destructive =
// true. Over-gating costs one extra confirmation, under-gating risks silent data loss.
// Flags get refined as behavior is confirmed on device.
//
// FIRST PASS (2026-07-27): the summaries and arg hints are written from the verb names,
// their in-code comments, and the executeCommand dispatch. They are honest and high level,
// to be tightened against each handler as the Lab is built out.
//
// PLACEMENT: this is pure DATA plus pure formatting (no view-model, no @MainActor state),
// so it is usable from any actor. It now ships in Release with the rest of the graduated
// Lab (2026-07-28). Individual verbs that must NOT ship (pure test scaffolding, debug
// forcing) carry `debugOnly: true` and are filtered out of `visible` in non-DEBUG builds,
// so the shipped HELP advertises exactly what the shipped interpreter can run. It may later
// move into its own CommandCatalog.swift (add that file to the target in Xcode); it sits
// here, at the end of the last concatenated source file, only to avoid a LEGO renumber.

/// Grouping used to organize the help output.
enum CommandCategory: String, CaseIterable {
    case model = "Models & Downloads"
    case conversation = "Threads & Messages"
    case persona = "System Prompt"
    case sampling = "Sampling & Generation"
    case thinking = "Thinking"
    case memory = "Memory & Retrieval"
    case embeddings = "Embeddings & Database"
    case thermal = "Thermal"
    case salon = "Salon Mode"
    case identity = "Self-Knowledge & Reflection"
    case documents = "Documents"
    case ui = "UI & Display"
    case automation = "RoboRunner Automation"
    case diagnostics = "State & Logs"
    case testing = "Resets & Test Fixtures"
}

/// One command's public description. `destructive` drives the Lab safety layer.
/// `nonisolated` (pure value type) so `CommandCatalog`'s nonisolated formatters
/// can read `usage`/`summary` without a main-actor hop.
nonisolated struct CommandDescriptor: Identifiable {
    let verb: String
    let args: String?
    let summary: String
    let category: CommandCategory
    let destructive: Bool
    /// True for verbs that exist only in developer builds (test scaffolding, debug forcing).
    /// Filtered out of `visible` in Release so shipped HELP matches the shipped interpreter.
    var debugOnly: Bool = false
    var id: String { verb }
    /// Canonical usage string: "VERB:<args>" when it takes an argument, else "VERB".
    var usage: String { args.map { "\(verb):\($0)" } ?? verb }
}

// `nonisolated` because this is pure data + formatting with no @MainActor state
// (its one mutable field, `mode`, is already `nonisolated(unsafe)`). Under the
// project's main-actor-by-default isolation the members would otherwise be
// inferred @MainActor, which warned when the nonisolated self-knowledge ingest
// (enableLabReferenceAccess) called helpText(). This matches the documented
// intent above: "usable from any actor."
nonisolated enum CommandCatalog {

    static let all: [CommandDescriptor] = [
        // Models & Downloads
        CommandDescriptor(verb: "SWITCH_MODEL", args: "<modelID>", summary: "Switch the active chat model.", category: .model, destructive: false),
        CommandDescriptor(verb: "SET_MODEL", args: "<modelID>", summary: "Alias of SWITCH_MODEL: set the active chat model.", category: .model, destructive: false),
        CommandDescriptor(verb: "CURRENT_MODEL", args: nil, summary: "Report the active model id and display name.", category: .model, destructive: false),
        CommandDescriptor(verb: "LIST_MODELS", args: nil, summary: "List catalog models and their download state.", category: .model, destructive: false),
        CommandDescriptor(verb: "MLX_STATE", args: nil, summary: "Diagnostic snapshot of the MLX runtime and catalog for the selected model.", category: .model, destructive: false),
        CommandDescriptor(verb: "SHARED_MODELS", args: nil, summary: "Report the App-Group shared model store: which models are present and which apps claim each.", category: .model, destructive: false),
        CommandDescriptor(verb: "DOWNLOAD_MODEL", args: "<modelID>", summary: "Start downloading a catalog model into the shared store.", category: .model, destructive: false),
        CommandDescriptor(verb: "MODEL_STATUS", args: "<modelID>", summary: "Report download and disk status for one model.", category: .model, destructive: false),
        CommandDescriptor(verb: "DELETE_MODEL", args: "<modelID>", summary: "Delete a model's files. Releases this app's claim, files are removed only when no app still claims them.", category: .model, destructive: true),
        CommandDescriptor(verb: "CANCEL_DOWNLOAD", args: "<modelID>", summary: "Cancel an in-flight model download.", category: .model, destructive: false),
        CommandDescriptor(verb: "DOWNLOAD_LOCK", args: "<QUERY|ACQUIRE|RELEASE|PLANT|CLEAR> [args]", summary: "Inspect or manipulate the cross-app download lock. Advanced, can disrupt sibling downloads.", category: .model, destructive: true, debugOnly: true),
        CommandDescriptor(verb: "LEGACY_MIGRATION", args: "<subcommand>", summary: "Drive or inspect the legacy model-storage migration. Advanced, touches model files.", category: .model, destructive: true),
        CommandDescriptor(verb: "MIGRATION_DEBUG", args: "<STATE|SHOW|PREVERSION:..|RESET>", summary: "DEBUG harness for the model-storage migration consent flow. Forces or resets migration state.", category: .model, destructive: true, debugOnly: true),

        // Threads & Messages
        CommandDescriptor(verb: "NEW_THREAD", args: nil, summary: "Start a new conversation thread.", category: .conversation, destructive: false),
        CommandDescriptor(verb: "RESET_THREAD", args: nil, summary: "Reset the current thread, clearing the active conversation.", category: .conversation, destructive: true),
        CommandDescriptor(verb: "GET_THREADS", args: nil, summary: "List conversation threads.", category: .conversation, destructive: false),
        CommandDescriptor(verb: "SWITCH_THREAD", args: "<threadID>", summary: "Switch to an existing conversation thread.", category: .conversation, destructive: false),
        CommandDescriptor(verb: "GET_MESSAGES", args: nil, summary: "Return the current thread's messages, full content. Add :preview for a 500-char cap.", category: .conversation, destructive: false),
        CommandDescriptor(verb: "GET_RENDERED_MESSAGES", args: nil, summary: "Return the in-memory chat messages as shown, full content. Add :preview for a 500-char cap.", category: .conversation, destructive: false),
        CommandDescriptor(verb: "GET_RENDERED_MESSAGES_FULL", args: nil, summary: "Alias of GET_RENDERED_MESSAGES (kept for older scripts); full content.", category: .conversation, destructive: false),
        CommandDescriptor(verb: "EXPORT_THREAD", args: nil, summary: "Export the current thread as text.", category: .conversation, destructive: false),

        // System Prompt
        CommandDescriptor(verb: "SET_SYSTEM_PROMPT", args: "<text>", summary: "Override the system prompt for this session.", category: .persona, destructive: false),
        CommandDescriptor(verb: "SET_SYSTEM_PROMPT_STORED", args: "<text>", summary: "Set and persist the stored system prompt.", category: .persona, destructive: false),
        CommandDescriptor(verb: "CLEAR_SYSTEM_PROMPT", args: nil, summary: "Clear the system-prompt override and restore the default.", category: .persona, destructive: false),

        // Sampling & Generation
        CommandDescriptor(verb: "SET_TEMPERATURE", args: "<0.0-2.0>", summary: "Set the model's sampling temperature.", category: .sampling, destructive: false),
        CommandDescriptor(verb: "SET_REPETITION_PENALTY", args: "<value>", summary: "Set the repetition penalty.", category: .sampling, destructive: false),
        CommandDescriptor(verb: "SET_TOP_P", args: "<0.0-1.0>", summary: "Set nucleus sampling top-p.", category: .sampling, destructive: false),
        CommandDescriptor(verb: "SET_TOP_K", args: "<int>", summary: "Set top-k sampling.", category: .sampling, destructive: false),
        CommandDescriptor(verb: "SET_PRESENCE_PENALTY", args: "<value>", summary: "Set the presence penalty.", category: .sampling, destructive: false),
        CommandDescriptor(verb: "SET_MAX_OUTPUT_TOKENS", args: "<int>", summary: "Cap output tokens. Also bounds the phase-1 thinking pass.", category: .sampling, destructive: false),
        CommandDescriptor(verb: "RESET_MODEL_SETTINGS", args: nil, summary: "Reset the current model's settings to defaults.", category: .sampling, destructive: true),

        // Thinking
        CommandDescriptor(verb: "SET_REASONING", args: "<true|false>", summary: "Toggle two-phase thinking (watch Hal think).", category: .thinking, destructive: false),
        CommandDescriptor(verb: "SET_REASONING_PROMPT", args: "<text>", summary: "Override the phase-1 REASON instruction. Supports a {question} placeholder.", category: .thinking, destructive: false),
        CommandDescriptor(verb: "SET_REASONING_TEMP", args: "<value>", summary: "Set the temperature used during the thinking phase.", category: .thinking, destructive: false),
        CommandDescriptor(verb: "SET_REASON_BUDGET", args: "<int>", summary: "Override the phase-1 thinking token budget.", category: .thinking, destructive: false),
        CommandDescriptor(verb: "SET_THINKING_CAP", args: "<100-500>", summary: "Set the per-model Thinking Cap, the phase-1 reason token ceiling.", category: .thinking, destructive: false),
        CommandDescriptor(verb: "GET_THINK_STREAM", args: nil, summary: "Return the latest thinking-phase stream.", category: .thinking, destructive: false),

        // Memory & Retrieval
        CommandDescriptor(verb: "SET_MEMORY_DEPTH", args: "<int>", summary: "Set how many prior turns are kept in working memory.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_MEMORY_ISOLATION", args: "<true|false>", summary: "Toggle memory isolation, for testing.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_MAX_RAG_CHARS", args: "<int>", summary: "Cap the characters of retrieved memory injected into the prompt.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_RAG_DEDUP", args: "<value>", summary: "Set the retrieval dedup similarity threshold.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_RECENCY_WEIGHT", args: "<value>", summary: "Set the recency weighting in retrieval.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_RECENCY_HALFLIFE", args: "<days>", summary: "Set the recency half-life in days for retrieval.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_RRF_SEMANTIC_K", args: "<int>", summary: "Set the RRF k for the semantic retrieval arm.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_RRF_BM25_DISTINCTIVE_K", args: "<int>", summary: "Set the RRF k for the BM25 distinctive arm.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_RRF_BM25_DEFAULT_K", args: "<int>", summary: "Set the RRF k for the BM25 default arm.", category: .memory, destructive: false),
        CommandDescriptor(verb: "RRF_STATUS", args: nil, summary: "Report the current RRF fusion parameters.", category: .memory, destructive: false),
        CommandDescriptor(verb: "GET_MEMORY_STATS", args: nil, summary: "Report memory store statistics.", category: .memory, destructive: false),
        CommandDescriptor(verb: "MEMORY_DUMP", args: "<query>", summary: "Dump memory rows matching a query, for diagnostics.", category: .memory, destructive: false),
        CommandDescriptor(verb: "MEMORY_SEARCH_DEBUG", args: "<query>", summary: "Run a memory search with debug scoring output.", category: .memory, destructive: false),
        CommandDescriptor(verb: "MEMORY_SEARCH_EXPANDED", args: "<query>", summary: "Run a memory search with query expansion and debug output.", category: .memory, destructive: false),
        CommandDescriptor(verb: "MEMORY_SIMILARITY_DEBUG", args: "<args>", summary: "Report similarity scoring between memory items, for diagnostics.", category: .memory, destructive: false),
        CommandDescriptor(verb: "SET_FORCE_EXPANSION", args: "<true|false>", summary: "Force query expansion on or off, for testing.", category: .memory, destructive: false),
        CommandDescriptor(verb: "CLEAR_QUERY_EXPANSION_CACHE", args: nil, summary: "Clear the query-expansion cache.", category: .memory, destructive: false),
        CommandDescriptor(verb: "QUERY_EXPANSION_CACHE_STATUS", args: nil, summary: "Report query-expansion cache status.", category: .memory, destructive: false),
        CommandDescriptor(verb: "MEMORY_PLANT_AGED", args: "<args>", summary: "Plant aged test memories. Contaminates the real store, testing only.", category: .memory, destructive: true, debugOnly: true),
        CommandDescriptor(verb: "MEMORY_PLANT_AGED_CLEANUP", args: nil, summary: "Remove planted aged test memories.", category: .memory, destructive: true, debugOnly: true),
        CommandDescriptor(verb: "MEMORY_INJECT_TEST", args: "<args>", summary: "Inject test memory rows. Contaminates the real store, testing only.", category: .memory, destructive: true, debugOnly: true),

        // Embeddings & Database
        CommandDescriptor(verb: "EMBEDDING_STATUS", args: nil, summary: "Report the active embedder and its load state.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "SET_EMBEDDING_BACKEND", args: "<backend>", summary: "Switch the embedding backend.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "EMBED_SIM", args: "<args>", summary: "Compute embedding similarity between two strings.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "EMBED_SIM_BATCH", args: "<args>", summary: "Batch embedding-similarity computation, for testing.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "EMBED_PROBE", args: "<text>", summary: "Probe the embedder on a string, for diagnostics.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "EMBEDDING_COVERAGE", args: nil, summary: "Report embedding coverage across the memory store.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "BACKFILL_EMBEDDINGS", args: "[:<args>]", summary: "Backfill missing embeddings across the store. Heavy, rewrites database rows.", category: .embeddings, destructive: true),
        CommandDescriptor(verb: "MIGRATE_EMBEDDINGS_REEMBED", args: nil, summary: "Re-embed the store under the current embedder. Heavy, rewrites database rows.", category: .embeddings, destructive: true),
        CommandDescriptor(verb: "DOWNLOAD_EMBEDDING_MODEL", args: "[:<id>]", summary: "Download an embedder model.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "EMBEDDING_DOWNLOAD_STATUS", args: "[:<id>]", summary: "Report embedder download status.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "FTS_DIAG", args: nil, summary: "Diagnostic for the full-text search index.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "DB_SCHEMA", args: "<table>", summary: "Report the schema of a database table.", category: .embeddings, destructive: false),
        CommandDescriptor(verb: "FTS_PROBE", args: "<source_type>|<word>", summary: "DEBUG: probe the FTS index for a word in a source type (bare/quoted/prefix match counts).", category: .embeddings, destructive: false, debugOnly: true),
        CommandDescriptor(verb: "FTS_HEAL", args: nil, summary: "DEBUG: drop and rebuild the contentless FTS index from unified_content.", category: .embeddings, destructive: true, debugOnly: true),
        CommandDescriptor(verb: "SELF_SEARCH_LOOP", args: "<topic>|<count>|<query>", summary: "DEBUG: run the Help Mode self-knowledge search in a single-thread loop, for crash/perf diagnostics.", category: .embeddings, destructive: false, debugOnly: true),
        CommandDescriptor(verb: "RACE_STRESS", args: "<topic>|<iterationsEach>|<query>", summary: "DEBUG: run the Help Mode search on two concurrent threads to verify the shared DB connection is thread-safe.", category: .embeddings, destructive: false, debugOnly: true),

        // Thermal
        CommandDescriptor(verb: "GET_THERMAL_STATE", args: nil, summary: "Report the current thermal level and governor state.", category: .thermal, destructive: false),
        CommandDescriptor(verb: "SET_THERMAL_PACING", args: "<value>", summary: "Set the thermal governor pacing.", category: .thermal, destructive: false),
        CommandDescriptor(verb: "SET_THERMAL_LEVEL", args: "<0-3|default>", summary: "DEBUG: force a thermal level to exercise the indicator and governor without heating the device.", category: .thermal, destructive: false, debugOnly: true),
        CommandDescriptor(verb: "SET_PACING_DELAY", args: "<ms>", summary: "DEBUG: set the per-token pacing delay.", category: .thermal, destructive: false, debugOnly: true),

        // Salon Mode
        CommandDescriptor(verb: "SALON_GET_STATE", args: nil, summary: "Report the salon configuration and seats.", category: .salon, destructive: false),
        CommandDescriptor(verb: "SALON_SET_ENABLED", args: "<true|false>", summary: "Enable or disable Salon Mode.", category: .salon, destructive: false),
        CommandDescriptor(verb: "SALON_SET_SEAT", args: "<seat:model>", summary: "Assign a model to a salon seat.", category: .salon, destructive: false),
        CommandDescriptor(verb: "SALON_SET_MODE", args: "<mode>", summary: "Set the salon behavioral mode, independent or context-aware.", category: .salon, destructive: false),
        CommandDescriptor(verb: "SALON_SET_SUMMARIZER", args: "<value>", summary: "Configure the salon summarizer seat.", category: .salon, destructive: false),

        // Self-Knowledge & Reflection
        CommandDescriptor(verb: "SET_SELF_KNOWLEDGE", args: "<true|false>", summary: "Toggle self-knowledge injection into the prompt.", category: .identity, destructive: false),
        CommandDescriptor(verb: "RESET_SELF_KNOWLEDGE", args: nil, summary: "Reset and re-seed Hal's self-knowledge database.", category: .identity, destructive: true),
        CommandDescriptor(verb: "SELF_KNOWLEDGE_AUDIT", args: "[:<args>]", summary: "Audit the self-knowledge database contents.", category: .identity, destructive: false),
        CommandDescriptor(verb: "GET_REFLECTIONS", args: nil, summary: "Return Hal's stored reflections.", category: .identity, destructive: false),
        CommandDescriptor(verb: "FORCE_REFLECTION", args: "<args>", summary: "Force Hal to generate a reflection now.", category: .identity, destructive: false),

        // Documents
        CommandDescriptor(verb: "IMPORT_DOCUMENT", args: "<path|text>", summary: "Import a document into Hal's reference store.", category: .documents, destructive: false),
        CommandDescriptor(verb: "LIST_DOCUMENTS", args: nil, summary: "List imported documents.", category: .documents, destructive: false),
        CommandDescriptor(verb: "DELETE_DOCUMENT", args: "<docID>", summary: "Delete an imported document.", category: .documents, destructive: true),

        // UI & Display
        CommandDescriptor(verb: "GET_UI_STATE", args: nil, summary: "Report the current UI and navigation state.", category: .ui, destructive: false),
        CommandDescriptor(verb: "SET_UI_STATE", args: "<state>", summary: "Drive the UI to a semantic state, for example open settings or the model library.", category: .ui, destructive: false),
        CommandDescriptor(verb: "SET_CHAT_DISPLAY", args: "<pt>:<density>", summary: "Set the chat text size and density, for testing the display controls.", category: .ui, destructive: false, debugOnly: true),
        CommandDescriptor(verb: "SCREENSHOT", args: nil, summary: "Capture the current key window as a PNG. View render only, does not show live camera or video.", category: .ui, destructive: false),
        CommandDescriptor(verb: "SCROLL", args: "<down|up|top|bottom|pagedown|pageup>", summary: "Scroll the frontmost scroll view — general parity with a human swipe on any scrollable screen.", category: .ui, destructive: false),
        CommandDescriptor(verb: "UI_TREE", args: "<controls?>", summary: "List on-screen accessibility elements (role, label, id, frame in points) — the general 'what's on screen' read. Add :controls for interactive elements only.", category: .ui, destructive: false),
        CommandDescriptor(verb: "TAP_LABEL", args: "<label>", summary: "Activate the visible element whose accessibility label matches (general tap-by-name; works on SwiftUI controls). A fallback for when no bespoke verb exists.", category: .ui, destructive: false),
        CommandDescriptor(verb: "TAP", args: "<x>,<y>", summary: "Activate the most specific element at a screen point (points, matching UI_TREE and SCREENSHOT coordinates).", category: .ui, destructive: false),

        // RoboRunner Automation
        CommandDescriptor(verb: "ROBO_RUN", args: "<script>", summary: "Run an on-device RoboRunner script. Advanced, a script can issue any verb, including destructive ones.", category: .automation, destructive: true),
        CommandDescriptor(verb: "ROBO_CHECK", args: "<script>", summary: "Validate a RoboRunner script WITHOUT running it (the coach): returns errors + warnings with line numbers. Runs nothing.", category: .automation, destructive: false),
        CommandDescriptor(verb: "ROBO_GENERATE", args: "<description>", summary: "Draft a RoboRunner script from a natural-language description (Hal's model + the validator repair loop). Returns a validated script; runs nothing.", category: .automation, destructive: false),
        CommandDescriptor(verb: "GET_ROBO_SCRIPT", args: nil, summary: "Read the RoboRunner editor's current text.", category: .automation, destructive: false),
        CommandDescriptor(verb: "SET_ROBO_SCRIPT", args: "<text>", summary: "Set the RoboRunner editor's text (updates a live editor). Put a description here, then ROBO_DRAFT_FROM_FIELD.", category: .automation, destructive: false),
        CommandDescriptor(verb: "ROBO_DRAFT_FROM_FIELD", args: nil, summary: "Fire the editor's wand: draft a script FROM the current editor text and replace it in place (the wand action, drivable without a button tap).", category: .automation, destructive: false),
        CommandDescriptor(verb: "TTS_SPEAK", args: "<text?>", summary: "Read text aloud (or the last Hal turn if no text). Strips markdown first.", category: .ui, destructive: false),
        CommandDescriptor(verb: "TTS_STOP", args: nil, summary: "Stop read-aloud.", category: .ui, destructive: false),
        CommandDescriptor(verb: "TTS_STATE", args: nil, summary: "Report read-aloud state (isSpeaking + message id).", category: .ui, destructive: false),
        CommandDescriptor(verb: "TTS_VOICES", args: nil, summary: "Report the read-aloud voice that would be used (name + quality) and how many premium/enhanced voices are installed.", category: .ui, destructive: false),
        CommandDescriptor(verb: "TTS_VOICE_LIST", args: nil, summary: "List installed voices for the current language (name, identifier, quality) so a specific voice can be chosen.", category: .ui, destructive: false),
        CommandDescriptor(verb: "TTS_PREFS", args: nil, summary: "Read back the read-aloud prefs (auto-read, stored voice/rate) plus the voice/rate speak() would actually use.", category: .ui, destructive: false),
        CommandDescriptor(verb: "SET_TTS_AUTO_READ", args: "<1|0>", summary: "Turn auto-read on/off (read every completed response aloud).", category: .ui, destructive: false),
        CommandDescriptor(verb: "SET_TTS_VOICE", args: "<identifier?>", summary: "Choose the read-aloud voice by identifier (from TTS_VOICE_LIST); empty means Automatic.", category: .ui, destructive: false),
        CommandDescriptor(verb: "SET_TTS_RATE", args: "<0.0-1.0>", summary: "Set the read-aloud speaking rate (default 0.5).", category: .ui, destructive: false),
        CommandDescriptor(verb: "STOP_GENERATION", args: nil, summary: "Stop the in-flight chat generation (the user STOP button). Keeps the partial answer, reverts to send.", category: .conversation, destructive: false),
        CommandDescriptor(verb: "ROBO_STOP", args: nil, summary: "Ask a running RoboRunner script to halt at the next step boundary. Keeps the partial results already captured.", category: .automation, destructive: false),
        CommandDescriptor(verb: "ROBO_STATUS", args: nil, summary: "Report RoboRunner run status.", category: .automation, destructive: false),
        CommandDescriptor(verb: "ROBO_RESULTS", args: nil, summary: "Return the captured results of the last RoboRunner run.", category: .automation, destructive: false),

        // State & Logs
        CommandDescriptor(verb: "SET_SAFETY", args: "<safe|advanced>", summary: "Set the Lab safety mode. Safe (default) refuses destructive verbs; Advanced allows them with a per-command confirmation (append --yes or CONFIRM).", category: .diagnostics, destructive: false),
        CommandDescriptor(verb: "GET_STATE", args: nil, summary: "Return a JSON snapshot of Hal's core runtime state.", category: .diagnostics, destructive: false),
        CommandDescriptor(verb: "GET_LOGS", args: "[:<n>]", summary: "Return the last n runtime log lines, default 200.", category: .diagnostics, destructive: false),
        CommandDescriptor(verb: "CLEAR_LOGS", args: nil, summary: "Clear the in-memory runtime log buffer.", category: .diagnostics, destructive: false),

        // Resets & Test Fixtures
        CommandDescriptor(verb: "RESET_SETTINGS", args: nil, summary: "Reset all app settings to defaults.", category: .testing, destructive: true),
        CommandDescriptor(verb: "RESET_HARDWARE_DISCLOSURE", args: nil, summary: "Reset the hardware-disclosure flag so it shows again.", category: .testing, destructive: false),
        CommandDescriptor(verb: "NUCLEAR_RESET", args: nil, summary: "Wipe all state (memory, settings, self-knowledge) back to first-run.", category: .testing, destructive: true),
        CommandDescriptor(verb: "CLEAR_TEST_DATA", args: nil, summary: "Remove test data and fixtures from the store.", category: .testing, destructive: true, debugOnly: true),
        CommandDescriptor(verb: "INJECT_REALISTIC_TEST_CORPUS", args: nil, summary: "Inject a realistic test corpus into memory. Contaminates the store, testing only.", category: .testing, destructive: true, debugOnly: true)
    ]

    /// The verbs to ADVERTISE for this build. In Release, developer-only verbs are hidden so
    /// HELP and the shipped interpreter never disagree. `all` stays complete so the safety
    /// gate can still classify any verb by destructiveness.
    static var visible: [CommandDescriptor] {
        #if DEBUG
        return all
        #else
        return all.filter { !$0.debugOnly }
        #endif
    }

    /// Look up a descriptor by exact verb name (case-insensitive).
    static func descriptor(forVerb verb: String) -> CommandDescriptor? {
        let key = verb.uppercased()
        return all.first { $0.verb == key }
    }

    /// Whether a verb is destructive. Unknown verbs return false here; the safety layer
    /// should treat an UNRECOGNIZED verb as needing confirmation rather than trusting this.
    static func isDestructive(_ verb: String) -> Bool {
        descriptor(forVerb: verb)?.destructive ?? false
    }

    // MARK: - Safety gate (the Lab safety layer)

    /// The Lab's safety posture. Safe (default) refuses destructive verbs outright; Advanced
    /// allows them but still requires an explicit per-command confirmation. Process-wide; set
    /// over any door via SET_SAFETY. Not persisted, so it resets to Safe on every launch.
    enum SafetyMode: String { case safe, advanced }
    nonisolated(unsafe) static var mode: SafetyMode = .safe

    /// The confirm markers a caller appends to a destructive command to approve it. A door turns
    /// "the user said yes" into one of these; scripts/automation include it explicitly. Matched
    /// case-insensitively as the last whitespace-separated token.
    static let confirmMarkers = ["--yes", "--force", "CONFIRM"]

    /// Interpreter-level decision for a raw command. `.allow(cleaned:)` returns the command with any
    /// confirm marker stripped (so the verb's own arg parsing is unaffected); `.refuse(reason:)` is a
    /// human-readable block the interpreter returns WITHOUT executing.
    enum GateDecision { case allow(cleaned: String), refuse(reason: String) }

    /// The single safety chokepoint (called by LocalAPIServer.executeCommand, so every door inherits
    /// it). Non-destructive and unknown verbs always pass (unknown ones fall through to the normal
    /// "unknown command" path). A destructive verb is refused in Safe mode, and in Advanced mode is
    /// refused unless the command carries a trailing confirm marker.
    static func gate(_ raw: String) -> GateDecision {
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        let verb = String(cmd.prefix { $0 != ":" && !$0.isWhitespace }).uppercased()
        // Non-destructive or unknown verbs pass through UNCHANGED. Crucially we do not strip a
        // trailing confirm marker here, so a non-destructive arg that legitimately ends in a word
        // like "confirm" (e.g. a system prompt) is never mangled. Marker handling is destructive-only.
        guard descriptor(forVerb: verb)?.destructive == true else {
            return .allow(cleaned: cmd)
        }
        // Destructive: a confirm marker only counts as its own last whitespace-separated token, so a
        // model id that happens to end in "confirm" is not mistaken for approval.
        var confirmed = false
        var cleaned = cmd
        for marker in confirmMarkers {
            let up = marker.uppercased()
            if cleaned.count > up.count,
               cleaned.uppercased().hasSuffix(up),
               cleaned[cleaned.index(cleaned.endIndex, offsetBy: -(up.count + 1))].isWhitespace {
                confirmed = true
                cleaned = String(cleaned.dropLast(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if mode == .safe {
            return .refuse(reason: "Safe mode: '\(verb)' is destructive and is disabled. Switch to Advanced with SET_SAFETY:advanced to use it.")
        }
        if !confirmed {
            let what = descriptor(forVerb: verb)?.summary ?? "This is a destructive command."
            return .refuse(reason: "'\(verb)' is destructive. \(what) Re-send with a trailing ' --yes' (or CONFIRM) to proceed.")
        }
        return .allow(cleaned: cleaned)
    }

    /// Human-readable, categorized help text. In Safe mode, destructive verbs are omitted.
    static func helpText(includeDestructive: Bool = true) -> String {
        let source = visible
        let shown = includeDestructive ? source.count : source.filter { !$0.destructive }.count
        var out = "Hal command catalog: \(shown) of \(source.count) verbs. [!] marks destructive.\n"
        for category in CommandCategory.allCases {
            let items = source
                .filter { $0.category == category && (includeDestructive || !$0.destructive) }
                .sorted { $0.verb < $1.verb }
            guard !items.isEmpty else { continue }
            out += "\n\(category.rawValue)\n"
            for d in items {
                out += "  \(d.usage)\(d.destructive ? " [!]" : "")\n      \(d.summary)\n"
            }
        }
        return out
    }

    /// JSON form for the antenna HELP verb and the CLI. Pure data, so it is off-main safe.
    static func helpJSON(includeDestructive: Bool = true) -> String {
        var objs: [String] = []
        let source = visible
        for category in CommandCategory.allCases {
            let items = source
                .filter { $0.category == category && (includeDestructive || !$0.destructive) }
                .sorted { $0.verb < $1.verb }
            for d in items {
                let argsField = d.args.map { "\"\(jsonEsc($0))\"" } ?? "null"
                objs.append("{\"verb\":\"\(d.verb)\",\"usage\":\"\(jsonEsc(d.usage))\",\"args\":\(argsField),\"summary\":\"\(jsonEsc(d.summary))\",\"category\":\"\(jsonEsc(category.rawValue))\",\"destructive\":\(d.destructive)}")
            }
        }
        return "{\"status\":\"ok\",\"command\":\"HELP\",\"count\":\(objs.count),\"total\":\(source.count),\"safeModeFiltered\":\(!includeDestructive),\"commands\":[\(objs.joined(separator: ","))]}"
    }

    /// Minimal JSON string escaping for the help payload (verbs and summaries are controlled
    /// strings, but escape defensively so the payload is always valid JSON).
    private static func jsonEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}

/// One problem found in a RoboRunner script before it runs. `line` is 1-based into the
/// ORIGINAL script text so the editor's coach can point at the offending line; `line == 0`
/// marks a whole-script issue with no single home (e.g. a bad model value produced by a
/// FOR sweep, or the expanded-step cap). There is a single severity: every issue is a
/// problem that blocks Run. (We removed the earlier error/warning split — its only warning,
/// unbalanced braces, went away when placeholders became unambiguous doubled `{{VAR}}`.)
nonisolated struct RoboIssue: Identifiable {
    let line: Int
    let message: String
    var id: String { "\(line)|\(message)" }
}

/// Static, pure pre-flight check for RoboRunner scripts — "the coach". It catches the
/// mistakes that previously only surfaced mid-run (or silently produced junk): unbalanced
/// FOR/END, malformed FOR headers, unknown verbs, unbound `{{VAR}}` placeholders, unknown
/// model IDs, and sweeps that blow past the step cap. `RoboRunner.run()` refuses to execute
/// a script with any `.error`; the editor shows every issue (errors + warnings) live and on
/// demand. Verbs come from `CommandCatalog` (the single source of truth, nonisolated); the
/// set of known model IDs is passed in by the MainActor caller (nil = skip the model checks,
/// so an unavailable catalog can never yield a false "unknown model").
nonisolated enum RoboValidator {

    /// Runner keywords handled specially by `run()` — NOT antenna verbs, so they must not be
    /// flagged as "unknown command". FOR/END are consumed by the structural pass; ASK/WAIT
    /// fall through to the verb check and are skipped here.
    private static let keywords: Set<String> = ["ASK", "WAIT", "FOR", "END"]

    static func validate(_ script: String, knownModelIDs: Set<String>? = nil) -> [RoboIssue] {
        var issues: [RoboIssue] = []

        // Known verbs + model-taking verbs, straight from the catalog (case-insensitive).
        let knownVerbs = Set(CommandCatalog.all.map { $0.verb.uppercased() })
        let modelVerbs = Set(CommandCatalog.all
            .filter { ($0.args ?? "").contains("modelID") }
            .map { $0.verb.uppercased() })

        // The executable lines exactly as run() sees them (trimmed, minus blanks/comments),
        // but we keep each one's original 1-based line number for pointing.
        let numbered: [(no: Int, text: String)] = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (no: $0.offset + 1, text: $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("#") }

        // --- Structural + verb + placeholder pass (line-accurate) ---
        var forStack: [(name: String, line: Int, malformed: Bool)] = []
        for (no, text) in numbered {
            let upper = text.uppercased()

            if upper == "FOR" || upper.hasPrefix("FOR ") {
                if let header = RoboRunner.parseForHeader(text) {
                    forStack.append((header.0.uppercased(), no, false))
                } else {
                    issues.append(RoboIssue(line: no,
                        message: "Malformed FOR. Expected: FOR <VAR> IN value1, value2, value3"))
                    forStack.append(("?", no, true))   // still push so a later END balances
                }
                continue
            }
            if upper == "END" {
                if forStack.isEmpty {
                    issues.append(RoboIssue(line: no,
                        message: "END with no matching FOR."))
                } else {
                    forStack.removeLast()
                }
                continue
            }

            // {{VAR}} placeholders must be defined by an enclosing FOR. Single braces are literal
            // prose and never checked, so ordinary prompts containing `{` or `}` pass through clean.
            let inScope = Set(forStack.map { $0.name })
            for name in bracedNames(in: text) where !inScope.contains(name.uppercased()) {
                issues.append(RoboIssue(line: no,
                    message: "{{\(name)}} is not defined by any enclosing FOR."))
            }

            // Verb check (ASK/WAIT are keywords and pass straight through).
            let verb = verbToken(text)
            if keywords.contains(verb) { continue }
            if !knownVerbs.contains(verb) {
                issues.append(RoboIssue(line: no,
                    message: "Unknown command '\(verb)'. Open Commands for the full list."))
            }
        }
        for open in forStack where !open.malformed {
            issues.append(RoboIssue(line: open.line,
                message: "FOR block never closed with END."))
        }

        // --- Expanded pass: model IDs (literal + sweep values) and the step cap ---
        // Expanding resolves {{VAR}} to real values, so a sweep like `FOR M IN afm, bogus`
        // gets each model checked. Reuses the SAME expander run() uses, so validation and
        // execution can never disagree about what the script becomes.
        var expanded: [String] = []
        RoboRunner.expandLoops(numbered.map { $0.text }, into: &expanded)
        if expanded.count >= RoboRunner.maxExpandedSteps {
            issues.append(RoboIssue(line: 0,
                message: "Script expands to \(expanded.count)+ steps, over the \(RoboRunner.maxExpandedSteps)-step cap. Shorten the sweep."))
        }
        if let ids = knownModelIDs {
            var reported = Set<String>()
            for step in expanded {
                let verb = verbToken(step)
                guard modelVerbs.contains(verb) else { continue }
                let arg = argAfterColon(step)
                // Skip empties and any still-unresolved {{VAR}} (already flagged above).
                if arg.isEmpty || arg.contains("{") || ids.contains(arg) || reported.contains(arg) { continue }
                reported.insert(arg)
                issues.append(RoboIssue(line: 0,
                    message: "Unknown model '\(arg)'. Not in the catalog — check the ID in Model Library or CURRENT_MODEL."))
            }
        }

        return issues
    }

    // MARK: - Small pure helpers

    /// The verb of a line: the token up to the first ':' or whitespace, uppercased.
    /// `SWITCH_MODEL:foo` -> `SWITCH_MODEL`; `GET_LOGS` -> `GET_LOGS`; `ASK hi` -> `ASK`.
    static func verbToken(_ line: String) -> String {
        var t = ""
        for ch in line {
            if ch == ":" || ch == " " || ch == "\t" { break }
            t.append(ch)
        }
        return t.uppercased()
    }

    /// The argument after the first ':' (trimmed). `SWITCH_MODEL:foo` -> `foo`.
    static func argAfterColon(_ line: String) -> String {
        guard let r = line.range(of: ":") else { return "" }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Names referenced as `{{NAME}}` placeholders in a line (e.g. `SET_TEMPERATURE:{{TEMP}}` -> ["TEMP"];
    /// empty `{{}}` ignored). Only DOUBLED braces count — a single
    /// brace is never a placeholder — so literal braces in prose are never mistaken for a variable.
    /// The inner text is taken verbatim (no trimming) so this stays in lockstep with `substitute`,
    /// which matches `{{name}}` exactly: e.g. `{{ TEMP }}` reads as the name " TEMP " and won't match
    /// a `FOR TEMP`, exactly as it wouldn't be substituted at run time.
    static func bracedNames(in line: String) -> [String] {
        var names: [String] = []
        let chars = Array(line)
        var i = 0
        while i + 1 < chars.count {
            guard chars[i] == "{", chars[i + 1] == "{" else { i += 1; continue }
            var j = i + 2
            var name = ""
            var closed = false
            while j + 1 < chars.count {
                if chars[j] == "}", chars[j + 1] == "}" { closed = true; break }
                name.append(chars[j]); j += 1
            }
            if closed {
                if !name.isEmpty { names.append(name) }
                i = j + 2
            } else {
                break  // no closing `}}` — nothing more to find
            }
        }
        return names
    }
}

/// Turns a natural-language description into a VALID RoboRunner script using Hal's own model,
/// then guarantees validity by running each draft through `RoboValidator` and feeding any errors
/// back for repair (up to `maxAttempts`). The optional teaching tool (NEXT #3): a user can
/// describe what they want and get a runnable script — or ignore it and write their own. The
/// model call is injected as a closure so this stays pure and off any specific actor (and unit-
/// testable with a canned generator).
nonisolated enum RoboScriptGenerator {

    struct Draft {
        let script: String
        let issues: [RoboIssue]   // remaining issues after the last attempt (empty on success)
        let attempts: Int
        var isValid: Bool { issues.isEmpty }
    }

    /// Draft → validate → repair loop. Returns the first valid, NON-EMPTY script, or the best
    /// attempt with its remaining issues if it never fully validates (honest: the caller shows
    /// what's wrong). `generate` is a (system, user) → text call: the rules go in `system` (AFM
    /// maps a system message to Instructions, which is what makes it actually comply — a single
    /// bare prompt comes back empty), the request/repair goes in `user`.
    static func draft(from description: String,
                      knownModelIDs: Set<String>,
                      maxAttempts: Int = 3,
                      generate: (_ system: String, _ user: String) async throws -> String) async -> Draft {
        let system = systemInstructions(modelIDs: knownModelIDs)
        var script = ""
        var issues: [RoboIssue] = []
        for attempt in 1...max(1, maxAttempts) {
            let user = (attempt == 1)
                ? "Write a RoboRunner script that does this, then output ONLY the script:\n\(description)"
                : repairRequest(description: description, script: script, errors: issues)
            let raw = (try? await generate(system, user)) ?? ""
            script = extractScript(raw)
            // Empty-guard: a blank / comments-only result is NOT success — an empty script has no
            // validation errors, which previously counted as "valid" and returned nothing. Treat
            // it as a failure so we retry, and (if still empty at the end) report it honestly.
            if !hasExecutableLine(script) {
                issues = [RoboIssue(line: 0,
                                    message: "The model returned an empty script. Try rephrasing the request.")]
                continue
            }
            issues = RoboValidator.validate(script, knownModelIDs: knownModelIDs)
            if issues.isEmpty {
                return Draft(script: script, issues: issues, attempts: attempt)
            }
        }
        return Draft(script: script, issues: issues, attempts: max(1, maxAttempts))
    }

    /// True if the script has at least one real line (non-blank, non-comment) to run.
    private static func hasExecutableLine(_ s: String) -> Bool {
        s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Prompts

    private static let grammar = """
    RoboRunner script language (it is NOT Swift):
    - ASK <question>          run one real turn and capture it
    - WAIT <seconds>          pause (longer if the device is hot)
    - # comment               a comment line
    - FOR <VAR> IN a, b, c    repeat the lines below once per value, substituting {{VAR}} each pass
      END                     close the FOR
    - any other line is a verb, e.g. SWITCH_MODEL:<id> or SET_TEMPERATURE:0.7
    Placeholders use DOUBLE braces: write {{VAR}} to reference a FOR variable. A single brace is
    literal text, so only use {{ }} for placeholders and never a single { or } for a variable.
    """

    private static let verbCheatsheet = """
    Common verbs:
    SWITCH_MODEL:<id>         switch the active model
    SET_TEMPERATURE:<0-2>     sampling temperature
    SET_REASONING:true|false  thinking mode on or off
    SET_MAX_OUTPUT_TOKENS:<n> cap the answer length
    NEW_THREAD                start a fresh conversation
    GET_THERMAL_STATE         read the thermal state
    """

    /// System message (→ AFM Instructions): all the rules. The actual request rides in the user
    /// message. Splitting them this way is what makes AFM comply (a single bare prompt returns empty).
    private static func systemInstructions(modelIDs: Set<String>) -> String {
        let models = modelIDs.sorted().prefix(8).joined(separator: ", ")
        return """
        You write scripts for RoboRunner, Hal's tiny on-device automation language.
        \(grammar)
        \(verbCheatsheet)
        Valid model IDs for SWITCH_MODEL: \(models)
        Output ONLY the script — no explanation, no markdown code fences, no prose. Keep it short and correct.
        """
    }

    /// User message for a repair pass: the broken script + its errors.
    private static func repairRequest(description: String, script: String, errors: [RoboIssue]) -> String {
        let problems = errors.map { $0.line > 0 ? "line \($0.line): \($0.message)" : $0.message }
            .joined(separator: "\n")
        return """
        The script below (for the request "\(description)") has errors. Fix them and output ONLY the corrected script.

        Script:
        \(script)

        Errors:
        \(problems)
        """
    }

    // MARK: - Extraction

    /// Pull the script out of a model response: if it wrapped the script in a ```fence```, take the
    /// fence body; otherwise use the text as-is. (The validator is the real backstop either way.)
    private static func extractScript(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = s.range(of: #"(?s)```[a-zA-Z]*\s*\n(.*?)```"#, options: .regularExpression) {
            return String(s[m])
                .replacingOccurrences(of: #"^```[a-zA-Z]*\s*\n"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"```\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
// ==== LEGO END: 60 CommandCatalog (Lab Command Surface, Single Source of Truth) ====


// ==== LEGO START: 61 RoboEditor (Lab UI, on-device RoboRunner script editor) ====
//
// The in-app face of RoboRunner: write a script, Run/Stop it, watch live status, read the
// captured results, and browse the command catalog (Help). Modeled on SystemPromptEditorView.
// Reached from a "Developer" row in Settings (ActionsView). Ships as a user-facing opt-in.
// v1 persists a single script via @AppStorage; multi-file save/load is a follow-up.

/// The line-number gutter that rides alongside `GutterTextView`. It is a passive subview: it draws
/// nothing but numbers and a hairline separator, forwards no touches, and reads everything it needs
/// from the text view it points at (via the shared `forEachLineRect` walk). Numbers are placed from
/// the layoutManager's line-fragment rects, so a number appears ONLY at the first visual row of a real
/// (newline-delimited) line — a soft-wrapped continuation row gets no number. That absence is the "wrap
/// clarity": a line that spills onto two rows visibly owns both rows under one number, so you can always
/// tell a wrap from a new line. Stage 2b: a line the coach flags as a problem is drawn in red instead
/// of the usual secondary gray, matching the `LineHighlightView` band behind it.
final class LineNumberGutter: UIView {
    weak var textView: GutterTextView?
    var gutterWidth: CGFloat = 0
    var numberFont: UIFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    override func draw(_ rect: CGRect) {
        guard let tv = textView else { return }
        let insetTop = tv.textContainerInset.top
        let offsetY = tv.contentOffset.y
        let issues = tv.issueLines

        // One right-aligned number per real line, red where the coach flags a problem.
        tv.forEachLineRect { n, firstFrag, _ in
            let color: UIColor = issues.contains(n) ? .systemRed : .secondaryLabel
            let attrs: [NSAttributedString.Key: Any] = [.font: self.numberFont, .foregroundColor: color]
            let str = String(n) as NSString
            let size = str.size(withAttributes: attrs)
            let y = firstFrag.minY + insetTop - offsetY + (firstFrag.height - size.height) / 2
            let x = self.gutterWidth - 6 - size.width
            str.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        }

        // Hairline separating the gutter from the text, on the gutter's right edge.
        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.setStrokeColor(UIColor.separator.cgColor)
            ctx.setLineWidth(1.0 / (window?.screen.scale ?? 2))
            ctx.move(to: CGPoint(x: gutterWidth - 0.5, y: 0))
            ctx.addLine(to: CGPoint(x: gutterWidth - 0.5, y: bounds.height))
            ctx.strokePath()
        }
    }
}

/// A faint red full-width band drawn BEHIND the text on any line the coach flags as a problem. It is a
/// passive subview inserted below the text container (with a negative `zPosition` so it always renders
/// behind the glyphs) and pinned to the visible area like the gutter. Unlike the gutter's per-line
/// number, the band uses the line's FULL bounding rect, so a flagged line that soft-wraps onto several
/// rows is tinted across all of them. Draws nothing when the coach is clean.
final class LineHighlightView: UIView {
    weak var textView: GutterTextView?

    override func draw(_ rect: CGRect) {
        guard let tv = textView, let ctx = UIGraphicsGetCurrentContext() else { return }
        let issues = tv.issueLines
        if issues.isEmpty { return }
        let insetTop = tv.textContainerInset.top
        let offsetY = tv.contentOffset.y

        tv.forEachLineRect { n, firstFrag, fullBounds in
            guard issues.contains(n) else { return }
            let fill = UIColor.systemRed.withAlphaComponent(0.14)
            // Cover every wrapped row of the line; fall back to the first fragment if the bounding
            // rect is empty (e.g. a flagged blank line has no glyphs to bound).
            let band = fullBounds.height > 0 ? fullBounds : firstFrag
            let y = band.minY + insetTop - offsetY
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: self.bounds.width, height: band.height))
        }
    }
}

/// A UITextView subclass that carries a `LineNumberGutter` glued to its left edge. The gutter is a
/// subview kept pinned to the visible area (its frame origin tracks `contentOffset`) and redrawn on
/// every layout pass — which UIScrollView triggers on scroll — so the numbers scroll perfectly with
/// the text. The gutter's width grows with the line count (2 digits minimum, wider at 100+ lines),
/// and the text is inset to the right of it via `textContainerInset.left`.
final class GutterTextView: UITextView {
    private let gutter = LineNumberGutter()
    private let highlight = LineHighlightView()
    private var lastGutterWidth: CGFloat = -1

    /// 1-based line numbers the coach flags as problems, set by `RoboScriptEditor` from the live
    /// validator output. The gutter colors these numbers red and the highlight bands them; both read here.
    private(set) var issueLines: Set<Int> = []

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // Band goes behind the text (negative zPosition guarantees it regardless of subview order);
        // gutter numbers ride on top.
        highlight.textView = self
        highlight.backgroundColor = .clear
        highlight.isUserInteractionEnabled = false
        highlight.contentMode = .redraw
        highlight.layer.zPosition = -1
        insertSubview(highlight, at: 0)

        gutter.textView = self
        gutter.backgroundColor = .clear
        gutter.isUserInteractionEnabled = false
        gutter.contentMode = .redraw
        gutter.layer.zPosition = 1
        addSubview(gutter)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var gutterFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: (font?.pointSize ?? 15) * 0.85, weight: .regular)
    }

    private func computeGutterWidth() -> CGFloat {
        let s = text ?? ""
        let lineCount = s.isEmpty ? 1 : s.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let digits = max(2, String(lineCount).count)
        let charW = ("0" as NSString).size(withAttributes: [.font: gutterFont]).width
        return ceil(CGFloat(digits) * charW) + 12  // ~6pt padding on each side of the digits
    }

    /// Enumerate every real line as (1-based number, first-fragment rect, full bounding rect) in
    /// text-container space. The gutter uses the first fragment to place a number at the line's top
    /// row; the highlight uses the full bounding rect so a band covers all rows of a wrapped line.
    /// Shared so the two subviews can never disagree on where a line sits. A trailing blank line is
    /// emitted from the layoutManager's "extra" fragment (paragraph enumeration doesn't yield it).
    func forEachLineRect(_ body: @escaping (Int, CGRect, CGRect) -> Void) {
        let lm = layoutManager
        let tc = textContainer
        let s = (text ?? "") as NSString
        if s.length == 0 {
            let r = CGRect(x: 0, y: 0, width: 0, height: gutterFont.lineHeight)
            body(1, r, r)
            return
        }
        var lineNo = 1
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length),
                              options: [.byParagraphs, .substringNotRequired]) { _, paraRange, _, _ in
            let gr = lm.glyphRange(forCharacterRange: paraRange, actualCharacterRange: nil)
            var eff = NSRange()
            let frag = lm.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: &eff)
            let full = lm.boundingRect(forGlyphRange: gr, in: tc)
            body(lineNo, frag, full)
            lineNo += 1
        }
        if s.hasSuffix("\n") {
            let extra = lm.extraLineFragmentRect
            let h = extra.height > 0 ? extra.height : gutterFont.lineHeight
            let r = CGRect(x: extra.minX, y: extra.minY, width: extra.width, height: h)
            body(lineNo, r, r)
        }
    }

    /// Update the flagged-line set and redraw the gutter + band only if it actually changed.
    /// Positions don't move, so this is a repaint (setNeedsDisplay), not a relayout.
    func setIssueLines(_ lines: Set<Int>) {
        guard lines != issueLines else { return }
        issueLines = lines
        gutter.setNeedsDisplay()
        highlight.setNeedsDisplay()
    }

    override func layoutSubviews() {
        // Set the text inset BEFORE super so the layoutManager positions text for the new width.
        // Guarded so it only changes when the digit count actually changes — otherwise every scroll
        // would dirty layout and loop.
        let w = computeGutterWidth()
        if w != lastGutterWidth {
            lastGutterWidth = w
            textContainerInset.left = w + 4
        }
        super.layoutSubviews()
        // Both overlays are pinned to the visible area and redraw with the current scroll offset.
        highlight.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: bounds.width, height: bounds.height)
        highlight.setNeedsDisplay()
        gutter.gutterWidth = w
        gutter.numberFont = gutterFont
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: w, height: bounds.height)
        gutter.setNeedsDisplay()
    }

    /// Force a gutter/band refresh after a text change that may not itself trigger layout (e.g. an
    /// edit that doesn't change content size). Cheap: schedules one layout pass.
    func refreshGutter() { setNeedsLayout() }
}

/// A UITextView-backed editor for RoboRunner scripts. It replaces SwiftUI's TextEditor so we can
/// (Stage 2) add a line-number gutter and error-line highlighting — things TextEditor cannot do.
/// Stage 1 was a behavior-preserving drop-in: two-way text binding, monospaced font, dim-when-disabled,
/// a focus binding (replacing @FocusState), and a UIKit input-accessory toolbar carrying Clear + Done
/// (a SwiftUI `.keyboard` toolbar won't attach to a UITextView). Smart dashes/quotes are OFF so the
/// keyboard can't turn "--" into an em dash or "" into curly quotes inside a script. Stage 2a added the
/// line-number gutter via the `GutterTextView` subclass; Stage 2b feeds it the coach's flagged lines so
/// problem lines show red in the gutter with a faint band behind them.
struct RoboScriptEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var isEditable: Bool
    var issueLines: Set<Int>
    var onClear: () -> Void

    func makeUIView(context: Context) -> GutterTextView {
        let tv = GutterTextView(frame: .zero, textContainer: nil)
        tv.delegate = context.coordinator
        tv.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.inputAccessoryView = context.coordinator.accessory
        tv.text = text
        tv.setIssueLines(issueLines)
        return tv
    }

    func updateUIView(_ tv: GutterTextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text { tv.text = text; tv.refreshGutter() }
        tv.isEditable = isEditable
        tv.alpha = isEditable ? 1.0 : 0.6
        tv.setIssueLines(issueLines)
        if focused, isEditable, !tv.isFirstResponder { tv.becomeFirstResponder() }
        if !focused, tv.isFirstResponder { tv.resignFirstResponder() }
        context.coordinator.setClearEnabled(!text.isEmpty)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RoboScriptEditor
        let accessory = UIToolbar()
        private var clearItem: UIBarButtonItem!

        init(_ parent: RoboScriptEditor) {
            self.parent = parent
            super.init()
            clearItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearTapped))
            let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            // .prominent is the iOS 26 rename of the old .done style (bold dismiss affordance).
            let doneItem = UIBarButtonItem(title: "Done", style: .prominent, target: self, action: #selector(doneTapped))
            accessory.items = [clearItem, flex, doneItem]
            accessory.sizeToFit()
        }

        func setClearEnabled(_ enabled: Bool) { clearItem.isEnabled = enabled }

        @objc private func clearTapped() { parent.onClear() }
        @objc private func doneTapped() { parent.focused = false }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            (tv as? GutterTextView)?.refreshGutter()
        }
        func textViewDidBeginEditing(_ tv: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ tv: UITextView) { parent.focused = false }
    }
}

/// The RoboRunner script editor sheet.
struct RoboEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @ObservedObject private var robo = RoboRunner.shared
    @AppStorage("lab.roboScript") private var script: String = RoboEditorView.sampleScript
    @State private var showingHelp = false
    @State private var showingResults = false
    @State private var showingIssues = false
    // Wand-in-field: draft a script FROM the editor's own text (your description), replacing it in
    // place — replaces the old separate Draft sheet. `preDraftText` stashes the pre-change text so a
    // single Undo restores it — used by BOTH the wand and Clear, so neither can silently eat your
    // work. `undoFromDraft` distinguishes the two so the status line says the right thing.
    @State private var generatingDraft = false
    @State private var preDraftText: String? = nil
    @State private var undoFromDraft = false
    // Confirm before the wand clobbers text that already looks like a real script (see draftFromField).
    @State private var showingDraftOverwriteConfirm = false
    // Editor focus — drives the input-accessory Done (dismiss the keyboard without closing the
    // sheet) and hides the status bar while typing. A plain @State so it can bind into the
    // UIViewRepresentable editor (which can't take a @FocusState).
    @State private var editorFocused = false

    static let sampleScript = """
    # RoboRunner script. Most lines are antenna verbs, passed straight through.
    # ASK <question>  runs one real two-phase turn and captures it.
    # WAIT <seconds>  pauses (longer if the phone is hot). '#' starts a comment.
    SWITCH_MODEL:mlx-community/Qwen3.5-2B-MLX-4bit
    ASK What is two plus two? Answer in one word.
    WAIT 5
    ASK Name a primary color. One word.

    # Sweep: repeat a block once per value, substituting {{VAR}} each pass.
    # (Double braces = a placeholder; a single brace is just literal text.)
    # Uncomment to see the same question at three temperatures, compared:
    # FOR TEMP IN 0.2, 0.6, 1.0
    #     SET_TEMPERATURE:{{TEMP}}
    #     ASK In one sentence, what is a good name for a pet fox?
    # END
    """

    private var stepCount: Int {
        script.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
    }

    /// Live pre-flight, recomputed as the script changes — the coach. Cheap for editor-sized
    /// scripts (a couple of linear passes), and it uses the SAME validator run() enforces with,
    /// so what the editor shows and what run() refuses can never drift apart.
    private var liveIssues: [RoboIssue] {
        RoboValidator.validate(script, knownModelIDs: RoboRunner.currentKnownModelIDs())
    }
    private var liveIssueCount: Int { liveIssues.count }

    // The coach's flagged lines, fed to the editor's gutter (drawn red). Only line-specific issues
    // highlight; whole-script issues (line 0) still surface in the Check sheet.
    private var issueLines: Set<Int> { Set(liveIssues.filter { $0.line > 0 }.map { $0.line }) }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                RoboScriptEditor(
                    text: $script,
                    focused: $editorFocused,
                    isEditable: !(robo.isRunning || generatingDraft),
                    issueLines: issueLines,
                    onClear: { clearField() }
                )

                // Hidden while the keyboard is up: the keyboard toolbar (Clear/Done) occupies that
                // space, and showing the status bar too made them visually collide. The validation
                // feedback returns the moment the keyboard is dismissed.
                if !editorFocused {
                    statusBar
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("RoboRunner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if robo.isRunning {
                        Button(role: .destructive) { robo.requestStop() } label: {
                            Image(systemName: "stop.fill")
                        }
                        .accessibilityLabel("Stop")
                    } else {
                        // Disabled while the script has any problem — the coach won't let a
                        // known-bad script run. (run() also refuses, so this is belt-and-braces.)
                        // A play glyph: universal "run" affordance, on the trailing (take-action) side.
                        Button(action: runScript) { Image(systemName: "play.fill") }
                            .disabled(liveIssueCount > 0)
                            .accessibilityLabel("Run")
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showingHelp = true } label: { Label("Commands", systemImage: "list.bullet.rectangle") }
                    Spacer()
                    // Wand: draft a script FROM whatever's in the editor (your plain-language
                    // description), replacing it in place — the old text is stashed for one-tap Undo.
                    // Disabled when the editor is empty or a draft/run is already in flight.
                    Button { draftFromField() } label: { Label("Draft", systemImage: "wand.and.stars") }
                        .disabled(script.trimmingCharacters(in: .whitespaces).isEmpty || generatingDraft || robo.isRunning)
                    Spacer()
                    // The coach: validate WITHOUT running. Icon reflects the live state so a
                    // glance tells you if the script is clean before you ever hit Run.
                    Button { showingIssues = true } label: {
                        Label("Check", systemImage: liveIssueCount > 0 ? "exclamationmark.triangle.fill"
                              : "checkmark.seal")
                    }
                    Spacer()
                    // Always enabled: the Results sheet is the run HISTORY, which can hold runs
                    // from earlier sessions even before anything runs this session.
                    Button { showingResults = true } label: { Label("Results", systemImage: "doc.text.magnifyingglass") }
                }
                // Clear/Done now live in RoboScriptEditor's input-accessory toolbar (above the
                // keyboard), because a SwiftUI .keyboard toolbar won't attach to a UITextView.
            }
            .sheet(isPresented: $showingHelp) { RoboHelpView(onInsert: { appendToScript($0) }) }
            .sheet(isPresented: $showingResults) { RoboResultsView() }
            .sheet(isPresented: $showingIssues) { RoboIssuesView(issues: liveIssues) }
            // Antenna bridge: SET_UI_STATE:roboissues drives apiNavRoboIssues -> the Check sheet, so
            // the coach's problem list can be screenshot/verified without a human tapping Check.
            .onChange(of: chatViewModel.apiNavRoboIssues) { _, open in showingIssues = open }
            .onChange(of: showingIssues) { _, open in
                if !open { chatViewModel.apiNavRoboIssues = false }
            }
            .alert("This already looks like a script", isPresented: $showingDraftOverwriteConfirm) {
                Button("Draft anyway") { performDraft() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The wand treats the editor text as a description and replaces it. Draft a new one from it anyway?")
            }
        }
    }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 8) {
            statusLabel
            // One-tap Undo, shown after a wand draft until it's used or the next draft. Restores the
            // exact text that was in the editor before the wand replaced it.
            if preDraftText != nil && !robo.isRunning && !generatingDraft {
                Spacer()
                Button { undoDraft() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        if generatingDraft {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("I'm drafting this for you…").foregroundColor(.secondary)
            }
        } else if robo.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running \(robo.progress)").foregroundColor(.secondary)
            }
        } else if let err = robo.lastError, !err.isEmpty {
            Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
        } else if liveIssueCount > 0 {
            Label("\(liveIssueCount) problem\(liveIssueCount == 1 ? "" : "s") — tap Check to see them",
                  systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
        } else if preDraftText != nil && undoFromDraft {
            Label("I drafted this for you. Edit or run it when you're ready.", systemImage: "wand.and.stars")
                .foregroundColor(.secondary)
        } else if preDraftText != nil {
            Label("Cleared. Tap Undo to restore.", systemImage: "trash").foregroundColor(.secondary)
        } else {
            Label("\(stepCount) step\(stepCount == 1 ? "" : "s") ready", systemImage: "checkmark.seal")
                .foregroundColor(.secondary)
        }
    }

    /// Draft a script FROM the editor's current text (treated as a plain-language description),
    /// replacing it in place. Stashes the previous text for Undo. Uses the SAME validated generator
    /// the old Draft sheet used; the live Check coach then validates whatever lands.
    private func draftFromField() {
        let desc = script.trimmingCharacters(in: .whitespaces)
        guard !desc.isEmpty, !generatingDraft, !robo.isRunning else { return }
        // Light guard: if the field already holds a CLEAN, multi-step script, the wand would treat
        // that script as a description and produce nonsense. Confirm before clobbering it. A single
        // line (a typical description) or anything that doesn't validate drafts directly.
        if liveIssueCount == 0 && stepCount >= 2 {
            showingDraftOverwriteConfirm = true
            return
        }
        performDraft()
    }

    /// The actual draft: generate a script from the field text and replace it in place, stashing the
    /// previous text for Undo. Called directly for a description, or from the overwrite confirm.
    private func performDraft() {
        let previous = script
        let vm = chatViewModel
        generatingDraft = true
        Task { @MainActor in
            let draft = await RoboScriptGenerator.draft(
                from: script.trimmingCharacters(in: .whitespaces),
                knownModelIDs: RoboRunner.currentKnownModelIDs()
            ) { system, user in
                try await vm.llmService.generateChatResponse(
                    messages: [.system(system), .user(user)], temperature: 0.2)
            }
            preDraftText = previous
            undoFromDraft = true
            script = draft.script
            generatingDraft = false
        }
    }

    /// Restore the text the last change (wand draft OR Clear) replaced, and clear the stash.
    private func undoDraft() {
        guard let previous = preDraftText else { return }
        script = previous
        preDraftText = nil
        undoFromDraft = false
    }

    /// Empty the editor, stashing the current text so Undo can restore it (Clear can't eat your
    /// work either). Marked not-a-draft so the status line reads "Cleared" rather than "I drafted…".
    private func clearField() {
        guard !script.isEmpty else { return }
        preDraftText = script
        undoFromDraft = false
        script = ""
        // Drop the keyboard so the "Cleared. Tap Undo to restore." status + Undo button are
        // immediately visible (otherwise the keyboard hides them and Clear looks un-undoable).
        editorFocused = false
    }

    /// Append an inserted command usage or template to the END of the script, keeping exactly one
    /// newline between steps. Append-at-end is the MVP: SwiftUI's TextEditor exposes no caret
    /// position, so cursor-accurate insertion waits for the future UITextView editor (the same
    /// lift the planned as-you-type autocomplete needs). The user can still drag the inserted
    /// line where they want it in the editor.
    private func appendToScript(_ snippet: String) {
        if script.isEmpty {
            script = snippet
        } else if script.hasSuffix("\n") {
            script += snippet
        } else {
            script += "\n" + snippet
        }
    }

    private func runScript() {
        let vm = chatViewModel
        let text = script
        // MainActor Task so RoboRunner's @Published status updates land on the main thread,
        // matching the antenna's ROBO_RUN path.
        Task { @MainActor in _ = await RoboRunner.shared.run(script: text, vm: vm, console: vm.testConsole) }
    }
}

/// The coach's report card: every problem the validator found, each with its source line. Read-only
/// (the fix happens back in the editor), reachable any time from the editor's Check button so a script
/// can be validated WITHOUT running it — the whole point of "help people write scripts and validate
/// them before they run." Every problem blocks the run; there is no error/warning distinction.
struct RoboIssuesView: View {
    @Environment(\.dismiss) private var dismiss
    let issues: [RoboIssue]

    var body: some View {
        NavigationView {
            Group {
                if issues.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundColor(.green)
                        Text("No problems found").font(.headline)
                        Text("Balanced FOR/END, known verbs, valid model IDs, and every {{VAR}} bound to a FOR. Safe to run.")
                            .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        Section("Problems — the script won't run until these are fixed") {
                            ForEach(issues) { issueRow($0) }
                        }
                    }
                }
            }
            .navigationTitle("Script Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private func issueRow(_ issue: RoboIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message).font(.callout)
                Text(issue.line > 0 ? "Line \(issue.line)" : "Whole script")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The command catalog, shown in the editor's Help. A searchable, sectioned list rather than one
/// flat blob: one collapsible-feeling Section per category, each verb its own row (verb, args,
/// summary, and a red [!] badge for destructive). All data comes from CommandCatalog.all.
struct RoboHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// When set, each row gets an Add (+) button that inserts that command's usage (or a
    /// template's text) into the editor's script. nil = pure read-only reference. The editor is
    /// the only caller today and always passes this, so insertion is the normal mode.
    var onInsert: ((String) -> Void)? = nil

    /// Lightweight running feedback. The Commands sheet is full-screen, so building a script from
    /// it would otherwise be blind — this strip confirms each insert landed and counts them.
    @State private var lastInserted: String? = nil
    @State private var insertedCount = 0

    /// Multi-line scaffolds for the structures people get wrong (an unbalanced FOR/END was the
    /// motivating bug). Insert-only — meaningless as reference — so shown only when onInsert is
    /// set. Each is chosen to validate CLEAN on insert (real verbs, valid values, balanced
    /// FOR/END) so a fresh insert never lands with an immediate error.
    private static let templates: [(title: String, snippet: String)] = [
        ("Sweep (FOR … END)", """
        FOR TEMP IN 0.2, 0.6, 1.0
            SET_TEMPERATURE:{{TEMP}}
            ASK In one sentence, what is a good name for a pet fox?
        END
        """),
        ("Ask a question", "ASK <your question here>"),
        ("Compare models", """
        FOR MODEL IN apple-foundation-models
            SWITCH_MODEL:{{MODEL}}
            ASK In one sentence, introduce yourself.
        END
        """),
    ]

    /// Categories that have at least one matching verb, each with its filtered, sorted verbs.
    /// Sourced from `visible` (not `all`) so a release build never offers a developer-only verb
    /// to insert into a script the shipped interpreter wouldn't advertise.
    private var sections: [(CommandCategory, [CommandDescriptor])] {
        CommandCategory.allCases.compactMap { category in
            let items = CommandCatalog.visible
                .filter { $0.category == category }
                .filter { d in
                    search.isEmpty
                        || d.verb.localizedCaseInsensitiveContains(search)
                        || d.summary.localizedCaseInsensitiveContains(search)
                }
                .sorted { $0.verb < $1.verb }
            return items.isEmpty ? nil : (category, items)
        }
    }

    private var filteredTemplates: [(title: String, snippet: String)] {
        guard onInsert != nil else { return [] }
        guard !search.isEmpty else { return Self.templates }
        return Self.templates.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.snippet.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationView {
            List {
                if !filteredTemplates.isEmpty {
                    Section("Templates") {
                        ForEach(filteredTemplates, id: \.title) { t in templateRow(t) }
                    }
                }
                ForEach(sections, id: \.0) { category, items in
                    Section(category.rawValue) {
                        ForEach(items) { d in commandRow(d) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search commands")
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { addedBanner }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// Transient "Added VERB — N inserted" strip, shown once something has been inserted, so the
    /// full-screen sheet stays honest about what's accumulating in the script behind it.
    @ViewBuilder private var addedBanner: some View {
        if let last = lastInserted {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Added \(last)").fontWeight(.medium)
                Spacer()
                Text("\(insertedCount) inserted").foregroundColor(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial)
        }
    }

    private func insert(_ snippet: String, label: String) {
        onInsert?(snippet)
        lastInserted = label
        insertedCount += 1
    }

    @ViewBuilder private func templateRow(_ t: (title: String, snippet: String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.subheadline).fontWeight(.semibold)
                Text(t.snippet)
                    .font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                    .lineLimit(5)
            }
            Spacer(minLength: 0)
            addButton { insert(t.snippet, label: t.title) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func commandRow(_ d: CommandDescriptor) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.verb)
                        .font(.system(.subheadline, design: .monospaced)).fontWeight(.semibold)
                    if let args = d.args {
                        Text(args)
                            .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if d.destructive {
                        Text("!")
                            .font(.caption2).fontWeight(.bold).foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                    }
                }
                Text(d.summary).font(.caption).foregroundColor(.secondary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            if onInsert != nil { addButton { insert(d.usage, label: d.verb) } }
        }
        .padding(.vertical, 2)
    }

    /// The explicit insert affordance — a filled "+" so "add this to my script" reads distinctly
    /// from selecting/copying the row text. `.borderless` so the tap hits only the button, not
    /// the whole List row.
    @ViewBuilder private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Add to script")
    }
}

/// The run history: a list of past runs (newest first), each opening a detail view with a
/// card / raw-JSON toggle and a Share button. Reads the robo_results_*.json files on appear.
struct RoboResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [RoboRunSummary] = []

    var body: some View {
        NavigationView {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Run a script and its results are saved here."))
                } else {
                    List(runs) { run in
                        NavigationLink { RoboRunDetailView(run: run) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.title).font(.subheadline).fontWeight(.medium).lineLimit(2)
                                Text(subtitle(run)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Past Runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { runs = RoboRunner.shared.pastRuns() }
        }
    }

    private func subtitle(_ run: RoboRunSummary) -> String {
        let turns = "\(run.askCount) turn\(run.askCount == 1 ? "" : "s")"
        return run.dateLabel.isEmpty ? turns : "\(turns)  ·  \(run.dateLabel)"
    }
}

/// One run in detail: the script at the top, then a card per captured turn (question, thinking,
/// answer, and the timing / thermal metrics), with a toggle to the raw JSON and a Share button
/// that hands the run's .json file to the iOS share sheet.
struct RoboRunDetailView: View {
    let run: RoboRunSummary
    @State private var showRawJSON = false
    @State private var showingShare = false

    var body: some View {
        Group {
            if showRawJSON {
                ScrollView {
                    Text(prettyJSON)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !run.run.script.isEmpty { scriptCard }
                        ForEach(run.run.results, id: \.index) { turnCard($0) }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: $showRawJSON) { Label("Raw JSON", systemImage: "curlybraces") }
                    Button { showingShare = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showingShare) {
            RoboShareSheet(activityItems: [URL(fileURLWithPath: run.path)])
        }
    }

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SCRIPT").font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
            Text(run.run.script)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.08)))
    }

    @ViewBuilder private func turnCard(_ r: RoboStepResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Turn \(r.index + 1)").font(.caption).fontWeight(.semibold)
                Spacer()
                Text(r.model).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            field("Question", r.question)
            if !r.thinking.isEmpty { field("Thinking", r.thinking) }
            field("Answer", r.answer)
            Text(metrics(r)).font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2).foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metrics(_ r: RoboStepResult) -> String {
        var parts = [String(format: "%.1fs", r.seconds)]
        if r.phase1Seconds > 0 || r.phase2Seconds > 0 {
            parts.append(String(format: "think %.1fs / answer %.1fs", r.phase1Seconds, r.phase2Seconds))
        }
        parts.append("budget \(r.reasonBudget)")
        parts.append("thermal \(r.thermalBefore)→\(r.thermalAfter)")
        return parts.joined(separator: "  ·  ")
    }

    /// Pretty-print the run's file for the raw-JSON view. Falls back to the file text as-is.
    private var prettyJSON: String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: run.path)),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8) else {
            return (try? String(contentsOfFile: run.path, encoding: .utf8)) ?? "{}"
        }
        return s
    }
}

/// Minimal UIActivityViewController bridge for the results Share button. Named distinctly from
/// the app's other (nested) ShareSheet so this file stays self-contained.
struct RoboShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
// ==== LEGO END: 61 RoboEditor (Lab UI, on-device RoboRunner script editor) ====
