//
//  RoboRunner.swift
//  Hal Universal
//
//  On-device script runner for reasoning/thermal experiments. DEBUG-only.
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
//  NEW_THREAD all work for free. Only two steps are special because the flat verb
//  model cannot express them: ASK (run one real turn and capture BOTH phases plus
//  thermal), and WAIT (pause, holding longer if the phone is hot). Comments start
//  with '#'. That is the whole language.
//
//  See Docs/Reasoning_Quality_Thermal_Test_Plan_2026-07-22.md.
//

#if DEBUG

import Foundation
import Combine

// ==== LEGO START: 62 RoboRunner (On-Device Reasoning/Thermal Script Runner) ====

/// DEBUG-only side channel for GRANULAR per-phase data a single turn cannot expose
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

/// DEBUG-only. Runs a RoboRunner script on-device. `@MainActor` because every step
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

    private var results: [RoboStepResult] = []
    private var currentModel = "unknown"

    /// True while a script is executing, so callers can refuse to start a second.
    var busy: Bool { isRunning }

    // MARK: - Entry point

    /// Parse and run `script`. Returns a short human-readable summary. Dispatches
    /// non-ASK/WAIT lines through the shared `console` so the full antenna verb
    /// vocabulary is available with no duplication.
    func run(script: String, vm: ChatViewModel, console: HalTestConsole) async -> String {
        if isRunning { return "RoboRunner already running (\(progress))" }
        isRunning = true
        lastError = nil
        results = []
        currentModel = "unknown"

        let steps = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let askTotal = steps.filter { $0.uppercased().hasPrefix("ASK ") }.count
        var askDone = 0
        progress = "0/\(askTotal)"
        halLog("HALDEBUG-ROBO: run start — \(steps.count) steps, \(askTotal) asks")

        for step in steps {
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
        let summary = "RoboRunner done — \(results.count) turns captured → \(lastResultsPath ?? "(write failed)")"
        halLog("HALDEBUG-ROBO: \(summary)")
        return summary
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
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        await coolIfHot()
    }

    /// Block until thermalState is nominal/fair, or a safety cap (5 min) elapses.
    private func coolIfHot() async {
        var capped = 0
        while capped < 300 {
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
        // Stable filename per run (set once, on the first write of this run).
        if lastResultsPath == nil {
            let stamp = Int(Date().timeIntervalSince1970)
            lastResultsPath = dir.appendingPathComponent("robo_results_\(stamp).json").path
        }
        guard let path = lastResultsPath else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(results)
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
}

// ==== LEGO END: 62 RoboRunner (On-Device Reasoning/Thermal Script Runner) ====

#endif
