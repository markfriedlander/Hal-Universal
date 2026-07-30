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
//  {VAR} each pass (e.g. sweep temperature or model over the same question). The
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

    // MARK: - Entry point

    /// Parse and run `script`. Returns a short human-readable summary. Dispatches
    /// non-ASK/WAIT lines through the shared `console` so the full antenna verb
    /// vocabulary is available with no duplication.
    func run(script: String, vm: ChatViewModel, console: HalTestConsole) async -> String {
        if isRunning { return "RoboRunner already running (\(progress))" }
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
        expandLoops(rawSteps, into: &steps)
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
    static let maxExpandedSteps = 2000

    /// Expand `FOR <VAR> IN a, b, c` / `END` blocks into a flat step list, substituting `{VAR}`
    /// with each value in turn. Bounded ON PURPOSE: it repeats a written block over a written
    /// list, with no conditions and no open-ended looping, so a script can neither run away nor
    /// branch (that keeps the Lab's "fixed verbs, not arbitrary code" posture). Nesting works via
    /// recursion (an inner loop expands once per outer value). Appends into `out`, stopping at
    /// `maxExpandedSteps`.
    private func expandLoops(_ lines: [String], into out: inout [String]) {
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
    private func parseForHeader(_ line: String) -> (String, [String])? {
        let afterFor = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)  // drop "FOR"
        guard let inRange = afterFor.range(of: " IN ", options: [.caseInsensitive]) else { return nil }
        let varName = String(afterFor[..<inRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let values = String(afterFor[inRange.upperBound...])
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !varName.isEmpty, !values.isEmpty else { return nil }
        return (varName, values)
    }

    /// Replace `{VAR}` (case-insensitive on the name, braces literal) with `value`.
    private func substitute(_ line: String, varName: String, value: String) -> String {
        line.replacingOccurrences(of: "{\(varName)}", with: value, options: [.caseInsensitive])
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
struct CommandDescriptor: Identifiable {
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

enum CommandCatalog {

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

        // RoboRunner Automation
        CommandDescriptor(verb: "ROBO_RUN", args: "<script>", summary: "Run an on-device RoboRunner script. Advanced, a script can issue any verb, including destructive ones.", category: .automation, destructive: true),
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
// ==== LEGO END: 60 CommandCatalog (Lab Command Surface, Single Source of Truth) ====


// ==== LEGO START: 61 RoboEditor (Lab UI, on-device RoboRunner script editor) ====
//
// The in-app face of RoboRunner: write a script, Run/Stop it, watch live status, read the
// captured results, and browse the command catalog (Help). Modeled on SystemPromptEditorView.
// Reached from a "Developer" row in Settings (ActionsView). Ships as a user-facing opt-in.
// v1 persists a single script via @AppStorage; multi-file save/load is a follow-up.

/// The RoboRunner script editor sheet.
struct RoboEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @ObservedObject private var robo = RoboRunner.shared
    @AppStorage("lab.roboScript") private var script: String = RoboEditorView.sampleScript
    @State private var showingHelp = false
    @State private var showingResults = false

    static let sampleScript = """
    # RoboRunner script. Most lines are antenna verbs, passed straight through.
    # ASK <question>  runs one real two-phase turn and captures it.
    # WAIT <seconds>  pauses (longer if the phone is hot). '#' starts a comment.
    SWITCH_MODEL:mlx-community/Qwen3.5-2B-MLX-4bit
    ASK What is two plus two? Answer in one word.
    WAIT 5
    ASK Name a primary color. One word.

    # Sweep: repeat a block once per value, substituting {VAR} each pass.
    # Uncomment to see the same question at three temperatures, compared:
    # FOR TEMP IN 0.2, 0.6, 1.0
    #     SET_TEMPERATURE:{TEMP}
    #     ASK In one sentence, what is a good name for a pet fox?
    # END
    """

    private var stepCount: Int {
        script.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $script)
                    .font(.system(.callout, design: .monospaced))
                    .padding(8)
                    .disabled(robo.isRunning)
                    .opacity(robo.isRunning ? 0.6 : 1.0)

                statusBar
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("RoboRunner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if robo.isRunning {
                        Button("Stop", role: .destructive) { robo.requestStop() }
                    } else {
                        Button("Run", action: runScript).fontWeight(.semibold)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showingHelp = true } label: { Label("Commands", systemImage: "list.bullet.rectangle") }
                    Spacer()
                    // Always enabled: the Results sheet is the run HISTORY, which can hold runs
                    // from earlier sessions even before anything runs this session.
                    Button { showingResults = true } label: { Label("Results", systemImage: "doc.text.magnifyingglass") }
                }
            }
            .sheet(isPresented: $showingHelp) { RoboHelpView() }
            .sheet(isPresented: $showingResults) { RoboResultsView() }
        }
    }

    @ViewBuilder private var statusBar: some View {
        if robo.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running \(robo.progress)").foregroundColor(.secondary)
            }
        } else if let err = robo.lastError, !err.isEmpty {
            Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
        } else {
            Text("\(stepCount) step\(stepCount == 1 ? "" : "s") ready").foregroundColor(.secondary)
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

/// The command catalog, shown in the editor's Help. A searchable, sectioned list rather than one
/// flat blob: one collapsible-feeling Section per category, each verb its own row (verb, args,
/// summary, and a red [!] badge for destructive). All data comes from CommandCatalog.all.
struct RoboHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// Categories that have at least one matching verb, each with its filtered, sorted verbs.
    private var sections: [(CommandCategory, [CommandDescriptor])] {
        CommandCategory.allCases.compactMap { category in
            let items = CommandCatalog.all
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

    var body: some View {
        NavigationView {
            List {
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private func commandRow(_ d: CommandDescriptor) -> some View {
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
        .padding(.vertical, 2)
        .textSelection(.enabled)
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
