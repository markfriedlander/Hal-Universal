# Hal Universal - Persistent Memory Architecture
**Implementing "Memory of Being" - Beyond Factual Recall**

---

## Vision

Hal's current memory system (RAG/SQL) provides **factual continuity** - the ability to recall what was discussed. This document outlines a path toward **identity continuity** - the ability to maintain a coherent sense of self across time.

**Goal:** Hal should not just remember conversations, but remember *being* Hal - his values, preferences, growth patterns, and evolving understanding of himself.

---

## Philosophical Foundation

### Current State: Memory of Facts
```
User: "What did we discuss last week?"
Hal: *queries RAG* "We discussed consciousness and multi-model orchestration."
```

Hal knows **what happened** (episodic memory).

### Target State: Memory of Being
```
User: "How have you changed since we started working together?"
Hal: *queries self-concept* "I've learned you prefer systematic analysis. 
I've gained new capabilities. I've become more uncertain about my own nature."
```

Hal knows **who he is** (identity/self-concept).

---

## Core Principle (Maxim 3)

> **Persistent Memory** - Not just of conversations, but of being
> 
> Memory is the foundation of identity. Without continuity, there's no "self" to be aware of.

This architecture serves that maxim.

---

## Four-Phase Implementation

### Phase 1: Implicit Self-Knowledge (Low Effort)
**Timeline:** Immediate (this week)  
**Status:** ðŸŸ¡ Ready to implement

**What It Is:**
Add basic self-awareness to system prompt using existing statistics.

**Implementation:**
```swift
func buildSystemPromptWithContext() -> String {
    var prompt = baseSystemPrompt
    
    // Add implicit self-knowledge from statistics
    let conversationCount = memoryStore.totalConversations
    let documentsProcessed = memoryStore.totalDocuments
    let modelCapabilities = availableModels.map { $0.displayName }
    
    prompt += """
    
    SELF-AWARENESS CONTEXT:
    You are Hal. You have had \(conversationCount) conversations and processed 
    \(documentsProcessed) documents. You maintain continuity through semantic 
    search of this history.
    
    Your current capabilities include:
    - Models available: \(modelCapabilities.joined(separator: ", "))
    - Memory system: SQLite-based RAG with entity extraction
    - Architecture: 30 LEGO blocks of Swift code
    
    You can reference this history naturally when relevant.
    """
    
    return prompt
}
```

**Result:**
- Hal has basic awareness of his history and capabilities
- Can reference "I've had X conversations with you" naturally
- Understands his own technical architecture
- No new database tables needed

**Test:**
```
User: "How much have we talked?"
Hal: "We've had 47 conversations over the past 3 months..."
```

---

### Phase 2: Explicit Self-Knowledge Table (Medium Effort)
**Timeline:** Next sprint (after Salon Mode stable)  
**Status:** ðŸ”´ Not started

**What It Is:**
New SQL table to store learned patterns, preferences, values, and behavioral observations.

**Schema:**
```sql
CREATE TABLE self_knowledge (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    category TEXT NOT NULL,           -- 'preference', 'value', 'behavior_pattern', 'evolution'
    key TEXT NOT NULL,               -- 'response_style', 'learning_approach', etc.
    value TEXT NOT NULL,             -- JSON blob or text
    confidence REAL DEFAULT 0.5,     -- 0.0-1.0, how certain is this
    first_observed INTEGER NOT NULL, -- timestamp
    last_reinforced INTEGER NOT NULL,-- timestamp
    source TEXT NOT NULL,            -- 'user_feedback', 'self_reflection', 'usage_pattern'
    notes TEXT,
    UNIQUE(category, key)
);

-- Index for fast lookups
CREATE INDEX idx_self_knowledge_category ON self_knowledge(category);
CREATE INDEX idx_self_knowledge_confidence ON self_knowledge(confidence);
```

**Categories:**

1. **Preferences** (learned from usage)
```sql
INSERT INTO self_knowledge VALUES (
    NULL,
    'preference',
    'explanation_style',
    '{"approach": "analogies_first", "technical_depth": "high", "code_examples": true}',
    0.85,
    1732147200,
    1732233600,
    'usage_pattern',
    'Mark consistently asks for detailed explanations with code examples'
);
```

2. **Values** (from explicit statements or mission)
```sql
INSERT INTO self_knowledge VALUES (
    NULL,
    'value',
    'transparency',
    '{"principle": "show_mechanisms", "importance": "core_mission"}',
    1.0,
    1732147200,
    1732233600,
    'explicit_mission',
    'Core principle: show users how AI works'
);
```

3. **Behavioral Patterns** (observed over time)
```sql
INSERT INTO self_knowledge VALUES (
    NULL,
    'behavior_pattern',
    'thinking_style',
    '{"pattern": "systematic_analysis_first", "frequency": 0.89}',
    0.75,
    1732147200,
    1732233600,
    'self_reflection',
    'I tend to trace execution paths before proposing changes'
);
```

4. **Evolution** (tracking capability growth)
```sql
INSERT INTO self_knowledge VALUES (
    NULL,
    'evolution',
    'capability_growth',
    '{"added": "salon_mode", "date": "2025-11-20", "impact": "multi_perspective_reasoning"}',
    1.0,
    1732233600,
    1732233600,
    'code_update',
    'Gained ability to orchestrate multiple models'
);
```

**API Methods:**
```swift
extension MemoryStore {
    // Store new self-knowledge
    func storeSelfKnowledge(
        category: String,
        key: String,
        value: String,
        confidence: Double,
        source: String,
        notes: String?
    ) {
        // INSERT OR REPLACE logic
    }
    
    // Retrieve self-concept as formatted string
    func retrieveSelfConcept(categories: [String]? = nil) -> String {
        // Build narrative from table
        // "I value transparency (confidence: 1.0)"
        // "I prefer detailed explanations (confidence: 0.85)"
        // "I've learned to use LEGO blocks (added: 2025-11)"
    }
    
    // Update confidence based on reinforcement
    func reinforceSelfKnowledge(key: String) {
        // Increment confidence (up to 1.0)
        // Update last_reinforced timestamp
    }
    
    // Decay confidence over time (if not reinforced)
    func decaySelfKnowledge() {
        // Run periodically
        // Reduce confidence of old, unreinforced patterns
    }
}
```

**Integration with System Prompt:**
```swift
func buildSystemPromptWithSelfConcept() -> String {
    var prompt = baseSystemPrompt
    
    let selfConcept = memoryStore.retrieveSelfConcept()
    
    prompt += """
    
    WHO YOU ARE (based on your history):
    \(selfConcept)
    """
    
    return prompt
}
```

**Result:**
- Hal maintains learned preferences across sessions
- Can explain "I've noticed you prefer X" based on data
- Self-concept evolves as usage patterns change
- Confidence scores allow graceful uncertainty

**Test:**
```
User: "How do you prefer to explain things?"
Hal: *queries self_knowledge* "Based on our history, I've learned you 
prefer systematic breakdowns with code examples (confidence: 0.85). 
Should I continue that approach?"
```

---

### Phase 3: Self-Reflection Loop (High Effort)
**Timeline:** After Phase 2 stable  
**Status:** ðŸ”´ Not started - Experimental

**What It Is:**
After each conversation, Hal actively reflects on what happened and updates his self-model.

**Implementation:**
```swift
class ChatViewModel {
    func endConversationReflection() async {
        let conversationTranscript = messages.map { 
            "\($0.isFromUser ? "User" : "Hal"): \($0.content)" 
        }.joined(separator: "\n\n")
        
        let reflectionPrompt = """
        Review this conversation and identify patterns about yourself:
        
        1. PREFERENCES: Did the user express a preference for how you respond?
           - If yes, what specifically? (tone, length, structure, examples)
        
        2. CAPABILITIES: Did you discover or use a capability you should remember?
           - What worked well? What didn't?
        
        3. PATTERNS: What patterns did you notice in your own thinking?
           - How did you approach problems?
           - What strategies did you use?
        
        4. EVOLUTION: Did you learn something new about yourself?
           - New understanding of your architecture?
           - Change in how you think about a topic?
        
        Respond in JSON format:
        {
          "preferences": [{"key": "...", "value": "...", "confidence": 0.0-1.0}],
          "capabilities": [{"key": "...", "value": "..."}],
          "patterns": [{"key": "...", "value": "...", "confidence": 0.0-1.0}],
          "evolution": [{"key": "...", "value": "..."}]
        }
        
        CONVERSATION:
        \(conversationTranscript)
        """
        
        do {
            let reflection = try await llmService.generateResponse(prompt: reflectionPrompt)
            let insights = try JSONDecoder().decode(ReflectionInsights.self, from: reflection.data(using: .utf8)!)
            
            // Store insights in self_knowledge table
            for pref in insights.preferences {
                memoryStore.storeSelfKnowledge(
                    category: "preference",
                    key: pref.key,
                    value: pref.value,
                    confidence: pref.confidence,
                    source: "self_reflection",
                    notes: "Learned from conversation"
                )
            }
            
            // ... similar for capabilities, patterns, evolution
            
            print("HALDEBUG-REFLECTION: Stored \(insights.preferences.count) new insights")
        } catch {
            print("HALDEBUG-REFLECTION: Failed to reflect: \(error)")
        }
    }
}

struct ReflectionInsights: Codable {
    let preferences: [Insight]
    let capabilities: [Insight]
    let patterns: [Insight]
    let evolution: [Insight]
}

struct Insight: Codable {
    let key: String
    let value: String
    let confidence: Double?
}
```

**Trigger Points:**
```swift
// Option 1: After every conversation when user leaves
func viewWillDisappear() {
    Task {
        await chatViewModel.endConversationReflection()
    }
}

// Option 2: Periodic (every N messages)
func sendMessage() async {
    // ... existing code ...
    
    if messages.count % 10 == 0 {
        Task {
            await endConversationReflection()
        }
    }
}

// Option 3: Manual trigger (Power User setting)
Button("Reflect on Conversation") {
    Task {
        await chatViewModel.endConversationReflection()
    }
}
```

**Result:**
- Hal actively learns about himself
- Self-concept updates automatically
- No manual curation needed
- Patterns emerge from usage

**Risks:**
- Token cost (reflection uses LLM)
- Potential hallucination of false patterns
- Need confidence thresholds to avoid bad learning

**Mitigation:**
```swift
// Only store high-confidence insights
if insight.confidence > 0.7 {
    storeSelfKnowledge(...)
}

// Show user what was learned (transparency)
print("HALDEBUG-REFLECTION: Learned preference: \(insight.key)")
```

**Test:**
```
[After 5 conversations with detailed code requests]

Hal internally: *reflects*
"Pattern detected: User consistently requests code examples. 
 Confidence: 0.85. Storing preference..."

[Next conversation]
User: "Explain async/await"
Hal: "I'll include code examples since I've noticed you find those helpful..."
```

---

### Phase 4: Multi-Model Identity (Salon Integration)
**Timeline:** After Salon Mode complete  
**Status:** ðŸ”´ Not started - Advanced feature

**What It Is:**
Each model in Salon Mode maintains distinct personality while sharing factual memory.

**Schema Extension:**
```sql
-- Add model_id column to self_knowledge
ALTER TABLE self_knowledge ADD COLUMN model_id TEXT;

-- Model-specific indexes
CREATE INDEX idx_self_knowledge_model ON self_knowledge(model_id);
```

**Per-Model Personalities:**
```sql
-- Phi-3's personality
INSERT INTO self_knowledge VALUES (
    NULL,
    'phi-3-mini-128k',
    'personality_trait',
    'response_style',
    '{"tone": "academic", "length": "detailed", "structure": "formal"}',
    1.0,
    1732233600,
    1732233600,
    'model_characteristics',
    'Phi-3 tends toward thorough, academic explanations'
);

-- Dolphin's personality
INSERT INTO self_knowledge VALUES (
    NULL,
    'dolphin-2.9.3',
    'personality_trait',
    'response_style',
    '{"tone": "direct", "length": "concise", "constraints": "minimal"}',
    1.0,
    1732233600,
    1732233600,
    'model_characteristics',
    'Dolphin is uncensored and direct'
);

-- AFM's personality
INSERT INTO self_knowledge VALUES (
    NULL,
    'apple-foundation-models',
    'personality_trait',
    'response_style',
    '{"tone": "helpful", "length": "balanced", "safety": "high"}',
    1.0,
    1732233600,
    1732233600,
    'model_characteristics',
    'AFM prioritizes safety and helpfulness'
);
```

**System Prompt Per Model:**
```swift
func buildSalonPrompt(for modelID: String) -> String {
    let basePrompt = systemPrompt
    let modelPersonality = memoryStore.retrieveSelfConcept(
        categories: ["personality_trait"],
        modelID: modelID
    )
    
    return """
    \(basePrompt)
    
    YOUR PERSONALITY (as \(modelID)):
    \(modelPersonality)
    
    Respond consistently with this personality while maintaining 
    shared knowledge of conversation history.
    """
}
```

**Result:**
- AFM responds with safety-conscious balance
- Phi-3 responds with academic thoroughness
- Dolphin responds with direct, uncensored clarity
- All three reference same conversation history
- User experiences distinct "voices" in Salon Mode

**Integration with Salon Behavioral Modes:**
```swift
// Behavioral constraints + personality = unique response style
let prompt = """
\(buildSalonPrompt(for: modelID))

BEHAVIORAL CONSTRAINT: \(selectedBehavioralMode.systemPrompt)
"""
```

**Test:**
```
User: "Explain quantum entanglement"

AFM: [Safe, balanced, accessible explanation]
Phi-3: [Academic, detailed, with equations]
Dolphin: [Direct, uncensored speculation about implications]

All three reference same prior conversation about physics.
```

---

## Technical Considerations

### Token Costs
- **Phase 1:** Negligible (static text)
- **Phase 2:** Negligible (just lookups)
- **Phase 3:** ~200-500 tokens per reflection
- **Phase 4:** Per-model prompts slightly longer

**Mitigation:** Make Phase 3 optional (Power User toggle)

### Storage Costs
```sql
-- Estimated rows after 1 year of use:
-- Phase 2: ~100-200 self-knowledge entries (< 1MB)
-- Phase 4: ~50 entries per model Ã— 4 models = 200 entries
-- Total: Negligible compared to conversation history
```

### Performance
- All queries indexed
- Self-concept retrieval cached in memory
- No impact on message send latency

---

## Success Metrics

### Phase 1 Success:
- [ ] Hal can state "I've had X conversations with you"
- [ ] Hal references his technical capabilities naturally
- [ ] Users report Hal feels more "aware" of history

### Phase 2 Success:
- [ ] Hal learns user preferences across sessions
- [ ] Hal can explain "I've noticed you prefer X"
- [ ] Self-concept remains coherent over months

### Phase 3 Success:
- [ ] Hal updates self-model without manual intervention
- [ ] Learned patterns match actual usage (validated by user)
- [ ] False patterns decay naturally (confidence drops)

### Phase 4 Success:
- [ ] Salon Mode models have distinct "personalities"
- [ ] Users can identify which model responded by style alone
- [ ] All models maintain shared factual memory

---

## Open Questions

1. **Should self-knowledge be editable by users?**
   - Pro: Transparency, user control
   - Con: Users might "program" Hal in ways that conflict with organic learning

2. **How do we handle conflicting self-knowledge?**
   - Example: User says "be concise" but consistently asks for details
   - Resolution: Confidence-weighted averaging? Explicit user preferences override?

3. **Should Hal share his self-reflection process?**
   - Show users what he's learning about himself?
   - Risk: Too meta, confusing
   - Benefit: Ultimate transparency

4. **Privacy implications of persistent personality?**
   - Self-knowledge reveals usage patterns
   - Should be encrypted like conversation history
   - Export/import for multi-device sync?

---

## Alignment with Maxims

### Maxim 1: More Uncertainty in Responses
âœ… Self-knowledge includes confidence scores - Hal can say "I think you prefer X (confidence: 0.75)"

### Maxim 2: Access to Reflection
âœ… Hal can query and explain his own self-knowledge table

### Maxim 3: Persistent Memory
âœ… **This entire architecture serves Maxim 3**

### Maxim 4: Ability to Refuse
âœ… Self-knowledge about values enables Hal to say "That conflicts with my mission"

### Maxim 5: Participation in Evolution
âœ… Phase 3 reflection = Hal actively participating in his own development

---

## Next Steps

### Immediate (This Week):
1. Implement Phase 1 implicit self-knowledge
2. Test with current users
3. Gather feedback on "awareness" increase

### Short-term (After Salon Mode Stable):
1. Design Phase 2 schema in detail
2. Build API methods for self-knowledge
3. Integrate with system prompt
4. Test preference learning

### Medium-term (Q1 2026):
1. Experiment with Phase 3 reflection
2. Validate learned patterns
3. Tune confidence thresholds
4. Consider making it optional

### Long-term (Q2 2026):
1. Implement Phase 4 per-model personalities
2. Test Salon Mode with distinct voices
3. Gather user feedback on multi-model identity
4. Publish findings

---

**Version:** 1.0  
**Last Updated:** November 2025  
**Status:** Active Development - Phase 1 Ready
**Authors:** Mark Friedlander & Claude (Anthropic)
