// ProcessMemoryGuard.swift
// Hal Universal
//
// iOS process-memory introspection and load-time headroom waiting.
// Created 2026-05-18 to address Item 11: Gemma jetsam crash during
// model swap (see NEXT.md / HISTORY.md 2026-05-18).
//
// Background:
//
// During the Phase 2 live test, switching from Qwen 3.5 2B (loaded
// with heavy chat context) to Gemma 4 E2B (3.4 GB) jetsam-killed Hal
// mid-load. The MLX→MLX swap path correctly calls unloadModel() +
// MLX.Memory.clearCache() before the new load, but iOS doesn't drop
// the freed pages instantly — Mach VM reclamation is lazy. A fixed
// 500 ms settle in the swap path was empirical and insufficient
// under heavy prior load.
//
// Two-pronged fix lives in this file:
//
//   1. Pre-flight refusal. Before LLMModelFactory.shared.loadContainer
//      runs (which mmaps the safetensors and faults pages), we check
//      `os_proc_available_memory()` against the model's estimated
//      requirement. If insufficient, we surface a user-facing error
//      instead of letting iOS terminate the process for jetsam.
//
//   2. Headroom poll. Replaces the fixed 500 ms swap-settle with a
//      poll on `os_proc_available_memory()` every ~150 ms for up to
//      `timeoutSeconds`. Returns as soon as the target is met, or on
//      timeout (which the caller can either treat as fatal or pass
//      through to the pre-flight check).
//
// `os_proc_available_memory()` reports bytes remaining before the
// process hits its current dirty-memory limit. It is iOS-only
// (API_UNAVAILABLE(macos)); since Hal's iPhone target is the only
// build that loads MLX models, this lives behind `#if !os(macOS)`
// for safety in case future targets change.
//
// Required-memory formula (`requiredMemoryMBForLoad`):
//
//   sizeGB × 1024 × 0.75 + 250
//
// where:
//   - 0.75 ≈ effective dirty-memory ratio for 4-bit quantized
//     safetensors loaded via mmap. Empirical: Qwen 3.5 2B is 1.8 GB
//     on disk but reports ~1.0 GB MLX-active footprint when fully
//     loaded (ratio 0.56); the 0.75 multiplier is a conservative
//     ceiling that also covers tokenizer/vocab residency and the
//     first prefill's scratch alloc.
//   - 250 MB safety margin = process baseline (Swift/SwiftUI ~150 MB)
//     + KV-cache headroom for the chat context + buffer above
//     iOS's dirty-memory cliff so we don't dance on the jetsam line.
//
// For unknown `sizeGB` (catalog miss), conservatively assume 2.5 GB.
//
// Calibration note (Item 11, 2026-05-18): the first cut of this
// formula used 1.05× and 300 MB margin, which refused Gemma 4 E2B
// (3.6 GB) at cold launch where the iPhone 16 Plus reports only
// ~3.3 GB available. That was over-conservative — Gemma loaded
// fine in practice. The 0.75× ratio lets cold-launch Gemma succeed
// (need 3015 MB, have ~3300) while still catching the swap-after-
// heavy-context case that originally crashed Hal (~3271 MB available
// after Qwen unload was below the 3015 MB Gemma threshold when
// chat-context KV cache pressure inflated the actual need).

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Process memory introspection
//
// All helpers are explicitly `nonisolated` so they can be called from
// any context — including the detached load Task in `setupLLM` and
// MLXWrapper background work. Without this, the project-level
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes top-level free
// functions implicitly `@MainActor`, which breaks every off-main
// call site. Same pattern as `halLog`.

/// Bytes the process can still allocate before iOS terminates it,
/// converted to MB. Returns `.infinity` on platforms / OS versions
/// where the API isn't available, so callers fail open rather than
/// blocking loads on unsupported hardware.
@inline(__always)
nonisolated func processAvailableMemoryMB() -> Double {
    #if !os(macOS)
    let bytes = os_proc_available_memory()
    if bytes == 0 { return .infinity }  // 0 = unsupported / over limit
    return Double(bytes) / (1024.0 * 1024.0)
    #else
    return .infinity
    #endif
}

/// Estimated MB the process needs available for a successful
/// MLX load of `model`. See the module comment for the formula.
///
/// `model.sizeGB` comes from the Hugging Face catalog; cold-seed
/// configs may be nil, in which case we assume 2.5 GB.
nonisolated func requiredMemoryMBForLoad(_ model: ModelConfiguration) -> Double {
    let sizeGB = model.sizeGB ?? 2.5
    let effectiveResidentMB = sizeGB * 1024.0 * 0.75
    return effectiveResidentMB + 250.0
}

// MARK: - Headroom polling

/// Result of `waitForMemoryHeadroom`. `success` is true if available
/// memory reached the target within the timeout. `finalAvailableMB`
/// is whatever memory was available at the final poll.
struct MemoryHeadroomResult {
    let success: Bool
    let finalAvailableMB: Double
    let pollsTaken: Int
    let elapsedSeconds: Double
}

/// Poll `os_proc_available_memory()` until we have enough headroom
/// to load `requiredMB + 100 MB` of safety, or until `timeoutSeconds`
/// elapses. Logs each poll under `HALDEBUG-MEMORY` so we can see the
/// reclamation curve in post-hoc logs.
///
/// Used in the MLX→MLX swap path after `unloadModel()` to replace the
/// previous fixed 500 ms sleep. iOS Mach VM reclamation is lazy; the
/// actual wait time depends on prior memory pressure and what else
/// is running on the device.
nonisolated func waitForMemoryHeadroom(
    requiredMB: Double,
    timeoutSeconds: Double = 3.0,
    intervalMillis: UInt64 = 150
) async -> MemoryHeadroomResult {
    let target = requiredMB + 100.0
    let intervalNs = intervalMillis * 1_000_000
    let start = Date()
    let deadline = start.addingTimeInterval(timeoutSeconds)
    var pollCount = 0
    while Date() < deadline {
        let available = processAvailableMemoryMB()
        pollCount += 1
        let elapsed = Date().timeIntervalSince(start)
        halLog("HALDEBUG-MEMORY: headroom poll #\(pollCount) availableMB=\(formatMB(available)) targetMB=\(formatMB(target)) elapsed=\(String(format: "%.2f", elapsed))s")
        if available >= target {
            return MemoryHeadroomResult(
                success: true,
                finalAvailableMB: available,
                pollsTaken: pollCount,
                elapsedSeconds: elapsed
            )
        }
        try? await Task.sleep(nanoseconds: intervalNs)
    }
    let final = processAvailableMemoryMB()
    return MemoryHeadroomResult(
        success: false,
        finalAvailableMB: final,
        pollsTaken: pollCount,
        elapsedSeconds: Date().timeIntervalSince(start)
    )
}

// MARK: - Formatting helpers

@inline(__always)
fileprivate nonisolated func formatMB(_ mb: Double) -> String {
    if mb.isInfinite { return "∞" }
    return String(format: "%.0f", mb)
}

/// User-facing message rendered when a load is refused for memory.
/// Centralized so the wording is consistent across call sites and
/// can be revised in one place if Mark wants softer language.
nonisolated func memoryRefusalMessage(
    model: ModelConfiguration,
    availableMB: Double,
    requiredMB: Double
) -> String {
    let availableGB = availableMB / 1024.0
    let requiredGB = requiredMB / 1024.0
    let availableStr: String = availableMB.isInfinite
        ? "an unknown amount"
        : String(format: "%.1f GB", availableGB)
    let requiredStr = String(format: "%.1f GB", requiredGB)
    return "Not enough memory to load \(model.displayName) right now. I need roughly \(requiredStr) but only have \(availableStr) available. Try closing other apps, switching back to a smaller model, or restarting Hal — sometimes iOS needs a moment to reclaim memory after a model swap."
}
