// EmbeddingBackend.swift
// Hal Universal
//
// Extracted from Hal.swift 2026-05-17 afternoon as part of the standing
// refactor-as-you-go directive. Lives separately so the embedder backend
// system has a clearly named home and doesn't bloat Hal.swift further.
//
// Two switchable embedding backends in v2.0.1+:
//   - "nlcontextual" (default): NLContextualEmbedding, Apple's transformer-
//     based replacement for the older NLEmbedding.sentenceEmbedding API.
//     iOS 17+, on-device via Neural Engine, 512-dim, lazy asset download.
//   - "nomicswift": Nomic AI's Nomic Embed Text v1.5, 137M params, 768-dim,
//     via Apple's MLTensor (no MLX). Asymmetric retrieval, 522 MB on disk.
//
// The backend is selected via UserDefaults key "embeddingBackend"; default
// is "nlcontextual". When the backend changes, wipeStaleEmbeddingsIfNeeded
// detects the version mismatch (via systemVersion) and NULLs all stored
// embeddings — the re-embed happens via reEmbedAllNullRows.
//
// =====================================================================
// HISTORY — EmbeddingGemma (removed 2026-05-20 as part of v2.0.1 hotfix)
// =====================================================================
//
// A third backend, "embeddinggemma" (Google EmbeddingGemma 300M, MLX 4-bit,
// 768-dim, ~210 MB), was added 2026-05-17 (Proposal A). It hit a hard wall:
// the upstream MLX iOS Metal initializer crashes on iOS 26.5 the first
// time the model loads. The crash is in MLX's framework code, not ours;
// upstream fix is pending.
//
// We initially compile-gated it behind `HAL_ENABLE_EMBEDDING_GEMMA` so
// Debug builds could iterate while Release shipped without it. That gate
// allowed a subtle bug: `EmbedderMigrationCoordinator.startDownload()` was
// hardcoded to download EmbeddingGemma's weights regardless of which
// backend row the user actually tapped. In Release builds where the
// Gemma row was filtered out of the UI, tapping Download on Nomic still
// downloaded Gemma's weights (210 MB wasted, status messages mislabeled
// "EmbeddingGemma already downloaded"). The mismatch between the
// compile-gated UI surface and the un-gated download path is exactly the
// kind of build-config drift the compile flag introduced.
//
// 2026-05-20 hotfix decision: remove the flag entirely. Comment out all
// Gemma code so it's discoverable but completely inert in all builds.
// No flag, no Debug/Release gap, no possibility of accidental Gemma
// activation. Orphaned weights from prior installs are cleaned up by
// MaintenanceTasks.runAtLaunch().
//
// =====================================================================
// HOW TO RE-ENABLE EMBEDDINGGEMMA WHEN THE UPSTREAM FIX LANDS
// =====================================================================
//
// All Gemma code is preserved as comments. To re-enable:
//
//  1. Uncomment in this file:
//     - The `case embeddingGemma = "embeddinggemma"` enum case.
//     - Each commented `case .embeddingGemma:` switch arm (10 sites).
//     - The crash-guard block in `applyCrashGuardAtLaunch()`.
//     - `crashGuardKey` if you want crash-guard semantics back.
//
//  2. Uncomment in EmbeddingProvider.swift:
//     - The `import MLX / MLXEmbedders / MLXLMCommon / MLXHuggingFace /
//       Tokenizers` block at the top.
//     - The `gemmaContainer` / `gemmaLoadAttempted` stored properties.
//     - The `.embeddingGemma:` arms in `embed()`, `isLoaded`, `warmUp()`.
//     - The entire `embedEmbeddingGemma(_:)` + `ensureGemmaLoadedBlocking()`
//       block at the bottom of the file.
//
//  3. Uncomment in EmbedderMigrationCoordinator.swift:
//     - The Gemma-specific UI label fallback in `EmbedderMigrationStatusRow`
//       (currently uses `activeBackend.displayName`, no change needed).
//
//  4. Uncomment in Hal.swift:
//     - `import MLXEmbedders`.
//     - The boot-time Gemma-specific warm-up delay (`if backendAtBoot ==
//       .embeddingGemma { ... }`).
//     - The `.embeddingGemma: sizeGB = 0.21` arm in DOWNLOAD_EMBEDDING_MODEL.
//
//  5. Run: search the codebase for `// REMOVED 2026-05-20:` — that
//     prefix marks every commented-out region, so you can find them all
//     with a single search and uncomment in one pass.
//
//  6. Remove this history block and rev the file header back to the
//     three-backend prose at the top.
//
// The crash guard / `crashGuardKey` / `recordLoadAttempt` machinery was
// specifically about Gemma's load instability. If a future third backend
// has the same risk profile, the guard can be generalized.
// =====================================================================

import Foundation

// Marked nonisolated/Sendable so EmbeddingProvider (which is nonisolated
// to allow calls from any thread) can read backend identity without a
// hop to MainActor. Project default isolation is MainActor; without these
// annotations the enum members get inherited isolation and produce
// warnings in nonisolated contexts.
/// Distinguishes how an embedding is being used. Required by retrieval-
/// asymmetric models (e.g. Nomic Embed v1.5, which needs "search_query:"
/// vs "search_document:" prefixes). Backends that don't care about
/// purpose ignore the parameter.
nonisolated enum EmbeddingPurpose: Sendable {
    /// The text is being stored in the database for later retrieval.
    case document
    /// The text is a search query being matched against stored documents.
    case query
}

nonisolated enum EmbeddingBackend: String, Sendable, CaseIterable {
    case nlContextual = "nlcontextual"
    // REMOVED 2026-05-20: case embeddingGemma = "embeddinggemma"
    case nomicSwift = "nomicswift"
    /// Mixedbread mxbai-embed-large-v1 — BERT-large (335M, 1024-dim), via the
    /// SAME swift-embeddings `Bert` path Nomic uses (no MLX, no Metal-init crash
    /// risk). CLS pooling; asymmetric retrieval (query-only prefix). Added
    /// 2026-07-09 (v2.1 item 5); device-proven in Posey 2026-06-19.
    case mxbai = "mxbai"

    nonisolated static let defaultsKey = "embeddingBackend"
    // REMOVED 2026-05-20: nonisolated static let crashGuardKey = "embeddingGemmaCrashAttempts"

    /// Is this backend available in the current build? The defensive scaffold
    /// that lets us hide a backend without removing the enum case. Today all
    /// remaining backends are available; the property stays so future
    /// temporary removals don't have to reinvent the gate.
    ///
    /// Callers (Model Library row filter, startDownload guard, etc.) MUST
    /// check this before exposing a backend to the user or initiating
    /// network operations on its behalf.
    nonisolated var isAvailableInThisBuild: Bool {
        switch self {
        case .nlContextual: return true
        case .nomicSwift: return true
        case .mxbai: return true
        // REMOVED 2026-05-20: case .embeddingGemma:
        //     #if HAL_ENABLE_EMBEDDING_GEMMA
        //     return true
        //     #else
        //     return false
        //     #endif
        }
    }

    /// Reads current backend from UserDefaults. Defaults to NLContextual
    /// when the key is unset or invalid.
    ///
    /// Crash guard: a launch-time snapshot, not a per-call check. If the
    /// previous launch wrote `crashGuardKey` (meaning Gemma load was in
    /// progress when the process died), we force NLContextual on the next
    /// launch. Once a load completes, recordLoadSuccess clears the key.
    /// The check happens at AppDelegate startup; this function reads the
    /// resolved value rather than re-evaluating every call (avoids the
    /// race where the guard's own attempt counter trips current() during
    /// the load).
    nonisolated static func current() -> EmbeddingBackend {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? Self.nlContextual.rawValue
        return EmbeddingBackend(rawValue: raw) ?? .nlContextual
    }

    /// Called once at AppDelegate launch BEFORE any embed() call. Today
    /// this is a passthrough — the only backend that needed crash-guard
    /// protection (EmbeddingGemma) was removed 2026-05-20. The function
    /// is preserved so AppDelegate doesn't need to change shape, and so
    /// a future unstable backend can drop crash-guard logic back in here.
    @discardableResult
    nonisolated static func applyCrashGuardAtLaunch() -> EmbeddingBackend {
        return current()
        // REMOVED 2026-05-20: Gemma-specific crash-guard logic.
        //   let selected = current()
        //   guard selected == .embeddingGemma else { return selected }
        //   let crashed = UserDefaults.standard.bool(forKey: crashGuardKey)
        //   if crashed {
        //       halLog("HALDEBUG-EMBEDDING: Crash guard tripped — previous Gemma load crashed before completing. Reverting to NLContextual.")
        //       UserDefaults.standard.set(EmbeddingBackend.nlContextual.rawValue, forKey: defaultsKey)
        //       UserDefaults.standard.removeObject(forKey: crashGuardKey)
        //       return .nlContextual
        //   }
        //   return selected
    }

    // REMOVED 2026-05-20: Gemma-specific load-attempt counter.
    //   nonisolated static func recordLoadAttempt() {
    //       UserDefaults.standard.set(true, forKey: crashGuardKey)
    //   }
    //   nonisolated static func recordLoadSuccess() {
    //       UserDefaults.standard.removeObject(forKey: crashGuardKey)
    //   }

    /// Integer used by `wipeStaleEmbeddingsIfNeeded` so a backend change
    /// triggers wipe-and-re-embed. Bump this when adding a new backend.
    nonisolated var systemVersion: Int {
        switch self {
        case .nlContextual: return 2  // matches original (post-NLEmbedding migration)
        // REMOVED 2026-05-20: case .embeddingGemma: return 3
        case .nomicSwift: return 4
        case .mxbai: return 5
        }
    }

    /// Sentence-vector dimension for this backend.
    nonisolated var dimension: Int {
        switch self {
        case .nlContextual: return 512
        // REMOVED 2026-05-20: case .embeddingGemma: return 768
        case .nomicSwift: return 768
        case .mxbai: return 1024
        }
    }

    /// HuggingFace model id for backends that load a downloadable model.
    nonisolated var modelID: String? {
        switch self {
        case .nlContextual: return nil
        // REMOVED 2026-05-20: case .embeddingGemma: return "mlx-community/embeddinggemma-300m-4bit"
        case .nomicSwift: return "nomic-ai/nomic-embed-text-v1.5"
        case .mxbai: return "mixedbread-ai/mxbai-embed-large-v1"
        }
    }

    // MARK: - UI surface (display strings)

    /// Display name shown in the Model Library embedder section.
    var displayName: String {
        switch self {
        case .nlContextual: return "Apple NLContextual"
        // REMOVED 2026-05-20: case .embeddingGemma: return "EmbeddingGemma 300M"
        case .nomicSwift: return "Nomic Embed Text v1.5"
        case .mxbai: return "Mixedbread mxbai-embed-large"
        }
    }

    /// Short description used in the embedder card body.
    var blurb: String {
        switch self {
        case .nlContextual:
            return "Built into iOS 26+. Runs on the Neural Engine. 512-dim sentence vectors. No download, always available."
        // REMOVED 2026-05-20:
        // case .embeddingGemma:
        //     return "Google's open embedding model, 308M params, MLX 4-bit quantized. 768-dim, state-of-the-art on MTEB Multilingual v2 among models under 500M. Adds ~210 MB on disk."
        case .nomicSwift:
            return "Nomic AI's open embedding model, 137M params, 768-dim, purpose-built for asymmetric retrieval (query vs document). Runs via Apple's MLTensor framework (no MLX). Adds ~522 MB on disk."
        case .mxbai:
            return "Mixedbread's mxbai-embed-large-v1, 335M params, 1024-dim. BERT-large via the same swift-embeddings path as Nomic (no MLX). CLS pooling, asymmetric retrieval (query prefix). The strongest retrieval of the three and the heaviest. Adds ~670 MB on disk."
        }
    }

    /// Size note shown in the row header. nil for backends that don't ship a model file.
    var sizeBlurb: String? {
        switch self {
        case .nlContextual: return nil
        // REMOVED 2026-05-20: case .embeddingGemma: return "~210 MB"
        case .nomicSwift: return "~522 MB"
        case .mxbai: return "~670 MB"
        }
    }

    // MARK: - Reflection synthesis threshold (per backend)
    //
    // The cosine-similarity threshold above which two reflections are
    // considered "the same thought said differently" and synthesized into
    // a single entry rather than stored separately. See
    // `MemoryStore.storeReflectionWithSynthesis` for how this is consumed.
    //
    // CRITICAL: thresholds are NOT transferable between backends. Each
    // embedding model has its own score distribution — NLContextual's
    // unrelated text scores 0.05-0.10, Nomic's scores 0.3-0.5. A threshold
    // calibrated for one will misbehave for another. Calibrate empirically
    // for each backend by running known-related and known-unrelated text
    // pairs and finding the gap.
    //
    // Marked nonisolated so the synthesis path (which is nonisolated) can
    // read it without an actor hop.
    nonisolated var recommendedSynthesisThreshold: Double {
        switch self {
        case .nlContextual:
            // Calibrated empirically against Apple's NLContextual sentence
            // vectors. Unrelated English text scores >0.6 from shared
            // language structure alone, so 0.85 requires real conceptual
            // overlap. Conservative bias toward false negatives (stores
            // near-duplicates as separate entries rather than merging
            // unrelated thoughts).
            return 0.85
        case .nomicSwift:
            // Calibrated 2026-05-18 via tests/nomic_calibration_probe.py —
            // 18 of 30 planned pairs measured on device (10 SAME + 8 RELATED;
            // UNREL class was cut short by repeated iOS suspension of the
            // app during the long probe run — see commit message + HISTORY).
            //
            // Measured distribution under Nomic Embed Text v1.5 on
            // reflection-shaped sentences:
            //   SAME    (same thought, different words):  0.73 – 0.93  (mean 0.84)
            //   RELATED (same topic, distinct ideas):     0.71 – 0.83  (mean 0.76)
            //
            // The bands OVERLAP. Nomic does not crisply separate "exact
            // duplicate" from "same topic / same subject" — both look very
            // close in embedding space. Concrete example: "Mark likes
            // morning walks" vs "Mark sometimes runs marathons" scored
            // 0.83 (RELATED, not SAME).
            //
            // 0.85 sits at the safe edge ABOVE the observed RELATED tail
            // (max 0.8311 + 0.02 headroom). It captures the top half of
            // SAME pairs (those Nomic agrees are most-duplicate) and
            // avoids all observed RELATED false positives. Weaker SAME
            // pairs get stored separately; reinforcement_count bumps when
            // a stronger duplicate arrives later. Conservative bias is
            // correct because synthesis is destructive.
            //
            // Same numeric value as NLContextual but for a different
            // reason: NLContextual's 0.85 sits high in its 0.69–0.91
            // range; Nomic's 0.85 sits at the floor of its safe-merge
            // zone.
            return 0.85
        case .mxbai:
            // PLACEHOLDER (v2.1 item 5, step 1) — mxbai's CLS/L2-normalized
            // cosine distribution differs from Nomic's and must be calibrated on
            // reflection-shaped SAME/RELATED pairs in step 3 (the A/B pass)
            // before this is trusted. 0.85 is a conservative starting point, not
            // a measured value. See tests/nomic_calibration_probe.py for the
            // probe shape to reuse.
            return 0.85
        // REMOVED 2026-05-20:
        // case .embeddingGemma:
        //     // PLACEHOLDER — calibrate from real corpus data when re-enabled.
        //     return 0.85
        }
    }

    // MARK: - Trait-evolution contradiction threshold (per backend, Phase 3)
    //
    // The cosine-similarity threshold above which a new reflection is
    // considered to be reinforcing an existing trait in the SAME direction
    // (the "deepen" path — the LLM just refines the trait's value in
    // place). Below this threshold, the reflection is treated as a
    // contradiction or tension (the "absorb-tension" path — multi-valued
    // JSON storage with a weighted secondary state).
    //
    // Same per-backend story as the synthesis threshold: each embedding
    // model has its own score distribution. NLContextual's "clearly
    // aligned" band is much narrower than Nomic's. A single number won't
    // work across all three; calibrate per backend.
    //
    // Important: this threshold is LOWER than recommendedSynthesisThreshold
    // because synthesis asks "are these effectively the same thought?"
    // (very high bar, conservative against merging unrelated content),
    // while contradiction detection asks "is this reinforcing or
    // contradicting?" (lower bar, only needs to distinguish broad
    // agreement from broad disagreement).
    nonisolated var recommendedContradictionThreshold: Double {
        switch self {
        case .nlContextual:
            // Per Mark/SC's Phase 3 design call (2026-05-18): start at 0.6.
            // Calibrate from real evolution events once they accumulate.
            return 0.6
        case .nomicSwift:
            // PLACEHOLDER — needs calibration. Nomic's wider score
            // distribution likely wants a lower threshold here (maybe
            // 0.4-0.5), but we'll know after observing real evolutions.
            return 0.6
        case .mxbai:
            // PLACEHOLDER (v2.1 item 5) — calibrate in step 3 alongside the
            // synthesis threshold.
            return 0.6
        // REMOVED 2026-05-20:
        // case .embeddingGemma:
        //     // PLACEHOLDER — calibrate when re-enabled.
        //     return 0.6
        }
    }
}
