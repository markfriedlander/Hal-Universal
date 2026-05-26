// EmbeddingProvider.swift
// Hal Universal
//
// Single-instance wrapper around whichever embedding backend is active.
// Lazy-loaded on first use; subsequent calls are synchronous and fast.
//
// Two switchable backends (v2.0.1+):
//   - NLContextualEmbedding (default, built-in, 512-dim)
//   - Nomic Embed Text v1.5 via swift-embeddings (768-dim, ~522 MB,
//     uses Apple's MLTensor — no MLX, no Metal init crash). Asymmetric-
//     retrieval tuned (requires "search_query:" / "search_document:"
//     prefixes; handled here via EmbeddingPurpose).
//
// EmbeddingGemma was removed 2026-05-20. See EmbeddingBackend.swift's
// header for full history and the recipe for re-enabling.
//
// Thread safety: locked around the one-time backend load; subsequent
// embed() calls are reentrant and serialize through the backend's own
// thread-safety guarantees.
//
// Sync API preserved across all backends via DispatchSemaphore bridges
// when the underlying load/inference is async. Callers continue to
// receive a `[Double]?` per call.

import Foundation
import CoreML
import NaturalLanguage
import Embeddings

// REMOVED 2026-05-20: MLXEmbedders + companions for EmbeddingGemma backend.
//   import MLX
//   import MLXEmbedders
//   import MLXLMCommon
//   import MLXHuggingFace
//   import Tokenizers

final class EmbeddingProvider: @unchecked Sendable {
    nonisolated static let shared = EmbeddingProvider()

    private let lock = NSLock()
    nonisolated(unsafe) private var nlModel: NLContextualEmbedding?
    nonisolated(unsafe) private var nlLoadAttempted: Bool = false
    nonisolated(unsafe) private var nomicBundle: NomicBert.ModelBundle?
    nonisolated(unsafe) private var nomicLoadAttempted: Bool = false

    // REMOVED 2026-05-20: Gemma-backed container + load-attempt flag.
    //   nonisolated(unsafe) private var gemmaContainer: EmbedderModelContainer?
    //   nonisolated(unsafe) private var gemmaLoadAttempted: Bool = false

    private init() {}

    /// Pooled sentence-level vector for `text`, or nil if the active
    /// backend isn't loaded.
    ///
    /// `purpose` is honored by retrieval-asymmetric backends (Nomic adds
    /// "search_query:" / "search_document:" prefixes). NLContextual
    /// ignores it.
    nonisolated func embed(_ text: String, as purpose: EmbeddingPurpose) -> [Double]? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }

        switch EmbeddingBackend.current() {
        case .nlContextual:
            return embedNLContextual(cleanText)
        // REMOVED 2026-05-20:
        // case .embeddingGemma:
        //     return embedEmbeddingGemma(cleanText)
        case .nomicSwift:
            return embedNomicSwift(cleanText, purpose: purpose)
        }
    }

    /// Convenience overload — defaults to `.document` for callers that
    /// don't yet distinguish purpose. New code should always pass a
    /// purpose explicitly.
    nonisolated func embed(_ text: String) -> [Double]? {
        return embed(text, as: .document)
    }

    /// True if the *currently active* backend is loaded and ready.
    nonisolated var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        switch EmbeddingBackend.current() {
        case .nlContextual: return nlModel != nil
        // REMOVED 2026-05-20:
        // case .embeddingGemma:
        //     #if HAL_ENABLE_EMBEDDING_GEMMA
        //     return gemmaContainer != nil
        //     #else
        //     return false
        //     #endif
        case .nomicSwift: return nomicBundle != nil
        }
    }

    /// Currently active backend (for diagnostics).
    nonisolated var activeBackend: EmbeddingBackend {
        return EmbeddingBackend.current()
    }

    /// Trigger an async warm-up of the active backend — used from app
    /// boot so the model loads (and downloads assets if needed) in the
    /// background before any chat turn fires. Idempotent.
    nonisolated func warmUp() {
        Task.detached { [weak self] in
            guard let self = self else { return }
            switch EmbeddingBackend.current() {
            case .nlContextual: self.ensureNLLoadedBlocking()
            // REMOVED 2026-05-20:
            // case .embeddingGemma:
            //     #if HAL_ENABLE_EMBEDDING_GEMMA
            //     self.ensureGemmaLoadedBlocking()
            //     #else
            //     halLog("HALDEBUG-EMBEDDING: warmUp() skipped — EmbeddingGemma not enabled.")
            //     #endif
            case .nomicSwift: self.ensureNomicLoadedBlocking()
            }
        }
    }

    // MARK: - NLContextualEmbedding path

    private nonisolated func embedNLContextual(_ cleanText: String) -> [Double]? {
        ensureNLLoadedBlocking()

        lock.lock()
        let loaded = nlModel
        lock.unlock()

        guard let model = loaded else { return nil }

        do {
            let result = try model.embeddingResult(for: cleanText, language: .english)
            let dim = model.dimension
            guard dim > 0 else { return nil }

            var sum = [Double](repeating: 0, count: dim)
            var tokenCount = 0
            result.enumerateTokenVectors(in: cleanText.startIndex..<cleanText.endIndex) { vector, _ in
                let limit = min(dim, vector.count)
                for i in 0..<limit {
                    sum[i] += vector[i]
                }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else { return nil }
            let pooled = sum.map { $0 / Double(tokenCount) }
            return pooled
        } catch {
            halLog("HALDEBUG-EMBEDDING: NLContextualEmbedding.embeddingResult failed: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated func ensureNLLoadedBlocking() {
        lock.lock()
        if nlModel != nil { lock.unlock(); return }
        if nlLoadAttempted { lock.unlock(); return }
        nlLoadAttempted = true
        lock.unlock()

        guard let candidate = NLContextualEmbedding(language: .english) else {
            halLog("HALDEBUG-EMBEDDING: NLContextualEmbedding(language:.english) returned nil — model unavailable")
            return
        }

        if !candidate.hasAvailableAssets {
            halLog("HALDEBUG-EMBEDDING: Assets not on device; requesting download (this happens once per install)")
            let sem = DispatchSemaphore(value: 0)
            var assetError: Error?
            candidate.requestAssets(completionHandler: { _, err in
                if let e = err { assetError = e }
                sem.signal()
            })
            sem.wait()
            if let error = assetError {
                halLog("HALDEBUG-EMBEDDING: Asset request failed: \(error.localizedDescription) — semantic search will be unavailable until next attempt")
                lock.lock(); nlLoadAttempted = false; lock.unlock()  // allow retry next call
                return
            }
        }

        do {
            try candidate.load()
            lock.lock()
            self.nlModel = candidate
            lock.unlock()
            halLog("HALDEBUG-EMBEDDING: NLContextualEmbedding loaded — dimension=\(candidate.dimension)")
        } catch {
            halLog("HALDEBUG-EMBEDDING: NLContextualEmbedding.load() failed: \(error.localizedDescription)")
            lock.lock(); nlLoadAttempted = false; lock.unlock()  // allow retry next call
        }
    }

    // MARK: - Nomic Embed Text v1.5 path (swift-embeddings, BertModel)

    /// Nomic v1.5 was trained with task instruction prefixes; embeddings
    /// require them or retrieval quality degrades sharply. See the model
    /// card on HuggingFace.
    private nonisolated func nomicPrefixed(_ text: String, purpose: EmbeddingPurpose) -> String {
        switch purpose {
        case .document: return "search_document: " + text
        case .query: return "search_query: " + text
        }
    }

    private nonisolated func embedNomicSwift(_ cleanText: String, purpose: EmbeddingPurpose) -> [Double]? {
        ensureNomicLoadedBlocking()

        lock.lock()
        let loaded = nomicBundle
        lock.unlock()

        guard let bundle = loaded else { return nil }

        let prefixed = nomicPrefixed(cleanText, purpose: purpose)

        // Bridge async MLTensor inference to sync embed() API.
        let sem = DispatchSemaphore(value: 0)
        var resultVec: [Double]?
        Task.detached {
            do {
                // bundle.encode returns an MLTensor with shape [1, seqLen, hidden]
                // OR [1, hidden] depending on the model's pooling. For
                // Nomic Embed v1.5 the model emits per-token outputs; we
                // mean-pool over the sequence to get a single sentence
                // vector. Cast to Float and collect scalars.
                let encoded = try bundle.encode(prefixed, maxLength: 512)
                let asFloat = await encoded.cast(to: Float.self).shapedArray(of: Float.self)
                let shape = asFloat.shape
                let scalars = asFloat.scalars
                // Determine pooling. Common shapes:
                //   [1, hidden]                  — already pooled
                //   [1, seqLen, hidden]          — mean-pool over seqLen
                //   [seqLen, hidden]             — mean-pool over seqLen
                let hidden: Int
                let pooled: [Double]
                if shape.count == 2 && shape[0] == 1 {
                    hidden = shape[1]
                    pooled = (0..<hidden).map { Double(scalars[$0]) }
                } else if shape.count == 3 && shape[0] == 1 {
                    let seqLen = shape[1]
                    hidden = shape[2]
                    var acc = [Double](repeating: 0, count: hidden)
                    for t in 0..<seqLen {
                        let base = t * hidden
                        for h in 0..<hidden {
                            acc[h] += Double(scalars[base + h])
                        }
                    }
                    pooled = acc.map { $0 / Double(seqLen) }
                } else if shape.count == 2 {
                    let seqLen = shape[0]
                    hidden = shape[1]
                    var acc = [Double](repeating: 0, count: hidden)
                    for t in 0..<seqLen {
                        let base = t * hidden
                        for h in 0..<hidden {
                            acc[h] += Double(scalars[base + h])
                        }
                    }
                    pooled = acc.map { $0 / Double(seqLen) }
                } else {
                    halLog("HALDEBUG-EMBEDDING: Nomic returned unexpected tensor shape \(shape)")
                    sem.signal()
                    return
                }
                // L2-normalize so cosine similarity equals dot product.
                let norm = sqrt(pooled.reduce(0) { $0 + $1 * $1 })
                if norm > 0 {
                    resultVec = pooled.map { $0 / norm }
                } else {
                    resultVec = pooled
                }
            } catch {
                halLog("HALDEBUG-EMBEDDING: Nomic encode failed: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        return resultVec
    }

    private nonisolated func ensureNomicLoadedBlocking() {
        lock.lock()
        if nomicBundle != nil { lock.unlock(); return }
        if nomicLoadAttempted { lock.unlock(); return }
        nomicLoadAttempted = true
        lock.unlock()

        guard let modelID = EmbeddingBackend.nomicSwift.modelID else {
            halLog("HALDEBUG-EMBEDDING: Nomic has no modelID — programming error")
            return
        }

        // Load from local directory. MLXModelDownloader / BackgroundDownloadCoordinator
        // owns the actual HuggingFace download; we resolve the on-disk path
        // and call swift-embeddings' local-loader.
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelDirectory = cacheDir
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)

        // Verify required files are present before attempting load.
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            halLog("HALDEBUG-EMBEDDING: Nomic model not present at \(modelDirectory.path) — user must download it via the Model Library first")
            lock.lock(); nomicLoadAttempted = false; lock.unlock()  // allow retry after download
            return
        }

        halLog("HALDEBUG-EMBEDDING: Loading Nomic Embed Text v1.5 from \(modelDirectory.path)...")
        let sem = DispatchSemaphore(value: 0)
        var loadedBundle: NomicBert.ModelBundle?
        var loadError: Error?
        Task.detached {
            do {
                loadedBundle = try await NomicBert.loadModelBundle(from: modelDirectory)
            } catch {
                loadError = error
            }
            sem.signal()
        }
        sem.wait()

        if let e = loadError {
            halLog("HALDEBUG-EMBEDDING: Nomic load failed: \(e.localizedDescription) — semantic search unavailable until next attempt")
            lock.lock(); nomicLoadAttempted = false; lock.unlock()
            return
        }
        guard let bundle = loadedBundle else {
            halLog("HALDEBUG-EMBEDDING: Nomic load returned nil bundle")
            lock.lock(); nomicLoadAttempted = false; lock.unlock()
            return
        }
        lock.lock()
        self.nomicBundle = bundle
        lock.unlock()
        halLog("HALDEBUG-EMBEDDING: Nomic Embed Text v1.5 loaded (\(modelID)) — dimension=\(EmbeddingBackend.nomicSwift.dimension)")
    }

    // REMOVED 2026-05-20: EmbeddingGemma path (embedEmbeddingGemma +
    // ensureGemmaLoadedBlocking + all MLX-flavored loading logic). The
    // ~120-line block followed an upstream MLX iOS Metal init crash on
    // iOS 26.5 that we couldn't work around. To re-enable, restore from
    // git history of this file at commit `e30c888` (or earlier) along
    // with the import block at the top and the `gemmaContainer` stored
    // properties. See EmbeddingBackend.swift's header for the full
    // re-enable recipe.

}

// MARK: - MemoryStore embedding helpers

extension MemoryStore {

    /// Returns the pooled sentence vector for `text`. Empty array if the
    /// embedding model isn't loaded yet (first-launch download pending or
    /// failed). Storage callers that get an empty array store NULL in the
    /// embedding column; search callers that get an empty array return
    /// zero semantic results (BM25 keyword path still applies).
    ///
    /// `purpose` is passed through to the backend; retrieval-asymmetric
    /// backends like Nomic Embed v1.5 use it to choose the right task
    /// instruction prefix. Backends that don't distinguish ignore it.
    ///
    /// nonisolated: callable from background work like the embedding
    /// migration (`reEmbedAllNullRows`). Underlying EmbeddingProvider.embed
    /// is also nonisolated and thread-safe via NSLock + per-backend
    /// serial containers.
    nonisolated func generateEmbedding(for text: String, as purpose: EmbeddingPurpose) -> [Double] {
        return EmbeddingProvider.shared.embed(text, as: purpose) ?? []
    }

    /// Convenience overload — defaults to `.document` for callers in the
    /// storage / write path (this is the dominant call site). Search
    /// callers should always use the explicit form with `.query`.
    nonisolated func generateEmbedding(for text: String) -> [Double] {
        return generateEmbedding(for: text, as: .document)
    }

    /// Standard cosine similarity. Rejects dimension mismatches (returns 0)
    /// so embedding-system migrations can't silently produce noise.
    func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count && v1.count > 0 else { return 0 }
        let dot = zip(v1, v2).map(*).reduce(0, +)
        let norm1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let norm2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        return norm1 == 0 || norm2 == 0 ? 0 : dot / (norm1 * norm2)
    }
}
