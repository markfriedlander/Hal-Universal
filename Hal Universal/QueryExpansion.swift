// ==== LEGO START: 33 Query Expansion (LLM-Assisted Weak-Retrieval Recovery) ====
// QueryExpansion.swift
// Hal Universal
//
// LLM-driven query expansion for weak RAG retrieval.
//
// Hybrid retrieval (semantic + BM25 + RRF) does well when the query
// shares either content words or concept-level meaning with stored
// memories, and fails when both signals are weak — e.g. "Where do I live
// now?" against "house in Berkeley", or "What kind of car?" against
// "Subaru Outback", where neither side has lexical overlap or enough
// semantic proximity.
//
// Fix: when the initial retrieval comes back weak, ask the active LLM to
// extract 5-10 related concept terms for the query, then re-run the BM25
// side of the hybrid pipeline with `(original-tokens) OR (expansion-
// tokens)`. AFM-safe — prompt + response budget is < 200 tokens total.
//
// Trigger: top-1 RRF score < 0.020 AND top-1.isEntityMatch == false.
// RRF max single-list score is 1/(60+1) ~ 0.0164; both lists agreeing
// yields ~ 0.0328. Consistently-failing queries sit at ~ 0.0164 with
// isEntityMatch=false (semantic only, no BM25 contribution).
//
// Results are cached in SQLite, keyed by SHA-256 of the normalized
// (lowercased + trimmed) query, so repeated queries don't re-call the
// LLM. Invalidated on model switch (different models extract different
// concepts) or on user request.

import Foundation
import CryptoKit
import SQLite3

@MainActor
enum QueryExpansion {

    // MARK: - Trigger condition (calibrated, see file header)

    /// Threshold for "the initial retrieval is weak enough to warrant
    /// an LLM expansion call." Documented in NEXT.md. Adjust based on
    /// real usage data, but don't set higher than ≈ 0.025 or this
    /// triggers on healthy retrievals.
    static let triggerRRFScoreUpperBound: Double = 0.020

    /// Pure predicate — given the initial top-1 result, decide whether
    /// expansion is worth running. No side effects.
    static func shouldExpand(top1Score: Double, top1IsEntityMatch: Bool) -> Bool {
        // Diagnostic override: setting UserDefaults("forceQueryExpansion")
        // to true forces expansion on EVERY query. Used by
        // tests/rag_expanded_eval.py to measure expansion's impact
        // independent of the trigger predicate. Production callers
        // should leave this off.
        if UserDefaults.standard.bool(forKey: "forceQueryExpansion") {
            return true
        }
        return top1Score < triggerRRFScoreUpperBound && !top1IsEntityMatch
    }

    // MARK: - LLM prompt (kept under 200 tokens total incl. response)

    /// One system prompt for all backends. Lowercased terms-only output
    /// keeps tokenization compact (10 short terms ≈ 30 tokens). The
    /// instruction is deliberately concrete — "might appear in stored
    /// memories" — so models extract concept synonyms instead of
    /// definitions or commentary.
    nonisolated static let systemPrompt: String = "Extract 5-10 short related terms that might appear in stored memories related to the user's question. One term per line, lowercase, no punctuation, no explanation. Just the terms."

    // MARK: - Entry point

    /// Async expansion path. Caller awaits the result; this avoids the
    /// MainActor deadlock the earlier sync wrapper hit (the LLM call
    /// hops to MainActor for `generateChatResponse`, which can't run
    /// while the caller is holding MainActor in `sem.wait()`).
    ///
    /// Returns the list of expansion terms (may be empty if the LLM
    /// returns nothing useful or the call fails). On cache hit, returns
    /// immediately without an LLM call. On cache miss, awaits the LLM
    /// round-trip (~0.5–2s on AFM for a 200-token prompt).
    static func expand(
        query: String,
        memoryStore: MemoryStore,
        llmService: LLMService
    ) async -> [String] {
        let normalized = normalizeQuery(query)
        guard !normalized.isEmpty else { return [] }
        let hash = sha256(normalized)
        let activeModel = llmService.activeModelID

        // Cache hit? Only honor the cache entry if it was produced by
        // the currently active model — different models extract
        // different concepts.
        if let cached = memoryStore.queryExpansionCacheLookup(hash: hash, modelID: activeModel) {
            halLog("HALDEBUG-EXPANSION: cache hit query='\(normalized.prefix(60))' terms=\(cached.count)")
            return cached
        }

        halLog("HALDEBUG-EXPANSION: cache miss query='\(normalized.prefix(60))' — calling LLM (\(activeModel))…")
        let start = Date()
        let terms = await callLLM(for: query, service: llmService)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        let sample = terms.prefix(8).joined(separator: ", ")
        halLog("HALDEBUG-EXPANSION: LLM returned \(terms.count) terms in \(elapsedMs)ms: \(sample)")

        if !terms.isEmpty {
            memoryStore.queryExpansionCacheStore(
                hash: hash,
                normalized: normalized,
                terms: terms,
                modelID: activeModel
            )
        }
        return terms
    }

    // MARK: - Internals

    private static func normalizeQuery(_ q: String) -> String {
        return q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Async LLM call. Pure await chain — no semaphore, no deadlock
    /// risk. The caller (`expand`) is `async` too, and propagates up
    /// to the chat path (already async) and the diagnostic API
    /// handler (wrapped in `Task { … }` at its callsite so the API
    /// thread isn't blocked).
    static func callLLM(for query: String, service: LLMService) async -> [String] {
        // Compact two-message prompt — system instruction + user query.
        // Token budget (rough): system ≈ 35 tokens, query ≈ 5–15 tokens,
        // response capped at 10 short terms ≈ 30 tokens. Total under
        // 100 tokens — well within AFM's 4K window.
        let messages: [HalChatMessage] = [
            .system(systemPrompt),
            .user(query)
        ]
        do {
            let response = try await service.generateChatResponse(
                messages: messages,
                temperature: 0.0
            )
            return parseTerms(from: response)
        } catch {
            halLog("HALDEBUG-EXPANSION: LLM call failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Parse the LLM's free-form text output into a list of clean terms.
    /// Tolerant of bullets, numbering, mixed case, trailing punctuation,
    /// and incidental commentary. Caps at 10 terms.
    nonisolated private static func parseTerms(from response: String) -> [String] {
        let lines = response.components(separatedBy: .newlines)
        var terms: [String] = []
        var seen = Set<String>()
        for line in lines {
            // Strip leading bullets, numbering, dashes, commentary.
            var s = line.trimmingCharacters(in: .whitespaces)
            // Remove leading "- ", "* ", "1. ", "1) ", etc.
            while let first = s.first, first.isPunctuation || first.isNumber || first == "•" {
                s.removeFirst()
                s = s.trimmingCharacters(in: .whitespaces)
            }
            // Lowercase + keep letters, digits, spaces, hyphens.
            let clean = s.lowercased().filter { c in
                c.isLetter || c.isNumber || c == " " || c == "-"
            }.trimmingCharacters(in: .whitespaces)
            // Multi-word phrases up to 30 chars are fine — Nomic and FTS5
            // both handle multi-word tokens (FTS5 will tokenize internally).
            guard clean.count >= 2 && clean.count <= 30 else { continue }
            // Skip obvious sentence fragments (commas, periods inside).
            guard !clean.contains("  ") else { continue }
            // Dedupe.
            guard !seen.contains(clean) else { continue }
            seen.insert(clean)
            terms.append(clean)
            if terms.count >= 10 { break }
        }
        return terms
    }
}

// MARK: - MemoryStore cache extension

extension MemoryStore {

    /// Create the query_expansion_cache table if it doesn't exist. The
    /// table is small (a few hundred bytes per row at most) and the
    /// schema is stable; no migration needed.
    nonisolated func ensureQueryExpansionCacheSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS query_expansion_cache (
            query_hash TEXT NOT NULL,
            model_id TEXT NOT NULL,
            query_normalized TEXT NOT NULL,
            terms TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (query_hash, model_id)
        );
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Look up a cached expansion. The model_id is part of the key —
    /// different LLMs extract different concept sets so we can't share
    /// the cache across models.
    nonisolated func queryExpansionCacheLookup(hash: String, modelID: String) -> [String]? {
        ensureQueryExpansionCacheSchema()
        let sql = "SELECT terms FROM query_expansion_cache WHERE query_hash = ? AND model_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (modelID as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let raw = sqlite3_column_text(stmt, 0) else { return nil }
        let joined = String(cString: raw)
        return joined.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Store a cached expansion. INSERT OR REPLACE so re-running an
    /// expansion (e.g. after a deliberate cache invalidation) overwrites.
    nonisolated func queryExpansionCacheStore(hash: String, normalized: String, terms: [String], modelID: String) {
        ensureQueryExpansionCacheSchema()
        let joined = terms.joined(separator: "\n")
        let sql = "INSERT OR REPLACE INTO query_expansion_cache (query_hash, model_id, query_normalized, terms, created_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (modelID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (normalized as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (joined as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 5, Int64(Date().timeIntervalSince1970))
        _ = sqlite3_step(stmt)
    }

    /// Clear all cached expansions. Called by SET_LLM (model switch) and
    /// the API command CLEAR_QUERY_EXPANSION_CACHE for diagnostics.
    /// Returns the number of rows deleted.
    @discardableResult
    nonisolated func queryExpansionCacheClear() -> Int {
        ensureQueryExpansionCacheSchema()
        if sqlite3_exec(db, "DELETE FROM query_expansion_cache;", nil, nil, nil) == SQLITE_OK {
            return Int(sqlite3_changes(db))
        }
        return 0
    }

    /// Count cached entries — used by EMBEDDING_STATUS-style diagnostics
    /// and the API.
    nonisolated func queryExpansionCacheCount() -> Int {
        ensureQueryExpansionCacheSchema()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM query_expansion_cache;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }
}
// ==== LEGO END: 33 Query Expansion (LLM-Assisted Weak-Retrieval Recovery) ====
