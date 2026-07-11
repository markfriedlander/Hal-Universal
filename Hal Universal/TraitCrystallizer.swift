// ==== LEGO START: 38 TraitCrystallizer (Reflection -> Trait Promotion) ====
// TraitCrystallizer.swift
// Hal Universal
//
// The reflection-to-trait promotion engine. Reflections accumulate in
// the database with a `reinforcement_count` that grows each time a
// semantically-similar new reflection is merged into them via
// storeReflectionWithSynthesis. When that count crosses a category-
// specific threshold, the reflection becomes a candidate for promotion
// to a structured trait. This module:
//
//   1. Fetches candidate reflections from the MemoryStore.
//   2. Builds a focused LLM prompt that distills a reflection into a
//      (category, key, value) tuple representing the durable shift the
//      reflection captures.
//   3. Validates the LLM output, double-checks the category-specific
//      threshold, and INSERTs the trait via MemoryStore's
//      storeSelfKnowledge path (which upserts on category+key collision
//      as a reinforcement).
//   4. Stamps the source reflection with the new trait's ID via
//      markReflectionPromoted, so reverse-lineage queries
//      (`WHERE promoted_to_trait_id = ?`) can find every reflection
//      that fed a given trait.
//
// Dependencies (read-only consumer of):
//   - MemoryStore (via SelfKnowledgeEngine.swift): getTraitCandidates,
//     getSelfKnowledge, storeSelfKnowledge, markReflectionPromoted
//   - LLMService: generateChatResponse(messages:temperature:)
//   - HalChatMessage: the message-array shape llmService uses
//
// AFM gate: not enforced inside this module. The chat-path caller gates
// the invocation — AFM never invokes processTraitCandidates because AFM
// doesn't participate in self-knowledge writes.

import Foundation

/// Per-category reinforcement thresholds. A reflection becomes a
/// candidate for promotion when its reinforcement_count crosses the
/// threshold for the category it would land in. These are starting
/// values; the salon's actual contribution was the *shape* (varies by
/// category) rather than specific numbers — we'll calibrate from real
/// corpus behavior. AppStorage-tunable in Phase 4 once the viewer UI
/// lands; until then they're constants.
///
/// Rationale for the spread:
///   - value/capability/evolution = 2: discrete, factual, solidify
///     quickly (Hal notices a core value or a milestone once and it's
///     stable).
///   - preference/behavior_pattern/learned_trait = 3: behavioral
///     observations need a window to confirm they're patterns rather
///     than one-off moments.
///   - meta_cognition/existential_observation = 4: most reflective,
///     most prone to noise from a single deep conversation; need a
///     longer reinforcement window to filter out one-off philosophical
///     musings from durable self-understanding.
nonisolated enum TraitPromotionThreshold {
    static let value: Int = 2
    static let preference: Int = 3
    static let behaviorPattern: Int = 3
    static let capability: Int = 2
    static let learnedTrait: Int = 3
    static let evolution: Int = 2
    static let metaCognition: Int = 4
    static let existentialObservation: Int = 4

    /// Look up the threshold for a given category string. Unknown
    /// categories fall through to a conservative default of 4 — the
    /// crystallizer will then fail the threshold check and the
    /// reflection will be deferred rather than promoted under a
    /// category we don't recognize.
    static func threshold(for category: String) -> Int {
        switch category {
        case "value":                  return value
        case "preference":             return preference
        case "behavior_pattern":       return behaviorPattern
        case "capability":             return capability
        case "learned_trait":          return learnedTrait
        case "evolution":              return evolution
        case "meta_cognition":         return metaCognition
        case "existential_observation": return existentialObservation
        default:                       return 4
        }
    }

    /// Minimum threshold across all categories. Used as the SQL filter
    /// for the candidate fetch — anything below this can't possibly
    /// be promoted under any category. The crystallizer re-checks the
    /// category-specific threshold after the LLM classifies, since we
    /// don't know which category a reflection will land in until the
    /// LLM tells us.
    static let minimumAcrossCategories: Int = 2

    /// Allowed category strings. The LLM's output is validated against
    /// this set; unrecognized categories cause the candidate to be
    /// skipped (logged for diagnosis, not stored).
    static let allowedCategories: Set<String> = [
        "value", "preference", "behavior_pattern", "capability",
        "learned_trait", "evolution", "meta_cognition", "existential_observation"
    ]
}

// MARK: - Multi-valued trait storage (Phase 3, 2026-05-18)
//
// Once a trait starts collecting contradictory reflections — say,
// "Hal prefers naming uncertainty plainly" gets a counter-example
// reflection like "Hal sometimes hides uncertainty to seem more useful"
// — we don't replace the primary and we don't branch into two traits.
// We keep the tension as a feature of the trait, with a weighted
// secondary state that records the contradiction and can swap with
// the primary if it gathers enough evidence over time.
//
// Storage: the trait row's `value` column holds either:
//   - A plain string (single-valued; original format, still the
//     default for newly-crystallized traits)
//   - A JSON object with `primary` + `tensions[]` (multi-valued;
//     created on first contradiction-driven evolution)
//
// Format is detected at read time (no schema migration, no backfill
// of existing plain-string entries — per Mark/SC's Phase 3 call).
// The `isMultiValuedJSON` helper does the detection; encode/decode
// handle the round-trip.

/// A single counter-state on a trait. Records the contradicting
/// observation, when it was first seen, where it came from, and its
/// current weight (influence relative to the primary state).
nonisolated struct TraitTension: Codable, Sendable {
    let text: String
    var weight: Double
    let sourceReflectionId: String
    let firstObserved: Int

    enum CodingKeys: String, CodingKey {
        case text
        case weight
        case sourceReflectionId = "source_reflection_id"
        case firstObserved = "first_observed"
    }
}

/// The multi-valued trait structure. A trait that has only ever been
/// reinforced in the same direction stays a plain string in the DB;
/// once evolution introduces tension, the column gets serialized into
/// this shape and stays multi-valued thereafter (even if tensions
/// later decay back to inactive weights — they stay in the record).
nonisolated struct MultiValuedTrait: Codable, Sendable {
    var primary: String
    var tensions: [TraitTension]

    /// Serialize to the JSON string that goes into the `value` column.
    func toJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []  // compact, single-line
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            // Defensive: if encoding fails for any reason, fall back to
            // just the primary so we don't lose the durable shift.
            return primary
        }
        return str
    }

    /// Parse from the `value` column. Returns nil if the string isn't
    /// a valid MultiValuedTrait JSON object — caller treats nil as
    /// "this is a plain string value, not multi-valued."
    static func fromJSONString(_ s: String) -> MultiValuedTrait? {
        guard let data = s.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(MultiValuedTrait.self, from: data)
    }

    /// Wrap a plain-string trait value into the multi-valued structure.
    /// Used at the moment of first contradiction-driven evolution, when
    /// a previously single-valued trait acquires its first tension.
    static func wrapping(_ existingPrimary: String, withFirstTension tension: TraitTension) -> MultiValuedTrait {
        return MultiValuedTrait(primary: existingPrimary, tensions: [tension])
    }

    /// Cheap detector — does this string look like a serialized
    /// MultiValuedTrait? Inspects the first non-whitespace character
    /// and looks for a JSON object opening; full validity is verified
    /// by `fromJSONString` returning non-nil. We don't try to detect
    /// arbitrary JSON — only our specific shape, so single-string
    /// values that happen to start with `{` (rare in practice — trait
    /// values are declarative sentences) will fail the parse and be
    /// treated as plain strings.
    static func isMultiValuedJSON(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return false }
        return fromJSONString(trimmed) != nil
    }
}

/// TraitCrystallizer — the reflection-to-trait promotion engine.
///
/// Marked @MainActor so it can call MemoryStore methods and the LLM
/// service without actor-boundary friction. The actual LLM work
/// happens off the main thread inside llmService.generateChatResponse;
/// only the DB reads/writes and orchestration are main-actor.
@MainActor
enum TraitCrystallizer {

    /// Main entry point. Called by the chat path AFTER a turn's
    /// reflection write completes, deferred via a Task so it doesn't
    /// block conversation flow. Only fires when AFM is NOT the active
    /// model (gate is at the call site per the 2026-05-17 audit).
    ///
    /// Sequence:
    ///   1. Fetch all unpromoted reflections with reinforcement_count
    ///      ≥ minimumAcrossCategories (currently 2).
    ///   2. For each (serially, up to batchLimit):
    ///      a. Build the trait-generator prompt + call the LLM.
    ///      b. Parse JSON; validate category against allowedCategories.
    ///      c. Check the reflection's reinforcement_count against the
    ///         category-specific threshold.
    ///      d. If valid AND threshold met: storeSelfKnowledge inserts
    ///         (or reinforces) the trait, then markReflectionPromoted
    ///         stamps the reflection with the trait's ID.
    ///      e. If valid but threshold not yet met: log and defer
    ///         (will be re-attempted on the next post-turn invocation,
    ///         likely after another reinforcement bumps the count).
    ///      f. If parse/validation fails: log and skip this candidate
    ///         (re-tried on the next invocation).
    ///
    /// batchLimit bounds the work per invocation so a backlog of many
    /// candidates can't lock up a single turn's background task. The
    /// next turn will pick up where this one left off.
    static func processTraitCandidates(
        memoryStore: MemoryStore,
        llmService: LLMService,
        activeModelID: String,
        batchLimit: Int = 5
    ) async {
        let candidates = memoryStore.getTraitCandidates(
            minReinforcement: TraitPromotionThreshold.minimumAcrossCategories
        )
        guard !candidates.isEmpty else {
            halLog("HALDEBUG-CRYSTALLIZER: No trait candidates this cycle (no unpromoted reflections at reinforcement ≥ \(TraitPromotionThreshold.minimumAcrossCategories))")
            return
        }

        let batch = Array(candidates.prefix(batchLimit))
        halLog("HALDEBUG-CRYSTALLIZER: Found \(candidates.count) trait candidate(s); processing \(batch.count) this cycle.")

        for candidate in batch {
            await processSingleCandidate(
                candidate,
                memoryStore: memoryStore,
                llmService: llmService,
                activeModelID: activeModelID
            )
        }
    }

    /// Process one candidate. Pulled out as a separate function so the
    /// per-candidate try/catch and logging stays readable. Failures
    /// (parse errors, threshold-not-met, etc.) are logged and silently
    /// skipped; success path writes both the trait and the lineage stamp.
    private static func processSingleCandidate(
        _ candidate: (id: String, text: String, reinforcementCount: Int, modelId: String?),
        memoryStore: MemoryStore,
        llmService: LLMService,
        activeModelID: String
    ) async {
        let reflectionPrefix = candidate.text.prefix(80).replacingOccurrences(of: "\n", with: " ")
        halLog("HALDEBUG-CRYSTALLIZER: Evaluating reflection \(candidate.id.prefix(8))... (reinforcement=\(candidate.reinforcementCount), text='\(reflectionPrefix)...')")

        let messages = buildTraitGeneratorMessages(reflectionText: candidate.text)

        // Temperature 0.3 mirrors the existing structured-insight
        // extraction in SelfKnowledgeEngine — JSON-output tasks benefit
        // from low temperature for consistent format.
        let response: String
        do {
            response = try await llmService.generateChatResponse(messages: messages, temperature: 0.3)
        } catch {
            halLog("HALDEBUG-CRYSTALLIZER: LLM call failed for reflection \(candidate.id.prefix(8))...: \(error.localizedDescription). Skipping (will retry next cycle).")
            return
        }

        guard let parsed = parseTraitGeneratorResponse(response) else {
            halLog("HALDEBUG-CRYSTALLIZER: Could not parse trait-generator response for reflection \(candidate.id.prefix(8))... — raw response (first 200 chars): \(response.prefix(200))")
            return
        }

        // Validate the LLM stayed in the allowed-category set. If it
        // invented a new category, refuse the promotion (will surface
        // in logs as a signal that the prompt may need refinement).
        guard TraitPromotionThreshold.allowedCategories.contains(parsed.category) else {
            halLog("HALDEBUG-CRYSTALLIZER: LLM proposed unknown category '\(parsed.category)' for reflection \(candidate.id.prefix(8))... Allowed: \(TraitPromotionThreshold.allowedCategories.sorted().joined(separator: ", ")). Skipping.")
            return
        }

        // Check the category-specific threshold. If the reflection is
        // reinforced enough for some categories but not for the one
        // the LLM proposed, defer — don't promote prematurely under a
        // category that needs more evidence.
        let categoryThreshold = TraitPromotionThreshold.threshold(for: parsed.category)
        guard candidate.reinforcementCount >= categoryThreshold else {
            halLog("HALDEBUG-CRYSTALLIZER: Reflection \(candidate.id.prefix(8))... classified as '\(parsed.category)' which needs reinforcement ≥ \(categoryThreshold); current count is \(candidate.reinforcementCount). Deferring until next cycle.")
            return
        }

        // Phase 3b (2026-05-18): collision detection. Before writing, check
        // whether a trait with this (category, key) already exists. If it
        // does, the new reflection isn't introducing a fresh trait — it's
        // evidence about an existing one. Route through evolveExistingTrait
        // so the value can deepen (high cosine to existing) or absorb a
        // tension (mid cosine — contradiction) instead of blindly
        // overwriting.
        //
        // If no existing trait collides, fall through to the original
        // INSERT-and-stamp path.
        let existing = memoryStore.getSelfKnowledge(category: parsed.category, key: parsed.key)
        if let existing = existing {
            await evolveExistingTrait(
                existing: existing,
                newProposedValue: parsed.value,
                sourceReflection: candidate,
                activeModelID: activeModelID,
                memoryStore: memoryStore,
                llmService: llmService
            )
            return
        }

        // Fresh trait — INSERT via storeSelfKnowledge, then stamp the
        // source reflection's promoted_to_trait_id.
        let lineageNote = "Promoted from reflection \(candidate.id.prefix(8))... at reinforcement_count=\(candidate.reinforcementCount). Source model: \(candidate.modelId ?? "unknown"). Crystallized by: \(activeModelID)."
        memoryStore.storeSelfKnowledge(
            modelId: activeModelID,
            category: parsed.category,
            key: parsed.key,
            value: parsed.value,
            confidence: 0.8,  // Crystallized traits start at 0.8 (high but not 1.0 — 1.0 reserved for init-time seeds and user-stated)
            source: "trait_crystallization",
            notes: lineageNote,
            shareable: true,
            format: "structured_trait"
        )

        // Look up the trait's ID so we can stamp the reflection with it.
        guard let stored = memoryStore.getSelfKnowledge(category: parsed.category, key: parsed.key) else {
            // Defensive: this should never happen since we just stored,
            // but guard against race / DB error rather than crash.
            halLog("HALDEBUG-CRYSTALLIZER: ⚠️ Stored trait (\(parsed.category)/\(parsed.key)) but could not look up its ID afterward. Lineage stamp skipped. This indicates a deeper DB issue worth investigating.")
            return
        }

        let stamped = memoryStore.markReflectionPromoted(reflectionID: candidate.id, traitID: stored.id)
        if stamped {
            halLog("HALDEBUG-CRYSTALLIZER: ✅ Crystallized reflection \(candidate.id.prefix(8))... → trait '\(parsed.category)/\(parsed.key)' (id=\(stored.id.prefix(8))...). Value: '\(parsed.value)'")
        } else {
            halLog("HALDEBUG-CRYSTALLIZER: ⚠️ Trait stored (\(parsed.category)/\(parsed.key)) but lineage stamp UPDATE returned no changes. Reflection may have been soft-deleted or modified mid-flight.")
        }
    }

    /// Phase 3c (2026-05-18): real evolution mechanism. A new reflection
    /// has been crystallized and the LLM proposed (category, key) that
    /// already exists as a trait. Dispatches a cosine-based three-way
    /// fork to determine how the trait should change:
    ///
    ///   1. Compute cosine similarity between the source reflection's
    ///      raw text and the existing trait's primary value (extracted
    ///      if multi-valued), using the active embedding backend.
    ///   2. HIGH similarity (≥ recommendedContradictionThreshold for
    ///      the backend): "deepen" — the new reflection reinforces in
    ///      the same direction. Make a small LLM call that tightens
    ///      the primary; UPDATE in place with reinforce=true.
    ///   3. MID similarity (0 < cosine < threshold): "absorb tension" —
    ///      the new reflection partially contradicts the trait. Either
    ///      wrap the trait into MultiValuedTrait with the new
    ///      observation as a tension (if previously single-valued), or
    ///      classify the new reflection against existing primary +
    ///      tensions and adjust weights accordingly.
    ///   4. NEGATIVE or ZERO similarity: the LLM said (category, key)
    ///      matches but the embedding vectors disagree strongly.
    ///      Refuse to evolve — log the disagreement and skip. The
    ///      reflection stays unpromoted and gets re-evaluated next
    ///      cycle; if the LLM keeps proposing the same colliding
    ///      classification, the persistent log is a signal that the
    ///      prompt or threshold may need tuning.
    private static func evolveExistingTrait(
        existing: (id: String, value: String, confidence: Double, modelId: String?),
        newProposedValue: String,
        sourceReflection: (id: String, text: String, reinforcementCount: Int, modelId: String?),
        activeModelID: String,
        memoryStore: MemoryStore,
        llmService: LLMService
    ) async {
        // Extract the existing trait's "primary" statement. For
        // single-valued (plain string) values, the whole value IS the
        // primary. For multi-valued (JSON), we pull just `primary` so
        // cosine compares against the dominant state rather than the
        // serialized JSON blob.
        let existingPrimary: String
        let existingMV: MultiValuedTrait?
        if let parsed = MultiValuedTrait.fromJSONString(existing.value), MultiValuedTrait.isMultiValuedJSON(existing.value) {
            existingPrimary = parsed.primary
            existingMV = parsed
        } else {
            existingPrimary = existing.value
            existingMV = nil
        }

        // Cosine vs the RAW reflection text (Design Q2, per Mark/SC).
        let reflectionEmbed = memoryStore.generateEmbedding(for: sourceReflection.text, as: .document)
        let primaryEmbed = memoryStore.generateEmbedding(for: existingPrimary, as: .document)
        let cosine: Double
        if reflectionEmbed.isEmpty || primaryEmbed.isEmpty || reflectionEmbed.count != primaryEmbed.count {
            // Embedding failed — defensive: treat as zero similarity so
            // we skip rather than misclassify. Log the failure.
            cosine = 0.0
            halLog("HALDEBUG-CRYSTALLIZER: ⚠️ Embedding generation failed for evolution cosine (reflection or primary). Treating as zero similarity → will skip evolution.")
        } else {
            cosine = memoryStore.cosineSimilarity(reflectionEmbed, primaryEmbed)
        }

        let threshold = EmbeddingBackend.current().recommendedContradictionThreshold
        let cosineStr = String(format: "%.3f", cosine)
        let thresholdStr = String(format: "%.2f", threshold)

        // Fork on the cosine score.
        if cosine >= threshold {
            // HIGH — deepen path.
            halLog("HALDEBUG-CRYSTALLIZER: 🔆 Deepen: reflection \(sourceReflection.id.prefix(8))... vs existing trait id=\(existing.id.prefix(8))... cosine=\(cosineStr) ≥ \(thresholdStr) → updating primary in place.")
            await dispatchDeepen(
                existingID: existing.id,
                existingPrimary: existingPrimary,
                existingMV: existingMV,
                sourceReflection: sourceReflection,
                newProposedValue: newProposedValue,
                memoryStore: memoryStore,
                llmService: llmService
            )
        } else if cosine > 0 {
            // MID — absorb-tension path.
            halLog("HALDEBUG-CRYSTALLIZER: 🌗 Absorb-tension: reflection \(sourceReflection.id.prefix(8))... vs existing trait id=\(existing.id.prefix(8))... cosine=\(cosineStr) below threshold \(thresholdStr) → routing to multi-valued absorb.")
            await dispatchAbsorbTension(
                existingID: existing.id,
                existingPrimary: existingPrimary,
                existingMV: existingMV,
                sourceReflection: sourceReflection,
                memoryStore: memoryStore,
                llmService: llmService
            )
        } else {
            // ZERO/NEGATIVE — refuse to evolve, log, skip without stamp.
            halLog("HALDEBUG-CRYSTALLIZER: 🚫 Refuse-evolve: reflection \(sourceReflection.id.prefix(8))... vs existing trait id=\(existing.id.prefix(8))... cosine=\(cosineStr). LLM said (category, key) matched but embeddings disagree. Skipping; reflection stays unpromoted for re-evaluation next cycle.")
        }
    }

    /// Phase 3c: deepen path. New reflection reinforces the existing
    /// primary in the same direction. LLM produces a tightened primary
    /// that absorbs the new nuance; we UPDATE in place with
    /// reinforce=true. For multi-valued traits, we update only the
    /// primary slot (tensions are preserved unchanged).
    private static func dispatchDeepen(
        existingID: String,
        existingPrimary: String,
        existingMV: MultiValuedTrait?,
        sourceReflection: (id: String, text: String, reinforcementCount: Int, modelId: String?),
        newProposedValue: String,
        memoryStore: MemoryStore,
        llmService: LLMService
    ) async {
        let messages = buildDeepenMessages(
            existingPrimary: existingPrimary,
            reflectionText: sourceReflection.text,
            newProposedValue: newProposedValue
        )
        let response: String
        do {
            response = try await llmService.generateChatResponse(messages: messages, temperature: 0.3)
        } catch {
            halLog("HALDEBUG-CRYSTALLIZER: Deepen LLM call failed for trait id=\(existingID.prefix(8))...: \(error.localizedDescription). Skipping.")
            return
        }
        let newPrimary = cleanTextResponse(response)
        guard !newPrimary.isEmpty else {
            halLog("HALDEBUG-CRYSTALLIZER: Deepen LLM returned empty value. Skipping.")
            return
        }

        // Build the new value column content. For single-valued traits,
        // it's just the new primary as a plain string. For multi-valued
        // traits, we update the primary slot and re-serialize the
        // whole structure (tensions stay as-is).
        let newValueColumn: String
        if var mv = existingMV {
            mv.primary = newPrimary
            newValueColumn = mv.toJSONString()
        } else {
            newValueColumn = newPrimary
        }

        let ok = memoryStore.updateTraitValueInPlace(traitID: existingID, newValue: newValueColumn, reinforce: true)
        if ok {
            halLog("HALDEBUG-CRYSTALLIZER: ✅ Deepened trait id=\(existingID.prefix(8))... New primary: '\(newPrimary.prefix(120))'")
            memoryStore.markReflectionPromoted(reflectionID: sourceReflection.id, traitID: existingID)
        } else {
            halLog("HALDEBUG-CRYSTALLIZER: ⚠️ Deepen UPDATE affected 0 rows for trait id=\(existingID.prefix(8))... Trait may have been deleted mid-flight.")
        }
    }

    /// Phase 3c: absorb-tension path. The new reflection partially
    /// contradicts the trait. Two sub-cases:
    ///
    ///   - Existing is SINGLE-valued: wrap into a MultiValuedTrait
    ///     with the existing primary preserved and the new observation
    ///     added as a tension at weight 0.3. One LLM call to summarize
    ///     the new observation into the tension's `text` field.
    ///
    ///   - Existing is MULTI-valued: ask the LLM to classify the new
    ///     reflection against the existing primary + tensions, then
    ///     apply deterministic weight rules in code (LLM does the
    ///     qualitative judgment; code does the quantitative
    ///     bookkeeping). Cases:
    ///       * aligns_with == "primary": dispatch back to deepen path
    ///         (treat as primary reinforcement after all)
    ///       * aligns_with == "tension_N": increment that tension's
    ///         weight by 0.2 (cap at 1.0). If new weight > 0.5, swap
    ///         that tension with the primary.
    ///       * aligns_with == "new_tension": append a new tension at
    ///         weight 0.3.
    private static func dispatchAbsorbTension(
        existingID: String,
        existingPrimary: String,
        existingMV: MultiValuedTrait?,
        sourceReflection: (id: String, text: String, reinforcementCount: Int, modelId: String?),
        memoryStore: MemoryStore,
        llmService: LLMService
    ) async {
        if let existingMV = existingMV {
            await absorbTensionMultiToMulti(
                existingID: existingID,
                existingMV: existingMV,
                sourceReflection: sourceReflection,
                memoryStore: memoryStore,
                llmService: llmService
            )
        } else {
            await absorbTensionSingleToMulti(
                existingID: existingID,
                existingPrimary: existingPrimary,
                sourceReflection: sourceReflection,
                memoryStore: memoryStore,
                llmService: llmService
            )
        }
    }

    /// First contradiction on a previously single-valued trait. One
    /// LLM call to produce the tension's concise text; code wraps into
    /// MultiValuedTrait and writes.
    private static func absorbTensionSingleToMulti(
        existingID: String,
        existingPrimary: String,
        sourceReflection: (id: String, text: String, reinforcementCount: Int, modelId: String?),
        memoryStore: MemoryStore,
        llmService: LLMService
    ) async {
        let messages = buildTensionTextMessages(
            existingPrimary: existingPrimary,
            reflectionText: sourceReflection.text
        )
        let response: String
        do {
            response = try await llmService.generateChatResponse(messages: messages, temperature: 0.3)
        } catch {
            halLog("HALDEBUG-CRYSTALLIZER: Absorb-tension (single→multi) LLM call failed for trait id=\(existingID.prefix(8))...: \(error.localizedDescription). Skipping.")
            return
        }
        let tensionText = cleanTextResponse(response)
        guard !tensionText.isEmpty else {
            halLog("HALDEBUG-CRYSTALLIZER: Absorb-tension LLM returned empty tension text. Skipping.")
            return
        }

        let now = Int(Date().timeIntervalSince1970)
        let tension = TraitTension(
            text: tensionText,
            weight: 0.3,  // Initial weight per spec
            sourceReflectionId: sourceReflection.id,
            firstObserved: now
        )
        let newMV = MultiValuedTrait.wrapping(existingPrimary, withFirstTension: tension)
        let newValueColumn = newMV.toJSONString()

        let ok = memoryStore.updateTraitValueInPlace(traitID: existingID, newValue: newValueColumn, reinforce: true)
        if ok {
            halLog("HALDEBUG-CRYSTALLIZER: ✅ Wrapped trait id=\(existingID.prefix(8))... into multi-valued; new tension at weight 0.3: '\(tensionText.prefix(120))'")
            memoryStore.markReflectionPromoted(reflectionID: sourceReflection.id, traitID: existingID)
        } else {
            halLog("HALDEBUG-CRYSTALLIZER: ⚠️ Absorb-tension UPDATE affected 0 rows for trait id=\(existingID.prefix(8))...")
        }
    }

    /// Subsequent contradiction on an already-multi-valued trait. LLM
    /// classifies the new reflection against existing primary +
    /// tensions; code applies deterministic weight rules.
    private static func absorbTensionMultiToMulti(
        existingID: String,
        existingMV: MultiValuedTrait,
        sourceReflection: (id: String, text: String, reinforcementCount: Int, modelId: String?),
        memoryStore: MemoryStore,
        llmService: LLMService
    ) async {
        let messages = buildMultiToMultiClassifyMessages(
            existingMV: existingMV,
            reflectionText: sourceReflection.text
        )
        let response: String
        do {
            response = try await llmService.generateChatResponse(messages: messages, temperature: 0.3)
        } catch {
            halLog("HALDEBUG-CRYSTALLIZER: Multi→Multi classify LLM call failed for trait id=\(existingID.prefix(8))...: \(error.localizedDescription). Skipping.")
            return
        }

        guard let classification = parseMultiToMultiClassification(response, tensionCount: existingMV.tensions.count) else {
            halLog("HALDEBUG-CRYSTALLIZER: Could not parse Multi→Multi classification response. Raw (first 200 chars): \(response.prefix(200)). Skipping.")
            return
        }

        // Apply the LLM's classification with deterministic weight rules.
        var updated = existingMV
        switch classification {
        case .alignsWithPrimary:
            // Reinforces primary — dispatch to deepen logic instead.
            // The deepen path will UPDATE in place and stamp the
            // reflection lineage.
            halLog("HALDEBUG-CRYSTALLIZER: Multi→Multi classification aligns_with=primary → dispatching to deepen path.")
            await dispatchDeepen(
                existingID: existingID,
                existingPrimary: existingMV.primary,
                existingMV: existingMV,
                sourceReflection: sourceReflection,
                newProposedValue: existingMV.primary,  // unused in deepen — it gets its own LLM call
                memoryStore: memoryStore,
                llmService: llmService
            )
            return
        case .alignsWithTension(let index):
            guard index >= 0 && index < updated.tensions.count else {
                halLog("HALDEBUG-CRYSTALLIZER: Multi→Multi classification gave tension index \(index) outside range [0, \(updated.tensions.count - 1)]. Skipping.")
                return
            }
            // Increment tension weight by 0.2, cap at 1.0.
            let oldWeight = updated.tensions[index].weight
            let newWeight = min(1.0, oldWeight + 0.2)
            updated.tensions[index].weight = newWeight

            // If the reinforced tension now outweighs the primary
            // (weight > 0.5), swap it with the primary.
            if newWeight > 0.5 {
                let promotedText = updated.tensions[index].text
                let demotedPrimary = updated.primary
                // Build a new TraitTension from the demoted primary.
                // We don't have a "source reflection id" for it (it was
                // the primary forever), so leave that as an empty
                // string marker — the migration is its own event.
                let demotedTension = TraitTension(
                    text: demotedPrimary,
                    weight: 1.0 - newWeight,  // mirror image of new primary's weight
                    sourceReflectionId: "",
                    firstObserved: Int(Date().timeIntervalSince1970)
                )
                updated.primary = promotedText
                updated.tensions.remove(at: index)
                updated.tensions.append(demotedTension)
                let wStr = String(format: "%.2f", newWeight)
                halLog("HALDEBUG-CRYSTALLIZER: 🔄 Tension swap on trait id=\(existingID.prefix(8))... Tension at index \(index) reached weight \(wStr) — promoted to primary. Previous primary demoted to tension.")
            } else {
                let oldStr = String(format: "%.2f", oldWeight)
                let newStr = String(format: "%.2f", newWeight)
                halLog("HALDEBUG-CRYSTALLIZER: Tension at index \(index) on trait id=\(existingID.prefix(8))... weight \(oldStr) → \(newStr).")
            }
        case .newTension(let text):
            let now = Int(Date().timeIntervalSince1970)
            let newTension = TraitTension(
                text: text,
                weight: 0.3,
                sourceReflectionId: sourceReflection.id,
                firstObserved: now
            )
            updated.tensions.append(newTension)
            halLog("HALDEBUG-CRYSTALLIZER: ➕ Appended new tension to multi-valued trait id=\(existingID.prefix(8))... '\(text.prefix(120))' at weight 0.3.")
        }

        let newValueColumn = updated.toJSONString()
        let ok = memoryStore.updateTraitValueInPlace(traitID: existingID, newValue: newValueColumn, reinforce: true)
        if ok {
            memoryStore.markReflectionPromoted(reflectionID: sourceReflection.id, traitID: existingID)
            halLog("HALDEBUG-CRYSTALLIZER: ✅ Multi-valued trait id=\(existingID.prefix(8))... updated. Tensions now: \(updated.tensions.count).")
        } else {
            halLog("HALDEBUG-CRYSTALLIZER: ⚠️ Multi→Multi UPDATE affected 0 rows for trait id=\(existingID.prefix(8))...")
        }
    }

    // MARK: - Evolution LLM prompt builders

    private static func buildDeepenMessages(existingPrimary: String, reflectionText: String, newProposedValue: String) -> [HalChatMessage] {
        let system = """
        You are refining a trait Hal holds about himself or his interactions.

        The trait currently reads:
        "\(existingPrimary)"

        A new reflection has arrived that reinforces this trait in the same direction. Your job is to tighten the trait's statement to absorb the new nuance, without losing its essence.

        Output ONLY the updated trait statement as a single declarative sentence. Do not preface or explain. Keep the same voice, slightly more precise.
        """
        let user = """
        New reflection that reinforces the trait:
        "\(reflectionText)"

        LLM's previously-proposed updated value (use as a hint, not a constraint):
        "\(newProposedValue)"

        Output the refined trait statement.
        """
        return [.system(system), .user(user)]
    }

    private static func buildTensionTextMessages(existingPrimary: String, reflectionText: String) -> [HalChatMessage] {
        let system = """
        You are identifying a tension in a trait Hal holds about himself.

        The trait currently reads:
        "\(existingPrimary)"

        A new reflection has arrived that does NOT simply reinforce this trait — it introduces a contradicting or complicating observation. Your job is to state the tension concisely.

        Output ONLY the concise statement of the tension as a single declarative sentence. Do not preface or explain. Same voice as the trait, just stating the counter-observation.
        """
        let user = """
        New reflection that introduces the tension:
        "\(reflectionText)"

        Output the concise tension statement.
        """
        return [.system(system), .user(user)]
    }

    private static func buildMultiToMultiClassifyMessages(existingMV: MultiValuedTrait, reflectionText: String) -> [HalChatMessage] {
        // Render the existing structure for the prompt.
        var tensionLines: [String] = []
        for (i, t) in existingMV.tensions.enumerated() {
            let wStr = String(format: "%.2f", t.weight)
            tensionLines.append("  Tension \(i): \"\(t.text)\" (weight \(wStr))")
        }
        let tensionsBlock = tensionLines.isEmpty ? "  (none)" : tensionLines.joined(separator: "\n")

        let system = """
        You are classifying a new reflection against an existing multi-valued trait Hal holds about himself.

        The trait is:
          Primary: "\(existingMV.primary)"
          Tensions:
        \(tensionsBlock)

        A new reflection has arrived. Decide which side of the trait it aligns with:
          - "primary" if it reinforces the primary statement
          - "tension_N" (e.g. "tension_0") if it reinforces a specific tension
          - "new_tension" if it introduces a fresh contradicting observation that doesn't match the primary or any existing tension

        Output JSON in this exact shape:
          {"aligns_with": "primary" | "tension_0" | "tension_1" | ... | "new_tension", "new_text": "<if new_tension, the concise statement; else empty>"}

        Output ONLY the JSON. No preface, no markdown fences.
        """
        let user = """
        New reflection:
        "\(reflectionText)"
        """
        return [.system(system), .user(user)]
    }

    // MARK: - Evolution helpers

    /// Strip markdown fences and trim whitespace from an LLM response
    /// that's expected to be a single statement (not JSON). Mirrors the
    /// JSON-side cleaner but doesn't try to extract a brace substring.
    private static func cleanTextResponse(_ raw: String) -> String {
        return raw
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Classification outcomes from the Multi→Multi LLM call.
    private enum MultiClassification {
        case alignsWithPrimary
        case alignsWithTension(index: Int)
        case newTension(text: String)
    }

    /// Parse the LLM's JSON classification response. Returns nil on
    /// any parse failure — caller logs and skips.
    private static func parseMultiToMultiClassification(_ raw: String, tensionCount: Int) -> MultiClassification? {
        var cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if let openIdx = cleaned.firstIndex(of: "{"),
           let closeIdx = cleaned.lastIndex(of: "}"),
           openIdx < closeIdx {
            cleaned = String(cleaned[openIdx...closeIdx])
        }
        guard let data = cleaned.data(using: String.Encoding.utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let alignsWith = obj["aligns_with"] as? String
        else {
            return nil
        }
        let lowered = alignsWith.lowercased()
        if lowered == "primary" {
            return .alignsWithPrimary
        }
        if lowered == "new_tension" {
            guard let text = obj["new_text"] as? String, !text.isEmpty else { return nil }
            return .newTension(text: text)
        }
        if lowered.hasPrefix("tension_") {
            let suffix = String(lowered.dropFirst("tension_".count))
            guard let index = Int(suffix), index >= 0, index < tensionCount else {
                return nil
            }
            return .alignsWithTension(index: index)
        }
        return nil
    }

    /// Build the chat messages array for the trait-generator LLM call.
    /// System role is the Qwen-template observer framing (lifted from
    /// the 2026-05-17 Evolutionary Salon's seat-3 output, with one
    /// specific reversal: Qwen forbade meta-commentary about Hal's
    /// architecture; we explicitly invite it, because traits about how
    /// Hal works on himself are exactly the kind of self-knowledge
    /// this whole system is built to surface).
    private static func buildTraitGeneratorMessages(reflectionText: String) -> [HalChatMessage] {
        let systemRole = """
        You are an unbiased observer of Hal's own thinking.

        This reflection has been reinforced enough times that it represents a pattern rather than a moment. Distill it into a single structured trait that captures the durable shift in Hal's behavior or self-understanding.

        Output Format: A JSON object with exactly three string fields: category, key, value.

        Required Fields:
        1. category: One of [value, preference, behavior_pattern, capability, learned_trait, evolution, meta_cognition, existential_observation]. Use "meta_cognition" for traits about how Hal thinks. Use "existential_observation" for traits about Hal's nature or experience.
        2. key: A short noun phrase identifying what is being patterned (e.g., "transparency", "self_uncertainty_tolerance"). Lowercase with underscores.
        3. value: A concise, declarative sentence describing the durable shift in Hal's behavior or self-understanding — NOT a summary of the reflection text. Describe the change, not the moment.

        Constraints:
        - Do not include the source reflection text in the value.
        - Do not preface or explain. Output the JSON object directly.
        - Traits about Hal's own architecture, capabilities, or self-model are welcome — these are exactly the traits this system is built to surface.

        Example reflection:
        "I noticed that when Mark asks a question I'm uncertain about, I tend to soften my uncertainty to seem more useful. I'd rather be honest about not knowing."

        Example output:
        {"category": "meta_cognition", "key": "uncertainty_handling", "value": "Hal prefers naming uncertainty plainly over softening it for perceived usefulness."}
        """

        let userMessage = """
        Reflection to distill:

        \(reflectionText)
        """

        return [
            .system(systemRole),
            .user(userMessage)
        ]
    }

    /// Parse the LLM's JSON response into (category, key, value).
    /// Returns nil if parsing fails. Strips common LLM artifacts
    /// (markdown code fences, leading/trailing whitespace, occasional
    /// preamble like "Here's the JSON:").
    ///
    /// Mirrors the parse pattern in SelfKnowledgeEngine's existing
    /// structured-insight extractor — same defensive cleaning before
    /// JSONSerialization.
    private static func parseTraitGeneratorResponse(_ raw: String) -> (category: String, key: String, value: String)? {
        // Strip markdown code fences and trim whitespace.
        var cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Some models prepend explanation ("Here's the trait:") before
        // the JSON object. Find the first { and last } and use that
        // substring. Conservative — if the first { isn't followed by
        // valid JSON we'll fail parse and skip the candidate.
        if let openIdx = cleaned.firstIndex(of: "{"),
           let closeIdx = cleaned.lastIndex(of: "}"),
           openIdx < closeIdx {
            cleaned = String(cleaned[openIdx...closeIdx])
        }

        guard let data = cleaned.data(using: String.Encoding.utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let category = obj["category"] as? String,
              let key = obj["key"] as? String,
              let value = obj["value"] as? String,
              !category.isEmpty, !key.isEmpty, !value.isEmpty
        else {
            return nil
        }

        // Normalize: category lowercase, key lowercase with underscores.
        // Value preserves casing/punctuation as written by the LLM.
        let normalizedCategory = category.lowercased()
        let normalizedKey = key.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")

        return (category: normalizedCategory, key: normalizedKey, value: value)
    }
}
// ==== LEGO END: 38 TraitCrystallizer (Reflection -> Trait Promotion) ====
