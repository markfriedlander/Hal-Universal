// ==== LEGO START: 30 Embedding Backends (NLContextual + Nomic + mxbai) ====
// EmbeddingBackend.swift
// Hal Universal
//
// The switchable embedding-backend system: the backend enum, its per-backend
// vector-column mapping, and the load/embed plumbing each backend needs.
//
// Two active backends:
//   - "nlcontextual" (default): NLContextualEmbedding, Apple's on-device
//     transformer embedder. 512-dim, lazy asset download.
//   - "nomicswift": Nomic Embed Text v1.5, 768-dim, via Apple's MLTensor
//     (no MLX). Asymmetric retrieval, ~522 MB on disk.
// (mxbai is also selectable; its seed lives in ModelCatalogService.)
//
// The active backend is chosen via the UserDefaults key "embeddingBackend"
// (default "nlcontextual"). Each backend owns a permanent per-backend vector
// column in unified_content and all vector sets coexist, so switching just
// reads a different column - no destructive wipe. An inactive backend's
// column is backfilled in the background by MemoryStore.backfillEmbeddings(for:).
//
// EmbeddingGemma is currently DISABLED: the upstream MLX iOS Metal initializer
// crashes on first load (a framework bug, not ours; fix pending upstream). All
// its code is preserved as comments, each tagged `// REMOVED 2026-05-20:` so a
// single grep finds every region. Re-enable recipe:
//   1. This file: uncomment the `case embeddingGemma` enum case, each
//      `case .embeddingGemma:` switch arm (10 sites), and the crash-guard block
//      in applyCrashGuardAtLaunch() (plus crashGuardKey for crash-guard semantics).
//   2. EmbeddingProvider.swift: the MLX/MLXEmbedders/MLXLMCommon/MLXHuggingFace/
//      Tokenizers import block, the gemmaContainer / gemmaLoadAttempted properties,
//      the .embeddingGemma arms in embed()/isLoaded/warmUp(), and
//      embedEmbeddingGemma(_:) + ensureGemmaLoadedBlocking() at the bottom.
//   3. Hal.swift: `import MLXEmbedders`, the boot-time Gemma warm-up delay, and
//      the `.embeddingGemma: sizeGB = 0.21` arm in DOWNLOAD_EMBEDDING_MODEL.
//   4. Grep `// REMOVED 2026-05-20:` to find every region in one pass.
// The crash-guard / recordLoadAttempt machinery was specific to Gemma's load
// instability; generalize it if a future backend needs the same guard.

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

    /// Legacy per-backend version integer. Was used by the retired destructive
    /// wipe-on-switch; kept for the one-time legacy→per-backend-column migration
    /// bookkeeping and as a stable per-backend id. Bump when adding a backend.
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

    /// The `unified_content` BLOB column this backend's vectors live in (v2.1
    /// step 2 — "keep-both" per-backend columns). Each backend owns a permanent
    /// column so all backends' vectors coexist; switching backends just changes
    /// which column the retriever reads/writes — no destructive wipe-and-re-embed.
    /// A backfill worker fills an inactive backend's column in the background.
    /// Column names are fixed enum-derived identifiers (never user input), so it
    /// is safe to interpolate them into SQL.
    nonisolated var vectorColumn: String {
        switch self {
        case .nlContextual: return "embedding_nl"
        case .nomicSwift:   return "embedding_nomic"
        case .mxbai:        return "embedding_mxbai"
        }
    }

    /// All per-backend vector columns, for schema creation + coverage queries.
    nonisolated static var allVectorColumns: [String] {
        allCases.map { $0.vectorColumn }
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

    /// Short "model card" description shown in the embedder card body. All three
    /// are legitimate choices with different tradeoffs (Mark, 2026-07-09 — "all
    /// three are the recommended ones"); the wording states each one's strengths
    /// and costs neutrally rather than ranking a single winner. The
    /// retrieval-precision language is grounded in the measured separation
    /// between related and unrelated memories (tests/embedder_ab_eval.py):
    /// mxbai (0.48) > Nomic (0.30) > NLContextual (0.10).
    var blurb: String {
        switch self {
        case .nlContextual:
            return "Apple's built-in embedder (512-dim), running on the Neural Engine.\n• Good at: nothing to download, instant, fully private, tiny storage, fastest to embed, works out of the box.\n• Weaker at: precision. It's the least sharp of the three at telling closely-related memories apart, so it can occasionally surface a loosely-related memory instead of the exact one.\nBest when you want zero setup and the smallest footprint."
        // REMOVED 2026-05-20:
        // case .embeddingGemma:
        //     return "Google's open embedding model, 308M params, MLX 4-bit quantized. 768-dim, state-of-the-art on MTEB Multilingual v2 among models under 500M. Adds ~210 MB on disk."
        case .nomicSwift:
            return "Nomic Embed Text v1.5 (768-dim), purpose-built for search. On-device via Apple's MLTensor (no MLX).\n• Good at: a clear step up in precision over the built-in embedder (better at pulling the right memory rather than a merely on-topic one) while staying moderate in size and speed. It tests extremely well in Hal's own end-to-end retrieval, holding its own with the larger model.\n• Costs: a ~522 MB download and a bit more compute than the built-in option.\nA balanced middle ground."
        case .mxbai:
            return "Mixedbread mxbai-embed-large (1024-dim, BERT-large). On-device via the same path as Nomic (no MLX).\n• Good at: the most detailed representation of the three: its 1024-dim vectors are the sharpest at telling near-identical passages apart in isolation, which can help with large or nuanced memories.\n• Costs: the largest download (~670 MB) and the slowest to embed, so building or rebuilding your memory index takes the longest; and in Hal's own end-to-end retrieval its edge over Nomic is subtle.\nBest when you want the most detailed embeddings and can spare the storage."
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
            // Calibrated 2026-07-09 via tests/embedder_ab_eval.py on
            // reflection-shaped pairs (device, iPhone 16 Plus). mxbai's
            // CLS/L2-normalized cosine distribution is much wider than Nomic's:
            //   SAME    0.79 – 0.92  (mean 0.84)
            //   RELATED 0.58 – 0.79  (mean 0.67)
            //   UNREL   0.26 – 0.49  (mean 0.36)
            // As with Nomic, SAME and RELATED overlap at the bottom, so the
            // threshold sits just ABOVE the RELATED tail (max 0.79 + headroom).
            // 0.82 captures the clearer SAME duplicates while never merging an
            // observed RELATED pair. Conservative bias is correct — synthesis is
            // destructive. See Docs/Embedder_AB_Findings_2026-07-09.md.
            return 0.82
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
            // Distribution-informed (2026-07-09 A/B): mxbai's RELATED band
            // centers ~0.67 and UNREL ~0.36, so ~0.5 is a sensible "aligned vs
            // in-tension" boundary (below RELATED, above UNREL). Still soft —
            // like the others, refine from real trait-evolution events.
            return 0.5
        // REMOVED 2026-05-20:
        // case .embeddingGemma:
        //     // PLACEHOLDER — calibrate when re-enabled.
        //     return 0.6
        }
    }
}
// ==== LEGO END: 30 Embedding Backends (NLContextual + Nomic + mxbai) ====
