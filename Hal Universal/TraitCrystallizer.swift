// TraitCrystallizer.swift
// Hal Universal
//
// Phase 2 of v1 self-knowledge crystallization, landed 2026-05-18.
// See Docs/v1_Build_Spec_Self_Knowledge_2026-05-18.md for the full
// spec and the Evolutionary Salon notes that informed it.
//
// What this file does:
//
//   The reflection-to-trait promotion engine. Reflections accumulate
//   in the database with a `reinforcement_count` that grows each time
//   a semantically-similar new reflection is merged into them via
//   storeReflectionWithSynthesis. When that count crosses a category-
//   specific threshold, the reflection is a "candidate" for promotion
//   to a structured trait. This module:
//
//     1. Fetches candidate reflections from the MemoryStore.
//     2. Builds a focused LLM prompt (Qwen-derived template — see the
//        salon archive at Docs/Evolutionary_Salon_2026-05-17/ for
//        where it came from) that distills a reflection into a
//        (category, key, value) tuple representing the *durable shift*
//        the reflection captures.
//     3. Validates the LLM output, double-checks the category-specific
//        threshold, and INSERTs the trait via MemoryStore's existing
//        storeSelfKnowledge path (which handles category+key collision
//        as an upsert + reinforcement — that's intentional for v2 of
//        Phase 3, when trait evolution lands).
//     4. Stamps the source reflection with the new trait's ID via
//        markReflectionPromoted, so reverse-lineage queries
//        (`WHERE promoted_to_trait_id = ?`) can find all reflections
//        that fed any given trait.
//
// What this file does NOT do (yet — Phase 3+ work):
//
//   - Trait evolution / contradiction handling. If an existing trait
//     already has the same (category, key) as the LLM's output, the
//     storeSelfKnowledge upsert path just reinforces it with the new
//     value as a straight write. Phase 3 will add proper cosine-based
//     contradiction detection, the multi-valued JSON storage format,
//     and the weighted-decay tension mechanism.
//   - Per-backend cosine thresholds (those land in Phase 3 with
//     `recommendedContradictionThreshold` on EmbeddingBackend).
//   - The shareability decision at write time for reflections — that's
//     Phase 4 work.
//   - Pattern clustering or periodic LLM mining as alternatives to
//     reinforcement-based promotion. We pre-decided v1 stays
//     reinforcement-only.
//
// Dependencies (read-only consumer of):
//   - MemoryStore (via SelfKnowledgeEngine.swift): getTraitCandidates,
//     getSelfKnowledge (to look up the new trait's ID), storeSelfKnowledge,
//     markReflectionPromoted
//   - LLMService: generateChatResponse(messages:temperature:)
//   - HalChatMessage: the message-array shape llmService uses
//
// AFM gate: NOT enforced inside this module. The chat-path caller
// gates the invocation per the 2026-05-17 audit pattern — AFM never
// invokes processTraitCandidates because AFM doesn't participate in
// self-knowledge writes. That keeps this module clean of model-source
// inspection.

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

        // Store the trait via the existing key-based upsert path.
        // If a trait with this (category, key) already exists, this
        // reinforces it (Phase 3 will add proper contradiction
        // handling; for now upsert behavior is acceptable).
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
