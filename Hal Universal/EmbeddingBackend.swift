// EmbeddingBackend.swift
// Hal Universal
//
// Extracted from Hal.swift 2026-05-17 afternoon as part of the standing
// refactor-as-you-go directive. Lives separately so the embedder backend
// system has a clearly named home and doesn't bloat Hal.swift further.
//
// Two switchable embedding backends:
//   - "nlcontextual" (default): NLContextualEmbedding, Apple's transformer-
//     based replacement for the older NLEmbedding.sentenceEmbedding API.
//     iOS 17+, on-device via Neural Engine, 512-dim, lazy asset download.
//   - "embeddinggemma" (Proposal A, 2026-05-17): Google's EmbeddingGemma
//     300M, MLX 4-bit quantized via `mlx-community/embeddinggemma-300m-4bit`.
//     Loaded through MLXEmbedders (already linked via mlx-swift-lm). MTEB
//     SOTA for open models under 500M; ~210 MB on disk after download.
//     768-dim with optional Matryoshka truncation (we use full 768).
//
// The backend is selected via UserDefaults key "embeddingBackend"; default
// is "nlcontextual". When the backend changes, wipeStaleEmbeddingsIfNeeded
// detects the version mismatch (via systemVersion) and NULLs all stored
// embeddings — the re-embed happens via reEmbedAllNullRows.
//
// Crash guard: if a previous launch attempted to load EmbeddingGemma and
// didn't reset the counter (i.e. the load crashed the process before
// completing), current() forces NLContextual on this launch. The user can
// manually re-enable via SET_EMBEDDING_BACKEND once the underlying issue
// is fixed. Keeps the app launchable even when a backend load is unstable.

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
    case embeddingGemma = "embeddinggemma"
    case nomicSwift = "nomicswift"

    nonisolated static let defaultsKey = "embeddingBackend"
    nonisolated static let crashGuardKey = "embeddingGemmaCrashAttempts"

    /// Is this backend available in the current build? Used to compile out
    /// the Gemma path in App Store builds (pending the upstream MLX Metal
    /// init crash fix on iOS 26.5). Selecting an unavailable backend via
    /// API or stale UserDefaults falls back to NLContextual on load.
    ///
    /// Build flag: HAL_ENABLE_EMBEDDING_GEMMA (Debug-only by default).
    nonisolated var isAvailableInThisBuild: Bool {
        switch self {
        case .nlContextual: return true
        case .nomicSwift: return true
        case .embeddingGemma:
            #if HAL_ENABLE_EMBEDDING_GEMMA
            return true
            #else
            return false
            #endif
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

    /// Called once at AppDelegate launch BEFORE any embed() call. If the
    /// previous run left `crashGuardKey` set, the load crashed before
    /// completing — force NLContextual and persist that choice so any
    /// readers see a stable backend for this launch. Returns the resolved
    /// backend so the caller can log it.
    @discardableResult
    nonisolated static func applyCrashGuardAtLaunch() -> EmbeddingBackend {
        let selected = current()
        guard selected == .embeddingGemma else { return selected }
        let crashed = UserDefaults.standard.bool(forKey: crashGuardKey)
        if crashed {
            halLog("HALDEBUG-EMBEDDING: Crash guard tripped — previous Gemma load crashed before completing. Reverting to NLContextual. To re-try, call SET_EMBEDDING_BACKEND:embeddinggemma again after the fix.")
            UserDefaults.standard.set(EmbeddingBackend.nlContextual.rawValue, forKey: defaultsKey)
            UserDefaults.standard.removeObject(forKey: crashGuardKey)
            return .nlContextual
        }
        return selected
    }

    /// Mark a Gemma load as in-flight. Stored as a Bool so reads are cheap
    /// and idempotent — repeated attempts during the same launch are a no-op.
    nonisolated static func recordLoadAttempt() {
        UserDefaults.standard.set(true, forKey: crashGuardKey)
    }

    /// Load completed without crashing — clear the in-flight flag.
    nonisolated static func recordLoadSuccess() {
        UserDefaults.standard.removeObject(forKey: crashGuardKey)
    }

    /// Integer used by `wipeStaleEmbeddingsIfNeeded` so a backend change
    /// triggers wipe-and-re-embed. Bump this when adding a new backend.
    nonisolated var systemVersion: Int {
        switch self {
        case .nlContextual: return 2  // matches original (post-NLEmbedding migration)
        case .embeddingGemma: return 3
        case .nomicSwift: return 4
        }
    }

    /// Sentence-vector dimension for this backend.
    nonisolated var dimension: Int {
        switch self {
        case .nlContextual: return 512
        case .embeddingGemma: return 768
        case .nomicSwift: return 768
        }
    }

    /// HuggingFace model id for backends that load a downloadable model.
    nonisolated var modelID: String? {
        switch self {
        case .nlContextual: return nil
        case .embeddingGemma: return "mlx-community/embeddinggemma-300m-4bit"
        case .nomicSwift: return "nomic-ai/nomic-embed-text-v1.5"
        }
    }

    // MARK: - UI surface (display strings)

    /// Display name shown in the Model Library embedder section.
    var displayName: String {
        switch self {
        case .nlContextual: return "Apple NLContextual"
        case .embeddingGemma: return "EmbeddingGemma 300M"
        case .nomicSwift: return "Nomic Embed Text v1.5"
        }
    }

    /// Short description used in the embedder card body.
    var blurb: String {
        switch self {
        case .nlContextual:
            return "Built into iOS 26+. Runs on the Neural Engine. 512-dim sentence vectors. No download, always available."
        case .embeddingGemma:
            return "Google's open embedding model, 308M params, MLX 4-bit quantized. 768-dim, state-of-the-art on MTEB Multilingual v2 among models under 500M. Adds ~210 MB on disk. (Currently unavailable in App Store builds pending an upstream MLX iOS Metal fix.)"
        case .nomicSwift:
            return "Nomic AI's open embedding model, 137M params, 768-dim, purpose-built for asymmetric retrieval (query vs document). Runs via Apple's MLTensor framework (no MLX). Adds ~522 MB on disk."
        }
    }

    /// Size note shown in the row header. nil for backends that don't ship a model file.
    var sizeBlurb: String? {
        switch self {
        case .nlContextual: return nil
        case .embeddingGemma: return "~210 MB"
        case .nomicSwift: return "~522 MB"
        }
    }
}
