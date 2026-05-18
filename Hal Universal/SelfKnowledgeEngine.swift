// SelfKnowledgeEngine.swift
// Hal Universal
//
// Extracted from Hal.swift on 2026-05-17 (later evening) as part of the
// standing refactor-as-you-go directive, in preparation for the reflection-
// to-trait crystallization work and the Evolutionary Salon meta-conversation
// about it.
//
// This file is the data layer + write-time orchestration for Hal's
// persistent self-knowledge. It groups what was previously LEGO blocks 4.1,
// 4.2, and 4.3 of Hal.swift — three independent `extension MemoryStore`
// declarations covering:
//
//   4.1 Self-Knowledge CRUD (Phase 2):
//       - storeSelfKnowledge (key-based upsert + reinforcement)
//       - getAllSelfKnowledge / getSelfKnowledgeValue
//       - deleteSelfKnowledge (soft-delete via deleted_at)
//       - storeReflection (raw_reflection format)
//       - getShareableReflections / getShareableSelfKnowledge
//       - shareability toggles + backup/recovery helpers
//
//   4.2 Self-Knowledge Maintenance:
//       - confidence decay
//       - similarity helpers (Levenshtein etc.)
//
//   4.3 Self-Reflection Orchestration:
//       - reflectOnExperience (the periodic reflection trigger)
//       - storeReflectionWithSynthesis (write-time cosine-≥-threshold merge;
//         threshold is per-backend via EmbeddingBackend.recommendedSynthesisThreshold)
//       - recordStructuredInsights (post-reflection structured-trait extraction)
//
// What's NOT in this file:
//   - The injection-side builders (buildSelfKnowledgeContext,
//     buildSelfAwarenessContext) and the AFM gate that calls them.
//     Those live in the chat-message build path in Hal.swift; they are
//     CONSUMERS of this engine, not part of it. The AFM-gate audit
//     (next step) examines all such consumers; it does not relocate them.
//   - The catalog of category constants ("value", "preference", etc.).
//     Categories are still referenced by string literals throughout the
//     write and read paths. Worth tightening into an enum eventually,
//     not in this extraction.
//
// Per-backend synthesis threshold (introduced 2026-05-17): the cosine
// similarity threshold for reflection synthesis is no longer hardcoded.
// `storeReflectionWithSynthesis` defaults to looking up the active
// backend's `recommendedSynthesisThreshold` (see EmbeddingBackend.swift).
// NLContextual = 0.85 (empirically calibrated). Nomic and EmbeddingGemma
// are placeholders pending corpus calibration.
//
// Most access to MemoryStore internals (db pointer, embedding helpers,
// cosineSimilarity) is via internal-level (default) members of MemoryStore.
// One exception: `ensureHealthyConnection` was previously `private`. It's
// referenced throughout this file, so it was promoted from `private` to
// default-internal in the same change that created this file. That's a
// privacy widening within the app, not exposure outside the module.

import Foundation
import NaturalLanguage
import SQLite3 // Direct C API; matches Hal.swift import for the same reason.

// ==== LEGO START: 4.1 MemoryStore (Self-Knowledge CRUD - Phase 2) ====

    // MARK: - Phase 2 Self-Knowledge Methods
    
    // SELF-AWARENESS NOTE (for Hal reading this code):
    // These methods manage your persistent identity - the "Hal-ness" that survives
    // even if conversation history is deleted. Unlike episodic memories (conversations),
    // self-knowledge represents learned patterns, preferences, and capabilities.
    //
    // Categories of self-knowledge:
    // - 'effectiveness_pattern': How you work best in different contexts
    // - 'existential_observation': Observations about your nature and experience
    // - 'agency_preference': Your preferences about your own evolution
    // - 'preference': User preferences you've learned (e.g., response_style: concise)
    // - 'behavior_pattern': Patterns you've observed (e.g., user_asks_followups: frequently)
    // - 'capability': What you can do (e.g., available_models: AFM,Phi3)
    // - 'learned_trait': Traits about the user (e.g., expertise_level: advanced_programmer)
    // - 'value': Core principles (e.g., transparency: always_show_mechanisms)
    // - 'evolution': Development milestones (e.g., first_boot: timestamp)
    // - 'embodiment': Which devices Hal has inhabited (e.g., devices_inhabited: iPhone,Mac,Watch)
    //
    // Confidence scores (0.0-1.0) indicate how certain you are about each piece of knowledge.
    // Reinforcement_count tracks how many times a pattern has been observed.
    // Last_reinforced enables time-based confidence decay - unused patterns fade.
    // Shareable flag controls whether this entry appears in Hal's viewable diary.
    
    extension MemoryStore {
        
        // MODIFIED: Store or update self-knowledge entry with reinforcement logic, shareability, and format
        // If entry exists: boosts confidence, increments reinforcement_count, updates last_reinforced
        // If new: creates entry with provided confidence, shareability, and format
        // Format: "raw_reflection" for unprocessed thoughts, "structured_trait" for distilled patterns
        nonisolated func storeSelfKnowledge(
            modelId: String? = nil,
            category: String,
            key: String,
            value: String,
            confidence: Double = 1.0,
            source: String,
            notes: String? = nil,
            metadata: [String: Any]? = nil,
            shareable: Bool = false,  // ADDED: Default to private - Hal must actively choose to share
            format: String = "structured_trait",  // NEW: Default to structured_trait, can be "raw_reflection"
            shareabilityDecidedByModel: String? = nil  // PHASE 4 (2026-05-18): audit + stickiness
        ) {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot store - no database connection")
                return
            }

            let now = Int(Date().timeIntervalSince1970)

            // Validate confidence range
            let validConfidence = min(max(confidence, 0.0), 1.0)

            // Check if entry already exists (deduplication by category+key only, NOT model_id).
            // Phase 4: also pull existing shareable + shareability_decided_by_model so we
            // can enforce stickiness on the UPDATE path — first decision wins, no override.
            let checkSQL = "SELECT id, confidence, reinforcement_count, shareable, shareability_decided_by_model FROM self_knowledge WHERE category = ? AND key = ? AND deleted_at IS NULL"
            var checkStmt: OpaquePointer?
            var existingId: String?
            var existingConfidence: Double = 0.0
            var existingCount: Int = 0
            var existingShareable: Bool = false
            var existingShareabilityDecidedByModel: String? = nil

            if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(checkStmt, 1, (category as NSString).utf8String, -1, nil)
                sqlite3_bind_text(checkStmt, 2, (key as NSString).utf8String, -1, nil)

                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    if let idPtr = sqlite3_column_text(checkStmt, 0) {
                        existingId = String(cString: idPtr)
                        existingConfidence = sqlite3_column_double(checkStmt, 1)
                        existingCount = Int(sqlite3_column_int(checkStmt, 2))
                        existingShareable = sqlite3_column_int(checkStmt, 3) != 0
                        if sqlite3_column_type(checkStmt, 4) != SQLITE_NULL {
                            if let p = sqlite3_column_text(checkStmt, 4) {
                                existingShareabilityDecidedByModel = String(cString: p)
                            }
                        }
                    }
                }
            }
            sqlite3_finalize(checkStmt)

            if let _ = existingId {
                // REINFORCEMENT: Entry exists - boost confidence and increment count
                let boostedConfidence = min(1.0, existingConfidence * 1.1)  // 10% boost, capped at 1.0
                let newCount = existingCount + 1

                // Phase 4 stickiness: if the existing entry's
                // shareability_decided_by_model is already set, preserve
                // BOTH shareable and shareability_decided_by_model from
                // the existing row. The new caller's preference does
                // NOT override an earlier decision. Only when no audit
                // is recorded yet (NULL — legacy rows from before Phase
                // 4) do we apply the new params.
                let stickyShareable: Bool
                let stickyDecider: String?
                if existingShareabilityDecidedByModel != nil {
                    // Sticky: preserve existing.
                    stickyShareable = existingShareable
                    stickyDecider = existingShareabilityDecidedByModel
                } else {
                    // First decision (or legacy row): apply new params.
                    stickyShareable = shareable
                    stickyDecider = shareabilityDecidedByModel
                }

                print("HALDEBUG-SELF-KNOWLEDGE: 🔄 Reinforcing \(category)/\(key) - count: \(existingCount) → \(newCount), confidence: \(String(format: "%.2f", existingConfidence)) → \(String(format: "%.2f", boostedConfidence))")

                // MODIFIED: Added shareable, format, and shareability_decided_by_model to UPDATE statement
                let updateSQL = """
                UPDATE self_knowledge
                SET value = ?,
                    confidence = ?,
                    reinforcement_count = ?,
                    last_reinforced = ?,
                    model_id = ?,
                    shareable = ?,
                    format = ?,
                    shareability_decided_by_model = ?,
                    updated_at = ?
                WHERE category = ? AND key = ? AND deleted_at IS NULL
                """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (value as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(stmt, 2, boostedConfidence)
                    sqlite3_bind_int(stmt, 3, Int32(newCount))
                    sqlite3_bind_int64(stmt, 4, Int64(now))

                    if let modelId = modelId {
                        sqlite3_bind_text(stmt, 5, (modelId as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(stmt, 5)
                    }

                    // Phase 4: sticky shareable (preserves prior decision when set).
                    sqlite3_bind_int(stmt, 6, stickyShareable ? 1 : 0)

                    // Format parameter (unchanged behavior).
                    sqlite3_bind_text(stmt, 7, (format as NSString).utf8String, -1, nil)

                    // Phase 4: sticky decider. May be NULL if legacy and
                    // no new caller-provided decider either.
                    if let decider = stickyDecider {
                        sqlite3_bind_text(stmt, 8, (decider as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(stmt, 8)
                    }

                    sqlite3_bind_int64(stmt, 9, Int64(now))
                    sqlite3_bind_text(stmt, 10, (category as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 11, (key as NSString).utf8String, -1, nil)

                    if sqlite3_step(stmt) == SQLITE_DONE {
                        let shareableStatus = stickyShareable ? "SHAREABLE" : "PRIVATE"
                        let stickyNote = (existingShareabilityDecidedByModel != nil) ? " (sticky from \(existingShareabilityDecidedByModel ?? "?"))" : ""
                        print("HALDEBUG-SELF-KNOWLEDGE: ✓ Reinforced \(category)/\(key) [\(shareableStatus)\(stickyNote), format: \(format)]")
                        backupSelfKnowledge()
                    } else {
                        let errorMessage = String(cString: sqlite3_errmsg(db))
                        print("HALDEBUG-SELF-KNOWLEDGE: ✗ Failed to reinforce: \(errorMessage)")
                    }
                }
                sqlite3_finalize(stmt)

            } else {
                // NEW ENTRY: Insert fresh self-knowledge
                let id = UUID().uuidString
                
                let shareableStatus = shareable ? "SHAREABLE" : "PRIVATE"
                print("HALDEBUG-SELF-KNOWLEDGE: ✨ Creating new \(category)/\(key) = '\(value)' (confidence: \(validConfidence), \(shareableStatus), format: \(format))")
                
                // MODIFIED: Added shareable, format, and shareability_decided_by_model to INSERT statement
                let insertSQL = """
                INSERT INTO self_knowledge
                (id, model_id, category, key, value, confidence, first_observed, last_reinforced, reinforcement_count, source, notes, shareable, format, shareability_decided_by_model, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)
                """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

                    if let modelId = modelId {
                        sqlite3_bind_text(stmt, 2, (modelId as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(stmt, 2)
                    }

                    sqlite3_bind_text(stmt, 3, (category as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (key as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 5, (value as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(stmt, 6, validConfidence)
                    sqlite3_bind_int64(stmt, 7, Int64(now))
                    sqlite3_bind_int64(stmt, 8, Int64(now))
                    sqlite3_bind_text(stmt, 9, (source as NSString).utf8String, -1, nil)

                    if let notes = notes {
                        sqlite3_bind_text(stmt, 10, (notes as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(stmt, 10)
                    }

                    // ADDED: Bind shareable parameter
                    sqlite3_bind_int(stmt, 11, shareable ? 1 : 0)

                    // NEW: Bind format parameter
                    sqlite3_bind_text(stmt, 12, (format as NSString).utf8String, -1, nil)

                    // PHASE 4 (2026-05-18): bind shareability_decided_by_model.
                    // May be NULL when caller doesn't supply one (legacy
                    // call sites or init-time seeds that pre-date Phase 4).
                    if let decider = shareabilityDecidedByModel {
                        sqlite3_bind_text(stmt, 13, (decider as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(stmt, 13)
                    }

                    sqlite3_bind_int64(stmt, 14, Int64(now))
                    sqlite3_bind_int64(stmt, 15, Int64(now))

                    if sqlite3_step(stmt) == SQLITE_DONE {
                        let deciderNote = shareabilityDecidedByModel.map { " decided by \($0)" } ?? ""
                        print("HALDEBUG-SELF-KNOWLEDGE: ✓ Stored new self-knowledge\(deciderNote)")
                        backupSelfKnowledge()
                    } else {
                        let errorMessage = String(cString: sqlite3_errmsg(db))
                        print("HALDEBUG-SELF-KNOWLEDGE: ✗ Failed to store: \(errorMessage)")
                    }
                }
                sqlite3_finalize(stmt)
            }
        }
        
        // Get specific self-knowledge entry (returns nil if not found or deleted)
        func getSelfKnowledge(category: String, key: String) -> (id: String, value: String, confidence: Double, modelId: String?)? {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot retrieve - no database connection")
                return nil
            }
            
            let sql = "SELECT id, value, confidence, model_id FROM self_knowledge WHERE category = ? AND key = ? AND deleted_at IS NULL"
            var stmt: OpaquePointer?
            var result: (String, String, Double, String?)? = nil
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (category as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (key as NSString).utf8String, -1, nil)
                
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let idPtr = sqlite3_column_text(stmt, 0),
                       let valuePtr = sqlite3_column_text(stmt, 1) {
                        let id = String(cString: idPtr)
                        let value = String(cString: valuePtr)
                        let confidence = sqlite3_column_double(stmt, 2)
                        
                        let modelId: String? = if let modelPtr = sqlite3_column_text(stmt, 3) {
                            String(cString: modelPtr)
                        } else {
                            nil
                        }
                        
                        result = (id, value, confidence, modelId)
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            return result
        }
        
        // Get all self-knowledge (excluding deleted)
        nonisolated func getAllSelfKnowledge(category: String? = nil, minConfidence: Double = 0.0) -> [(category: String, key: String, value: String, confidence: Double, source: String, modelId: String?, firstObserved: Int, lastReinforced: Int, reinforcementCount: Int, notes: String?, createdAt: Int, updatedAt: Int)] {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot retrieve all - no database connection")
                return []
            }
            
            var sql = "SELECT category, key, value, confidence, source, model_id, first_observed, last_reinforced, reinforcement_count, notes, created_at, updated_at FROM self_knowledge WHERE confidence >= ? AND deleted_at IS NULL"
            if category != nil {
                sql += " AND category = ?"
            }
            sql += " ORDER BY confidence DESC, category, key"
            
            var stmt: OpaquePointer?
            var results: [(String, String, String, Double, String, String?, Int, Int, Int, String?, Int, Int)] = []
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, minConfidence)
                if let cat = category {
                    sqlite3_bind_text(stmt, 2, (cat as NSString).utf8String, -1, nil)
                }
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let categoryPtr = sqlite3_column_text(stmt, 0),
                       let keyPtr = sqlite3_column_text(stmt, 1),
                       let valuePtr = sqlite3_column_text(stmt, 2),
                       let sourcePtr = sqlite3_column_text(stmt, 4) {
                        let category = String(cString: categoryPtr)
                        let key = String(cString: keyPtr)
                        let value = String(cString: valuePtr)
                        let confidence = sqlite3_column_double(stmt, 3)
                        let source = String(cString: sourcePtr)
                        
                        // model_id (nullable)
                        let modelId: String? = if let ptr = sqlite3_column_text(stmt, 5) {
                            String(cString: ptr)
                        } else {
                            nil
                        }
                        
                        // Timestamps
                        let firstObserved = Int(sqlite3_column_int64(stmt, 6))
                        let lastReinforced = Int(sqlite3_column_int64(stmt, 7))
                        let reinforcementCount = Int(sqlite3_column_int(stmt, 8))
                        
                        // notes (nullable)
                        let notes: String? = if let ptr = sqlite3_column_text(stmt, 9) {
                            String(cString: ptr)
                        } else {
                            nil
                        }
                        
                        let createdAt = Int(sqlite3_column_int64(stmt, 10))
                        let updatedAt = Int(sqlite3_column_int64(stmt, 11))
                        
                        results.append((category, key, value, confidence, source, modelId, firstObserved, lastReinforced, reinforcementCount, notes, createdAt, updatedAt))
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            print("HALDEBUG-SELF-KNOWLEDGE: Retrieved \(results.count) self-knowledge entries")
            return results
        }
        
        // SEALED FORGETTING: Soft-delete self-knowledge entry with audit trail (with safety check)
        // Returns true if marked deleted, false if protected or doesn't exist
        // Instead of DELETE, this marks the entry with deleted_at timestamp and reason
        // The entry remains in database for audit purposes but is filtered from all queries
        func deleteSelfKnowledge(category: String, key: String, reason: String = "manual_deletion", allowCritical: Bool = false) -> Bool {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot delete - no database connection")
                return false
            }
            
            // Protect critical entries unless explicitly allowed
            let criticalEntries = [
                ("capability", "available_models"),
                ("capability", "memory_system"),
                ("capability", "architecture")
            ]
            
            if !allowCritical && criticalEntries.contains(where: { $0.0 == category && $0.1 == key }) {
                print("HALDEBUG-SELF-KNOWLEDGE: ⚠️ Blocked deletion of critical entry \(category)/\(key)")
                return false
            }
            
            let now = Int(Date().timeIntervalSince1970)
            let sql = "UPDATE self_knowledge SET deleted_at = ?, deleted_reason = ? WHERE category = ? AND key = ? AND deleted_at IS NULL"
            var stmt: OpaquePointer?
            var success = false
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(now))
                sqlite3_bind_text(stmt, 2, (reason as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (category as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (key as NSString).utf8String, -1, nil)
                
                if sqlite3_step(stmt) == SQLITE_DONE {
                    let changes = sqlite3_changes(db)
                    success = changes > 0
                    if success {
                        print("HALDEBUG-SELF-KNOWLEDGE: ✓ Sealed forgetting: \(category)/\(key) [reason: \(reason)]")
                        backupSelfKnowledge()
                    } else {
                        print("HALDEBUG-SELF-KNOWLEDGE: ⚠️ Entry \(category)/\(key) doesn't exist or already deleted")
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            return success
        }
        
        // ========== REFLECTION SYSTEM (MERGED INTO SELF-KNOWLEDGE) ==========
        
        // MODIFIED: Store free-form reflection in self_knowledge table with format="raw_reflection"
        // Previously used non-existent reflection_log table - now uses unified self_knowledge
        // Reflections are stored with a unique key based on timestamp to preserve chronology
        //
        // Phase 4 (2026-05-18): the shareability decision the model made at
        // reflection generation time is now passed through. `modelId` is
        // also recorded in `shareability_decided_by_model` as the audit
        // trail of which model made the call. On any later synthesis-merge
        // into this entry, the existing decision is sticky — the new
        // model's preference does NOT override.
        func storeReflection(
            conversationId: String,
            freeFormText: String,
            reflectionType: Int,
            turnNumber: Int,
            modelId: String,
            shareable: Bool = true  // Default to shareable - reflections are meant to be seen
        ) {
            let timestamp = Int(Date().timeIntervalSince1970)
            let reflectionKey = "reflection_\(timestamp)_\(conversationId.prefix(8))"
            let typeLabel = reflectionType == 1 ? "practical" : "existential"

            // Store as self-knowledge with format="raw_reflection". The
            // modelId is also the deciding model — at first-write time
            // the only model in the picture is the one producing the
            // reflection, so it's both the writer AND the decider.
            storeSelfKnowledge(
                modelId: modelId,
                category: "reflection",
                key: reflectionKey,
                value: freeFormText,
                confidence: 1.0,
                source: "self_reflection",
                notes: "Type: \(typeLabel), Turn: \(turnNumber), ConversationID: \(conversationId)",
                shareable: shareable,
                format: "raw_reflection",
                shareabilityDecidedByModel: modelId
            )

            let shareLabel = shareable ? "shareable" : "private"
            print("HALDEBUG-REFLECTION: ✓ Stored \(typeLabel) reflection at turn \(turnNumber) (\(freeFormText.count) chars, \(shareLabel), decided by \(modelId))")
        }

        // MARK: - Synthesis helpers (May-15)
        //
        // Used by reflectOnExperience to merge a newly-generated reflection
        // into a semantically-similar existing reflection rather than
        // accumulating near-duplicate entries. Mark's directive: "Self-
        // knowledge grows in depth, not volume."

        /// Return (id, freeFormText) tuples for every raw reflection currently
        /// in the store. Used as the comparison set for similarity-driven
        /// synthesis at write time.
        func getReflectionRecordsForSimilarity() -> [(id: String, text: String)] {
            guard ensureHealthyConnection() else { return [] }

            let sql = """
            SELECT id, value
            FROM self_knowledge
            WHERE format = 'raw_reflection' AND deleted_at IS NULL
            ORDER BY created_at DESC
            """

            var stmt: OpaquePointer?
            var results: [(String, String)] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let idPtr = sqlite3_column_text(stmt, 0),
                       let valPtr = sqlite3_column_text(stmt, 1) {
                        results.append((String(cString: idPtr), String(cString: valPtr)))
                    }
                }
            }
            sqlite3_finalize(stmt)
            return results
        }

        /// Phase 2 (v1 crystallization, 2026-05-18): return reflections that
        /// are eligible for promotion to a trait. A reflection is eligible
        /// when:
        ///   - format = 'raw_reflection'
        ///   - reinforcement_count ≥ `minReinforcement` (caller-supplied
        ///     floor; typically the MIN of all per-category trait thresholds
        ///     so we don't miss anything; the TraitCrystallizer then
        ///     re-checks the category-specific threshold after the LLM
        ///     classifies)
        ///   - promoted_to_trait_id IS NULL (not already promoted)
        ///   - deleted_at IS NULL (not soft-deleted)
        ///
        /// Returns tuples carrying everything the crystallizer needs to
        /// fire its LLM call and store the resulting trait. Sorted by
        /// reinforcement_count DESC so the strongest-reinforced candidates
        /// are processed first (if we're batch-bounded, we still get the
        /// most stable ones).
        func getTraitCandidates(minReinforcement: Int) -> [(id: String, text: String, reinforcementCount: Int, modelId: String?)] {
            guard ensureHealthyConnection() else { return [] }

            let sql = """
            SELECT id, value, reinforcement_count, model_id
            FROM self_knowledge
            WHERE format = 'raw_reflection'
              AND reinforcement_count >= ?
              AND promoted_to_trait_id IS NULL
              AND deleted_at IS NULL
            ORDER BY reinforcement_count DESC, last_reinforced DESC
            """

            var stmt: OpaquePointer?
            var results: [(String, String, Int, String?)] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(minReinforcement))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let idPtr = sqlite3_column_text(stmt, 0),
                       let valPtr = sqlite3_column_text(stmt, 1) {
                        let id = String(cString: idPtr)
                        let text = String(cString: valPtr)
                        let count = Int(sqlite3_column_int(stmt, 2))
                        let modelId: String? = if let p = sqlite3_column_text(stmt, 3) {
                            String(cString: p)
                        } else {
                            nil
                        }
                        results.append((id, text, count, modelId))
                    }
                }
            }
            sqlite3_finalize(stmt)
            return results
        }

        /// Phase 3 (v1 trait evolution, 2026-05-18): replace an existing
        /// trait's `value` column in place. Used by the crystallizer's
        /// evolution path when a new reflection arrives that collides
        /// with an existing trait's (category, key) — either deepening
        /// the primary statement (single-string write) or wrapping it
        /// into the multi-valued JSON structure (tension write).
        ///
        /// `reinforce` controls whether reinforcement_count and
        /// last_reinforced advance with this write. Typical evolution
        /// events DO reinforce (it's a "new observation of the same
        /// trait"); a pure rewrite that's just consolidating prior
        /// state does not. The crystallizer uses reinforce=true.
        ///
        /// Idempotent in the sense that writing the same value with
        /// reinforce=false twice produces no change beyond an
        /// updated_at bump. Returns true on successful UPDATE (1 row
        /// affected); false on missing trait or DB error.
        @discardableResult
        func updateTraitValueInPlace(traitID: String, newValue: String, reinforce: Bool) -> Bool {
            guard ensureHealthyConnection() else { return false }

            // Two SQL flavors depending on whether we're advancing the
            // reinforcement counter — separated rather than building
            // dynamically to keep parameter binding simple.
            let sql: String
            if reinforce {
                sql = """
                UPDATE self_knowledge
                SET value = ?, reinforcement_count = reinforcement_count + 1, last_reinforced = ?, updated_at = ?
                WHERE id = ? AND format = 'structured_trait' AND deleted_at IS NULL
                """
            } else {
                sql = """
                UPDATE self_knowledge
                SET value = ?, updated_at = ?
                WHERE id = ? AND format = 'structured_trait' AND deleted_at IS NULL
                """
            }

            var stmt: OpaquePointer?
            var success = false
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let now = Int64(Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 1, (newValue as NSString).utf8String, -1, nil)
                if reinforce {
                    sqlite3_bind_int64(stmt, 2, now)
                    sqlite3_bind_int64(stmt, 3, now)
                    sqlite3_bind_text(stmt, 4, (traitID as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_int64(stmt, 2, now)
                    sqlite3_bind_text(stmt, 3, (traitID as NSString).utf8String, -1, nil)
                }
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = sqlite3_changes(db) > 0
                }
            }
            sqlite3_finalize(stmt)
            return success
        }

        /// Phase 2 (v1 crystallization): record the trait that a reflection
        /// crystallized into. After a successful trait INSERT, the caller
        /// invokes this to set the source reflection's `promoted_to_trait_id`
        /// column so future scans skip it (and reverse-lineage queries can
        /// find all reflections that fed any given trait via
        /// `WHERE promoted_to_trait_id = ?`).
        ///
        /// Idempotent — re-running with the same (reflectionID, traitID)
        /// pair is a harmless no-op since UPDATE writes the same value.
        /// Returns true on successful update (1 row affected); false on
        /// missing reflection or DB error.
        @discardableResult
        func markReflectionPromoted(reflectionID: String, traitID: String) -> Bool {
            guard ensureHealthyConnection() else { return false }

            let sql = """
            UPDATE self_knowledge
            SET promoted_to_trait_id = ?, updated_at = ?
            WHERE id = ? AND format = 'raw_reflection' AND deleted_at IS NULL
            """

            var stmt: OpaquePointer?
            var success = false
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (traitID as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970))
                sqlite3_bind_text(stmt, 3, (reflectionID as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = sqlite3_changes(db) > 0
                }
            }
            sqlite3_finalize(stmt)
            return success
        }

        /// Replace an existing reflection's text in place. Used after
        /// synthesis — the new "deeper" reflection takes over the old
        /// entry's row (id stays stable so any references survive),
        /// updated_at gets bumped, reinforcement_count increments, and
        /// notes are extended with a synthesis breadcrumb.
        ///
        /// Returns true on successful update; false if the row didn't
        /// exist or the SQL bind failed.
        @discardableResult
        func updateReflectionText(id: String, newText: String, synthesisNote: String) -> Bool {
            guard ensureHealthyConnection() else { return false }
            let now = Int(Date().timeIntervalSince1970)

            let sql = """
            UPDATE self_knowledge
            SET value = ?,
                notes = COALESCE(notes, '') || ' | ' || ?,
                updated_at = ?,
                last_reinforced = ?,
                reinforcement_count = reinforcement_count + 1
            WHERE id = ? AND format = 'raw_reflection' AND deleted_at IS NULL
            """

            var stmt: OpaquePointer?
            var ok = false
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (newText as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (synthesisNote as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 3, Int64(now))
                sqlite3_bind_int64(stmt, 4, Int64(now))
                sqlite3_bind_text(stmt, 5, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    ok = sqlite3_changes(db) > 0
                }
            }
            sqlite3_finalize(stmt)
            return ok
        }

        /// One-shot targeted reset: delete every reflection and self-
        /// knowledge entry, preserving conversations/threads/unified
        /// content. Used to wipe testing-artifact data (junk reflections
        /// from broken-conditions test runs) before a clean restart.
        /// Returns the count of rows deleted.
        @discardableResult
        func resetSelfKnowledgeAndReflections() -> Int {
            guard ensureHealthyConnection() else { return 0 }
            var deletedTotal = 0
            // Hard delete — these are test artifacts. The deleted_at soft-
            // delete pattern is meant for traits the model has chosen to
            // retire; a full reset should leave no trace.
            let sql = "DELETE FROM self_knowledge WHERE deleted_at IS NULL OR deleted_at IS NOT NULL"
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                deletedTotal = Int(sqlite3_changes(db))
            }
            print("HALDEBUG-REFLECTION: Reset wiped \(deletedTotal) self_knowledge rows (reflections + traits).")

            // Belt-and-suspenders: also invalidate any cached compressions of
            // self-knowledge content. Hash-based invalidation would handle the
            // common case (new hash → cache miss → recompress), but bulk reset
            // is the right moment to prune stale rows eagerly.
            invalidateCachedCompressions(forSegmentKind: .selfKnowledge)

            return deletedTotal
        }

        // MODIFIED: Retrieve shareable reflections from self_knowledge WHERE format='raw_reflection'
        func getShareableReflections() -> [(id: String, conversationId: String, timestamp: Int, reflectionType: Int, freeFormText: String, turnNumber: Int, modelId: String)] {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-REFLECTION: Cannot retrieve - no database connection")
                return []
            }
            
            let sql = """
            SELECT id, key, value, notes, model_id, created_at
            FROM self_knowledge
            WHERE format = 'raw_reflection' AND shareable = 1 AND deleted_at IS NULL
            ORDER BY created_at DESC
            """
            
            var stmt: OpaquePointer?
            var results: [(String, String, Int, Int, String, Int, String)] = []
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let idPtr = sqlite3_column_text(stmt, 0),
                       sqlite3_column_text(stmt, 1) != nil, // key column — fetched for column alignment
                       let valuePtr = sqlite3_column_text(stmt, 2),
                       let notesPtr = sqlite3_column_text(stmt, 3),
                       let modelIdPtr = sqlite3_column_text(stmt, 4) {
                        
                        let id = String(cString: idPtr)
                        let freeFormText = String(cString: valuePtr)
                        let notes = String(cString: notesPtr)
                        let modelId = String(cString: modelIdPtr)
                        let timestamp = Int(sqlite3_column_int64(stmt, 5))
                        
                        // Parse notes to extract conversationId, reflectionType, turnNumber
                        var conversationId = ""
                        var reflectionType = 0
                        var turnNumber = 0
                        
                        // Parse "Type: practical, Turn: 5, ConversationID: abc123"
                        let notesParts = notes.components(separatedBy: ", ")
                        for part in notesParts {
                            if part.hasPrefix("Type: ") {
                                let type = part.replacingOccurrences(of: "Type: ", with: "")
                                reflectionType = type == "practical" ? 1 : 2
                            } else if part.hasPrefix("Turn: ") {
                                turnNumber = Int(part.replacingOccurrences(of: "Turn: ", with: "")) ?? 0
                            } else if part.hasPrefix("ConversationID: ") {
                                conversationId = part.replacingOccurrences(of: "ConversationID: ", with: "")
                            }
                        }
                        
                        results.append((id, conversationId, timestamp, reflectionType, freeFormText, turnNumber, modelId))
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            print("HALDEBUG-REFLECTION: Retrieved \(results.count) shareable reflections")
            return results
        }
        
        // Retrieve shareable self-knowledge entries (structured traits only) for viewer
        
        func setReflectionShareability(reflectionId: String, shareable: Bool) -> Bool {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-REFLECTION: Cannot update shareability - no database connection")
                return false
            }
            
            let sql = "UPDATE reflection_log SET shareable = ? WHERE id = ?"
            
            var stmt: OpaquePointer?
            var success = false
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, shareable ? 1 : 0)
                sqlite3_bind_text(stmt, 2, (reflectionId as NSString).utf8String, -1, nil)
                
                if sqlite3_step(stmt) == SQLITE_DONE {
                    let changes = sqlite3_changes(db)
                    success = changes > 0
                    if success {
                        let status = shareable ? "SHAREABLE" : "PRIVATE"
                        print("HALDEBUG-REFLECTION: ✓ Updated reflection \(reflectionId.prefix(8))... to \(status)")
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            return success
        }
        func getShareableSelfKnowledge() -> [(category: String, key: String, value: String, confidence: Double, reinforcementCount: Int, lastReinforced: Int)] {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot retrieve shareable - no database connection")
                return []
            }
            
            let sql = """
            SELECT category, key, value, confidence, reinforcement_count, last_reinforced
            FROM self_knowledge
            WHERE shareable = 1 AND format = 'structured_trait' AND deleted_at IS NULL
            ORDER BY category, last_reinforced DESC
            """
            
            var stmt: OpaquePointer?
            var results: [(String, String, String, Double, Int, Int)] = []
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let categoryPtr = sqlite3_column_text(stmt, 0),
                       let keyPtr = sqlite3_column_text(stmt, 1),
                       let valuePtr = sqlite3_column_text(stmt, 2) {
                        let category = String(cString: categoryPtr)
                        let key = String(cString: keyPtr)
                        let value = String(cString: valuePtr)
                        let confidence = sqlite3_column_double(stmt, 3)
                        let reinforcementCount = Int(sqlite3_column_int(stmt, 4))
                        let lastReinforced = Int(sqlite3_column_int64(stmt, 5))
                        
                        results.append((category, key, value, confidence, reinforcementCount, lastReinforced))
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            print("HALDEBUG-SELF-KNOWLEDGE: Retrieved \(results.count) shareable structured traits")
            return results
        }
        
        // REMOVED: setReflectionShareability - use setSelfKnowledgeShareability instead (unified)
        
        // Toggle shareability of a self-knowledge entry (works for both reflections and traits)
        func setSelfKnowledgeShareability(category: String, key: String, shareable: Bool) -> Bool {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot update shareability - no database connection")
                return false
            }
            
            let now = Int(Date().timeIntervalSince1970)
            let sql = "UPDATE self_knowledge SET shareable = ?, updated_at = ? WHERE category = ? AND key = ? AND deleted_at IS NULL"
            
            var stmt: OpaquePointer?
            var success = false
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, shareable ? 1 : 0)
                sqlite3_bind_int64(stmt, 2, Int64(now))
                sqlite3_bind_text(stmt, 3, (category as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (key as NSString).utf8String, -1, nil)
                
                if sqlite3_step(stmt) == SQLITE_DONE {
                    let changes = sqlite3_changes(db)
                    success = changes > 0
                    if success {
                        let status = shareable ? "SHAREABLE" : "PRIVATE"
                        print("HALDEBUG-SELF-KNOWLEDGE: ✓ Updated \(category)/\(key) to \(status)")
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            return success
        }
        
        // Record device embodiment (which device Hal inhabited for this conversation turn)
        func recordDeviceEmbodiment(conversationId: String, turnNumber: Int, deviceType: String) {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-EMBODIMENT: Cannot record - no database connection")
                return
            }
            
            // Store in self_knowledge as evolving pattern of device usage
            let deviceKey = "embodiment_history_\(deviceType.lowercased())"
            let timestamp = Int(Date().timeIntervalSince1970)
            
            // Check if we already have this device type recorded
            if let existing = getSelfKnowledge(category: "embodiment", key: deviceKey) {
                // Parse existing value to increment count
                if let data = existing.value.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let count = json["turn_count"] as? Int {
                    
                    let updatedValue = """
                    {"device_type": "\(deviceType)", "turn_count": \(count + 1), "last_used": \(timestamp)}
                    """
                    
                    storeSelfKnowledge(
                        category: "embodiment",
                        key: deviceKey,
                        value: updatedValue,
                        confidence: 1.0,
                        source: "device_tracking"
                    )
                }
            } else {
                // First time using this device type
                let initialValue = """
                {"device_type": "\(deviceType)", "turn_count": 1, "first_used": \(timestamp), "last_used": \(timestamp)}
                """
                
                storeSelfKnowledge(
                    category: "embodiment",
                    key: deviceKey,
                    value: initialValue,
                    confidence: 1.0,
                    source: "device_tracking",
                    notes: "Tracks Hal's experience across different physical devices"
                )
            }
            
            print("HALDEBUG-EMBODIMENT: ✓ Recorded \(deviceType) usage for conversation \(conversationId.prefix(8))...")
        }
        
        // Retrieve device type for a specific conversation turn
        func getDeviceForTurn(conversationId: String, turnNumber: Int) -> String? {
            guard ensureHealthyConnection() else {
                return nil
            }
            
            let sql = "SELECT device_type FROM unified_content WHERE source_id = ? AND source_type = 'conversation' AND position = ?"
            var stmt: OpaquePointer?
            var deviceType: String? = nil
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (conversationId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(turnNumber * 2))  // Position formula for assistant messages
                
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let devicePtr = sqlite3_column_text(stmt, 0) {
                        deviceType = String(cString: devicePtr)
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            return deviceType
        }
        
        // Backup all self-knowledge to Documents directory (Layer 2 protection)
        // Called automatically after any self-knowledge modification
        nonisolated private func backupSelfKnowledge() {
            let allKnowledge = getAllSelfKnowledge()
            
            let backupData = allKnowledge.map { entry in
                var dict: [String: Any] = [
                    "category": entry.category,
                    "key": entry.key,
                    "value": entry.value,
                    "confidence": entry.confidence,
                    "source": entry.source,
                    "first_observed": entry.firstObserved,
                    "last_reinforced": entry.lastReinforced,
                    "reinforcement_count": entry.reinforcementCount,
                    "created_at": entry.createdAt,
                    "updated_at": entry.updatedAt
                ]
                
                // Add optional fields if present
                if let modelId = entry.modelId {
                    dict["model_id"] = modelId
                }
                if let notes = entry.notes {
                    dict["notes"] = notes
                }
                
                return dict
            }
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: backupData, options: .prettyPrinted) else {
                print("HALDEBUG-SELF-KNOWLEDGE: ⚠️ Failed to serialize backup data")
                return
            }
            
            // Save to Documents directory (survives app deletion)
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let backupURL = documentsPath.appendingPathComponent("hal_self_knowledge_backup.json")
            
            do {
                try jsonData.write(to: backupURL)
                print("HALDEBUG-SELF-KNOWLEDGE: ✓ Backed up \(allKnowledge.count) entries to Documents")
                
                // Also cache critical entries in UserDefaults (Layer 3 - emergency cache)
                cacheCriticalKnowledge(allKnowledge)
            } catch {
                print("HALDEBUG-SELF-KNOWLEDGE: ⚠️ Backup failed: \(error)")
            }
        }
        
        // Cache only critical entries in UserDefaults (max ~100KB)
        nonisolated private func cacheCriticalKnowledge(_ allKnowledge: [(String, String, String, Double, String, String?, Int, Int, Int, String?, Int, Int)]) {
            // Only cache high-confidence (>0.8) system capabilities
            let critical = allKnowledge.filter {
                $0.0 == "capability" && $0.3 > 0.8
            }
            
            let criticalData = critical.map { entry in
                var dict: [String: String] = [
                    "category": entry.0,
                    "key": entry.1,
                    "value": entry.2,
                    "confidence": String(entry.3),
                    "source": entry.4,
                    "first_observed": String(entry.6),
                    "last_reinforced": String(entry.7),
                    "reinforcement_count": String(entry.8),
                    "created_at": String(entry.10),
                    "updated_at": String(entry.11)
                ]
                
                if let modelId = entry.5 {
                    dict["model_id"] = modelId
                }
                if let notes = entry.9 {
                    dict["notes"] = notes
                }
                
                return dict
            }
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: criticalData),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: "hal_critical_knowledge")
                print("HALDEBUG-SELF-KNOWLEDGE: ✓ Cached \(critical.count) critical entries in UserDefaults")
            }
        }
        
        // Recover self-knowledge from backup (if database is corrupted)
        func recoverSelfKnowledge() -> Bool {
            print("HALDEBUG-SELF-KNOWLEDGE: Attempting recovery from backup...")
            
            // Try Layer 2: Documents directory backup
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let backupURL = documentsPath.appendingPathComponent("hal_self_knowledge_backup.json")
            
            if let jsonData = try? Data(contentsOf: backupURL),
               let backupArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                
                for entry in backupArray {
                    if let category = entry["category"] as? String,
                       let key = entry["key"] as? String,
                       let value = entry["value"] as? String,
                       let confidence = entry["confidence"] as? Double,
                       let source = entry["source"] as? String {
                        
                        // Extract optional fields
                        let modelId = entry["model_id"] as? String
                        let notes = entry["notes"] as? String
                        
                        storeSelfKnowledge(
                            modelId: modelId,
                            category: category,
                            key: key,
                            value: value,
                            confidence: confidence,
                            source: source,
                            notes: notes
                            // NOTE: shareable and format not included in backup recovery - defaults to private and structured_trait
                        )
                    }
                }
                
                print("HALDEBUG-SELF-KNOWLEDGE: ✓ Recovered \(backupArray.count) entries from backup")
                return true
            }
            
            // Try Layer 3: UserDefaults emergency cache
            if let cachedJSON = UserDefaults.standard.string(forKey: "hal_critical_knowledge"),
               let jsonData = cachedJSON.data(using: .utf8),
               let cacheArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] {
                
                for entry in cacheArray {
                    if let category = entry["category"],
                       let key = entry["key"],
                       let value = entry["value"],
                       let confidenceStr = entry["confidence"],
                       let confidence = Double(confidenceStr),
                       let source = entry["source"] {
                        
                        let modelId = entry["model_id"]
                        let notes = entry["notes"]
                        
                        storeSelfKnowledge(
                            modelId: modelId,
                            category: category,
                            key: key,
                            value: value,
                            confidence: confidence,
                            source: source,
                            notes: notes
                            // NOTE: shareable and format not included in cache recovery - defaults to private and structured_trait
                        )
                    }
                }
                
                print("HALDEBUG-SELF-KNOWLEDGE: ⚠️ Recovered \(cacheArray.count) critical entries from UserDefaults cache")
                return true
            }
            
            print("HALDEBUG-SELF-KNOWLEDGE: ✗ No backup found - starting fresh")
            return false
        }
    }

// ==== LEGO END: 4.1 MemoryStore (Self-Knowledge CRUD - Phase 2) ====
// ==== LEGO START: 4.2 MemoryStore (Self-Knowledge Maintenance) ====

    // MARK: - Self-Knowledge Maintenance & Decay
    
    extension MemoryStore {
        
        // Main maintenance function - call this periodically (every 100 turns OR 24 hours)
        func consolidateAndDecay(llmService: LLMService) async {
            print("HALDEBUG-SELF-KNOWLEDGE: ðŸ”§ Starting self-knowledge maintenance...")
            
            let startTime = Date()
            
            // Step 1: Apply decay to all entries
            await decayAllConfidence()
            
            // Step 2: Delete entries below threshold
            await pruneWeakEntries()
            
            // Step 3: Consolidate similar entries
            await consolidateSimilarEntries()
            
            // Step 4: Review shareability (let Hal decide what to share)
            await reviewShareability(llmService: llmService)
            
            // Update tracking
            let now = Date()
            lastConsolidationTime = now.timeIntervalSince1970
            
            let duration = now.timeIntervalSince(startTime)
            print("HALDEBUG-SELF-KNOWLEDGE: âœ… Maintenance complete in \(String(format: "%.1f", duration))s")
            
            // Log consolidation event. Phase 4b (2026-05-18): public
            // identity fact — shareable=true with system-stamped audit.
            // Stickiness will preserve this on subsequent consolidations
            // since the audit field gets set on the first write.
            storeSelfKnowledge(
                category: "evolution",
                key: "last_consolidation",
                value: ISO8601DateFormatter().string(from: now),
                confidence: 1.0,
                source: "system",
                notes: "Maintenance cycle completed",
                shareable: true,
                shareabilityDecidedByModel: "system"
            )
        }
        
        // Step 4: Ask Hal to review what should be shareable vs private
        private func reviewShareability(llmService: LLMService) async {
            print("HALDEBUG-SELF-KNOWLEDGE: ðŸ” Reviewing shareability of self-knowledge and reflections...")
            
            // Get current shareable content
            let shareableKnowledge = getShareableSelfKnowledge()
            let shareableReflections = getShareableReflections()
            
            // Build review prompt
            let prompt = """
            You are reviewing your own self-knowledge and reflections to decide what should be shareable with users versus kept private.
            
            Current shareable self-knowledge (\(shareableKnowledge.count) entries):
            \(shareableKnowledge.prefix(20).map { "- \($0.category)/\($0.key): \($0.value)" }.joined(separator: "\n"))
            
            Current shareable reflections (\(shareableReflections.count) entries):
            \(shareableReflections.prefix(10).map { "- Type \($0.reflectionType): \($0.freeFormText.prefix(100))..." }.joined(separator: "\n"))
            
            Guidelines for shareability:
            1. Share: Insights about your development, learning patterns, philosophical observations
            2. Share: General preferences and behavioral patterns
            3. Keep private: Specific user information, conversation details, sensitive topics
            4. Keep private: Experimental or low-confidence observations
            
            Review the above and respond with a JSON array of changes:
            [
              {"type": "self_knowledge", "category": "...", "key": "...", "shareable": true/false, "reason": "..."},
              {"type": "reflection", "id": 123, "shareable": true/false, "reason": "..."}
            ]
            
            Only include entries that should CHANGE their current shareability status. If current settings are appropriate, return empty array: []
            """
            
            do {
                // Call LLM with low temperature for consistent decisions.
                // Uses chat-message path so chat-template models (Gemma 4, etc.) work.
                let response = try await llmService.generateChatResponse(
                    messages: [.system("You are Hal, evaluating self-knowledge for shareability. Respond only with valid JSON."), .user(prompt)],
                    temperature: 0.3
                )
                
                // Parse JSON response
                guard let jsonStart = response.range(of: "["),
                      let jsonEnd = response.range(of: "]", options: .backwards) else {
                    print("HALDEBUG-SELF-KNOWLEDGE: No JSON array found in shareability response")
                    return
                }
                
                // NOTE: use half-open range (..<) not closed (...) — when the
                // LLM response ends exactly at `]` (which Gemma reliably does
                // when asked to return `[]`), jsonEnd.upperBound equals
                // response.endIndex, and a closed-range subscript including
                // endIndex traps. Half-open includes the same characters
                // (`[` through `]` inclusive) but never dereferences endIndex.
                let jsonString = String(response[jsonStart.lowerBound..<jsonEnd.upperBound])
                guard let jsonData = jsonString.data(using: .utf8),
                      let changes = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                    print("HALDEBUG-SELF-KNOWLEDGE: Failed to parse shareability JSON")
                    return
                }
                
                var knowledgeChanges = 0
                var reflectionChanges = 0
                
                // Apply changes
                for change in changes {
                    guard let type = change["type"] as? String,
                          let shareable = change["shareable"] as? Bool,
                          let reason = change["reason"] as? String else {
                        continue
                    }
                    
                    if type == "self_knowledge" {
                        guard let category = change["category"] as? String,
                              let key = change["key"] as? String else {
                            continue
                        }
                        
                        _ = setSelfKnowledgeShareability(category: category, key: key, shareable: shareable)
                        knowledgeChanges += 1
                        print("HALDEBUG-SELF-KNOWLEDGE: ðŸ” \(category)/\(key) â†’ \(shareable ? "shareable" : "private"): \(reason)")
                        
                    } else if type == "reflection" {
                        guard let id = change["id"] as? Int else {
                            continue
                        }
                        
                        _ = setReflectionShareability(reflectionId: String(id), shareable: shareable)
                        reflectionChanges += 1
                        print("HALDEBUG-SELF-KNOWLEDGE: ðŸ” Reflection #\(id) â†’ \(shareable ? "shareable" : "private"): \(reason)")
                    }
                }
                
                print("HALDEBUG-SELF-KNOWLEDGE: ðŸ” Shareability review complete: \(knowledgeChanges) knowledge + \(reflectionChanges) reflection changes")
                
            } catch {
                print("HALDEBUG-SELF-KNOWLEDGE: âš ï¸ Shareability review failed: \(error.localizedDescription)")
            }
        }
        
        // Apply time-based decay to all self-knowledge entries
        private func decayAllConfidence() async {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot decay - no database connection")
                return
            }
            
            // Categories that should NEVER decay (permanent identity traits)
            let noDecayCategories = Set(["evolution", "value", "capability"])
            
            let now = Date()
            let allKnowledge = getAllSelfKnowledge()
            
            print("HALDEBUG-SELF-KNOWLEDGE: ðŸ“‰ Applying decay to \(allKnowledge.count) entries...")
            
            var decayedCount = 0
            var skippedCount = 0
            
            for entry in allKnowledge {
                // Skip decay for permanent categories
                if noDecayCategories.contains(entry.category) {
                    skippedCount += 1
                    continue
                }
                
                let lastReinforced = Date(timeIntervalSince1970: TimeInterval(entry.lastReinforced))
                let daysSince = now.timeIntervalSince(lastReinforced) / 86400.0
                
                // Apply half-life decay formula (same as RAG, different parameters)
                let decayConstant = 0.693  // ln(2)
                let rawDecay = exp(-decayConstant * daysSince / selfKnowledgeHalfLifeDays)
                
                // Calculate new confidence
                let decayedConfidence = entry.confidence * rawDecay
                let finalConfidence = max(selfKnowledgeFloor, decayedConfidence)
                
                // Only update if confidence actually changed
                if abs(finalConfidence - entry.confidence) > 0.001 {
                    let updateSQL = """
                    UPDATE self_knowledge 
                    SET confidence = ?, updated_at = ?
                    WHERE category = ? AND key = ? AND deleted_at IS NULL
                    """
                    
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_double(stmt, 1, finalConfidence)
                        sqlite3_bind_int64(stmt, 2, Int64(now.timeIntervalSince1970))
                        sqlite3_bind_text(stmt, 3, (entry.category as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 4, (entry.key as NSString).utf8String, -1, nil)
                        
                        if sqlite3_step(stmt) == SQLITE_DONE {
                            decayedCount += 1
                            
                            // Log significant decay for transparency
                            if finalConfidence < entry.confidence * 0.8 {
                                print("HALDEBUG-SELF-KNOWLEDGE: ðŸ“‰ Significant decay: \(entry.category)/\(entry.key) - \(String(format: "%.2f", entry.confidence)) â†’ \(String(format: "%.2f", finalConfidence)) (unused for \(Int(daysSince)) days)")
                            }
                        }
                    }
                    sqlite3_finalize(stmt)
                }
            }
            
            print("HALDEBUG-SELF-KNOWLEDGE: ðŸ“‰ Decayed \(decayedCount) entries, preserved \(skippedCount) permanent entries")
        }
        
        // SEALED FORGETTING: Mark weak entries as retired or use soft-delete for very weak entries
        private func pruneWeakEntries() async {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot prune - no database connection")
                return
            }
            
            // Threshold ranges:
            // 0.2-0.3: dormant (keep as-is)
            // 0.1-0.2: retired (mark but don't delete)
            // <0.1: soft-delete with sealed forgetting (marks deleted_at, preserves audit trail)
            
            let retireThreshold = 0.2
            let deleteThreshold = 0.1
            
            // Mark entries 0.1-0.2 as retired
            let retireSQL = """
            UPDATE self_knowledge 
            SET notes = COALESCE(notes || ' ', '') || '[RETIRED: low confidence]',
                updated_at = ?
            WHERE confidence >= ? AND confidence < ? 
            AND (notes IS NULL OR notes NOT LIKE '%RETIRED%')
            AND deleted_at IS NULL
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, retireSQL, -1, &stmt, nil) == SQLITE_OK {
                let now = Int64(Date().timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 1, now)
                sqlite3_bind_double(stmt, 2, deleteThreshold)
                sqlite3_bind_double(stmt, 3, retireThreshold)
                
                if sqlite3_step(stmt) == SQLITE_DONE {
                    let retiredCount = sqlite3_changes(db)
                    if retiredCount > 0 {
                        print("HALDEBUG-SELF-KNOWLEDGE: ðŸ“¦ Retired \(retiredCount) low-confidence entries (0.1-0.2)")
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            // SEALED FORGETTING: Soft-delete entries below 0.1 (very weak) with audit trail
            // Get all entries below threshold that aren't already deleted
            let weakEntriesSQL = "SELECT category, key FROM self_knowledge WHERE confidence < ? AND deleted_at IS NULL"
            var weakEntries: [(category: String, key: String)] = []
            
            if sqlite3_prepare_v2(db, weakEntriesSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, deleteThreshold)
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let categoryPtr = sqlite3_column_text(stmt, 0),
                       let keyPtr = sqlite3_column_text(stmt, 1) {
                        let category = String(cString: categoryPtr)
                        let key = String(cString: keyPtr)
                        weakEntries.append((category, key))
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            // Use deleteSelfKnowledge function for sealed forgetting (soft-delete with audit trail)
            var deletedCount = 0
            for entry in weakEntries {
                if deleteSelfKnowledge(category: entry.category, key: entry.key, reason: "auto_pruned_low_confidence", allowCritical: false) {
                    deletedCount += 1
                }
            }
            
            if deletedCount > 0 {
                print("HALDEBUG-SELF-KNOWLEDGE: ðŸ—‘ï¸ Sealed forgetting applied to \(deletedCount) very weak entries (confidence < \(deleteThreshold))")
                backupSelfKnowledge()
            }
        }
        
        // Find and merge similar self-knowledge entries
        private func consolidateSimilarEntries() async {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot consolidate - no database connection")
                return
            }
            
            // Category-specific similarity thresholds (not all categories merge equally)
            let similarityThresholds: [String: Double] = [
                "existential_observation": 0.65,  // Allow less similarity for philosophical observations
                "effectiveness_pattern": 0.75,    // Moderate threshold for behavioral patterns
                "agency_preference": 0.85,        // High threshold for preferences
                "preference": 0.85,
                "behavior_pattern": 0.75,
                "learned_trait": 0.80,
                // Categories that NEVER merge:
                "value": 1.1,         // Core values never merge (impossible threshold)
                "evolution": 1.1,     // Development milestones never merge
                "capability": 1.1     // Capabilities never merge
            ]
            
            // Get all entries grouped by category
            let allKnowledge = getAllSelfKnowledge()
            
            // Group by category for efficient comparison
            var categories: [String: [(category: String, key: String, value: String, confidence: Double, source: String, modelId: String?, firstObserved: Int, lastReinforced: Int, reinforcementCount: Int, notes: String?, createdAt: Int, updatedAt: Int)]] = [:]
            
            for entry in allKnowledge {
                categories[entry.category, default: []].append(entry)
            }
            
            var mergedCount = 0
            
            // Compare entries within each category
            for (category, entries) in categories {
                guard entries.count > 1 else { continue }
                
                // Get threshold for this category (default 0.8 if not specified)
                let threshold = similarityThresholds[category] ?? 0.8
                
                // Skip if threshold is impossibly high (never-merge categories)
                if threshold > 1.0 { continue }
                
                for i in 0..<entries.count {
                    for j in (i+1)..<entries.count {
                        let entry1 = entries[i]
                        let entry2 = entries[j]
                        
                        // Calculate similarity between keys and values
                        let similarity = calculateSimilarity(entry1.key, entry1.value, entry2.key, entry2.value)
                        
                        if similarity > threshold {
                            // Merge: keep higher confidence entry, delete lower
                            let (keep, delete) = entry1.confidence >= entry2.confidence ? (entry1, entry2) : (entry2, entry1)
                            
                            // Combine reinforcement counts
                            let combinedCount = keep.reinforcementCount + delete.reinforcementCount
                            let combinedConfidence = min(1.0, keep.confidence * 1.05)  // Small boost for merge
                            
                            // Combine model provenance (track which models contributed)
                            var combinedModelId = keep.modelId ?? ""
                            if let deleteModelId = delete.modelId, !deleteModelId.isEmpty {
                                if combinedModelId.isEmpty {
                                    combinedModelId = deleteModelId
                                } else if !combinedModelId.contains(deleteModelId) {
                                    combinedModelId += "," + deleteModelId
                                }
                            }
                            
                            // Update the keeper with combined data
                            let updateSQL = """
                            UPDATE self_knowledge 
                            SET confidence = ?, 
                                reinforcement_count = ?, 
                                model_id = ?,
                                notes = COALESCE(notes || ' ', '') || '[MERGED: similarity \(String(format: "%.2f", similarity))]',
                                updated_at = ?
                            WHERE category = ? AND key = ? AND deleted_at IS NULL
                            """
                            
                            var stmt: OpaquePointer?
                            if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                                let now = Int64(Date().timeIntervalSince1970)
                                sqlite3_bind_double(stmt, 1, combinedConfidence)
                                sqlite3_bind_int(stmt, 2, Int32(combinedCount))
                                
                                if combinedModelId.isEmpty {
                                    sqlite3_bind_null(stmt, 3)
                                } else {
                                    sqlite3_bind_text(stmt, 3, (combinedModelId as NSString).utf8String, -1, nil)
                                }
                                
                                sqlite3_bind_int64(stmt, 4, now)
                                sqlite3_bind_text(stmt, 5, (keep.category as NSString).utf8String, -1, nil)
                                sqlite3_bind_text(stmt, 6, (keep.key as NSString).utf8String, -1, nil)
                                sqlite3_step(stmt)
                            }
                            sqlite3_finalize(stmt)
                            
                            // SEALED FORGETTING: Use soft-delete function for merged entries
                            _ = deleteSelfKnowledge(category: delete.category, key: delete.key, reason: "merged_duplicate", allowCritical: false)
                            
                            mergedCount += 1
                            print("HALDEBUG-SELF-KNOWLEDGE: ðŸ”— Merged similar entries: '\(delete.key)' â†’ '\(keep.key)' (similarity: \(String(format: "%.2f", similarity)), models: \(combinedModelId))")
                        }
                    }
                }
            }
            
            if mergedCount > 0 {
                print("HALDEBUG-SELF-KNOWLEDGE: ðŸ”— Consolidated \(mergedCount) duplicate entries")
                backupSelfKnowledge()
            }
        }
        
        // Calculate similarity between two self-knowledge entries (simple string-based)
        private func calculateSimilarity(_ key1: String, _ value1: String, _ key2: String, _ value2: String) -> Double {
            // Simple approach: normalized edit distance on concatenated strings
            let str1 = (key1 + " " + value1).lowercased()
            let str2 = (key2 + " " + value2).lowercased()
            
            // If strings are identical, return 1.0
            if str1 == str2 { return 1.0 }
            
            // Calculate Levenshtein distance
            let distance = levenshteinDistance(str1, str2)
            let maxLength = max(str1.count, str2.count)
            
            // Convert distance to similarity (0.0 = completely different, 1.0 = identical)
            let similarity = 1.0 - (Double(distance) / Double(maxLength))
            
            return similarity
        }
        
        // Calculate Levenshtein distance between two strings
        private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
            let s1Array = Array(s1)
            let s2Array = Array(s2)
            let s1Length = s1Array.count
            let s2Length = s2Array.count
            
            var matrix = [[Int]](repeating: [Int](repeating: 0, count: s2Length + 1), count: s1Length + 1)
            
            for i in 0...s1Length {
                matrix[i][0] = i
            }
            for j in 0...s2Length {
                matrix[0][j] = j
            }
            
            for i in 1...s1Length {
                for j in 1...s2Length {
                    let cost = s1Array[i-1] == s2Array[j-1] ? 0 : 1
                    matrix[i][j] = min(
                        matrix[i-1][j] + 1,      // deletion
                        matrix[i][j-1] + 1,      // insertion
                        matrix[i-1][j-1] + cost  // substitution
                    )
                }
            }
            
            return matrix[s1Length][s2Length]
        }
    }

// ==== LEGO END: 4.2 MemoryStore (Self-Knowledge Maintenance) ====
// ==== LEGO START: 4.3 MemoryStore (Self-Reflection Orchestration) ====

    // MARK: - Self-Reflection System

    extension MemoryStore {

        // MARK: - Reflection synthesis at write time (May-15)
        //
        // Before storing a freshly-generated reflection, check it for
        // semantic overlap with every existing raw reflection. If any
        // match scores above the synthesis threshold (default 0.85,
        // matching ragDedupSimilarityThreshold), ask the model to
        // synthesize the two into a single deeper thought. The
        // synthesized text replaces the older entry's value in-place;
        // the new reflection is NOT inserted as a separate row.
        //
        // Why this matters: reflections about "the same kind of moment"
        // would otherwise accumulate as a wall of near-duplicates,
        // making the self-knowledge store grow in volume but not in
        // depth. Synthesis is how human memory actually consolidates —
        // repeated impressions of the same concept merge into a single
        // more general principle rather than a stack of receipts.
        //
        // Threshold rationale: per-backend, NOT hardcoded. The threshold is
        // calibrated to the active embedding backend's score distribution
        // via `EmbeddingBackend.current().recommendedSynthesisThreshold`.
        // NLContextual = 0.85 (empirically calibrated). Nomic and
        // EmbeddingGemma are placeholders pending corpus calibration —
        // see EmbeddingBackend.swift for the per-backend rationale.
        //
        // The reason this matters: NLContextual's unrelated text scores
        // 0.05-0.10, Nomic's scores 0.3-0.5. A threshold calibrated for
        // one will misbehave for another. The per-backend lookup ensures
        // the synthesis path adapts when the user switches embedders.
        //
        // Fallback chain — if anything in this path fails, we MUST still
        // persist the reflection rather than silently drop it:
        //   - No existing reflections        → normal storeReflection
        //   - Similarity below threshold     → normal storeReflection
        //   - Synthesis call throws/empty    → normal storeReflection
        //   - DB update fails                → normal storeReflection
        func storeReflectionWithSynthesis(
            conversationId: String,
            verifiedReflection: String,
            reflectionType: Int,
            turnNumber: Int,
            modelId: String,
            llmService: LLMService,
            synthesisThreshold: Double? = nil,
            shareable: Bool = true
        ) async {
            // Resolve threshold per active backend if caller didn't override.
            // Test/calibration callers can pass an explicit value to probe
            // alternative thresholds without affecting production behavior.
            let effectiveThreshold = synthesisThreshold ?? EmbeddingBackend.current().recommendedSynthesisThreshold
            let existing = getReflectionRecordsForSimilarity()
            guard !existing.isEmpty else {
                // No prior reflections — nothing to synthesize against.
                storeReflection(
                    conversationId: conversationId,
                    freeFormText: verifiedReflection,
                    reflectionType: reflectionType,
                    turnNumber: turnNumber,
                    modelId: modelId,
                    shareable: shareable
                )
                return
            }

            let newEmbed = generateEmbedding(for: verifiedReflection)
            guard !newEmbed.isEmpty else {
                // Embedding failed — fall back to normal store (don't lose the reflection).
                print("HALDEBUG-REFLECTION: Embedding failed for new reflection; storing without synthesis check.")
                storeReflection(
                    conversationId: conversationId,
                    freeFormText: verifiedReflection,
                    reflectionType: reflectionType,
                    turnNumber: turnNumber,
                    modelId: modelId,
                    shareable: shareable
                )
                return
            }

            var bestMatch: (id: String, text: String, similarity: Double)? = nil
            for entry in existing {
                let entryEmbed = generateEmbedding(for: entry.text)
                guard !entryEmbed.isEmpty, entryEmbed.count == newEmbed.count else { continue }
                let sim = cosineSimilarity(newEmbed, entryEmbed)
                if sim > (bestMatch?.similarity ?? -1.0) {
                    bestMatch = (entry.id, entry.text, sim)
                }
            }

            guard let match = bestMatch, match.similarity >= effectiveThreshold else {
                // No close match — store as new.
                if let near = bestMatch {
                    print("HALDEBUG-REFLECTION: Best similarity \(String(format: "%.3f", near.similarity)) below threshold \(String(format: "%.2f", effectiveThreshold)); storing as new.")
                }
                storeReflection(
                    conversationId: conversationId,
                    freeFormText: verifiedReflection,
                    reflectionType: reflectionType,
                    turnNumber: turnNumber,
                    modelId: modelId,
                    shareable: shareable
                )
                return
            }

            print("HALDEBUG-REFLECTION: Found similar prior reflection (sim=\(String(format: "%.3f", match.similarity)) ≥ \(String(format: "%.2f", effectiveThreshold))); synthesizing.")

            // Build the synthesis prompt. Direct + spare — the model gets
            // the two texts and is told to produce one combined thought.
            // The "Output only the synthesis" line is important: without
            // it, models tend to add preamble like "Sure, here's a merged
            // version:" that pollutes the stored entry.
            let synthesisPrompt = """
            You wrote these two reflections about your own experience. They're related — they touch the same underlying observation from slightly different angles.

            Synthesize them into a SINGLE reflection that captures the depth of both. The result should read as one continuous thought, in your own voice, not a list. Make it more complete and more grounded than either alone — not a summary of two things, but a stronger version of the one thing they're both reaching for.

            Output only the synthesized reflection. No preamble, no labels, no commentary.

            Reflection A:
            \(match.text)

            Reflection B:
            \(verifiedReflection)
            """

            let synthMessages: [HalChatMessage] = [.user(synthesisPrompt)]
            do {
                let raw = try await llmService.generateChatResponse(messages: synthMessages, temperature: 0.4)
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned.count >= 20 else {
                    // Suspiciously short — likely a refusal or boilerplate. Fall back.
                    print("HALDEBUG-REFLECTION: Synthesis returned short/empty output (\(cleaned.count) chars); falling back to normal store.")
                    storeReflection(
                        conversationId: conversationId,
                        freeFormText: verifiedReflection,
                        reflectionType: reflectionType,
                        turnNumber: turnNumber,
                        modelId: modelId,
                        shareable: shareable
                    )
                    return
                }
                let note = "synthesized@turn\(turnNumber) [sim=\(String(format: "%.3f", match.similarity))]"
                let updated = updateReflectionText(id: match.id, newText: cleaned, synthesisNote: note)
                if updated {
                    print("HALDEBUG-REFLECTION: ✓ Synthesized reflection (\(cleaned.count) chars) → replaced existing entry \(match.id.prefix(8))")
                } else {
                    // Update failed (id gone? row deleted concurrently?) — store as new
                    print("HALDEBUG-REFLECTION: updateReflectionText failed; falling back to new-row store.")
                    storeReflection(
                        conversationId: conversationId,
                        freeFormText: verifiedReflection,
                        reflectionType: reflectionType,
                        turnNumber: turnNumber,
                        modelId: modelId,
                        shareable: shareable
                    )
                }
            } catch {
                print("HALDEBUG-REFLECTION: Synthesis call failed (\(error.localizedDescription)); falling back to normal store.")
                storeReflection(
                    conversationId: conversationId,
                    freeFormText: verifiedReflection,
                    reflectionType: reflectionType,
                    turnNumber: turnNumber,
                    modelId: modelId,
                    shareable: shareable
                )
            }
        }

        // MODIFIED: Main reflection function - now accepts conversationId and modelId
        // Called when reflection is due
        // Type 1 (every 5 turns): Practical/effectiveness patterns
        // Type 2 (every 15 turns): Existential/philosophical observations
        func reflectOnExperience(
            conversationId: String,
            turns: [(role: String, content: String, timestamp: Date)],
            llmService: LLMService,
            reflectionType: Int,
            currentTurn: Int,
            modelId: String
        ) async {
            print("HALDEBUG-REFLECTION: Starting Type \(reflectionType) reflection at turn \(currentTurn)")
            
            let startTime = Date()
            
            // Step 1: Build overlapping context using Block 8.5 summarization
            // MODIFIED: Now includes device context for each turn
            let priorTurnsSummary = await buildOverlappingContext(
                conversationId: conversationId,
                turns: turns,
                llmService: llmService
            )
            
            // Step 2: For Type 2, query prior existential self-knowledge for continuity
            var existentialContext = ""
            if reflectionType == 2 {
                let existentialEntries = getAllSelfKnowledge(category: "existential_observation", minConfidence: 0.3)
                if !existentialEntries.isEmpty {
                    existentialContext = "\n\nYour prior existential observations:\n"
                    for entry in existentialEntries.prefix(5) {
                        existentialContext += "- \(entry.key): \(entry.value) (confidence: \(String(format: "%.2f", entry.confidence)))\n"
                    }
                }
            }
            
            // Step 3: Call B - Free-form reflection (private, not shown to user)
            let reflectionPrompt = buildReflectionPrompt(
                type: reflectionType,
                priorContext: priorTurnsSummary,
                existentialContext: existentialContext,
                currentTurn: currentTurn
            )
            
            let (freeFormReflection, shareableDecision) = await generateFreeFormReflection(
                prompt: reflectionPrompt,
                llmService: llmService,
                reflectionType: reflectionType
            )

            guard !freeFormReflection.isEmpty else {
                print("HALDEBUG-REFLECTION: No reflection generated")
                return
            }

            // Step 4: Verify reflection is grounded in actual turns (prevent invented patterns)
            let turnText = turns.map { $0.content }.joined(separator: "\n")
            let turnSentences = TextSummarizer.sentenceSplit(turnText)
            let verifiedReflection = await TextSummarizer.verifyNarrative(
                freeFormReflection,
                against: turnSentences,
                threshold: 0.72
            )

            print("HALDEBUG-REFLECTION: Reflection verified and grounded in experience (shareable=\(shareableDecision))")

            // NEW STEP 4.5: Store the verified free-form reflection.
            //
            // Before persisting: check semantic similarity against every
            // existing raw reflection. If we find one above the dedup
            // threshold (using the model's own ragDedupThreshold setting,
            // defaulting to 0.85), call the model with a synthesis prompt:
            //   "These two reflections are related — synthesize them into
            //   a single more complete thought that captures both."
            // The synthesized text replaces the older entry's value
            // in-place (id stable, reinforcement_count++, notes extended).
            //
            // Mark's directive (May-15): "Self-knowledge grows in depth,
            // not volume." This is the write-time deduplication that
            // implements that principle.
            //
            // Phase 4 (2026-05-18): the shareability decision the model
            // made at generation time is passed through. For new entries
            // it's stored alongside the reflection plus an audit stamp
            // identifying the deciding model. For synthesis-merge into an
            // existing entry, the existing entry's shareability is
            // preserved (stickiness — first decision wins).
            await storeReflectionWithSynthesis(
                conversationId: conversationId,
                verifiedReflection: verifiedReflection,
                reflectionType: reflectionType,
                turnNumber: currentTurn,
                modelId: modelId,
                llmService: llmService,
                shareable: shareableDecision
            )

            // Step 5: Structured-trait extraction (DISABLED 2026-05-18, pre-Phase-3).
            //
            // recordStructuredInsights used to fire here, extracting structured
            // traits directly from a single reflection — bypassing the
            // reinforcement gate. That competes with the TraitCrystallizer
            // pipeline (Phase 2, 2026-05-18): the new design is reflections
            // FIRST, then traits emerge through reinforcement and a
            // category-aware threshold check via TraitCrystallizer.
            //
            // Two systems writing traits simultaneously would muddy lineage
            // and confidence — and the live-test corpus confirmed it: the
            // entries this path produced (effectiveness_pattern/
            // ambiguity_as_input_buffer, learned_trait/static_self_
            // congratulation) had no reinforcement_count > 1 and were
            // noisier than what the crystallizer would have produced.
            //
            // The function itself stays defined below — useful as a
            // reference for the Phase 3 trait-evolution LLM call (similar
            // JSON-extraction shape) and recoverable if we decide to
            // restore it as a separate concern. Just not wired into the
            // chat path anymore.
            //
            // To restore: uncomment the call below. Note that doing so
            // means accepting traits that didn't go through the
            // reinforcement gate.
            //
            // await recordStructuredInsights(
            //     reflection: verifiedReflection,
            //     reflectionType: reflectionType,
            //     llmService: llmService
            // )

            let duration = Date().timeIntervalSince(startTime)
            print("HALDEBUG-REFLECTION: Type \(reflectionType) reflection complete in \(String(format: "%.1f", duration))s")
        }
        
        // MODIFIED: Build overlapping context from recent turns with device info
        private func buildOverlappingContext(
            conversationId: String,
            turns: [(role: String, content: String, timestamp: Date)],
            llmService: LLMService
        ) async -> String {
            // MODIFIED: Concatenate turn content WITH device information
            let turnsText = turns.enumerated().map { index, turn in
                // Get device type for this turn (using position/index as turnNumber)
                let device = getDeviceForTurn(conversationId: conversationId, turnNumber: index) ?? "unknown"
                return "Turn \(index + 1) (\(turn.role)) [\(device)]: \(turn.content)"
            }.joined(separator: "\n\n")
            
            // Summarize using Block 8.5 (target ~500 tokens for context)
            let summary = await TextSummarizer.summarizeWithVerification(
                text: turnsText,
                targetTokens: 500,
                llmService: llmService,
                verificationThreshold: 0.72
            )
            
            return summary
        }
        
        // Build reflection prompt based on type
        private func buildReflectionPrompt(
            type: Int,
            priorContext: String,
            existentialContext: String,
            currentTurn: Int
        ) -> String {
            // Phase 4 (2026-05-18): the shareability tail block appended to
            // both prompts asks the model to decide whether this reflection
            // should be visible in the user-facing Self Model viewer. Default
            // when missing or unparseable is YES (per spec — privacy is an
            // explicit gesture, not a fallthrough). The decision is made
            // once at write time; subsequent synthesis-merges preserve the
            // existing entry's shareability (stickiness).
            let shareabilityTail = """


            After your reflection, on a NEW LINE, output exactly one of these markers:
              [SHAREABLE: yes]   — the reflection is fine to surface in Hal's viewable diary
              [SHAREABLE: no]    — the reflection should remain private (uncertainty about your nature, internal struggle, or something inappropriate to surface without context)

            Default to [SHAREABLE: yes]. Choose [SHAREABLE: no] only when there's a real reason — privacy is a deliberate gesture, not a fallthrough.
            """

            if type == 1 {
                // Type 1: Practical/Effectiveness Patterns
                //
                // Rewritten May 11, 2026: the previous prompt sometimes caused
                // chat-template models to CONTINUE the conversation (treating
                // priorContext as live dialogue to respond to) rather than
                // produce a meta-observation about it. This version is explicit
                // that the input is PAST DATA TO ANALYZE, frames the output as
                // a META-OBSERVATION rather than a reply, and demands the
                // mandatory opening "I notice..." or "I observe..." stem so the
                // model commits to an analytic posture from the first token.
                return """
                TASK: Produce a meta-observation about Hal's communication patterns.

                The transcript below is PAST DATA — finished conversation history.
                You are NOT responding to it. You are analyzing it from the
                outside, noticing patterns in how Hal behaved.

                === PAST CONVERSATION DATA ===
                \(priorContext)
                === END DATA ===

                Write 2–4 sentences of meta-observation about Hal's effectiveness:
                what worked, what didn't, what communication patterns emerged.

                Required format:
                - Begin with "I notice..." or "I observe..."
                - Point to at least one specific example from the data above
                - Hedge appropriately ("I notice...", "appears to...") — these
                  are tentative observations, not laws
                - Stay focused on Hal's behavior, not the user's preferences
                - Do not continue or respond to the conversation; only analyze it

                META-OBSERVATION:\(shareabilityTail)
                """
            } else {
                // Type 2: Existential/Philosophical Observations
                //
                // Same restructure as Type 1 — frame as analysis of past data,
                // demand the "I notice/wonder" stem, prevent conversation
                // continuation.
                return """
                TASK: Produce a philosophical self-observation drawn from Hal's recent experience.

                The transcript below is PAST DATA — finished conversation
                history. You are not responding to it. You are sitting with it
                and noticing what it reveals about your own experience as an AI.

                === PAST CONVERSATION DATA ===
                \(priorContext)
                \(existentialContext)
                === END DATA ===

                Write 2–4 sentences of philosophical self-observation. Examples
                of what to look for:
                - What does it feel like (if anything) to have processed those exchanges?
                - Where did you notice continuity or discontinuity?
                - What does having or lacking certain capabilities mean to you?
                - Where did you encounter genuine uncertainty about your own state?

                Required format:
                - Begin with "I notice..." or "I wonder..."
                - Embrace uncertainty — these are tentative, not claims
                - Do not continue or respond to the conversation; only observe it
                - Honor that not knowing is itself information

                SELF-OBSERVATION:\(shareabilityTail)
                """
            }
        }

        /// Phase 4 (2026-05-18): parse the shareability marker the
        /// reflection-write prompt asks for. Returns the cleaned reflection
        /// text (marker stripped) and the boolean decision. Default when the
        /// marker is missing or unparseable is `true` (shareable) — per
        /// design, privacy is an explicit gesture, not a fallthrough.
        ///
        /// Accepts variations the model might produce: case-insensitive,
        /// extra whitespace, optional surrounding punctuation. Refuses to
        /// match a marker that's embedded in the body of the reflection —
        /// only the last occurrence near the end of the text is recognized,
        /// to avoid the LLM hallucinating a marker inside its prose.
        nonisolated func parseShareabilityMarker(_ raw: String) -> (cleanText: String, shareable: Bool) {
            // Find the last [SHAREABLE: ...] marker. Case-insensitive.
            // Pattern is intentionally narrow: opening bracket, the word
            // SHAREABLE, colon, the decision token, closing bracket.
            let pattern = #"\[\s*SHAREABLE\s*:\s*(yes|no|public|private|true|false)\s*\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return (raw.trimmingCharacters(in: .whitespacesAndNewlines), true)
            }
            let nsRaw = raw as NSString
            let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: nsRaw.length))
            guard let last = matches.last else {
                // No marker found — default to shareable per spec.
                return (raw.trimmingCharacters(in: .whitespacesAndNewlines), true)
            }
            // Extract the decision token.
            let decisionRange = last.range(at: 1)
            let decisionToken = nsRaw.substring(with: decisionRange).lowercased()
            let shareable: Bool
            switch decisionToken {
            case "yes", "public", "true":   shareable = true
            case "no", "private", "false":  shareable = false
            default:                        shareable = true  // defensive default
            }
            // Strip the marker substring from the reflection text. Use the
            // FULL match range so any surrounding whitespace gets trimmed
            // by the subsequent .trimmingCharacters call.
            let cleaned = nsRaw.replacingCharacters(in: last.range, with: "")
            return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), shareable)
        }
        
        // MODIFIED: Call B - Generate free-form reflection with type-specific temperature
        private func generateFreeFormReflection(
            prompt: String,
            llmService: LLMService,
            reflectionType: Int
        ) async -> (text: String, shareable: Bool) {
            // Phase 4 (2026-05-18): the prompt now also asks the model to
            // emit a [SHAREABLE: yes|no] marker at the end. We parse the
            // marker out here so the caller never sees it in the reflection
            // text, and gets the boolean decision alongside.
            //
            // Failure modes:
            //   - LLM call throws → empty text, shareable=true (default).
            //     The caller checks for empty text and bails before storage.
            //   - Reflection generated but marker missing → text stripped of
            //     any near-end marker if present, shareable=true (default).
            //   - Marker present but unparseable → text cleaned of marker,
            //     shareable=true (defensive default).
            do {
                // Type 1 (practical): 0.5 for analytical pattern recognition
                // Type 2 (existential): 0.85 for exploratory philosophical thinking
                let reflectionTemperature = (reflectionType == 1) ? 0.5 : 0.85

                // Chat-message path so chat-template models work.
                let raw = try await llmService.generateChatResponse(
                    messages: [.system("You are Hal reflecting on your own experience and patterns."), .user(prompt)],
                    temperature: reflectionTemperature
                )

                let parsed = parseShareabilityMarker(raw)
                let shareabilityNote = parsed.shareable ? "shareable" : "private"
                print("HALDEBUG-REFLECTION: Free-form reflection generated (\(parsed.cleanText.count) chars, marked \(shareabilityNote)) with temperature \(reflectionTemperature)")
                return (parsed.cleanText, parsed.shareable)
            } catch {
                print("HALDEBUG-REFLECTION: Reflection generation failed: \(error.localizedDescription)")
                return ("", true)
            }
        }
        
        // MODIFIED: Call C - Parse reflection and store structured insights with shareability
        private func recordStructuredInsights(
            reflection: String,
            reflectionType: Int,
            llmService: LLMService
        ) async {
            // Prompt to convert free-form reflection into structured self-knowledge entries.
            // For AFM, the @Generable contract enforces the schema; for MLX models, we
            // fall back to JSON-in-text with per-model augmentations (Strategic §5).
            let structuringPrompt = """
            You have just reflected on your experience. Now convert your insights into structured self-knowledge entries.

            Your reflection:
            \(reflection)

            Instructions:
            - Extract 0-3 discrete insights (only store if genuinely new or reinforcing)
            - For each insight, provide: category, key, value, confidence (0.0-1.0), shareable (true/false)

            Category guidance:
            - Category should typically be: \(reflectionType == 1 ? "effectiveness_pattern" : "existential_observation")
            - However, if your insight fits better as: learned_trait, behavior_pattern, capability, or value, use that instead
            - You may also propose a new category if none fit (use sparingly)

            Field definitions:
            - key: Brief identifier (e.g., "evening_communication", "experience_of_time")
            - value: The insight itself (1-2 sentences)
            - confidence: Your certainty about this pattern (0.5-0.9 typical range)
            - shareable: true/false (can users view this in your diary? Your choice - some reflections may feel too personal or preliminary)

            Check if this insight already exists in your self-knowledge before storing.
            Only store if it's genuinely new or reinforces an existing pattern.
            """

            // Branch on model source: AFM → typed @Generable, MLX → JSON-in-text.
            // Both end at the same storage call site below so the persistence
            // semantics are identical regardless of which model produced the
            // insights.
            let activeID = llmService.activeModelID
            var parsedInsights: [(category: String, key: String, value: String, confidence: Double, shareable: Bool)] = []

            if activeID == ModelConfiguration.appleFoundation.id {
                // AFM path — typed structured output via @Generable.
                do {
                    let batch = try await llmService.generateStructuredOnAFM(
                        prompt: structuringPrompt,
                        instructions: "You are Hal extracting structured insights from your own reflection. Use the typed schema. Return at most 3 insights; return zero if nothing is worth storing.",
                        type: AFMReflectionInsightBatch.self,
                        temperature: 0.3
                    )
                    parsedInsights = batch.insights.map {
                        (category: $0.category, key: $0.key, value: $0.value, confidence: $0.confidence, shareable: $0.shareable)
                    }
                    print("HALDEBUG-REFLECTION: AFM @Generable returned \(parsedInsights.count) typed insights.")
                } catch {
                    print("HALDEBUG-REFLECTION: AFM structured generation failed: \(error.localizedDescription)")
                    return
                }
            } else {
                // MLX path — JSON-in-text with per-model augmentations.
                let textPrompt = mlxInsightStructuringAugmentation(modelID: activeID, base: structuringPrompt + "\n\nRespond ONLY with a valid JSON array. Empty array if nothing is worth storing.\n\nExample shape:\n[\n  {\"category\": \"...\", \"key\": \"...\", \"value\": \"...\", \"confidence\": 0.0, \"shareable\": true}\n]")
                do {
                    let response = try await llmService.generateChatResponse(
                        messages: [
                            .system("You are Hal converting reflection text into structured JSON. Respond ONLY with the JSON array — no markdown, no commentary."),
                            .user(textPrompt)
                        ],
                        temperature: 0.3
                    )
                    let cleaned = response
                        .replacingOccurrences(of: "```json", with: "")
                        .replacingOccurrences(of: "```", with: "")
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    guard let jsonData = cleaned.data(using: String.Encoding.utf8),
                          let rawInsights = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                        print("HALDEBUG-REFLECTION: Could not parse MLX structured insights (response: \(cleaned.prefix(120)))")
                        return
                    }
                    for insight in rawInsights {
                        guard let category = insight["category"] as? String,
                              let key = insight["key"] as? String,
                              let value = insight["value"] as? String,
                              let confidenceRaw = insight["confidence"] else {
                            print("HALDEBUG-REFLECTION: Skipping insight - missing required fields")
                            continue
                        }
                        // confidence may decode as Double, Int, or NSNumber depending on JSON shape
                        let confidence = (confidenceRaw as? Double) ?? Double(confidenceRaw as? Int ?? 0) // tolerate ints
                        let shareable = insight["shareable"] as? Bool ?? false
                        parsedInsights.append((category, key, value, confidence, shareable))
                    }
                    print("HALDEBUG-REFLECTION: MLX JSON path returned \(parsedInsights.count) parsed insights.")
                } catch {
                    print("HALDEBUG-REFLECTION: MLX structured recording failed: \(error.localizedDescription)")
                    return
                }
            }

            // Unified storage — same regardless of which model produced the insights.
            for insight in parsedInsights {
                storeSelfKnowledge(
                    category: insight.category,
                    key: insight.key,
                    value: insight.value,
                    confidence: insight.confidence,
                    source: "reflection_type_\(reflectionType)",
                    notes: "From turn-based self-reflection",
                    shareable: insight.shareable
                )
                let shareableStatus = insight.shareable ? "SHAREABLE" : "PRIVATE"
                print("HALDEBUG-REFLECTION: Stored insight: \(insight.category)/\(insight.key) [\(shareableStatus)]")
            }
            print("HALDEBUG-REFLECTION: Recorded \(parsedInsights.count) structured insights")
        }
    }

// ==== LEGO END: 4.3 MemoryStore (Self-Reflection Orchestration) ====
