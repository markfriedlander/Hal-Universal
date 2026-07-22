// ==== LEGO START: 61 ThermalGovernor (Proactive Thermal Pacing) ====
// ThermalGovernor.swift
// Hal Universal
//
// Proactive thermal pacing for on-device MLX generation.
//
// **Why.** ALL generation heats the chip. Every token is GPU/ANE work at
// near-100% duty, so the heat is a property of *generation itself*, not of any
// one failure mode. A long or heavy conversation is many back-to-back
// generations, and that sustained load is what drives the device toward thermal
// throttling, the standing risk that grows with use, independent of what the
// model happens to be saying. So the fix is to pace generation itself so the
// chip never pegs. (Runaway-repetition loops are a *separate* concern and are
// already bounded by the two-phase reasoning design plus the output-token
// hammer; a hot run may make a loop more likely, but loops are not what this
// governor is for. It is for the heat of ordinary heavy use.)
//
// **Invisible until it warms.** Cold is the common case (real conversations have
// natural gaps that keep the chip cool), so at .nominal we do NOTHING, full
// speed, zero cost. That is the whole point: the normal experience must never be
// touched. Pacing appears only as the chip warms, and scales with pressure:
//   - .fair     — a gentle, near-imperceptible yield to SLOW the climb (buy time).
//   - .serious  — a firmer back-off, and Hal says so in character (see below).
//                 This tier is the real backstop; .fair is only meant to delay.
//   - .critical — hold generation entirely until it cools.
// The one time the user notices anything, the device is genuinely hot, and an
// honest "I'm running warm" beats a silent throttle. (A measured stress run,
// 2026-07-21, showed even a small yield meaningfully slows the climb; it does not
// hold the line alone, which is why .serious is the backstop, not .fair.)
//
// Ported from Posey's `ThermalGovernor` (Services/ThermalGovernor.swift), which
// was built after sustained indexing overheated the device on 2026-06-18 (no
// damage, thermal throttling). Same class of problem, same proven cure. The
// graduated yield values below are Posey's
// starting numbers; generation is finer-grained than Posey's per-embed-chunk
// pacing, so the cadence (pace per output-chunk, and these nanosecond values)
// is the one thing to device-tune for text generation.
//
// **Where it's called.** `pace()` is awaited at each generation-chunk boundary
// in the MLX stream loop, so a long response self-throttles before it cooks the
// phone. It honors `Task` cancellation so a user stop / cancel is never delayed
// behind a cooldown sleep.
//
// **In-character surface.** `snapshot()` exposes the current thermal state, the
// same reading that feeds Hal's in-character "I'm running hot, let me slow down"
// behavior. The pacing and the personality moment come from one source.
//
// **Testability.** A DEBUG-only injected state lets the .serious / .critical
// backoff + hold paths be exercised off-device (via the harness) without ever
// heating real hardware, you cannot, and must not, deliberately overheat the
// phone to test.

import Foundation

actor ThermalGovernor {

    static let shared = ThermalGovernor()

    /// Internal (not private) so a future `@testable` unit test can construct a
    /// fresh, isolated instance. Production uses `.shared`.
    init() {}

    // MARK: Thermal source (+ test injection)

    #if DEBUG
    /// Test-only override of the OS thermal state. Actor-isolated (set via
    /// `setDebugThermalState`) so reads/writes serialize cleanly with `pace()`.
    /// Lets the harness drive the backoff/hold paths without real heat.
    private var debugThermalState: ProcessInfo.ThermalState?
    func setDebugThermalState(_ state: ProcessInfo.ThermalState?) {
        debugThermalState = state
    }
    #endif

    private func currentState() -> ProcessInfo.ThermalState {
        #if DEBUG
        if let injected = debugThermalState { return injected }
        #endif
        return ProcessInfo.processInfo.thermalState
    }

    /// Current thermal state, for the in-character "cooling down" surface and
    /// diagnostics. Cheap; safe to poll.
    func snapshot() -> ProcessInfo.ThermalState { currentState() }

    // MARK: Pacing policy (tunable; device-tune for generation cadence)

    /// Graduated yield ABOVE nominal only (nominal = zero, handled in `pace()`).
    /// `.fair` gently slows the climb; `.serious` backs off harder; `.critical`
    /// doesn't sleep a fixed amount, it holds and re-checks until the device
    /// drops back to `.fair`.
    private static let fairYieldNanos:       UInt64 =  60_000_000   // 60ms
    private static let seriousCooldownNanos: UInt64 = 250_000_000   // 250ms
    private static let criticalRecheckNanos: UInt64 = 1_000_000_000 // 1s

    /// Pace one generation-chunk boundary. Sleeps proportionally to thermal
    /// pressure; at `.critical`, loop-waits (re-checking) until the state drops
    /// back to `.nominal`/`.fair`. Returns promptly if the Task is cancelled
    /// (user stop / cancel) so a halt is never stuck behind a cooldown.
    func pace() async {
        // NOTE: the SET_THERMAL_PACING off-switch is checked at the CALL SITE
        // (in the generation loop's own isolation), not here, so this actor never
        // reaches across into the main-actor-isolated ReasoningTuning singleton.
        if Task.isCancelled { return }
        switch currentState() {
        case .nominal:
            // Cold: zero pacing cost — full speed. The common case is untouched.
            break
        case .fair:
            try? await Task.sleep(nanoseconds: Self.fairYieldNanos)
        case .serious:
            try? await Task.sleep(nanoseconds: Self.seriousCooldownNanos)
        case .critical:
            // Hold generation entirely until the device cools. Re-check on a
            // slow cadence; bail immediately if cancelled.
            while !Task.isCancelled {
                let state = currentState()
                if state == .nominal || state == .fair { break }
                try? await Task.sleep(nanoseconds: Self.criticalRecheckNanos)
            }
        @unknown default:
            try? await Task.sleep(nanoseconds: Self.fairYieldNanos)
        }
    }
}

// ==== LEGO END: 61 ThermalGovernor (Proactive Thermal Pacing) ====
