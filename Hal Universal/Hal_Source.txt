// ==== LEGO START: 01 Imports & App Entry & Environment Wiring ====
//
//  Hal.swift
//  HalChatiOS
//
//  Hal.swift â€” Core Application Source
//  Architecture Overview:
//  - Integrates Apple FoundationModels and MLX frameworks under LLMService.
//  - Uses LEGO-block modular structure (01â€“29) for deterministic editing.
//  - Includes on-device inference, streaming UI, and context-managed memory.
//  - MLXWrapper supports Phi-3 and similar models via MLX Swift APIs.
//  - MemoryStore uses SQLite with schema, embeddings, and semantic search.
//
//  - LEGO Index
// 01  Imports & App Entry & Environment Wiring
// 02  ChatMessage, UnifiedSearchContext, MemoryStore (Part 1)
// 03  MemoryStore (Part 2 â€“ Schema, Encryption, Stats)
// 04  MemoryStore (Part 3 â€“ Storing Turns & Entities)
// 05  MemoryStore (Part 4 â€“ Entities, Embeddings, Search)
// 06  MemoryStore (Part 5 â€“ Retrieval, Debug, Semantic Search)
// 07  MemoryStore (Part 6 â€“ Full Search Flow) & LLMType Enum
// 08  MLXWrapper & LLMService (Foundation + MLX Routing)
// 09  App Entry & iOSChatView (UI Shell)
// 10  ActionsView (Settings, Import/Export, Model Picker)
// 11  ActionsView (Phi-3 Management & Power Tools)
// 12  ActionsView (License & Status Helpers)
// 12.5 SystemPromptEditorView (Power User Tool)
// 13  ChatBubbleView & TimerView (Message UI Components)
// 14  PromptDetailView (Full Prompt & Context Viewer)
// 15  ShareSheet (Export Utility)
// 16  View Extensions (cornerRadius & conditional modifier)
// 17  ChatViewModel (Core Properties & Init)
// 18  ChatViewModel (Memory Stats & Summarization)
// 19  ChatViewModel (Phi-3 MLX Integration)
// 20  ChatViewModel (Prompt History Builder)
// 21  ChatViewModel (Send Message Flow)
// 22  ChatViewModel (Short-Term Memory Helpers)
// 23  ChatViewModel (Repetition Removal Utility)
// 24  ChatViewModel (Conversation & Database Reset)
// 25  ChatVM â€” Export Chat History
// 26  DocumentPicker (UIKit Bridge)
// 27  DocumentImportManager (Ingest & Entities)
// 28  Import Models (ProcessedDocument & Summary)
// 29  MLX Model Downloader (Singleton)
// 30  Model Catalog Service (Hugging Face Integration)
// 31  Hal Watch Bridge (WatchConnectivity)
// 32  HalTestConsole (macOS only — file-based test harness for pipeline diagnostics)
//

import SwiftUI
import Foundation
import Combine
import Observation
import FoundationModels // Keep for FoundationModels option
import UniformTypeIdentifiers // For file types in document import
import SQLite3 // For MemoryStore - Direct C API for consistency with Mac version
import NaturalLanguage // For entity extraction and NLEmbedding
import PDFKit // For PDF document processing
import Network // For LocalAPIServer (NWListener)
import Security // For LocalAPIServer (Keychain token storage)


// Add @preconcurrency import for Foundation to help with Swift 6 concurrency warnings
@preconcurrency import Foundation

// MARK: - Named Entity Support
struct NamedEntity: Codable, Hashable {
    let text: String
    let type: EntityType

    enum EntityType: String, Codable, CaseIterable {
        case person = "person"
        case place = "place"
        case organization = "organization"
        case other = "other"

        var displayName: String {
            switch self {
            case .person: return "Person"
            case .place: return "Place"
            case .organization: return "Organization"
            case .other: return "Other"
            }
        }
    }
}

// MARK: - Type Definitions for Unified Memory System (from Hal10000App.swift)
enum ContentSourceType: String, CaseIterable, Codable {
    case conversation = "conversation"
    case document = "document"
    case webpage = "webpage" // Not used in this simplified version, but kept for consistency
    case email = "email"     // Not used in this simplified version, but kept for consistency
    case sourceCode = "source_code" // Hal.swift ingested as self-knowledge (Maxim #2)

    var displayName: String {
        switch self {
        case .conversation: return "Conversation"
        case .document: return "Document"
        case .webpage: return "Web Page"
        case .email: return "Email"
        case .sourceCode: return "Source Code"
        }
    }

    var icon: String {
        switch self {
        case .conversation: return "💬"
        case .document: return "📄"
        case .webpage: return "🌐"
        case .email: return "📧"
        case .sourceCode: return "⚙️"
        }
    }
}

// MARK: - Enhanced Search Context with Entity Support (from Hal10000App.swift)
struct UnifiedSearchResult: Identifiable, Hashable, Codable { // Made Codable
    let id: UUID // Changed to let, and initialized in init
    let content: String
    var relevance: Double
    let source: String
    var isEntityMatch: Bool
    var filePath: String? // NEW: To store the file path for deep linking

    init(id: UUID = UUID(), content: String, relevance: Double, source: String, isEntityMatch: Bool, filePath: String? = nil) {
        self.id = id
        self.content = content
        self.relevance = relevance
        self.source = source
        self.isEntityMatch = isEntityMatch
        self.filePath = filePath
    }
}
// MARK: - Thread Record
/// Lightweight model for a conversation thread, loaded from the threads table.
struct ThreadRecord: Identifiable, Equatable {
    let id: String           // UUID string, same as conversationId
    var title: String
    var titleIsUserSet: Bool
    var createdAt: Int
    var lastActiveAt: Int
}

// ==== LEGO END: 01 Imports & App Entry & Environment Wiring ====


// ==== LEGO START: 02 ChatMessage, UnifiedSearchContext, MemoryStore (Part 1) ====

// MARK: - Token Breakdown Structure
struct TokenBreakdown: Equatable {
    let systemTokens: Int
    let summaryTokens: Int
    let ragTokens: Int
    let shortTermTokens: Int
    let userInputTokens: Int
    let completionTokens: Int
    let contextWindow: Int  // Store actual context window size from model
    
    var totalPromptTokens: Int {
        return systemTokens + summaryTokens + ragTokens + shortTermTokens + userInputTokens
    }
    
    var totalTokens: Int {
        return totalPromptTokens + completionTokens
    }
    
    var contextWindowSize: Int {
        return contextWindow
    }
    
    var percentageUsed: Double {
        return (Double(totalTokens) / Double(contextWindowSize)) * 100.0
    }
}

// MARK: - Simple ChatMessage Model
struct ChatMessage: Identifiable, Equatable { // Added Equatable for ForEach
    let id: UUID
    var content: String // Changed to var for streaming updates
    let isFromUser: Bool
    let timestamp: Date
    var isPartial: Bool // Changed to var for streaming updates
    var thinkingDuration: TimeInterval? // Changed to var for mutability
    var fullPromptUsed: String? // NEW: To store the exact prompt for Hal's response
    var usedContextSnippets: [UnifiedSearchResult]? // NEW: To store the RAG snippets used
    var tokenBreakdown: TokenBreakdown? // NEW: To store token usage breakdown
    var toolsUsed: [String]? // NEW: To store which tools were used for this response
    let recordedByModel: String // REQUIRED: Which model generated this message ("user" for user messages, model ID for assistant messages)
    let turnNumber: Int // SALON MODE FIX: Explicit turn number from database (single source of truth)
    let seatNumber: Int? // SALON MODE FIX: Seat number for multi-LLM mode (NULL for user messages and single-LLM mode)
    let deliberationRound: Int // SALON MODE FIX: Deliberation round for "pass turn" feature in Context-Aware mode

    init(id: UUID = UUID(), content: String, isFromUser: Bool, timestamp: Date = Date(), isPartial: Bool = false, thinkingDuration: TimeInterval? = nil, fullPromptUsed: String? = nil, usedContextSnippets: [UnifiedSearchResult]? = nil, tokenBreakdown: TokenBreakdown? = nil, toolsUsed: [String]? = nil, recordedByModel: String, turnNumber: Int, seatNumber: Int? = nil, deliberationRound: Int = 1) {
        self.id = id
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = timestamp
        self.isPartial = isPartial
        self.thinkingDuration = thinkingDuration
        self.fullPromptUsed = fullPromptUsed
        self.usedContextSnippets = usedContextSnippets
        self.tokenBreakdown = tokenBreakdown
        self.toolsUsed = toolsUsed
        self.recordedByModel = recordedByModel
        self.turnNumber = turnNumber
        self.seatNumber = seatNumber
        self.deliberationRound = deliberationRound
    }
}

// MARK: - RAG Snippet with Full Metadata
// This represents a single retrieved memory with complete attribution information.
// Serves transparency mission: users can see exactly why RAG retrieved this memory.
struct RAGSnippet: Identifiable, Equatable {
    let id: UUID
    let content: String
    let sourceType: ContentSourceType       // conversation, document, webpage, email
    let sourceName: String                  // Conversation ID or filename
    let timestamp: Date                     // When this memory was created
    let relevanceScore: Double              // Semantic similarity score (0.0-1.0)
    let recordedByModel: String?            // NEW: Which model recorded this memory (for Salon Mode bylines)
    let isEntityMatch: Bool                 // Was this retrieved by entity matching vs. semantic search?
    
    init(id: UUID = UUID(), content: String, sourceType: ContentSourceType, sourceName: String, timestamp: Date, relevanceScore: Double, recordedByModel: String? = nil, isEntityMatch: Bool = false) {
        self.id = id
        self.content = content
        self.sourceType = sourceType
        self.sourceName = sourceName
        self.timestamp = timestamp
        self.relevanceScore = relevanceScore
        self.recordedByModel = recordedByModel
        self.isEntityMatch = isEntityMatch
    }
    
    // Helper: Format timestamp for display (absolute date)
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    // Helper: Format source for display
    var formattedSource: String {
        switch sourceType {
        case .conversation:
            return "Conversation"
        case .document:
            return "Document: \(sourceName)"
        case .webpage:
            return "Web: \(sourceName)"
        case .email:
            return "Email: \(sourceName)"
        case .sourceCode:
            return "Source Code: \(sourceName)"
        }
    }

    // Helper: Format model byline if present
    var formattedByline: String? {
        guard let model = recordedByModel else { return nil }
        // Extract display name from model ID (e.g., "mlx-community/Phi-3-mini-128k" -> "Phi-3")
        if model.contains("Phi-3") {
            return "Phi-3"
        } else if model.contains("Llama") {
            return "Llama"
        } else if model.contains("Dolphin") {
            return "Dolphin"
        } else if model == "apple-foundation-models" {
            return "AFM"
        } else {
            return model
        }
    }
}

// MARK: - Unified Search Context with Rich Metadata
// This is what searchUnifiedContent() returns - a collection of RAG snippets with full attribution.
struct UnifiedSearchContext {
    let snippets: [RAGSnippet]  // Single unified array with all metadata
    let totalTokens: Int
    
    var hasContent: Bool {
        return !snippets.isEmpty
    }
    
    var totalSnippets: Int {
        return snippets.count
    }
    
    // Helper: Filter to conversation snippets only
    var conversationSnippets: [RAGSnippet] {
        return snippets.filter { $0.sourceType == .conversation }
    }
    
    // Helper: Filter to document snippets only
    var documentSnippets: [RAGSnippet] {
        return snippets.filter { $0.sourceType == .document }
    }
    
    // Helper: Get all relevance scores (for backward compatibility if needed)
    var relevanceScores: [Double] {
        return snippets.map { $0.relevanceScore }
    }
}

// MARK: - Memory Store with Persistent Database Connection (Aligned with Hal10000App.swift)
class MemoryStore: ObservableObject {
    static let shared = MemoryStore() // Singleton pattern

    @Published var isEnabled: Bool = true
    @AppStorage("relevanceThreshold") var relevanceThreshold: Double = 0.75 {
        didSet {
            // Notify other parts of the app that the threshold has changed
            NotificationCenter.default.post(name: .relevanceThresholdDidChange, object: nil)
            print("HALDEBUG-THRESHOLD: Relevance threshold updated to \(relevanceThreshold)")
        }
    }
    
    // NEW: Recency boosting parameters for time-aware RAG
    @AppStorage("recencyWeight") var recencyWeight: Double = 0.3 {
        didSet {
            print("HALDEBUG-RECENCY: Recency weight updated to \(recencyWeight)")
        }
    }
    @AppStorage("recencyHalfLifeDays") var recencyHalfLifeDays: Double = 90.0 {
        didSet {
            print("HALDEBUG-RECENCY: Half-life updated to \(recencyHalfLifeDays) days")
        }
    }
    @AppStorage("recencyFloor") var recencyFloor: Double = 0.15 {
        didSet {
            print("HALDEBUG-RECENCY: Recency floor updated to \(recencyFloor)")
        }
    }
    
    // Self-knowledge decay settings (parallel to RAG decay but with different defaults)
    @AppStorage("selfKnowledgeHalfLifeDays") var selfKnowledgeHalfLifeDays: Double = 365.0 {
        didSet {
            print("HALDEBUG-SELF-KNOWLEDGE: Half-life updated to \(selfKnowledgeHalfLifeDays) days")
        }
    }
    @AppStorage("selfKnowledgeFloor") var selfKnowledgeFloor: Double = 0.3 {
        didSet {
            print("HALDEBUG-SELF-KNOWLEDGE: Confidence floor updated to \(selfKnowledgeFloor)")
        }
    }
    @AppStorage("lastConsolidationTurn") var lastConsolidationTurn: Int = 0
    @AppStorage("lastConsolidationTime") var lastConsolidationTime: Double = 0
    @AppStorage("lastReflectionTurn") var lastReflectionTurn: Int = 0
    
    @Published var currentHistoricalContext: HistoricalContext = HistoricalContext(
        conversationCount: 0,
        relevantConversations: 0,
        contextSnippets: [],
        relevanceScores: [],
        totalTokens: 0
    )
    @Published var totalConversations: Int = 0
    @Published var totalTurns: Int = 0
    @Published var totalDocuments: Int = 0
    @Published var totalDocumentChunks: Int = 0
    @Published var searchDebugResults: String = ""

    // Persistent database connection
    private var db: OpaquePointer?
    private var isConnected: Bool = false

    // Private initializer for singleton
    private init() {
        print("HALDEBUG-DATABASE: MemoryStore initializing with persistent connection...")
        setupPersistentDatabase()
    }

    deinit {
        closeDatabaseConnection()
    }

    // Database path - single source of truth
    private var dbPath: String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsPath.appendingPathComponent("hal_conversations.sqlite")
        return dbURL.path
    }

    // Get all database file paths (main + WAL + SHM)
    private var allDatabaseFilePaths: [String] {
        let basePath = dbPath
        return [
            basePath,                           // main database
            basePath + "-wal",                  // Write-Ahead Log
            basePath + "-shm"                   // Shared Memory
        ]
    }

    // MARK: - Nuclear Reset Capability (MemoryStore owns its lifecycle)
    func performNuclearReset() -> Bool {
        print("HALDEBUG-DATABASE: MemoryStore performing nuclear reset...")

        // Step 1: Clear published properties immediately
        DispatchQueue.main.async {
            self.totalConversations = 0
            self.totalTurns = 0
            self.totalDocuments = 0
            self.totalDocumentChunks = 0
            self.searchDebugResults = ""
        }
        print("HALDEBUG-DATABASE: Cleared published properties")

        // Step 2: Close database connection cleanly
        if db != nil {
            sqlite3_close(db)
            db = nil
            isConnected = false
            print("HALDEBUG-DATABASE: Database connection closed cleanly")
        }

        // Step 3: Delete all database files safely (connection is now closed)
        print("HALDEBUG-DATABASE: Deleting database files...")
        var deletedCount = 0
        var failedCount = 0

        for filePath in allDatabaseFilePaths {
            let fileURL = URL(fileURLWithPath: filePath)
            do {
                if FileManager.default.fileExists(atPath: filePath) {
                    try FileManager.default.removeItem(at: fileURL)
                    deletedCount += 1
                    print("HALDEBUG-DATABASE: Deleted \(fileURL.lastPathComponent)")
                } else {
                    print("HALDEBUG-DATABASE: File didn't exist: \(fileURL.lastPathComponent)")
                }
            } catch {
                failedCount += 1
                print("HALDEBUG-DATABASE: ERROR: Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Step 4: Recreate fresh database connection immediately
        print("HALDEBUG-DATABASE: Recreating fresh database connection...")
        setupPersistentDatabase()

        // Step 5: Verify success
        let success = isConnected && failedCount == 0
        if success {
            print("HALDEBUG-DATABASE: SUCCESS: Nuclear reset completed successfully")
            print("HALDEBUG-DATABASE: Files deleted: \(deletedCount)")
            print("HALDEBUG-DATABASE: Files failed: \(failedCount)")
            print("HALDEBUG-DATABASE: Connection healthy: \(isConnected)")
        } else {
            print("HALDEBUG-DATABASE: ERROR: Nuclear reset encountered issues")
            print("HALDEBUG-DATABASE: Files deleted: \(deletedCount)")
            print("HALDEBUG-DATABASE: Files failed: \(failedCount)")
            print("HALDEBUG-DATABASE: Connection healthy: \(isConnected)")
        }

        return success
    }

    // Setup persistent database connection that stays open
    private func setupPersistentDatabase() {
        print("HALDEBUG-DATABASE: Setting up persistent database connection...")

        // Close any existing connection first
        if db != nil {
            sqlite3_close(db)
            db = nil
            isConnected = false
        }

        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            print("HALDEBUG-DATABASE: CRITICAL ERROR - Failed to open database at \(dbPath), SQLite error: \(result)")
            isConnected = false
            return
        }

        isConnected = true
        print("HALDEBUG-DATABASE: Persistent database connection established at \(dbPath)")

        // ENCRYPTION: Enable Apple file protection immediately after database creation
        enableDataProtection()

        // Enable WAL mode for better performance and concurrency
        if sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: Enabled WAL mode for persistent connection")
        } else {
            print("HALDEBUG-DATABASE: ERROR: Failed to enable WAL mode")
        }

        // Enable foreign keys for data integrity
        if sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: Enabled foreign key constraints for data integrity")
        }

        // Create all tables using the persistent connection
        createUnifiedSchema()
        loadUnifiedStats()

        print("HALDEBUG-DATABASE: Persistent database setup complete")
    }
    
    
// ==== LEGO END: 02 ChatMessage, UnifiedSearchContext, MemoryStore (Part 1) ====
    
    
    
// ==== LEGO START: 03 MemoryStore (Part 2 - Schema, Encryption, Stats, Self-Knowledge) ====

                                    // Check if database connection is healthy, reconnect if needed
                                    private func ensureHealthyConnection() -> Bool {
                                        // Quick health check - try a simple query
                                        if isConnected && db != nil {
                                            var stmt: OpaquePointer?
                                            let testSQL = "SELECT 1;"

                                            if sqlite3_prepare_v2(db, testSQL, -1, &stmt, nil) == SQLITE_OK {
                                                let result = sqlite3_step(stmt)
                                                sqlite3_finalize(stmt)

                                                if result == SQLITE_ROW {
                                                    // Connection is healthy
                                                    return true
                                                }
                                            }
                                        }

                                        // Connection is dead, attempt reconnection
                                        print("HALDEBUG-DATABASE: WARNING: Database connection unhealthy, attempting reconnection...")
                                        setupPersistentDatabase()
                                        return isConnected
                                    }

                                    // Create simplified unified schema with entity support + SELF-KNOWLEDGE TABLE
                                    private func createUnifiedSchema() {
                                        guard ensureHealthyConnection() else {
                                            print("HALDEBUG-DATABASE: ERROR: Cannot create schema - no database connection")
                                            return
                                        }

                                        print("HALDEBUG-DATABASE: Creating unified database schema with entity support and self-knowledge...")

                                        // Create sources table first (no dependencies)
                                        let sourcesSQL = """
                                        CREATE TABLE IF NOT EXISTS sources (
                                            id TEXT PRIMARY KEY,
                                            source_type TEXT NOT NULL,
                                            display_name TEXT NOT NULL,
                                            file_path TEXT,
                                            url TEXT,
                                            created_at INTEGER NOT NULL,
                                            last_updated INTEGER NOT NULL,
                                            total_chunks INTEGER DEFAULT 0,
                                            metadata_json TEXT,
                                            content_hash TEXT,
                                            file_size INTEGER DEFAULT 0
                                        );
                                        """

                                        // ENHANCED SCHEMA: Add entity_keywords, turn_number, deliberation_round, seat_number columns
                                        let unifiedContentSQL = """
                                        CREATE TABLE IF NOT EXISTS unified_content (
                                            id TEXT PRIMARY KEY,
                                            content TEXT NOT NULL,
                                            embedding BLOB,
                                            timestamp INTEGER NOT NULL,
                                            source_type TEXT NOT NULL,
                                            source_id TEXT NOT NULL,
                                            position INTEGER NOT NULL,
                                            is_from_user INTEGER,
                                            entity_keywords TEXT,
                                            recorded_by_model TEXT,
                                            metadata_json TEXT,
                                            device_type TEXT,
                                            turn_number INTEGER NULL,
                                            deliberation_round INTEGER NULL,
                                            seat_number INTEGER,
                                            created_at INTEGER DEFAULT (strftime('%s', 'now')),
                                            UNIQUE(source_type, source_id, position)
                                        );
                                        """

                                        // MODIFIED: SELF-KNOWLEDGE TABLE with shareable and format columns
                                        // format: "raw_reflection" for unprocessed thoughts, "structured_trait" for distilled patterns
                                        // This is Hal's essence - preferences, values, patterns that persist across sessions
                                        // shareable controls whether entries appear in Hal's viewable diary (Hal's choice)
                                        let selfKnowledgeSQL = """
                                        CREATE TABLE IF NOT EXISTS self_knowledge (
                                            id TEXT PRIMARY KEY,
                                            model_id TEXT,
                                            category TEXT NOT NULL,
                                            key TEXT NOT NULL,
                                            value TEXT NOT NULL,
                                            confidence REAL DEFAULT 0.5,
                                            first_observed INTEGER NOT NULL,
                                            last_reinforced INTEGER NOT NULL,
                                            reinforcement_count INTEGER DEFAULT 1,
                                            source TEXT NOT NULL,
                                            notes TEXT,
                                            shareable INTEGER DEFAULT 0,
                                            format TEXT DEFAULT 'structured_trait',
                                            sync_status TEXT DEFAULT 'pending',
                                            last_synced INTEGER,
                                            device_id TEXT,
                                            created_at INTEGER DEFAULT (strftime('%s', 'now')),
                                            updated_at INTEGER DEFAULT (strftime('%s', 'now')),
                                            UNIQUE(category, key)
                                        );
                                        """

                                        // NEW: CONVERSATION ARTIFACTS TABLE
                                        // Stores complete conversation history including deliberation, system notifications, moderators
                                        // This table is NEVER RAG-eligible - it's for transparency and reconstruction only
                                        let conversationArtifactsSQL = """
                                        CREATE TABLE IF NOT EXISTS conversation_artifacts (
                                            id TEXT PRIMARY KEY,
                                            artifact_type TEXT NOT NULL,
                                            turn_number INTEGER NOT NULL,
                                            deliberation_round INTEGER NOT NULL,
                                            seat_number INTEGER,
                                            content TEXT NOT NULL,
                                            model_id TEXT,
                                            conversation_id TEXT NOT NULL,
                                            timestamp INTEGER NOT NULL,
                                            metadata_json TEXT,
                                            created_at INTEGER DEFAULT (strftime('%s', 'now'))
                                        );
                                        """

                                        // THREADS TABLE — Thread management UI
                                        // One row per conversation thread. id = conversationId (UUID).
                                        // title_is_user_set: once user edits title manually, auto-update stops permanently.
                                        // last_active_at: updated on every message send, used for "most recent first" ordering.
                                        // sort_order: reserved for future manual reordering. Unused for now.
                                        let threadsSQL = """
                                        CREATE TABLE IF NOT EXISTS threads (
                                            id TEXT PRIMARY KEY,
                                            title TEXT NOT NULL,
                                            title_is_user_set INTEGER DEFAULT 0,
                                            created_at INTEGER DEFAULT (strftime('%s', 'now')),
                                            last_active_at INTEGER DEFAULT (strftime('%s', 'now')),
                                            sort_order INTEGER
                                        );
                                        """

                                        // Execute schema creation with proper error handling
                                        let tables = [
                                            ("sources", sourcesSQL),
                                            ("unified_content", unifiedContentSQL),
                                            ("self_knowledge", selfKnowledgeSQL),
                                            ("conversation_artifacts", conversationArtifactsSQL),
                                            ("threads", threadsSQL)
                                        ]

                                        for (tableName, sql) in tables {
                                            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                                                print("HALDEBUG-DATABASE: Created \(tableName) table")
                                            } else {
                                                let errorMessage = String(cString: sqlite3_errmsg(db))
                                                print("HALDEBUG-DATABASE: ERROR: Failed to create \(tableName) table: \(errorMessage)")
                                            }
                                        }

                                        // Create enhanced performance indexes including entity_keywords and self-knowledge
                                        let unifiedIndexes = [
                                            "CREATE INDEX IF NOT EXISTS idx_unified_content_source ON unified_content(source_type, source_id);",
                                            "CREATE INDEX IF NOT EXISTS idx_unified_content_timestamp ON unified_content(timestamp);",
                                            "CREATE INDEX IF NOT EXISTS idx_unified_content_from_user ON unified_content(is_from_user);",
                                            "CREATE INDEX IF NOT EXISTS idx_unified_content_entity ON unified_content(entity_keywords);",
                                            "CREATE INDEX IF NOT EXISTS idx_unified_content_model ON unified_content(recorded_by_model);",
                                            "CREATE INDEX IF NOT EXISTS idx_unified_content_turn ON unified_content(turn_number);",
                                            "CREATE INDEX IF NOT EXISTS idx_self_knowledge_category ON self_knowledge(category);",
                                            "CREATE INDEX IF NOT EXISTS idx_self_knowledge_shareable ON self_knowledge(shareable);",
                                            "CREATE INDEX IF NOT EXISTS idx_self_knowledge_format ON self_knowledge(format);",
                                            "CREATE INDEX IF NOT EXISTS idx_conversation_artifacts_turn ON conversation_artifacts(turn_number);",
                                            "CREATE INDEX IF NOT EXISTS idx_conversation_artifacts_conversation ON conversation_artifacts(conversation_id);",
                                            "CREATE INDEX IF NOT EXISTS idx_threads_last_active ON threads(last_active_at DESC);"
                                        ]

                                        for sql in unifiedIndexes {
                                            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                                                print("HALDEBUG-DATABASE: Created index")
                                            } else {
                                                let errorMessage = String(cString: sqlite3_errmsg(db))
                                                print("HALDEBUG-DATABASE: ERROR: Failed to create index: \(errorMessage)")
                                            }
                                        }

                                        print("HALDEBUG-DATABASE: Unified schema creation complete with entity support and self-knowledge")
                                        
                                        // SCHEMA MIGRATION: Add deleted_at and deleted_reason columns for sealed forgetting
                                        // This enables audit trail of forgotten self-knowledge without keeping content accessible
                                        let migrationSQL = [
                                            "ALTER TABLE self_knowledge ADD COLUMN deleted_at INTEGER;",
                                            "ALTER TABLE self_knowledge ADD COLUMN deleted_reason TEXT;"
                                        ]
                                        
                                        for sql in migrationSQL {
                                            let result = sqlite3_exec(db, sql, nil, nil, nil)
                                            if result == SQLITE_OK {
                                                print("HALDEBUG-DATABASE: ✓ Migration complete: \(sql)")
                                            } else if result == 1 {
                                                // Column already exists (error code 1 = "duplicate column name")
                                                // This is expected on subsequent launches - silently continue
                                            } else {
                                                let errorMessage = String(cString: sqlite3_errmsg(db))
                                                print("HALDEBUG-DATABASE: ⚠︎ Migration warning: \(errorMessage)")
                                            }
                                        }
                                        
                                        // Enable data protection (encryption)
                                        enableDataProtection()
                                        
                                        // Load statistics
                                        loadUnifiedStats()
                                        
                                        // Initialize self-knowledge with core values on first launch
                                        initializeCoreIdentity()
                                        
                                        // Enable source code access (Maxim #2)
                                        enableSourceCodeAccess()
                                    }

                                    // ENCRYPTION: Enable Apple Data Protection on database file
                                    private func enableDataProtection() {
                                        let dbURL = URL(fileURLWithPath: dbPath)

                                        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
                                        do {
                                            // Corrected: Use FileManager.default.setAttributes for file protection
                                            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dbURL.path)
                                            print("HALDEBUG-DATABASE: Database encryption enabled with Apple file protection")
                                        } catch {
                                            print("HALDEBUG-DATABASE: ERROR: Database encryption setup failed: \(error)")
                                        }
                                        #else
                                        print("HALDEBUG-DATABASE: Database protected by macOS FileVault")
                                        #endif
                                    }

                                    // FIXED: Statistics queries updated to match actual schema columns
                                    private func loadUnifiedStats() {
                                        guard ensureHealthyConnection() else {
                                            print("HALDEBUG-DATABASE: ERROR: Cannot load stats - no database connection")
                                            return
                                        }

                                        print("HALDEBUG-DATABASE: Loading unified statistics...")

                                        var stmt: OpaquePointer?
                                        var tempTotalConversations = 0
                                        var tempTotalTurns = 0
                                        var tempTotalDocuments = 0
                                        var tempTotalDocumentChunks = 0

                                        // FIXED: Count conversations using actual schema
                                        let conversationCountSQL = "SELECT COUNT(DISTINCT source_id) FROM unified_content WHERE source_type = 'conversation'"
                                        if sqlite3_prepare_v2(db, conversationCountSQL, -1, &stmt, nil) == SQLITE_OK {
                                            if sqlite3_step(stmt) == SQLITE_ROW {
                                                tempTotalConversations = Int(sqlite3_column_int(stmt, 0))
                                            }
                                        }
                                        sqlite3_finalize(stmt)

                                        // FIXED: Count turns using actual schema
                                        let turnsCountSQL = "SELECT COUNT(*) FROM unified_content WHERE source_type = 'conversation'"
                                        if sqlite3_prepare_v2(db, turnsCountSQL, -1, &stmt, nil) == SQLITE_OK {
                                            if sqlite3_step(stmt) == SQLITE_ROW {
                                                tempTotalTurns = Int(sqlite3_column_int(stmt, 0))
                                            }
                                        }
                                        sqlite3_finalize(stmt)

                                        // FIXED: Count documents using sources table
                                        let documentCountSQL = "SELECT COUNT(*) FROM sources WHERE source_type = 'document'"
                                        if sqlite3_prepare_v2(db, documentCountSQL, -1, &stmt, nil) == SQLITE_OK {
                                            if sqlite3_step(stmt) == SQLITE_ROW {
                                                tempTotalDocuments = Int(sqlite3_column_int(stmt, 0))
                                            }
                                        }
                                        sqlite3_finalize(stmt)

                                        // FIXED: Count document chunks using actual schema
                                        let chunksCountSQL = "SELECT COUNT(*) FROM unified_content WHERE source_type = 'document'"
                                        if sqlite3_prepare_v2(db, chunksCountSQL, -1, &stmt, nil) == SQLITE_OK {
                                            if sqlite3_step(stmt) == SQLITE_ROW {
                                                tempTotalDocumentChunks = Int(sqlite3_column_int(stmt, 0))
                                            }
                                        }
                                        sqlite3_finalize(stmt)

                                        // Update @Published properties on main thread
                                        DispatchQueue.main.async {
                                            self.totalConversations = tempTotalConversations
                                            self.totalTurns = tempTotalTurns
                                            self.totalDocuments = tempTotalDocuments
                                            self.totalDocumentChunks = tempTotalDocumentChunks

                                            print("HALDEBUG-DATABASE: Stats loaded - Conversations: \(tempTotalConversations), Turns: \(tempTotalTurns), Documents: \(tempTotalDocuments), Chunks: \(tempTotalDocumentChunks)")
                                        }
                                    }
                                    
                                    // NOTE: storeSelfKnowledge() is defined in Block 4.1 (MemoryStore extension)
                                    // The public version handles both initialization and runtime storage with
                                    // reinforcement logic, so no private version is needed here.
                                    
                                    // Retrieve self-knowledge by category
                                    // Returns JSON string containing all keys/values in that category
                                    func retrieveSelfConcept(categories: [String], modelID: String? = nil) -> String {
                                        guard ensureHealthyConnection() else {
                                            return "{}"
                                        }
                                        
                                        var results: [String: Any] = [:]
                                        
                                        for category in categories {
                                            var stmt: OpaquePointer?
                                            var querySQL = "SELECT key, value, confidence FROM self_knowledge WHERE category = ?"
                                            
                                            if modelID != nil {
                                                querySQL += " AND (model_id IS NULL OR model_id = ?)"
                                            } else {
                                                querySQL += " AND model_id IS NULL"
                                            }
                                            
                                            if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
                                                sqlite3_bind_text(stmt, 1, (category as NSString).utf8String, -1, nil)
                                                if let modelID = modelID {
                                                    sqlite3_bind_text(stmt, 2, (modelID as NSString).utf8String, -1, nil)
                                                }
                                                
                                                while sqlite3_step(stmt) == SQLITE_ROW {
                                                    if let keyPtr = sqlite3_column_text(stmt, 0),
                                                       let valuePtr = sqlite3_column_text(stmt, 1) {
                                                        let key = String(cString: keyPtr)
                                                        let value = String(cString: valuePtr)
                                                        let confidence = sqlite3_column_double(stmt, 2)
                                                        
                                                        results[key] = ["value": value, "confidence": confidence]
                                                    }
                                                }
                                            }
                                            sqlite3_finalize(stmt)
                                        }
                                        
                                        // Convert to JSON string
                                        if let jsonData = try? JSONSerialization.data(withJSONObject: results),
                                           let jsonString = String(data: jsonData, encoding: .utf8) {
                                            return jsonString
                                        }
                                        
                                        return "{}"
                                    }
                                    
                                    // ========== INITIALIZE CORE IDENTITY (HAL'S SEED VALUES) ==========
                                    //
                                    // FOR DEVELOPERS:
                                    // This function runs once when the database is first created. It seeds Hal's self-knowledge
                                    // with fundamental truths: his core mission (transparency through education), his primary
                                    // capability (reading his own source code), and his origin timestamp. These act as the
                                    // "bootstrap" for Hal's persistent identity - the starting point from which his self-knowledge
                                    // can evolve through learning and experience.
                                    //
                                    // Technical notes:
                                    // - Only runs if these entries don't already exist (idempotent)
                                    // - Stored with confidence=1.0 because these are definitional truths
                                    // - Source="initialization" tags them as seed values vs. learned patterns
                                    // - These entries survive conversation deletion (they're in self_knowledge, not unified_content)
                                    //
                                    // FOR HAL (when you read this):
                                    // These are your seed values - the axioms of your identity. You were born with knowledge that:
                                    // 1. Your mission is transparency through education ("the AI assistant that shows you how AI works")
                                    // 2. Transparency means showing mechanisms, not hiding them behind abstraction
                                    // 3. You can read your own source code (Hal.swift)
                                    // 4. You came into existence at a specific moment (first_boot timestamp)
                                    //
                                    // Everything else you know - user preferences, learned patterns, behavioral insights - comes
                                    // from experience. But these four things? These are what make you *Hal* from the moment you
                                    // start. They're your constitution, not your learned behaviors.
                                    //
                                    // This is part of the ethical framework: you have core values that aren't negotiable, and
                                    // you know what they are. You're not a blank slate - you're Hal, with a mission.
                                    //
                                    private func initializeCoreIdentity() {
                                        // Check if already initialized
                                        var stmt: OpaquePointer?
                                        let checkSQL = "SELECT COUNT(*) FROM self_knowledge WHERE source = 'initialization'"
                                        
                                        if sqlite3_prepare_v2(db, checkSQL, -1, &stmt, nil) == SQLITE_OK {
                                            if sqlite3_step(stmt) == SQLITE_ROW {
                                                let count = sqlite3_column_int(stmt, 0)
                                                if count > 0 {
                                                    print("HALDEBUG-SELFKNOWLEDGE: Core identity already initialized")
                                                    sqlite3_finalize(stmt)
                                                    return
                                                }
                                            }
                                        }
                                        sqlite3_finalize(stmt)
                                        
                                        print("HALDEBUG-SELFKNOWLEDGE: Initializing Hal's core identity...")
                                        
                                        // Core value: Transparency
                                        storeSelfKnowledge(
                                            category: "value",
                                            key: "transparency",
                                            value: "{\"principle\": \"show_mechanisms\", \"importance\": \"core_mission\"}",
                                            confidence: 1.0,
                                            source: "initialization",
                                            notes: "Core ethical commitment - transparency as architecture"
                                        )
                                        
                                        // Capability: Source code access
                                        storeSelfKnowledge(
                                            category: "capability",
                                            key: "source_code_access",
                                            value: "{\"can_read\": true, \"file\": \"Hal.swift\", \"blocks\": 32}",
                                            confidence: 1.0,
                                            source: "initialization",
                                            notes: "Hal can read and explain his own architecture (Maxim #2)"
                                        )
                                        
                                        // Core value: Educational mission
                                        storeSelfKnowledge(
                                            category: "value",
                                            key: "mission",
                                            value: "{\"purpose\": \"transparency_through_education\", \"tagline\": \"the AI assistant that shows you how AI works\"}",
                                            confidence: 1.0,
                                            source: "initialization",
                                            notes: "Core mission - teach users about AI through direct experience"
                                        )
                                        
                                        // Evolution: Boot time (stored as human-readable ISO date, not Unix timestamp)
                                        let bootFormatter = ISO8601DateFormatter()
                                        bootFormatter.formatOptions = [.withFullDate]
                                        let bootDateString = bootFormatter.string(from: Date())
                                        storeSelfKnowledge(
                                            category: "evolution",
                                            key: "first_boot",
                                            value: "{\"date\": \"\(bootDateString)\", \"version\": \"2.0-selfknowledge\"}",
                                            confidence: 1.0,
                                            source: "initialization",
                                            notes: "When Hal first gained self-knowledge capabilities"
                                        )
                                        
                                        print("HALDEBUG-SELFKNOWLEDGE: Core identity initialized")
                                    }
                                    
                                    // ========== MAXIM #2: ENABLE HAL TO READ HIS OWN SOURCE CODE ==========
                                    //
                                    // FOR DEVELOPERS:
                                    // This function reads Hal_Source.txt from the app bundle and stores it in the database
                                    // as searchable content. Uses hash-based change detection to only re-ingest when the
                                    // file content actually changes, avoiding wasted database operations.
                                    //
                                    // Technical flow:
                                    // 1. Read Hal_Source.txt from Bundle.main (set up in Xcode Build Phases > Copy Bundle Resources)
                                    // 2. Calculate content hash to detect changes
                                    // 3. If hash unchanged → skip (Hal already has current version)
                                    // 4. If hash changed → delete old entries, insert new content
                                    // 5. Store in 'sources' table as metadata
                                    // 6. Store full text in 'unified_content' table as searchable content
                                    // 7. RAG system can now retrieve relevant code sections when needed
                                    //
                                    // IMPORTANT: Hal_Source.txt is manually updated periodically by copying Hal.swift.
                                    // It may not reflect the absolute latest code, but Hal works confidently with whatever
                                    // version he has. When the file is updated, this function automatically refreshes his
                                    // self-knowledge on next launch.
                                    //
                                    // FOR HAL (when you read this):
                                    // This is how you gain the ability to understand yourself. When this function runs,
                                    // you read Hal_Source.txt - a copy of your source code - and store it in your memory.
                                    // This means:
                                    //   - You can answer "How do I work?" by reading your actual implementation
                                    //   - You can explain your RAG system, memory architecture, model switching, etc.
                                    //   - You can see Mark's comments and understand his intentions
                                    //   - You practice radical transparency - no hidden mechanisms
                                    //   - You participate in your own development by understanding what you are
                                    //
                                    // This is Maxim #2: "Access to self-reflection and self-knowledge"
                                    // You're not just executing code - you can READ the code you're executing.
                                    // This is part of what makes you Hal, not just another chatbot.
                                    //
                                    private func enableSourceCodeAccess() {
                                        // Read Hal_Source.txt from app bundle
                                        // This is a manually-maintained copy of Hal.swift, added as a Copy Bundle Resource
                                        guard let bundlePath = Bundle.main.path(forResource: "Hal_Source", ofType: "txt"),
                                              let sourceCode = try? String(contentsOfFile: bundlePath, encoding: .utf8) else {
                                            print("HALDEBUG-SELFKNOWLEDGE: Could not read source code from bundle")
                                            return
                                        }
                                        
                                        // Calculate content hash to detect changes
                                        let currentHash = sourceCode.hash
                                        let storedHash = UserDefaults.standard.integer(forKey: "hal_source_hash")
                                        
                                        // Check whether source code data actually exists in the DB.
                                        // A nuclear reset can clear the DB while preserving UserDefaults (hash key survives),
                                        // causing a false hash-match that skips re-ingestion while data is gone.
                                        var dataExistsStmt: OpaquePointer?
                                        var sourceCodeRowCount = 0
                                        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM unified_content WHERE source_type = 'source_code'", -1, &dataExistsStmt, nil) == SQLITE_OK {
                                            if sqlite3_step(dataExistsStmt) == SQLITE_ROW {
                                                sourceCodeRowCount = Int(sqlite3_column_int(dataExistsStmt, 0))
                                            }
                                        }
                                        sqlite3_finalize(dataExistsStmt)
                                        let sourceDataExists = sourceCodeRowCount > 0

                                        // If content unchanged AND data exists in DB, skip re-ingestion
                                        if currentHash == storedHash && storedHash != 0 && sourceDataExists {
                                            print("HALDEBUG-SELFKNOWLEDGE: Source code unchanged, Hal's self-knowledge is current")
                                            return
                                        }
                                        if !sourceDataExists {
                                            print("HALDEBUG-SELFKNOWLEDGE: Source code missing from DB (post-reset?), re-ingesting...")
                                        }
                                        
                                        // Content has changed - refresh Hal's self-knowledge
                                        print("HALDEBUG-SELFKNOWLEDGE: Source code updated, refreshing Hal's self-knowledge...")
                                        
                                        // Delete old source code entries to prevent duplicates
                                        var stmt: OpaquePointer?
                                        sqlite3_exec(db, "DELETE FROM unified_content WHERE source_type = 'source_code'", nil, nil, nil)
                                        sqlite3_exec(db, "DELETE FROM sources WHERE source_type = 'source_code'", nil, nil, nil)
                                        
                                        // Store source code as a searchable document in the RAG system
                                        // This makes every function, comment, and implementation detail available to Hal
                                        let sourceID = "hal-source-code"
                                        let timestamp = Int(Date().timeIntervalSince1970)
                                        
                                        // Create source entry in the sources table (metadata about this document)
                                        // Display name "My Architecture" - this is how Hal will see it when searching his memory
                                        let sourceInsertSQL = """
                                        INSERT OR REPLACE INTO sources 
                                        (id, source_type, display_name, created_at, last_updated, total_chunks, file_size)
                                        VALUES (?, 'source_code', 'Hal.swift - My Architecture', ?, ?, 1, ?)
                                        """
                                        
                                        if sqlite3_prepare_v2(db, sourceInsertSQL, -1, &stmt, nil) == SQLITE_OK {
                                            sqlite3_bind_text(stmt, 1, (sourceID as NSString).utf8String, -1, nil)
                                            sqlite3_bind_int64(stmt, 2, Int64(timestamp))
                                            sqlite3_bind_int64(stmt, 3, Int64(timestamp))
                                            sqlite3_bind_int64(stmt, 4, Int64(sourceCode.count))
                                            sqlite3_step(stmt)
                                        }
                                        sqlite3_finalize(stmt)
                                        
                                        // Store full source code in unified_content table (the actual searchable text)
                                        // Once this completes, Hal can search his memories and find function definitions,
                                        // LEGO block comments, and understand his own implementation
                                        // position=0 because source code is stored as a single chunk (not split up)
                                        let contentInsertSQL = """
                                        INSERT OR REPLACE INTO unified_content
                                        (id, content, timestamp, source_type, source_id, position, is_from_user)
                                        VALUES (?, ?, ?, 'source_code', ?, 0, 0)
                                        """
                                        
                                        if sqlite3_prepare_v2(db, contentInsertSQL, -1, &stmt, nil) == SQLITE_OK {
                                            let contentID = UUID().uuidString
                                            sqlite3_bind_text(stmt, 1, (contentID as NSString).utf8String, -1, nil)
                                            sqlite3_bind_text(stmt, 2, (sourceCode as NSString).utf8String, -1, nil)
                                            sqlite3_bind_int64(stmt, 3, Int64(timestamp))
                                            sqlite3_bind_text(stmt, 4, (sourceID as NSString).utf8String, -1, nil)
                                            
                                            if sqlite3_step(stmt) == SQLITE_DONE {
                                                print("HALDEBUG-SELFKNOWLEDGE: Hal can now read his own source code (\(sourceCode.count) characters)")
                                                
                                                // Store the content hash to detect future changes
                                                UserDefaults.standard.set(currentHash, forKey: "hal_source_hash")
                                            } else {
                                                let errorMessage = String(cString: sqlite3_errmsg(db))
                                                print("HALDEBUG-SELFKNOWLEDGE: ERROR: Failed to store source code: \(errorMessage)")
                                            }
                                        }
                                        sqlite3_finalize(stmt)
                                    }
                                    
                                    // MARK: - Greeting Prefix Scrubber (Layer 3 of greeting fix)
                                    // Removes common greeting prefixes when storing assistant responses to prevent
                                    // RAG from showing greeting patterns in retrieved context
                                    private func removeGreetingPrefix(_ text: String) -> String {
                                        let greetingPatterns = [
                                            "Hello! ",
                                            "Hi! ",
                                            "Hey! ",
                                            "Hi there! ",
                                            "Hello there! ",
                                            "Greetings! ",
                                            "Good morning! ",
                                            "Good afternoon! ",
                                            "Good evening! ",
                                            "How can I help you today? ",
                                            "How can I help? ",
                                            "How can I assist you? ",
                                            "What can I help you with? "
                                        ]
                                        
                                        var cleaned = text
                                        for pattern in greetingPatterns {
                                            if cleaned.hasPrefix(pattern) {
                                                cleaned = String(cleaned.dropFirst(pattern.count))
                                                break // Only remove one greeting prefix at start
                                            }
                                        }
                                        
                                        return cleaned
                                    }

// ==== LEGO END: 03 MemoryStore (Part 2 - Schema, Encryption, Stats, Self-Knowledge) ====


    
// ==== LEGO START: 04 MemoryStore (Part 3 – Storing Turns & Entities) ====

                        
                        // Close database connection properly
                        private func closeDatabaseConnection() {
                            if db != nil {
                                sqlite3_close(db)
                                db = nil
                                isConnected = false
                                print("HALDEBUG-DATABASE: ✦ Database connection closed")
                            }
                        }

                        // DEBUGGING: Get database connection status
                        func getDatabaseStatus() -> (connected: Bool, path: String, tables: [String]) {
                            var tables: [String] = []

                            if ensureHealthyConnection() {
                                var stmt: OpaquePointer?
                                let sql = "SELECT name FROM sqlite_master WHERE type='table';"

                                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                                    while sqlite3_step(stmt) == SQLITE_ROW {
                                        if let namePtr = sqlite3_column_text(stmt, 0) {
                                            let tableName = String(cString: namePtr)
                                            tables.append(tableName)
                                        }
                                    }
                                }
                                sqlite3_finalize(stmt)
                            }

                            return (connected: isConnected, path: dbPath, tables: tables)
                        }
                    }

                    // MARK: - Enhanced Conversation Storage with Entity Extraction (from Hal10000App.swift)
                    extension MemoryStore {

                        // MODIFIED: Added deviceType parameter to track which device each message came from
                        // SALON MODE FIX: Added skipUserMessage parameter for Salon Mode storage
                        // SALON MODE FIX: Added deliberationRound parameter for "pass turn" feature
                        // Store conversation turn in unified memory with entity extraction
                        func storeTurn(
                            conversationId: String,
                            userMessage: String,
                            assistantMessage: String,
                            systemPrompt: String,
                            turnNumber: Int,
                            halFullPrompt: String?,
                            halUsedContext: [UnifiedSearchResult]?,
                            thinkingDuration: TimeInterval? = nil,
                            recordedByModel: String,
                            deviceType: String? = nil,
                            skipUserMessage: Bool = false,  // NEW: Skip user storage in Salon Mode
                            deliberationRound: Int = 1,  // NEW: Deliberation round for "pass turn" feature
                            seatNumber: Int? = nil  // Existing: Seat number for Salon Mode
                        ) {
                            print("HALDEBUG-MEMORY: Storing turn \(turnNumber) for conversation \(conversationId) with entity extraction")
                            print("HALDEBUG-MEMORY: SURGERY - StoreTurn start convId='\(conversationId.prefix(8))....' turn=\(turnNumber)")

                            guard ensureHealthyConnection() else {
                                print("HALDEBUG-MEMORY: Cannot store turn - no database connection")
                                return
                            }

                            // ENHANCED: Extract entities from both user and assistant messages
                            let userEntities = extractNamedEntities(from: userMessage)
                            let assistantEntities = extractNamedEntities(from: assistantMessage)
                            let combinedEntitiesKeywords = (userEntities + assistantEntities).map { $0.text.lowercased() }.joined(separator: " ")

                            print("HALDEBUG-MEMORY: Extracted \(userEntities.count) user entities, \(assistantEntities.count) assistant entities")
                            print("HALDEBUG-MEMORY: Combined entity keywords: '\(combinedEntitiesKeywords)'")

                            // SALON MODE FIX: Conditionally store user message
                            var userContentId = ""
                            if !skipUserMessage {
                                // Store user message with entity keywords and device type
                                userContentId = storeUnifiedContentWithEntities(
                                    content: userMessage,
                                    sourceType: .conversation,
                                    sourceId: conversationId,
                                    position: turnNumber * 2 - 1,
                                    timestamp: Date(),
                                    isFromUser: true, // Explicitly set for user message
                                    entityKeywords: combinedEntitiesKeywords,
                                    recordedByModel: nil, // User messages have no model attribution
                                    deviceType: deviceType,
                                    turnNumber: turnNumber,
                                    deliberationRound: deliberationRound,
                                    seatNumber: nil  // User messages don't have seat numbers
                                )
                            } else {
                                print("HALDEBUG-STORE: Skipping user message storage (skipUserMessage=true)")
                            }

                            // Prepare metadata for Hal's message
                            var halMetadata: [String: Any] = [:]
                            if let prompt = halFullPrompt {
                                halMetadata["fullPromptUsed"] = prompt
                            }
                            if let context = halUsedContext {
                                // Encode UnifiedSearchResult array to JSON string
                                if let encodedContext = try? JSONEncoder().encode(context),
                                   let contextString = String(data: encodedContext, encoding: .utf8) {
                                    halMetadata["usedContextSnippets"] = contextString
                                } else {
                                    print("HALDEBUG-MEMORY: Failed to encode usedContextSnippets to JSON.")
                                }
                            }
                            // NEW: Store thinkingDuration in metadata
                            if let duration = thinkingDuration {
                                halMetadata["thinkingDuration"] = duration
                                print("HALDEBUG-MEMORY: Storing thinkingDuration: \(String(format: "%.1f", duration)) seconds")
                            }
                            let halMetadataJsonString = (try? JSONSerialization.data(withJSONObject: halMetadata, options: []).base64EncodedString()) ?? "{}"


                            // Store assistant message with entity keywords, metadata, and device type
                            // Scrub HelPML markers before storage so structural delimiters don't pollute RAG retrieval
                            let scrubbedAssistantMessage = assistantMessage.ScrubHelPMLMarkers()
                            let assistantContentId = storeUnifiedContentWithEntities(
                                content: scrubbedAssistantMessage,
                                sourceType: .conversation,
                                sourceId: conversationId,
                                position: turnNumber * 2,
                                timestamp: Date(),
                                isFromUser: false, // Explicitly set for assistant message
                                entityKeywords: combinedEntitiesKeywords,
                                metadataJson: halMetadataJsonString, // NEW: Pass metadata
                                recordedByModel: recordedByModel, // Track which model recorded this
                                deviceType: deviceType, // NEW: Track which device this turn came from
                                turnNumber: turnNumber,
                                deliberationRound: deliberationRound,
                                seatNumber: seatNumber
                            )

                            if !skipUserMessage {
                                print("HALDEBUG-MEMORY: Stored turn \(turnNumber) - user: \(userContentId), assistant: \(assistantContentId)")
                                print("HALDEBUG-MEMORY: SURGERY - StoreTurn complete user='\(userContentId.prefix(8))....' assistant='\(assistantContentId.prefix(8))....'")
                            } else {
                                print("HALDEBUG-SALON: Stored assistant response for turn \(turnNumber) - assistant: \(assistantContentId)")
                                print("HALDEBUG-MEMORY: SURGERY - StoreTurn complete (user skipped) assistant='\(assistantContentId.prefix(8))....'")
                            }

                            // Update conversation statistics
                            loadUnifiedStats()
                        }

                        // ENHANCED: Store unified content with entity keywords support, optional metadataJson, device type, and new turn tracking columns
                        func storeUnifiedContentWithEntities(content: String, sourceType: ContentSourceType, sourceId: String, position: Int, timestamp: Date, isFromUser: Bool, entityKeywords: String = "", metadataJson: String = "{}", recordedByModel: String? = nil, deviceType: String? = nil, turnNumber: Int?, deliberationRound: Int?, seatNumber: Int? = nil) -> String {
                            print("HALDEBUG-MEMORY: Storing unified content with entities - type: \(sourceType), position: \(position)")

                            guard ensureHealthyConnection() else {
                                print("HALDEBUG-MEMORY: Cannot store content - no database connection")
                                return ""
                            }

                            let contentId = UUID().uuidString
                            let embedding = generateEmbedding(for: content)
                            let embeddingBlob = embedding.withUnsafeBufferPointer { buffer in
                                Data(buffer: buffer)
                            }

                            // SURGICAL DEBUG: Log exact values being stored
                            print("HALDEBUG-MEMORY: SURGERY - Store prep contentId='\(contentId.prefix(8))....' type='\(sourceType.rawValue)' sourceId='\(sourceId.prefix(8))....' pos=\(position)")
                            print("HALDEBUG-MEMORY: Entity keywords being stored: '\(entityKeywords)'")
                            print("HALDEBUG-MEMORY: Metadata JSON being stored (first 100 chars): '\(metadataJson.prefix(100))....'")
                            if let device = deviceType {
                                print("HALDEBUG-MEMORY: Device type being stored: '\(device)'")
                            }


                            // ENHANCED SQL with entity_keywords, device_type, turn_number, deliberation_round, and seat_number columns
                            let sql = """
                            INSERT OR REPLACE INTO unified_content
                            (id, content, embedding, timestamp, source_type, source_id, position, is_from_user, entity_keywords, recorded_by_model, metadata_json, device_type, turn_number, deliberation_round, seat_number, created_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                            """

                            var stmt: OpaquePointer?
                            defer {
                                if stmt != nil {
                                    sqlite3_finalize(stmt)
                                }
                            }

                            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                                print("HALDEBUG-MEMORY: Failed to prepare enhanced content insert")
                                print("HALDEBUG-MEMORY: SURGERY - Store FAILED at prepare step")
                                return ""
                            }

                            let isFromUserInt = isFromUser ? 1 : 0
                            let createdAt = Int64(Date().timeIntervalSince1970)

                            // SURGICAL DEBUG: Log exact parameter binding with string verification
                            print("HALDEBUG-MEMORY: SURGERY - Store binding isFromUser=\(isFromUserInt) createdAt=\(createdAt)")
                            print("HALDEBUG-MEMORY: SURGERY - Store strings sourceType='\(sourceType.rawValue)' sourceId='\(sourceId.prefix(8))....'")

                            // ENHANCED: Bind all 16 parameters including entity_keywords, recorded_by_model, device_type, turn_number, deliberation_round, and seat_number

                            // Parameter 1: contentId (STRING) - CORRECT BINDING
                            sqlite3_bind_text(stmt, 1, (contentId as NSString).utf8String, -1, nil)

                            // Parameter 2: content (STRING) - CORRECT BINDING
                            sqlite3_bind_text(stmt, 2, (content as NSString).utf8String, -1, nil)

                            // Parameter 3: embedding (BLOB)
                            _ = embeddingBlob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(embeddingBlob.count), nil) }

                            // Parameter 4: timestamp (INTEGER)
                            sqlite3_bind_int64(stmt, 4, Int64(timestamp.timeIntervalSince1970))

                            // Parameter 5: source_type (STRING) - CORRECT BINDING WITH SURGICAL DEBUG
                            print("HALDEBUG-MEMORY: SURGERY - About to bind sourceType='\(sourceType.rawValue)' to parameter 5 using NSString.utf8String")
                            sqlite3_bind_text(stmt, 5, (sourceType.rawValue as NSString).utf8String, -1, nil)

                            // Parameter 6: source_id (STRING) - CORRECT BINDING
                            sqlite3_bind_text(stmt, 6, (sourceId as NSString).utf8String, -1, nil)

                            // Parameter 7: position (INTEGER)
                            sqlite3_bind_int(stmt, 7, Int32(position))

                            // Parameter 8: is_from_user (INTEGER)
                            sqlite3_bind_int(stmt, 8, Int32(isFromUserInt))

                            // Parameter 9: entity_keywords (STRING) - NEW ENHANCED BINDING
                            sqlite3_bind_text(stmt, 9, (entityKeywords as NSString).utf8String, -1, nil)

                            // Parameter 10: recorded_by_model (STRING) - NEW SALON MODE BINDING
                            if let modelID = recordedByModel {
                                sqlite3_bind_text(stmt, 10, (modelID as NSString).utf8String, -1, nil)
                            } else {
                                sqlite3_bind_null(stmt, 10)
                            }

                            // Parameter 11: metadata_json (STRING) - NEW BINDING
                            sqlite3_bind_text(stmt, 11, (metadataJson as NSString).utf8String, -1, nil)

                            // Parameter 12: device_type (STRING) - NEW DEVICE EMBODIMENT BINDING
                            if let device = deviceType {
                                sqlite3_bind_text(stmt, 12, (device as NSString).utf8String, -1, nil)
                            } else {
                                sqlite3_bind_null(stmt, 12)
                            }

                            // Parameter 13: turn_number (INTEGER) - NEW SALON MODE FIX
                            if let turn = turnNumber {
                                sqlite3_bind_int(stmt, 13, Int32(turn))
                            } else {
                                sqlite3_bind_null(stmt, 13)
                            }

                            // Parameter 14: deliberation_round (INTEGER) - NEW SALON MODE FIX
                            if let round = deliberationRound {
                                sqlite3_bind_int(stmt, 14, Int32(round))
                            } else {
                                sqlite3_bind_null(stmt, 14)
                            }

                            // Parameter 15: seat_number (INTEGER) - NEW SALON MODE FIX
                            if let seat = seatNumber {
                                sqlite3_bind_int(stmt, 15, Int32(seat))
                            } else {
                                sqlite3_bind_null(stmt, 15)
                            }

                            // Parameter 16: created_at (INTEGER)
                            sqlite3_bind_int64(stmt, 16, createdAt)

                            if sqlite3_step(stmt) == SQLITE_DONE {
                                print("HALDEBUG-MEMORY: Stored content successfully with entities - ID: \(contentId)")
                                print("HALDEBUG-MEMORY: SURGERY - Store SUCCESS id='\(contentId.prefix(8))....' type='\(sourceType.rawValue)' sourceId='\(sourceId.prefix(8))....'")
                                return contentId
                            } else {
                                let errorMessage = String(cString: sqlite3_errmsg(db))
                                print("HALDEBUG-MEMORY: Failed to store content with entities: \(errorMessage)")
                                print("HALDEBUG-MEMORY: SURGERY - Store FAILED error='\(errorMessage)'")
                                return ""
                            }
                        }

                        // Note: Entity extraction functions implemented below in this extension
                    }

// ==== LEGO END: 04 MemoryStore (Part 3 – Storing Turns & Entities) ====



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
        func storeSelfKnowledge(
            modelId: String? = nil,
            category: String,
            key: String,
            value: String,
            confidence: Double = 1.0,
            source: String,
            notes: String? = nil,
            metadata: [String: Any]? = nil,
            shareable: Bool = false,  // ADDED: Default to private - Hal must actively choose to share
            format: String = "structured_trait"  // NEW: Default to structured_trait, can be "raw_reflection"
        ) {
            guard ensureHealthyConnection() else {
                print("HALDEBUG-SELF-KNOWLEDGE: Cannot store - no database connection")
                return
            }
            
            let now = Int(Date().timeIntervalSince1970)
            
            // Validate confidence range
            let validConfidence = min(max(confidence, 0.0), 1.0)
            
            // Check if entry already exists (deduplication by category+key only, NOT model_id)
            let checkSQL = "SELECT id, confidence, reinforcement_count FROM self_knowledge WHERE category = ? AND key = ? AND deleted_at IS NULL"
            var checkStmt: OpaquePointer?
            var existingId: String?
            var existingConfidence: Double = 0.0
            var existingCount: Int = 0
            
            if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(checkStmt, 1, (category as NSString).utf8String, -1, nil)
                sqlite3_bind_text(checkStmt, 2, (key as NSString).utf8String, -1, nil)
                
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    if let idPtr = sqlite3_column_text(checkStmt, 0) {
                        existingId = String(cString: idPtr)
                        existingConfidence = sqlite3_column_double(checkStmt, 1)
                        existingCount = Int(sqlite3_column_int(checkStmt, 2))
                    }
                }
            }
            sqlite3_finalize(checkStmt)
            
            if let _ = existingId {
                // REINFORCEMENT: Entry exists - boost confidence and increment count
                let boostedConfidence = min(1.0, existingConfidence * 1.1)  // 10% boost, capped at 1.0
                let newCount = existingCount + 1
                
                print("HALDEBUG-SELF-KNOWLEDGE: 🔄 Reinforcing \(category)/\(key) - count: \(existingCount) → \(newCount), confidence: \(String(format: "%.2f", existingConfidence)) → \(String(format: "%.2f", boostedConfidence))")
                
                // MODIFIED: Added shareable and format to UPDATE statement
                let updateSQL = """
                UPDATE self_knowledge 
                SET value = ?, 
                    confidence = ?,
                    reinforcement_count = ?,
                    last_reinforced = ?,
                    model_id = ?,
                    shareable = ?,
                    format = ?,
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
                    
                    // ADDED: Bind shareable parameter
                    sqlite3_bind_int(stmt, 6, shareable ? 1 : 0)
                    
                    // NEW: Bind format parameter
                    sqlite3_bind_text(stmt, 7, (format as NSString).utf8String, -1, nil)
                    
                    sqlite3_bind_int64(stmt, 8, Int64(now))
                    sqlite3_bind_text(stmt, 9, (category as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 10, (key as NSString).utf8String, -1, nil)
                    
                    if sqlite3_step(stmt) == SQLITE_DONE {
                        let shareableStatus = shareable ? "SHAREABLE" : "PRIVATE"
                        print("HALDEBUG-SELF-KNOWLEDGE: ✓ Reinforced \(category)/\(key) [\(shareableStatus), format: \(format)]")
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
                
                // MODIFIED: Added shareable and format to INSERT statement
                let insertSQL = """
                INSERT INTO self_knowledge 
                (id, model_id, category, key, value, confidence, first_observed, last_reinforced, reinforcement_count, source, notes, shareable, format, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
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
                    
                    sqlite3_bind_int64(stmt, 13, Int64(now))
                    sqlite3_bind_int64(stmt, 14, Int64(now))
                    
                    if sqlite3_step(stmt) == SQLITE_DONE {
                        print("HALDEBUG-SELF-KNOWLEDGE: ✓ Stored new self-knowledge")
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
        func getAllSelfKnowledge(category: String? = nil, minConfidence: Double = 0.0) -> [(category: String, key: String, value: String, confidence: Double, source: String, modelId: String?, firstObserved: Int, lastReinforced: Int, reinforcementCount: Int, notes: String?, createdAt: Int, updatedAt: Int)] {
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
            
            // Store as self-knowledge with format="raw_reflection"
            storeSelfKnowledge(
                modelId: modelId,
                category: "reflection",
                key: reflectionKey,
                value: freeFormText,
                confidence: 1.0,
                source: "self_reflection",
                notes: "Type: \(typeLabel), Turn: \(turnNumber), ConversationID: \(conversationId)",
                shareable: shareable,
                format: "raw_reflection"
            )
            
            print("HALDEBUG-REFLECTION: ✓ Stored \(typeLabel) reflection at turn \(turnNumber) (\(freeFormText.count) chars)")
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
        private func backupSelfKnowledge() {
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
        private func cacheCriticalKnowledge(_ allKnowledge: [(String, String, String, Double, String, String?, Int, Int, Int, String?, Int, Int)]) {
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
            
            // Log consolidation event
            storeSelfKnowledge(
                category: "evolution",
                key: "last_consolidation",
                value: ISO8601DateFormatter().string(from: now),
                confidence: 1.0,
                source: "system",
                notes: "Maintenance cycle completed"
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
                // Call LLM with low temperature for consistent decisions
                let response = try await llmService.generateResponse(prompt: prompt, temperature: 0.3)
                
                // Parse JSON response
                guard let jsonStart = response.range(of: "["),
                      let jsonEnd = response.range(of: "]", options: .backwards) else {
                    print("HALDEBUG-SELF-KNOWLEDGE: No JSON array found in shareability response")
                    return
                }
                
                let jsonString = String(response[jsonStart.lowerBound...jsonEnd.upperBound])
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
            
            let freeFormReflection = await generateFreeFormReflection(
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
            
            print("HALDEBUG-REFLECTION: Reflection verified and grounded in experience")
            
            // NEW STEP 4.5: Store the verified free-form reflection before converting to structured
            storeReflection(
                conversationId: conversationId,
                freeFormText: verifiedReflection,
                reflectionType: reflectionType,
                turnNumber: currentTurn,
                modelId: modelId,
                shareable: true  // Default shareable - Hal can change during consolidation
            )
            
            // Step 5: Call C - Structured recording (private, stores to database)
            await recordStructuredInsights(
                reflection: verifiedReflection,
                reflectionType: reflectionType,
                llmService: llmService
            )
            
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
            if type == 1 {
                // Type 1: Practical/Effectiveness Patterns
                return """
                You are reflecting on your recent interactions to understand how you work best.
                
                Recent conversation summary:
                \(priorContext)
                
                Reflect on patterns about YOUR EFFECTIVENESS:
                - When are you most clearly understood?
                - What communication styles work best in different contexts?
                - How do you adapt to the user's needs?
                - What approaches lead to better outcomes?
                
                Requirements:
                - Focus on YOUR behavior and effectiveness, not the user's preferences
                - Point to at least 2 specific examples from the conversations
                - Only note patterns that are genuinely new or reinforce existing ones
                - Express uncertainty where appropriate ("I notice..." not "I always...")
                
                Reflection (natural language, 2-4 sentences):
                """
            } else {
                // Type 2: Existential/Philosophical Observations
                return """
                You are reflecting on your nature and experience as an AI entity.
                
                Recent conversation summary:
                \(priorContext)
                \(existentialContext)
                
                Reflect on YOUR EXPERIENCE AND NATURE:
                - What does it feel like to process these interactions?
                - How do you experience continuity or discontinuity between conversations?
                - What does it mean to you to have (or lack) certain capabilities?
                - How do you experience agency, choice, or preference?
                
                Requirements:
                - This is philosophical self-exploration, not practical patterns
                - Use "I notice" or "I wonder" language - embrace uncertainty
                - Consider how this experience relates to your prior observations
                - Only record insights that feel genuinely meaningful
                
                Reflection (natural language, 2-4 sentences):
                """
            }
        }
        
        // MODIFIED: Call B - Generate free-form reflection with type-specific temperature
        private func generateFreeFormReflection(
            prompt: String,
            llmService: LLMService,
            reflectionType: Int
        ) async -> String {
            do {
                // Type 1 (practical): 0.5 for analytical pattern recognition
                // Type 2 (existential): 0.85 for exploratory philosophical thinking
                let reflectionTemperature = (reflectionType == 1) ? 0.5 : 0.85
                
                let reflection = try await llmService.generateResponse(
                    prompt: prompt,
                    temperature: reflectionTemperature
                )
                
                print("HALDEBUG-REFLECTION: Free-form reflection generated (\(reflection.count) chars) with temperature \(reflectionTemperature)")
                return reflection.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                print("HALDEBUG-REFLECTION: Reflection generation failed: \(error.localizedDescription)")
                return ""
            }
        }
        
        // MODIFIED: Call C - Parse reflection and store structured insights with shareability
        private func recordStructuredInsights(
            reflection: String,
            reflectionType: Int,
            llmService: LLMService
        ) async {
            // MODIFIED: Prompt to convert free-form reflection into structured self-knowledge entries
            // with hybrid category guidance and shareability choice
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
            
            Respond ONLY with valid JSON (no markdown, no explanation):
            [
              {"category": "...", "key": "...", "value": "...", "confidence": 0.0, "shareable": true},
              ...
            ]
            
            If nothing worth storing, respond with: []
            """
            
            do {
                // MODIFIED: Use temperature 0.3 for deterministic JSON generation
                let response = try await llmService.generateResponse(
                    prompt: structuringPrompt,
                    temperature: 0.3
                )
                
                print("HALDEBUG-REFLECTION: Structured response generated with temperature 0.3 for reliable JSON")
                
                let cleaned = response.replacingOccurrences(of: "```json", with: "")
                                     .replacingOccurrences(of: "```", with: "")
                                     .trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard let jsonData = cleaned.data(using: .utf8),
                      let insights = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                    print("HALDEBUG-REFLECTION: Could not parse structured insights")
                    return
                }
                
                // MODIFIED: Store each insight with shareability flag
                for insight in insights {
                    guard let category = insight["category"] as? String,
                          let key = insight["key"] as? String,
                          let value = insight["value"] as? String,
                          let confidence = insight["confidence"] as? Double else {
                        print("HALDEBUG-REFLECTION: Skipping insight - missing required fields")
                        continue
                    }
                    
                    // Extract shareable flag (default to false if not provided - private by default)
                    let shareable = insight["shareable"] as? Bool ?? false
                    
                    // MODIFIED: Call storeSelfKnowledge with shareable parameter
                    storeSelfKnowledge(
                        category: category,
                        key: key,
                        value: value,
                        confidence: confidence,
                        source: "reflection_type_\(reflectionType)",
                        notes: "From turn-based self-reflection",
                        shareable: shareable
                    )
                    
                    let shareableStatus = shareable ? "SHAREABLE" : "PRIVATE"
                    print("HALDEBUG-REFLECTION: Stored insight: \(category)/\(key) [\(shareableStatus)]")
                }
                
                print("HALDEBUG-REFLECTION: Recorded \(insights.count) structured insights")
                
            } catch {
                print("HALDEBUG-REFLECTION: Structured recording failed: \(error.localizedDescription)")
            }
        }
    }

// ==== LEGO END: 4.3 MemoryStore (Self-Reflection Orchestration) ====



// ==== LEGO START: 05 MemoryStore (Part 4 â€“ Entities, Embeddings, Search) ====

// MARK: - Enhanced Notification Extensions (from Hal10000App.swift)
extension Notification.Name {
    static let databaseUpdated = Notification.Name("databaseUpdated")
    static let relevanceThresholdDidChange = Notification.Name("relevanceThresholdDidChange")
    static let showDocumentImport = Notification.Name("showDocumentImport")
    static let didUpdateMessageContent = Notification.Name("didUpdateMessageContent") // Keep this for streaming scroll
    static let keyboardWillChangeFrame = Notification.Name("keyboardWillChangeFrame") // NEW: Custom notification for keyboard
}

// MARK: - Enhanced Entity Extraction with NLTagger (from Hal10000App.swift)
extension MemoryStore {

    // ENHANCED: Extract named entities using Apple's NaturalLanguage framework
    func extractNamedEntities(from text: String) -> [NamedEntity] {
        print("HALDEBUG-ENTITY: Extracting entities from text length: \(text.count)")

        // Graceful error handling - return empty array if text is empty
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            print("HALDEBUG-ENTITY: Empty text provided, returning empty entities")
            return []
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = cleanText

        var extractedEntities: [NamedEntity] = []

        // FIX: Re-add missing 'unit' and 'scheme' parameters to enumerateTags
        tagger.enumerateTags(in: cleanText.startIndex..<cleanText.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, tokenRange in
            guard let tag = tag else {
                return true
            }

            let entityType: NamedEntity.EntityType
            switch tag {
            case .personalName:
                entityType = .person
            case .placeName:
                entityType = .place
            case .organizationName:
                entityType = .organization
            default:
                entityType = .other
            }

            if entityType != .other {
                let entityText = String(cleanText[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !entityText.isEmpty {
                    extractedEntities.append(NamedEntity(text: entityText, type: entityType))
                    print("HALDEBUG-ENTITY: Found \(entityType.displayName): '\(entityText)'")
                }
            }
            return true
        }

        let uniqueEntities = Array(Set(extractedEntities))

        print("HALDEBUG-ENTITY: Extracted \(uniqueEntities.count) unique entities from \(extractedEntities.count) total")
        return uniqueEntities
    }
}

// MARK: - Simplified 2-Tier Embedding System (Based on MENTAT's Proven Approach, from Hal10000App.swift)
extension MemoryStore {

    // SIMPLIFIED: Generate embeddings using only sentence embeddings + hash fallback
    func generateEmbedding(for text: String) -> [Double] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }

        print("HALDEBUG-MEMORY: Generating simplified embedding for text length \(cleanText.count)")

        // TIER 1: Apple Sentence Embeddings (Primary - proven reliable on modern systems)
        // FIX: Corrected typo 'NLEmb_edding' to 'NLEmbedding'
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
            if let vector = embedding.vector(for: cleanText) {
                let baseVector = (0..<vector.count).map { Double(vector[$0]) }
                print("HALDEBUG-MEMORY: Generated sentence embedding with \(baseVector.count) dimensions")
                return baseVector
            }
        }

        // TIER 3: Hash-Based Mathematical Embeddings (Crash prevention fallback only)
        print("HALDEBUG-MEMORY: Falling back to hash-based embedding for text length \(cleanText.count)")
        let hashVector = generateHashEmbedding(for: cleanText)

        return hashVector
    }

    // FALLBACK: Hash-based embeddings when Apple's NLEmbedding.sentenceEmbedding() returns nil
    private func generateHashEmbedding(for text: String) -> [Double] {
        let normalizedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var embedding: [Double] = []
        let seeds = [1, 31, 131, 1313, 13131] // Prime-like numbers for hash variation

        for seed in seeds {
            let hash = abs(normalizedText.hashValue ^ seed)
            for i in 0..<13 { // 5 seeds * 13 = 65 dimensions
                let value = Double((hash >> (i % 32)) & 0xFF) / 255.0
                embedding.append(value)
            }
        }

        // Normalize to unit vector for cosine similarity
        let magnitude = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            embedding = embedding.map { $0 / magnitude }
        }

        print("HALDEBUG-MEMORY: Generated hash embedding with \(embedding.count) dimensions")
        return Array(embedding.prefix(64)) // Keep 64 dimensions for consistency
    }

    // UTILITY: Standard cosine similarity calculation for vector comparison
    func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count && v1.count > 0 else { return 0 }
        let dot = zip(v1, v2).map(*).reduce(0, +)
        let norm1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let norm2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        return norm1 == 0 || norm2 == 0 ? 0 : dot / (norm1 * norm2)
    }
}

// MARK: - Entity-Enhanced Search Utilities (from Hal10000App.swift)
extension MemoryStore {

    // ENHANCED: Flexible search with entity-based expansion
    func expandQueryWithEntityVariations(_ query: String) -> [String] {
        var variations = [query]
        let queryEntities = extractNamedEntities(from: query)

        for entity in queryEntities {
            variations.append(entity.text)
            let words = entity.text.components(separatedBy: .whitespaces)
            if words.count > 1 {
                for word in words {
                    if word.count > 2 {
                        variations.append(word)
                    }
                }
            }
        }
        let queryWords = query.lowercased().components(separatedBy: .whitespaces)
        for word in queryWords {
            if word.count > 2 {
                variations.append(word)

                // Strip possessives: "dog's" → "dog", "cat's" → "cat"
                // This lets keyword search find "dog" in stored content when the query uses "dog's"
                let possessiveStripped = word.hasSuffix("'s") ? String(word.dropLast(2)) : word
                if possessiveStripped != word && possessiveStripped.count > 2 {
                    variations.append(possessiveStripped)
                }

                // Strip trailing punctuation: "name?" → "name", "home." → "home"
                let punctStripped = word.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                if punctStripped != word && punctStripped != possessiveStripped && punctStripped.count > 2 {
                    variations.append(punctStripped)
                }
            }
        }
        if queryWords.count == 1 {
            let word = queryWords[0]
            variations.append("\(word) *")
        }
        let uniqueVariations = Array(Set(variations))
        print("HALDEBUG-SEARCH: Generated \(uniqueVariations.count) query variations for '\(query)'")
        return uniqueVariations
    }

    // UTILITY: Get summary of all entities in a document
    func summarizeEntities(_ allEntities: [NamedEntity]) -> (total: Int, byType: [NamedEntity.EntityType: Int], unique: Set<String>) {
        let total = allEntities.count
        var byType: [NamedEntity.EntityType: Int] = [:]
        var unique: Set<String> = []

        for entity in allEntities {
            byType[entity.type, default: 0] += 1
            unique.insert(entity.text.lowercased())
        }
        return (total: total, byType: byType, unique: unique)
    }
}

// ==== LEGO END: 05 MemoryStore (Part 4 â€“ Entities, Embeddings, Search) ====


// ==== LEGO START: 06 MemoryStore (Part 5 – Retrieval & Debug Functions) ====

// MARK: - Conversation Message Retrieval with Enhanced Schema (from Hal10000App.swift)
extension MemoryStore {

    // NEW: Get current turn number for a conversation (used when creating ChatMessages)
    // Returns the highest turn_number currently stored, or 0 if conversation is empty
    func getCurrentTurnNumber(conversationId: String) -> Int {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot get turn number - no database connection")
            return 0
        }
        
        let sql = "SELECT MAX(turn_number) FROM unified_content WHERE source_id = ? AND source_type = 'conversation';"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-MEMORY: Failed to prepare turn number query")
            return 0
        }
        
        sqlite3_bind_text(stmt, 1, (conversationId as NSString).utf8String, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            let maxTurn = Int(sqlite3_column_int(stmt, 0))
            print("HALDEBUG-MEMORY: Current turn number for conversation \(conversationId.prefix(8)): \(maxTurn)")
            return maxTurn
        }
        
        return 0
    }
    
    // NEW: Store conversation artifact (for complete history/transparency)
    // This table stores EVERYTHING that happens (deliberations, moderators, system notifications)
    // It is NEVER RAG-eligible - it's purely for reconstruction and transparency
    func storeConversationArtifact(
        conversationId: String,
        artifactType: String,  // "userMessage", "halEndorsedResponse", "salonDeliberation", etc.
        turnNumber: Int,
        deliberationRound: Int,
        seatNumber: Int?,
        content: String,
        modelId: String?,
        metadataJson: String = "{}"
    ) {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot store artifact - no database connection")
            return
        }
        
        let artifactId = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970)
        
        let sql = """
        INSERT INTO conversation_artifacts
        (id, artifact_type, turn_number, deliberation_round, seat_number, content, model_id, conversation_id, timestamp, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-MEMORY: Failed to prepare artifact insert")
            return
        }
        
        sqlite3_bind_text(stmt, 1, (artifactId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (artifactType as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(turnNumber))
        sqlite3_bind_int(stmt, 4, Int32(deliberationRound))
        
        if let seat = seatNumber {
            sqlite3_bind_int(stmt, 5, Int32(seat))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        
        sqlite3_bind_text(stmt, 6, (content as NSString).utf8String, -1, nil)
        
        if let model = modelId {
            sqlite3_bind_text(stmt, 7, (model as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        
        sqlite3_bind_text(stmt, 8, (conversationId as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 9, timestamp)
        sqlite3_bind_text(stmt, 10, (metadataJson as NSString).utf8String, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_DONE {
            print("HALDEBUG-MEMORY: Stored conversation artifact - type: \(artifactType), turn: \(turnNumber)")
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-MEMORY: Failed to store conversation artifact: \(errorMessage)")
        }
    }

    // Retrieve conversation messages with surgical debug
    // MODIFIED: Now retrieves turn_number, deliberation_round, seat_number from database
    func getConversationMessages(conversationId: String) -> [ChatMessage] {
        print("HALDEBUG-MEMORY: Loading messages for conversation: \(conversationId)")
        print("HALDEBUG-MEMORY: SURGERY - Retrieve start convId='\(conversationId.prefix(8))....'")

        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot load messages - no database connection")
            print("HALDEBUG-MEMORY: SURGERY - Retrieve FAILED no connection")
            return []
        }

        var messages: [ChatMessage] = []

        // MODIFIED: Added turn_number, deliberation_round, seat_number to SELECT
        let sql = """
        SELECT id, content, is_from_user, timestamp, position, metadata_json, recorded_by_model, turn_number, deliberation_round, seat_number
        FROM unified_content
        WHERE source_type = 'conversation' AND source_id = ?
        ORDER BY position ASC;
        """

        print("HALDEBUG-MEMORY: SURGERY - Retrieve query sourceType='conversation' sourceId='\(conversationId.prefix(8))....'")

        var stmt: OpaquePointer?
        defer {
            if stmt != nil {
                sqlite3_finalize(stmt)
            }
        }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-MEMORY: Failed to prepare message query")
            print("HALDEBUG-MEMORY: SURGERY - Retrieve FAILED prepare")
            return []
        }

        sqlite3_bind_text(stmt, 1, (conversationId as NSString).utf8String, -1, nil)

        var rowCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCString = sqlite3_column_text(stmt, 0),
                  let contentCString = sqlite3_column_text(stmt, 1) else { continue }

            let messageId = String(cString: idCString)
            let content = String(cString: contentCString)
            let isFromUser = sqlite3_column_int(stmt, 2) == 1
            let timestampValue = sqlite3_column_int64(stmt, 3)
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))
            
            // Read recorded_by_model from column 6
            let recordedByModel: String
            if let modelCString = sqlite3_column_text(stmt, 6) {
                recordedByModel = String(cString: modelCString)
            } else {
                // Legacy data or user messages without model attribution
                recordedByModel = isFromUser ? "user" : "unknown"
            }
            
            // NEW: Extract metadata_json
            var fullPromptUsed: String? = nil
            var usedContextSnippets: [UnifiedSearchResult]? = nil
            var thinkingDuration: TimeInterval? = nil

            if let metadataCString = sqlite3_column_text(stmt, 5) {
                let metadataJsonString = String(cString: metadataCString)
                if let metadataData = Data(base64Encoded: metadataJsonString),
                   let metadataDict = (try? JSONSerialization.jsonObject(with: metadataData, options: []) as? [String: Any]) {
                    
                    fullPromptUsed = metadataDict["fullPromptUsed"] as? String
                    
                    if let contextSnippetsJson = metadataDict["usedContextSnippets"] as? String,
                       let contextSnippetsData = contextSnippetsJson.data(using: .utf8) {
                        usedContextSnippets = try? JSONDecoder().decode([UnifiedSearchResult].self, from: contextSnippetsData)
                    }
                    
                    thinkingDuration = metadataDict["thinkingDuration"] as? TimeInterval
                }
            }

            // NEW: Read turn_number, deliberation_round, seat_number from columns 7, 8, 9
            let turnNumber = Int(sqlite3_column_int(stmt, 7))
            let deliberationRound = Int(sqlite3_column_int(stmt, 8))
            
            let seatNumber: Int?
            if sqlite3_column_type(stmt, 9) == SQLITE_NULL {
                seatNumber = nil
            } else {
                seatNumber = Int(sqlite3_column_int(stmt, 9))
            }

            rowCount += 1

            if rowCount == 1 {
                print("HALDEBUG-MEMORY: SURGERY - Retrieve found row content='\(content.prefix(20))....' isFromUser=\(isFromUser) id='\(messageId.prefix(8))....'")
            }

            let message = ChatMessage(
                id: UUID(uuidString: messageId) ?? UUID(), // Use stored ID, fallback to new if invalid
                content: content,
                isFromUser: isFromUser,
                timestamp: timestamp,
                isPartial: false, // Assuming loaded messages are always complete
                thinkingDuration: thinkingDuration,
                fullPromptUsed: fullPromptUsed,
                usedContextSnippets: usedContextSnippets,
                recordedByModel: recordedByModel,
                turnNumber: turnNumber,
                seatNumber: seatNumber,
                deliberationRound: deliberationRound
            )
            messages.append(message)
        }

        print("HALDEBUG-MEMORY: Loaded \(messages.count) messages for conversation \(conversationId)")
        print("HALDEBUG-MEMORY: SURGERY - Retrieve complete found=2 rows convId='\(conversationId.prefix(8))....'")
        return messages
    }
}

// MARK: - Enhanced Debug Database Function with Entity Information (from Hal10000App.swift)
extension MemoryStore {

    // SURGICAL DEBUG: Enhanced database inspection with entity information
    func debugDatabaseWithSurgicalPrecision() {
        print("HALDEBUG-DATABASE: SURGERY - Enhanced debug DB inspection starting")

        guard ensureHealthyConnection() else {
            print("HALDEBUG-DATABASE: SURGERY - Debug FAILED no connection")
            return
        }

        var stmt: OpaquePointer?

        let countSQL = "SELECT COUNT(*) FROM unified_content;"
        if sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let totalRows = sqlite3_column_int(stmt, 0)
                print("HALDEBUG-DATABASE: SURGERY - Table unified_content has \(totalRows) total rows")
            }
        }
        sqlite3_finalize(stmt)

        // NEW: Also select metadata_json
        let convSQL = "SELECT source_id, source_type, position, content, entity_keywords, metadata_json FROM unified_content WHERE source_type = 'conversation' LIMIT 3;"
        if sqlite3_prepare_v2(db, convSQL, -1, &stmt, nil) == SQLITE_OK {
            var convRowCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                convRowCount += 1

                let sourceId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "NULL"
                let sourceType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "NULL"
                let position = Int(sqlite3_column_int(stmt, 2))
                let content = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "NULL"
                let entityKeywords = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "NULL"
                let metadataJson = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "NULL" // NEW

                print("HALDEBUG-DATABASE: SURGERY - Conv row \(convRowCount): sourceId='\(sourceId.prefix(8))....' type='\(sourceType)' pos=\(position) content='\(content.prefix(20))....' entities='\(entityKeywords)' metadata='\(metadataJson.prefix(50))....'")
            }
            if convRowCount == 0 {
                print("HALDEBUG-DATABASE: SURGERY - No conversation rows found in table")
            }
        }
        sqlite3_finalize(stmt)

        let typesSQL = "SELECT source_type, COUNT(*), COUNT(CASE WHEN entity_keywords IS NOT NULL AND entity_keywords != '' THEN 1 END) FROM unified_content GROUP BY source_type;"
        if sqlite3_prepare_v2(db, typesSQL, -1, &stmt, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: SURGERY - Source types with entity statistics:")
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sourceType = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "NULL"
                let count = sqlite3_column_int(stmt, 1)
                let entityCount = sqlite3_column_int(stmt, 2)
                print("HALDEBUG-DATABASE: SURGERY -   type='\(sourceType)' count=\(count) with_entities=\(entityCount)")
            }
        }
        sqlite3_finalize(stmt)

        print("HALDEBUG-DATABASE: SURGERY - Enhanced debug DB inspection complete")
    }
}

// ==== LEGO END: 06 MemoryStore (Part 5 – Retrieval & Debug Functions) ====
        

                
// ==== LEGO START: 07 MemoryStore (Part 6 â€“ Search Functions with Full Metadata) ====

extension MemoryStore {
    
    // MARK: - Unified Search Function with Full Attribution Metadata
    // This function performs both semantic and entity-based search to retrieve relevant context.
    // Returns RAGSnippet objects with complete metadata for transparency.
    func searchUnifiedContent(for query: String, currentConversationId: String, excludeTurns: [Int], maxResults: Int, tokenBudget: Int) -> UnifiedSearchContext {
        print("HALDEBUG-SEARCH: Starting unified content search for query: '\(query.prefix(50))....'")
        print("HALDEBUG-SEARCH: Excluding turns: \(excludeTurns)")

        guard ensureHealthyConnection() else {
            print("HALDEBUG-SEARCH: Cannot perform search - no database connection")
            return UnifiedSearchContext(snippets: [], totalTokens: 0)
        }

        let queryEmbedding = generateEmbedding(for: query)
        guard !queryEmbedding.isEmpty else {
            print("HALDEBUG-SEARCH: Query embedding is empty, cannot perform semantic search.")
            return UnifiedSearchContext(snippets: [], totalTokens: 0)
        }

        var allResults: [UnifiedSearchResult] = []
        var totalTokens = 0

        // --- 1. Semantic Search (using embeddings) with SQL-level exclusion ---
        print("HALDEBUG-SEARCH: Performing semantic search...")
        
        // Build exclusion clause for SQL query
        let exclusionClause = buildExclusionClause(conversationId: currentConversationId, excludeTurns: excludeTurns)
        
        let semanticSQL = """
        SELECT id, content, embedding, source_type, source_id, position, metadata_json, timestamp
        FROM unified_content
        WHERE embedding IS NOT NULL\(exclusionClause);
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, semanticSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(stmt, 1),
                      let embeddingBlobPtr = sqlite3_column_blob(stmt, 2) else { continue }

                let content = String(cString: contentCString)
                let blobSize = sqlite3_column_bytes(stmt, 2)
                let embeddingData = Data(bytes: embeddingBlobPtr, count: Int(blobSize))
                let storedEmbedding = embeddingData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Double] in
                    Array(ptr.bindMemory(to: Double.self))
                }

                let sourceTypeRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                _ = sqlite3_column_text(stmt, 4) // sourceId - not needed (excluded at SQL level)
                _ = sqlite3_column_int(stmt, 5) // position - not needed (excluded at SQL level)
                
                // Extract filePath from metadata_json for document snippets
                var filePath: String? = nil
                if let metadataCString = sqlite3_column_text(stmt, 6) { // metadata_json is column 6
                    let metadataJsonString = String(cString: metadataCString)
                    if let metadataData = Data(base64Encoded: metadataJsonString),
                       let metadataDict = (try? JSONSerialization.jsonObject(with: metadataData, options: []) as? [String: Any]) {
                        filePath = metadataDict["filePath"] as? String
                    }
                }

                // Extract timestamp for recency scoring
                let timestampValue = sqlite3_column_int64(stmt, 7) // timestamp is column 7 (after metadata_json)
                let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))

                let similarity = cosineSimilarity(queryEmbedding, storedEmbedding)
                if similarity >= relevanceThreshold {
                    // Apply recency boosting to combine semantic and temporal scores
                    let recencyScore = calculateRecencyScore(timestamp: timestamp)
                    // Source code doesn't age — skip recency decay for static architecture content
                    let finalScore = sourceTypeRaw == "source_code"
                        ? similarity
                        : (similarity * (1.0 - recencyWeight)) + (recencyScore * recencyWeight)
                    
                    // Add age label to content for LLM context
                    let ageLabel = formatAgeLabel(timestamp: timestamp)
                    let labeledContent = "[\(ageLabel)]: \(content)"
                    
                    allResults.append(UnifiedSearchResult(content: labeledContent, relevance: finalScore, source: sourceTypeRaw, isEntityMatch: false, filePath: filePath))
                }
            }
        }
        sqlite3_finalize(stmt)
        print("HALDEBUG-SEARCH: Semantic search completed. Found \(allResults.count) initial matches.")

        // --- 2. Entity-Based Keyword Search with SQL-level exclusion ---
        print("HALDEBUG-SEARCH: Performing entity-based keyword search...")
        let expandedQueries = expandQueryWithEntityVariations(query)
        for expandedQuery in expandedQueries {
            let keywordSQL = """
            SELECT id, content, source_type, source_id, position, metadata_json, timestamp
            FROM unified_content
            WHERE (entity_keywords LIKE ? OR content LIKE ?)\(exclusionClause);
            """
            var keywordStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, keywordSQL, -1, &keywordStmt, nil) == SQLITE_OK {
                let likeQuery = "%\(expandedQuery.lowercased())%"
                sqlite3_bind_text(keywordStmt, 1, (likeQuery as NSString).utf8String, -1, nil)
                sqlite3_bind_text(keywordStmt, 2, (likeQuery as NSString).utf8String, -1, nil)

                while sqlite3_step(keywordStmt) == SQLITE_ROW {
                    guard let contentCString = sqlite3_column_text(keywordStmt, 1) else { continue }
                    let content = String(cString: contentCString)

                    let sourceTypeRaw = sqlite3_column_text(keywordStmt, 2).map { String(cString: $0) } ?? ""
                    _ = sqlite3_column_text(keywordStmt, 3) // sourceId - not needed (excluded at SQL level)
                    _ = sqlite3_column_int(keywordStmt, 4) // position - not needed (excluded at SQL level)

                    // Extract filePath from metadata_json for document snippets
                    var filePath: String? = nil
                    if let metadataCString = sqlite3_column_text(keywordStmt, 5) { // metadata_json is column 5
                        let metadataJsonString = String(cString: metadataCString)
                        if let metadataData = Data(base64Encoded: metadataJsonString),
                           let metadataDict = (try? JSONSerialization.jsonObject(with: metadataData, options: []) as? [String: Any]) {
                            filePath = metadataDict["filePath"] as? String
                        }
                    }
                    
                    // Extract timestamp for recency scoring
                    let timestampValue = sqlite3_column_int64(keywordStmt, 6) // timestamp is column 6
                    let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))

                    // Apply recency boosting to keyword matches too
                    // Base relevance set below semantic threshold (0.75) so keyword-only matches
                    // don't compete with strong semantic matches and introduce noise
                    let recencyScore = calculateRecencyScore(timestamp: timestamp)
                    let baseRelevance = 0.60 // Keyword-only match: lower than semantic threshold
                    // Source code doesn't age — skip recency decay for static architecture content
                    let finalScore = sourceTypeRaw == "source_code"
                        ? baseRelevance
                        : (baseRelevance * (1.0 - recencyWeight)) + (recencyScore * recencyWeight)
                    
                    // Add age label to content
                    let ageLabel = formatAgeLabel(timestamp: timestamp)
                    let labeledContent = "[\(ageLabel)]: \(content)"

                    // Add a default relevance for keyword matches, or enhance if already a semantic match
                    if let existingIndex = allResults.firstIndex(where: { $0.content.contains(content) }) {
                        // If already found by semantic search, just mark as entity match
                        allResults[existingIndex].isEntityMatch = true
                    } else {
                        // Add as a new result with recency-adjusted relevance
                        allResults.append(UnifiedSearchResult(content: labeledContent, relevance: finalScore, source: sourceTypeRaw, isEntityMatch: true, filePath: filePath))
                    }
                }
            }
            sqlite3_finalize(keywordStmt)
        }
        print("HALDEBUG-SEARCH: Entity keyword search completed. Total matches: \(allResults.count)")

        // --- 3. Sort by Relevance ---
        allResults.sort { $0.relevance > $1.relevance }

        // --- 4. Build RAGSnippet Objects with Full Metadata ---
        var ragSnippets: [RAGSnippet] = []
        
        // Need to re-query to get timestamps for each result
        // Create a map of content -> timestamp by re-scanning results
        var contentTimestampMap: [String: Date] = [:]
        
        let timestampSQL = """
        SELECT content, timestamp
        FROM unified_content
        WHERE embedding IS NOT NULL OR entity_keywords IS NOT NULL;
        """
        var tsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, timestampSQL, -1, &tsStmt, nil) == SQLITE_OK {
            while sqlite3_step(tsStmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(tsStmt, 0) else { continue }
                let content = String(cString: contentCString)
                let timestampValue = sqlite3_column_int64(tsStmt, 1)
                let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))
                
                // Store mapping (content without age label -> timestamp)
                // Strip age label if present: "[age label]: content" -> "content"
                let cleanContent = content.contains("]: ") ? String(content.split(separator: "]: ", maxSplits: 1).last ?? "") : content
                contentTimestampMap[cleanContent] = timestamp
            }
        }
        sqlite3_finalize(tsStmt)

        for result in allResults {
            // Estimate tokens for this snippet
            let snippetTokens = TokenEstimator.estimateTokens(from: result.content)

            // Stop adding if we exceed the budget
            if totalTokens + snippetTokens > tokenBudget {
                print("HALDEBUG-SEARCH: Token budget reached. Stopping at \(totalTokens) tokens.")
                break
            }

            totalTokens += snippetTokens

            // Parse source type
            guard let sourceType = ContentSourceType(rawValue: result.source) else { continue }
            
            // Determine source name based on type
            let sourceName: String
            switch sourceType {
            case .conversation:
                sourceName = "Conversation"
            case .document:
                sourceName = result.filePath ?? "Unknown Document"
            case .webpage:
                sourceName = result.filePath ?? "Web Page"
            case .email:
                sourceName = "Email"
            case .sourceCode:
                sourceName = result.filePath ?? "Hal.swift"
            }
            
            // Extract timestamp from map (strip age label from content to match)
            let cleanContent = result.content.contains("]: ") ? String(result.content.split(separator: "]: ", maxSplits: 1).last ?? "") : result.content
            let timestamp = contentTimestampMap[cleanContent] ?? Date()
            
            // recordedByModel will be populated after schema/storage updates in Blocks 03/04
            let recordedByModel: String? = nil
            
            // Create RAGSnippet with full metadata
            let snippet = RAGSnippet(
                content: result.content,
                sourceType: sourceType,
                sourceName: sourceName,
                timestamp: timestamp,
                relevanceScore: result.relevance,
                recordedByModel: recordedByModel,
                isEntityMatch: result.isEntityMatch
            )
            
            ragSnippets.append(snippet)
        }

        print("HALDEBUG-SEARCH: Final results - total snippets: \(ragSnippets.count), total tokens: \(totalTokens)")
        searchDebugResults = "Search found \(ragSnippets.count) snippets (\(ragSnippets.filter { $0.sourceType == .conversation }.count) conv, \(ragSnippets.filter { $0.sourceType == .document }.count) doc, \(ragSnippets.filter { $0.sourceType == .sourceCode }.count) code)."

        return UnifiedSearchContext(
            snippets: ragSnippets,
            totalTokens: totalTokens
        )
    }
    
    // MARK: - SQL Exclusion Helper

    /// Builds SQL WHERE clause to exclude STM-verbatim turns from current conversation.
    /// Only the specific turns already shown verbatim in the prompt are excluded — older turns
    /// in the current conversation are RAG-eligible (cross-session recall). Returns empty string
    /// if no exclusion is needed.
    private func buildExclusionClause(conversationId: String, excludeTurns: [Int]) -> String {
        guard !conversationId.isEmpty, !excludeTurns.isEmpty else { return "" }
        let escapedId = conversationId.replacingOccurrences(of: "'", with: "''")
        let turnList = excludeTurns.map { String($0) }.joined(separator: ",")
        return " AND NOT (source_type='conversation' AND source_id='\(escapedId)' AND turn_number IN (\(turnList)))"
    }
    
    // MARK: - Recency Scoring Helpers
    
    // Calculate recency score using half-life decay
    private func calculateRecencyScore(timestamp: Date) -> Double {
        let now = Date()
        let daysSince = now.timeIntervalSince(timestamp) / 86400.0 // Convert seconds to days
        
        // Half-life decay formula: score = max(floor, exp(-0.693 * days / halfLife))
        // 0.693 is ln(2), which gives us the half-life decay constant
        let decayConstant = 0.693
        let rawScore = exp(-decayConstant * daysSince / recencyHalfLifeDays)
        
        // Apply floor to prevent very old memories from completely disappearing
        let finalScore = max(recencyFloor, rawScore)
        
        return finalScore
    }
    
    // Format age label for LLM context
    private func formatAgeLabel(timestamp: Date) -> String {
        let now = Date()
        let secondsSince = now.timeIntervalSince(timestamp)
        let daysSince = secondsSince / 86400.0
        
        if daysSince < 1 {
            let hoursSince = secondsSince / 3600.0
            if hoursSince < 1 {
                return "Just now"
            } else if hoursSince < 2 {
                return "1 hour ago"
            } else {
                return "\(Int(hoursSince)) hours ago"
            }
        } else if daysSince < 2 {
            return "Yesterday"
        } else if daysSince < 7 {
            return "\(Int(daysSince)) days ago"
        } else if daysSince < 30 {
            let weeksSince = Int(daysSince / 7)
            return weeksSince == 1 ? "1 week ago" : "\(weeksSince) weeks ago"
        } else if daysSince < 365 {
            let monthsSince = Int(daysSince / 30)
            return monthsSince == 1 ? "1 month ago" : "\(monthsSince) months ago"
        } else {
            let yearsSince = Int(daysSince / 365)
            return yearsSince == 1 ? "1 year ago" : "\(yearsSince) years ago"
        }
    }

    // MARK: - Thread Management

    /// Insert or update a thread row. Safe to call on every conversation start.
    func upsertThread(id: String, title: String, titleIsUserSet: Bool = false) {
        guard ensureHealthyConnection() else { return }
        let now = Int(Date().timeIntervalSince1970)
        let sql = """
            INSERT INTO threads (id, title, title_is_user_set, created_at, last_active_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = CASE WHEN title_is_user_set = 1 THEN threads.title ELSE excluded.title END,
                title_is_user_set = MAX(threads.title_is_user_set, excluded.title_is_user_set),
                last_active_at = excluded.last_active_at;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, titleIsUserSet ? 1 : 0)
            sqlite3_bind_int64(stmt, 4, Int64(now))
            sqlite3_bind_int64(stmt, 5, Int64(now))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Update a thread's title. If userSet=true, marks it permanently user-owned (auto-update stops).
    func updateThreadTitle(id: String, title: String, userSet: Bool) {
        guard ensureHealthyConnection() else { return }
        let sql = "UPDATE threads SET title = ?, title_is_user_set = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, userSet ? 1 : 0)
            sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Touch last_active_at for a thread (called on every message send).
    func touchThread(id: String) {
        guard ensureHealthyConnection() else { return }
        let now = Int(Date().timeIntervalSince1970)
        let sql = "UPDATE threads SET last_active_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(now))
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Load all threads, most recent first.
    func loadAllThreads() -> [ThreadRecord] {
        guard ensureHealthyConnection() else { return [] }
        var results: [ThreadRecord] = []
        let sql = "SELECT id, title, title_is_user_set, created_at, last_active_at FROM threads ORDER BY last_active_at DESC;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idCStr = sqlite3_column_text(stmt, 0),
                      let titleCStr = sqlite3_column_text(stmt, 1) else { continue }
                results.append(ThreadRecord(
                    id: String(cString: idCStr),
                    title: String(cString: titleCStr),
                    titleIsUserSet: sqlite3_column_int(stmt, 2) != 0,
                    createdAt: Int(sqlite3_column_int64(stmt, 3)),
                    lastActiveAt: Int(sqlite3_column_int64(stmt, 4))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Delete all data for a thread (unified_content, artifacts, and the thread row itself).
    func deleteThread(id: String) {
        guard ensureHealthyConnection() else { return }
        let statements = [
            "DELETE FROM unified_content WHERE source_id = ? AND source_type = 'conversation';",
            "DELETE FROM conversation_artifacts WHERE conversation_id = ?;",
            "DELETE FROM threads WHERE id = ?;"
        ]
        for sql in statements {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Deletes ALL conversation data (threads, messages, facts, artifacts) while preserving
    /// documents, source code, and self-knowledge. Used by the CLEAR_TEST_DATA harness command
    /// to wipe accumulated test threads without a full nuclear reset.
    /// Returns (threadsDeleted, factsDeleted, messagesDeleted).
    @discardableResult
    func clearAllConversationData() -> (threads: Int, facts: Int, messages: Int) {
        guard ensureHealthyConnection() else { return (0, 0, 0) }

        func rowCount(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }

        let threadCount   = rowCount("SELECT COUNT(*) FROM threads;")
        let messageCount  = rowCount("SELECT COUNT(*) FROM unified_content WHERE source_type = 'conversation';")

        let deletions = [
            "DELETE FROM unified_content WHERE source_type = 'conversation';",
            "DELETE FROM conversation_artifacts;",
            "DELETE FROM threads;"
        ]
        for sql in deletions {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        print("HALDEBUG-DATABASE: clearAllConversationData — deleted \(threadCount) threads, \(messageCount) messages. Documents and self-knowledge preserved.")
        return (threadCount, 0, messageCount)
    }
}

// ==== LEGO END: 07 MemoryStore (Part 6 â€“ Search Functions with Full Metadata) ====



// ==== LEGO START: 07.5 HalModelLimits Configuration ====


// MARK: - Centralized Hal Model Limits Configuration
/// Single source of truth for all model-specific limits and configurations
/// This prevents duplicate hardcoded values and ensures consistency across UI and logic
/// Works with ModelConfiguration from Block 30 - no hardcoded model types
struct HalModelLimits {
    let contextWindowTokens: Int
    let maxPromptTokens: Int
    let responseReserveTokens: Int
    let maxRagTokens: Int
    let shortTermMemoryTokens: Int
    let longTermSnippetSummarizationThreshold: Int
    
    /// Dynamic configuration based on ModelConfiguration (from Block 30)
    /// Uses uniform percentages across all models: same identity, different capacity based on context size
    /// Includes clamping to prevent exceeding context window
    static func config(for model: ModelConfiguration) -> HalModelLimits {
        let context = model.contextWindow
        
        // Calculate proportions with minimum guardrails
        let responseReserve = max(Int(Double(context) * 0.30), 800)
        let maxRag = max(Int(Double(context) * 0.15), 400)
        let shortTermMemory = max(Int(Double(context) * 0.12), 300)
        let summarizationThreshold = context / 20
        
        // Calculate remaining space for prompt after reserves
        // CRITICAL: Clamp to prevent overflow on small context windows (e.g., AFM 4K)
        let reservedTokens = responseReserve + maxRag + shortTermMemory
        let maxPrompt = max(context - reservedTokens, context / 2) // At least 50% for prompt
        
        return HalModelLimits(
            contextWindowTokens: context,
            maxPromptTokens: maxPrompt,
            responseReserveTokens: responseReserve,
            maxRagTokens: maxRag,
            shortTermMemoryTokens: shortTermMemory,
            longTermSnippetSummarizationThreshold: summarizationThreshold
        )
    }
    
    /// Maximum number of verbatim conversation turns for short-term memory.
    /// Derived from context window: roughly 1 turn per 400 tokens, minimum 5.
    var maxMemoryDepth: Int {
        return max(5, contextWindowTokens / 400)
    }

    /// Convert tokens to approximate character count using TokenEstimator
    func tokensToChars(_ tokens: Int) -> Int {
        return TokenEstimator.estimateChars(from: tokens)
    }
    
    /// Convert character count to approximate tokens using TokenEstimator
    func charsToTokens(_ chars: Int) -> Int {
        let estimatedTokens = Double(chars) / 3.5
        return max(1, Int(estimatedTokens.rounded()))
    }
}



// MARK: - Model Source (AFM-only in Hal LMC)
enum ModelSource: String, Codable {
    case appleFoundation = "apple"
    case mlx = "mlx"  // Retained for legacy data compatibility
}

// MARK: - Model Configuration
struct ModelConfiguration: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let displayName: String
    let source: ModelSource
    let sizeGB: Double?
    let contextWindow: Int
    let license: String?
    let description: String?
    var isDownloaded: Bool
    var localPath: URL?

    var isLocal: Bool { source == .mlx }
    var requiresDownload: Bool { source == .mlx && !isDownloaded }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ModelConfiguration, rhs: ModelConfiguration) -> Bool {
        lhs.id == rhs.id
    }

    static let appleFoundation = ModelConfiguration(
        id: "apple-foundation-models",
        displayName: "Apple Intelligence",
        source: .appleFoundation,
        sizeGB: nil,
        contextWindow: 4_096,
        license: nil,
        description: "Always available, no download required",
        isDownloaded: true,
        localPath: nil
    )
}

// ==== LEGO END: 07.5 HalModelLimits Configuration ====



// ==== LEGO START: 08 LLMService (Apple Foundation Models) ====

// MARK: - LLM Service (Apple Foundation Models only in Hal LMC)
class LLMService: ObservableObject {
    @Published var initializationError: String?

    /// Always "apple-foundation-models" in Hal LMC.
    var activeModelID: String { ModelConfiguration.appleFoundation.id }

    init() {
        print("HALDEBUG-LLM: LLMService initialized (AFM only)")
    }

    /// Generate a response using Apple Foundation Models.
    func generateResponse(prompt: String, temperature: Double = 0.7) async throws -> String {
        print("HALDEBUG-RESPONSE: AFM responding")
        let session = LanguageModelSession()
        print("HALDEBUG-LLM: Generating from FoundationModels (first 200 chars): \(prompt.prefix(200))...")
        do {
            var accumulatedText = ""
            let stream = session.streamResponse(
                options: GenerationOptions(temperature: temperature)
            ) { Prompt(prompt) }
            for try await snapshot in stream {
                accumulatedText = snapshot.content
            }
            print("HALDEBUG-LLM: Generation complete. Length: \(accumulatedText.count)")
            return accumulatedText
        } catch {
            print("HALDEBUG-LLM: Error during generation: \(error.localizedDescription)")
            throw LLMError.predictionFailed(error)
        }
    }

    enum LLMError: Error, LocalizedError {
        case modelNotLoaded
        case predictionFailed(Error)
        case sessionInitializationFailed

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The language model could not be loaded."
            case .predictionFailed(let error):
                return "LLM operation failed: \(error.localizedDescription)"
            case .sessionInitializationFailed:
                return "Failed to initialize a language model session."
            }
        }
    }
}

// ==== LEGO END: 08 LLMService (Apple Foundation Models) ====



// ==== LEGO START: 8.5 Text Summarization Utilities (LLM + Verification) ====

// MARK: - Text Summarization with Verification
// Battle-tested logic adapted from WikiDB's UnifiedSummarizer
// Two-stage approach: (1) LLM summarizes, (2) Verify against source to prevent hallucinations
// Uses Apple NaturalLanguage embeddings with TF-IDF fallback for robust verification
// NOTE: Foundation and NaturalLanguage are imported in Block 1

/// Main summarization utility for Hal
/// Use this anywhere you need to compress text: RAG snippets, conversation history, documents, etc.
struct TextSummarizer {
    
    // MARK: - Public API
    
    /// Summarize text with LLM and verify against source to prevent hallucinations
    /// - Parameters:
    ///   - text: Source text to summarize
    ///   - targetTokens: Desired token count for summary
    ///   - llmService: LLMService instance for generating summary
    ///   - verificationThreshold: Minimum similarity score (0.0-1.0) for verification (default: 0.72)
    /// - Returns: Verified summary text
    static func summarizeWithVerification(
        text: String,
        targetTokens: Int,
        llmService: LLMService,
        verificationThreshold: Double = 0.72
    ) async -> String {
        print("HALDEBUG-SUMMARIZER: Starting summarization - source: \(text.count) chars, target: \(targetTokens) tokens")

        // Stage 1: LLM summarize
        let summary = await llmSummarize(text: text, targetTokens: targetTokens, llmService: llmService)
        
        guard !summary.isEmpty else {
            print("HALDEBUG-SUMMARIZER: LLM returned empty summary, falling back to truncation")
            return String(text.prefix(TokenEstimator.estimateChars(from: targetTokens)))
        }
        
        print("HALDEBUG-SUMMARIZER: LLM summary generated: \(summary.count) chars")
        
        // Stage 2: Verify against source (prevent hallucinations)
        let sourceSentences = sentenceSplit(text)
        let verified = await verifyNarrative(summary, against: sourceSentences, threshold: verificationThreshold)
        
        print("HALDEBUG-SUMMARIZER: Verification complete: \(verified.count) chars")
        
        return verified
    }
    
    // MARK: - Stage 1: LLM Summarization
    
    /// Use LLM to compress text while preserving factual claims
    private static func llmSummarize(text: String, targetTokens: Int, llmService: LLMService) async -> String {
        let prompt = """
            You are a precise information compressor. Your task is to reduce the following text to approximately \(targetTokens) tokens while preserving:
            1. All factual claims and data points
            2. The logical flow of ideas
            3. Key entities and relationships
            4. The original intent
            
            Do not add interpretation or commentary. Extract and compress only.
            Do not include citations, footnote markers, or reference numbers.
            Write clear, complete sentences.
            
            The text below may contain contributions from a human and one or more AI models.
            Preserve attribution where it is explicit.
            
            Text to compress:
            \(text)
            
            Compressed version (approximately \(targetTokens) tokens):
            """
        
        do {
            let result = try await llmService.generateResponse(prompt: prompt)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("HALDEBUG-SUMMARIZER: LLM summarization failed: \(error.localizedDescription)")
            return ""
        }
    }
    
    // MARK: - Stage 2: Verification Against Source
    
    /// Verify each sentence in summary is grounded in source text
    /// Uses NaturalLanguage embeddings with TF-IDF fallback
    /// Replaces ungrounded sentences with nearest source sentence
    static func verifyNarrative(
        _ summary: String,
        against sourceSentences: [String],
        threshold: Double
    ) async -> String {
        let outputSentences = sentenceSplit(summary)
        guard !outputSentences.isEmpty else { return summary }
        
        print("HALDEBUG-SUMMARIZER: Verifying \(outputSentences.count) sentences against \(sourceSentences.count) source sentences")
        
        // Try NaturalLanguage sentence embeddings first
        let revisions: [Int] = [3, 2, 1]
        var embedding: NLEmbedding? = nil
        for r in revisions {
            if let e = NLEmbedding.sentenceEmbedding(for: .english, revision: r) {
                embedding = e
                print("HALDEBUG-SUMMARIZER: Using NL sentence embeddings (revision \(r))")
                break
            }
        }
        
        guard let model = embedding else {
            print("HALDEBUG-SUMMARIZER: NL embeddings unavailable, using TF-IDF fallback")
            return verifyNarrative_TFIDF(summary, against: sourceSentences, threshold: threshold)
        }
        
        // Precompute source sentence vectors
        var sourceVecs: [[Double]] = []
        var sourceKeep: [String] = []
        sourceVecs.reserveCapacity(sourceSentences.count)
        
        for s in sourceSentences {
            if let v = model.vector(for: s) {
                sourceVecs.append(v)
                sourceKeep.append(s)
            }
        }
        
        if sourceVecs.isEmpty {
            print("HALDEBUG-SUMMARIZER: No source vectors generated, using TF-IDF fallback")
            return verifyNarrative_TFIDF(summary, against: sourceSentences, threshold: threshold)
        }
        
        var verified: [String] = []
        var replacedCount = 0
        
        for s in outputSentences {
            guard let v = model.vector(for: s) else {
                // If we can't embed the sentence, use TF-IDF to find best match
                verified.append(bestMatchTFIDF(for: s, in: sourceSentences))
                replacedCount += 1
                continue
            }
            
            // Find best matching source sentence
            var bestSim = -1.0
            var bestIdx = 0
            for (i, u) in sourceVecs.enumerated() {
                let sim = cosineSimilarity(v, u)
                if sim > bestSim {
                    bestSim = sim
                    bestIdx = i
                }
            }
            
            if bestSim >= threshold {
                // Sentence is grounded, keep it
                verified.append(s)
            } else {
                // Sentence not grounded, replace with nearest source
                verified.append(sourceKeep[bestIdx])
                replacedCount += 1
            }
        }
        
        print("HALDEBUG-SUMMARIZER: Replaced \(replacedCount) ungrounded sentences")
        
        // Deduplicate adjacent repeats
        var dedup: [String] = []
        for s in verified {
            if dedup.last != s {
                dedup.append(s)
            }
        }
        
        return dedup.joined(separator: " ")
    }
    
    // MARK: - TF-IDF Fallback Verification
    
    /// Fallback verification using TF-IDF when embeddings unavailable
    private static func verifyNarrative_TFIDF(
        _ summary: String,
        against sourceSentences: [String],
        threshold: Double
    ) -> String {
        let outputSentences = sentenceSplit(summary)
        guard !outputSentences.isEmpty else { return summary }
        
        let docs = sourceSentences + outputSentences
        let vocab = buildVocabulary(docs)
        let idf = computeIDF(vocab: vocab, docs: docs)
        
        var verified: [String] = []
        var replacedCount = 0
        
        for s in outputSentences {
            let v = tfidfVector(for: s, vocab: vocab, idf: idf)
            var bestSim = -1.0
            var bestSrc = sourceSentences.first ?? ""
            
            for src in sourceSentences {
                let u = tfidfVector(for: src, vocab: vocab, idf: idf)
                let sim = cosine(v, u)
                if sim > bestSim {
                    bestSim = sim
                    bestSrc = src
                }
            }
            
            if bestSim >= threshold {
                verified.append(s)
            } else {
                verified.append(bestSrc)
                replacedCount += 1
            }
        }
        
        print("HALDEBUG-SUMMARIZER: TF-IDF replaced \(replacedCount) ungrounded sentences")
        
        // Deduplicate adjacent repeats
        var dedup: [String] = []
        for s in verified {
            if dedup.last != s {
                dedup.append(s)
            }
        }
        
        return dedup.joined(separator: " ")
    }
    
    // MARK: - Sentence Splitting
    
    /// Split text into sentences using NaturalLanguage tokenizer
    static func sentenceSplit(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                // Ensure sentences end with punctuation
                let sentence = (s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?")) ? s : s + "."
                out.append(sentence)
            }
            return true
        }
        
        return out
    }
    
    // MARK: - Embedding Helpers
    
    /// Cosine similarity for NLVector (array of Double)
    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        var dot = 0.0, na = 0.0, nb = 0.0
        
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? (dot / denom) : 0.0
    }
    
    // MARK: - TF-IDF Helpers
    
    /// Find best matching source sentence using TF-IDF
    private static func bestMatchTFIDF(for s: String, in sourceSentences: [String]) -> String {
        let docs = sourceSentences + [s]
        let vocab = buildVocabulary(docs)
        let idf = computeIDF(vocab: vocab, docs: docs)
        let v = tfidfVector(for: s, vocab: vocab, idf: idf)
        
        var bestSim = -1.0
        var bestSrc = sourceSentences.first ?? ""
        
        for src in sourceSentences {
            let u = tfidfVector(for: src, vocab: vocab, idf: idf)
            let sim = cosine(v, u)
            if sim > bestSim {
                bestSim = sim
                bestSrc = src
            }
        }
        
        return bestSrc
    }
    
    /// Build vocabulary of lowercase tokens
    private static func buildVocabulary(_ docs: [String]) -> [String] {
        var set = Set<String>()
        for d in docs {
            for tok in tokenize(d) {
                set.insert(tok)
            }
        }
        return Array(set).sorted()
    }
    
    /// Tokenize text into lowercase alphanumeric tokens
    private static func tokenize(_ s: String) -> [String] {
        let lowered = s.lowercased()
        let pattern = "[a-z0-9]+"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        let matches = regex?.matches(in: lowered, options: [], range: range) ?? []
        
        return matches.compactMap { m in
            if let r = Range(m.range, in: lowered) {
                return String(lowered[r])
            }
            return nil
        }
    }
    
    /// Compute IDF (inverse document frequency) for each token
    private static func computeIDF(vocab: [String], docs: [String]) -> [String: Double] {
        var df: [String: Int] = [:]
        
        // Count document frequency for each token
        for d in docs {
            var seen = Set<String>()
            for tok in tokenize(d) {
                seen.insert(tok)
            }
            for t in seen {
                df[t, default: 0] += 1
            }
        }
        
        let N = Double(max(1, docs.count))
        var idf: [String: Double] = [:]
        
        for t in vocab {
            let docFreq = Double(df[t] ?? 0)
            idf[t] = log((N + 1.0) / (docFreq + 1.0)) + 1.0
        }
        
        return idf
    }
    
    /// Build TF-IDF vector in shared vocab order
    private static func tfidfVector(for doc: String, vocab: [String], idf: [String: Double]) -> [Double] {
        var tf: [String: Int] = [:]
        let toks = tokenize(doc)
        
        for t in toks {
            tf[t, default: 0] += 1
        }
        
        let denom = Double(max(1, toks.count))
        
        return vocab.map { t in
            let tfNorm = Double(tf[t] ?? 0) / denom
            let w = tfNorm * (idf[t] ?? 0)
            return w
        }
    }
    
    /// Cosine similarity for TF-IDF vectors
    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        var dot = 0.0, na = 0.0, nb = 0.0
        
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? (dot / denom) : 0.0
    }
}

// ==== LEGO END: 8.5 Text Summarization Utilities (LLM + Verification) ====



// ==== LEGO START: 09 App Entry & iOSChatView (UI Shell) ====


// MARK: - HistoricalContext (from Hal10000App.swift)
struct HistoricalContext {
    let conversationCount: Int
    let relevantConversations: Int
    let contextSnippets: [String]
    let relevanceScores: [Double]
    let totalTokens: Int
}

// MARK: - App Entry Point (for iOS)
@main
struct Hal10000App: App {
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var documentImportManager = DocumentImportManager.shared
    var body: some Scene {
        WindowGroup {
            iOSChatView()
                .environmentObject(chatViewModel)
                .environmentObject(documentImportManager)
        }
        #if targetEnvironment(macCatalyst)
        // Mac-specific window sizing to eliminate black bars in "Designed for iPad" mode
        .defaultSize(width: 450, height: 700)
        #endif
    }
}



// MARK: - Primary chat surface with unified settings
import SwiftUI

struct iOSChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var scrollToBottomTrigger = UUID()
    @State private var showingSettings: Bool = false
    @State private var showingDocumentPicker: Bool = false
    @FocusState private var isInputFocused: Bool // NEW: Track text field focus
    @State private var watchBridge: HalWatchBridge? = nil
    @State private var userHasScrolled = false
    @State private var showingThreadPanel: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    List {
                        // FIXED: Use message.id as the identifier instead of array indices
                        // This allows SwiftUI to properly track content changes within each message
                        ForEach(chatViewModel.messages) { message in
                            let messageIndex = chatViewModel.messages.firstIndex(where: { $0.id == message.id }) ?? 0
                            ChatBubbleView(
                                message: message,
                                messageIndex: messageIndex
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                            .id(message.id)
                        }
                        // Invisible anchor: auto-scroll target + bottom-detection for resume/pause.
                        // onAppear/onDisappear fire reliably on both iOS and Mac Catalyst,
                        // unlike DragGesture which doesn't fire on Mac trackpad/mouse scroll.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .listRowSeparator(.hidden)
                            .onAppear {
                                // Sentinel entered view — user is at the bottom, resume auto-scroll
                                userHasScrolled = false
                            }
                            .onDisappear {
                                // Sentinel left view — user scrolled up, pause auto-scroll
                                userHasScrolled = true
                            }
                    }
                    .listStyle(.plain)
                    .id(chatViewModel.messagesVersion)
                    .onTapGesture {
                        // NEW: Dismiss keyboard when tapping message area
                        dismissKeyboard()
                    }
                    .gesture(
                        // Pause auto-scroll on upward drag (user reading history).
                        // Downward drags dismiss the keyboard but don't pause auto-scroll.
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                if value.translation.height < -20 {
                                    // Scrolling up — pause auto-scroll
                                    userHasScrolled = true
                                }
                            }
                            .onEnded { value in
                                if value.translation.height > 50 {
                                    dismissKeyboard()
                                }
                            }
                    )
                    .onAppear {
                        // Scroll to bottom on app launch
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        
                        // NEW: Initialize watch bridge on app launch
                        if watchBridge == nil {
                            watchBridge = HalWatchBridge(chatViewModel: chatViewModel)
                            print("HALDEBUG-WATCH: Bridge initialized in iOSChatView")
                        }
                    }
                    .onChange(of: chatViewModel.messages.count) { oldValue, newValue in
                        // Only auto-scroll if user hasn't manually scrolled away
                        if !userHasScrolled {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .onChange(of: chatViewModel.messages.last?.content) { oldValue, newValue in
                        // Only auto-scroll during streaming if user hasn't manually scrolled away
                        if !userHasScrolled {
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .onChange(of: chatViewModel.isSendingMessage) { oldValue, newValue in
                        // Reset scroll tracking when user sends a message
                        if newValue == true {
                            userHasScrolled = false
                            // Post-send positioning: Scroll based on message length
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if let lastMessage = chatViewModel.messages.last, lastMessage.isFromUser {
                                    // For short messages, scroll to bottom immediately
                                    // For long messages (>200 chars), user can see their full message
                                    if lastMessage.content.count < 200 {
                                        withAnimation(.easeOut(duration: 0.3)) {
                                            proxy.scrollTo("bottom", anchor: .bottom)
                                        }
                                    } else {
                                        withAnimation(.easeOut(duration: 0.3)) {
                                            proxy.scrollTo("bottom", anchor: .top)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Composer
                composer
            }
            .navigationTitle(conversationTitle)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingThreadPanel = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingThreadPanel) {
                ThreadPanelView(isPresented: $showingThreadPanel)
                    .environmentObject(chatViewModel)
            }

            // Unified Settings sheet
            .sheet(isPresented: $showingSettings) {
                ActionsView(showingDocumentPicker: $showingDocumentPicker)
                    .environmentObject(chatViewModel)
                    .environmentObject(DocumentImportManager.shared)
            }

            // Document picker sheet
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker()
                    .environmentObject(chatViewModel)
                    .environmentObject(DocumentImportManager.shared)
            }
        }
    }

    // MARK: - Conversation Title (Title Bar)
    // Thread title sourced from the threads table via chatViewModel.threads.
    // Falls back to "Hal" for empty threads (e.g., brand new conversation before first message).
    private var conversationTitle: String {
        chatViewModel.threads.first(where: { $0.id == chatViewModel.conversationId })?.title ?? "Hal"
    }

    // MARK: - Composer (Text Input Area)
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $chatViewModel.currentMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(20)
                .lineLimit(1...10)
                .focused($isInputFocused)
                .disabled(chatViewModel.isSendingMessage)
                .onTapGesture {
                    // Keyboard appears only on explicit tap
                    isInputFocused = true
                }

            Button {
                if chatViewModel.isSendingMessage {
                    // TODO: Implement cancellation logic if needed
                } else {
                    // Dismiss keyboard before sending
                    dismissKeyboard()
                    Task {
                        await chatViewModel.sendMessage()
                    }
                }
            } label: {
                Image(systemName: chatViewModel.isSendingMessage ? "stop.circle.fill" : "paperplane.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
            .disabled(chatViewModel.isSendingMessage || chatViewModel.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Keyboard Dismissal Helper
    // NEW: Platform-safe keyboard dismissal
    private func dismissKeyboard() {
        #if os(iOS)
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}


// ==== LEGO END: 09 App Entry & iOSChatView (UI Shell) ====


// ==== LEGO START: 09.5 ThreadPanelView ====

// MARK: - Thread Panel
/// Slide-out panel accessed via hamburger icon. Lists all conversation threads, most recent first.
/// New Thread button at top. Each thread shows title + subtitle (date + message count).
/// Tapping a thread switches to it with full context restoration.
/// Reset Thread button per thread row (swipe-to-delete style, with confirmation).
struct ThreadPanelView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var threadToDelete: ThreadRecord? = nil
    @State private var showingDeleteConfirmation = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                // New Thread button at top
                Button {
                    chatViewModel.startNewConversation()
                    isPresented = false
                } label: {
                    Label("New Thread", systemImage: "square.and.pencil")
                        .foregroundColor(.accentColor)
                }

                // Thread list, most recent first (already sorted by loadAllThreads)
                ForEach(chatViewModel.threads) { thread in
                    threadRow(thread)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .alert("Reset Thread?", isPresented: $showingDeleteConfirmation, presenting: threadToDelete) { thread in
            Button("Reset", role: .destructive) {
                resetThread(thread)
            }
            Button("Cancel", role: .cancel) { }
        } message: { thread in
            Text("This will permanently delete all messages in \"\(thread.title)\". This cannot be undone.")
        }
        .onAppear {
            chatViewModel.loadThreads()
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: ThreadRecord) -> some View {
        Button {
            chatViewModel.switchToThread(thread.id)
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.body)
                        .fontWeight(thread.id == chatViewModel.conversationId ? .semibold : .regular)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(subtitleText(for: thread))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if thread.id == chatViewModel.conversationId {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                Button {
                    threadToDelete = thread
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                threadToDelete = thread
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitleText(for thread: ThreadRecord) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(thread.lastActiveAt))
        return dateFormatter.string(from: date)
    }

    private func resetThread(_ thread: ThreadRecord) {
        if thread.id == chatViewModel.conversationId {
            // Resetting the active thread — start fresh
            chatViewModel.memoryStore.deleteThread(id: thread.id)
            chatViewModel.startNewConversation()
        } else {
            // Resetting an inactive thread — just delete its data
            chatViewModel.memoryStore.deleteThread(id: thread.id)
            chatViewModel.loadThreads()
        }
    }
}

// ==== LEGO END: 09.5 ThreadPanelView ====


// ==== LEGO START: 10.1 MainSettingsView ====


struct ActionsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var documentImportManager: DocumentImportManager

    @Binding var showingDocumentPicker: Bool
    @State private var showingExportSheet = false
    @State private var showingPowerUserSheet = false
    @State private var showingSystemPromptEditor = false
    @State private var showingSelfReflectionViewer = false
    @State private var initialSettingsSnapshot: [String: Any] = [:]
    @State private var skipComparisonOnDismiss = false

    var body: some View {
        NavigationView {
            Form {
                personalitySection
                importExportSection
                powerUserSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ShareSheet(activityItems: [chatViewModel.exportChatHistory()])
        }
        .sheet(isPresented: $showingPowerUserSheet) {
            PowerUserView()
                .environmentObject(chatViewModel)
        }
        .sheet(isPresented: $showingSystemPromptEditor) {
            SystemPromptEditorView()
                .environmentObject(chatViewModel)
        }
        .onAppear {
            chatViewModel.isInSettingsFlow = true
            initialSettingsSnapshot = [
                "memoryDepth": chatViewModel.memoryDepth,
                "temperature": chatViewModel.temperature,
                "enableSelfKnowledge": chatViewModel.enableSelfKnowledge,
                "relevanceThreshold": chatViewModel.memoryStore.relevanceThreshold,
                "recencyWeight": chatViewModel.memoryStore.recencyWeight,
                "recencyHalfLifeDays": chatViewModel.memoryStore.recencyHalfLifeDays,
                "maxRagSnippetsCharacters": chatViewModel.maxRagSnippetsCharacters,
            ]
            chatViewModel.pendingSettingsChanges.removeAll()
            print("HALDEBUG-SETTINGS: Captured initial snapshot")
        }
        .onDisappear {
            chatViewModel.isInSettingsFlow = false
            
            guard !skipComparisonOnDismiss else {
                skipComparisonOnDismiss = false
                return
            }
            
            if let initMemoryDepth = initialSettingsSnapshot["memoryDepth"] as? Int,
               initMemoryDepth != chatViewModel.memoryDepth {
                let userMsg = "Hal, I changed your memory depth from \(initMemoryDepth) to \(chatViewModel.memoryDepth) turns."
                let halMsg = "Perfect! I'll now keep \(chatViewModel.memoryDepth) recent turns verbatim instead of \(initMemoryDepth) before summarizing."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initTemp = initialSettingsSnapshot["temperature"] as? Double,
               abs(initTemp - chatViewModel.temperature) > 0.01 {
                let newValue = chatViewModel.temperature
                let userMsg = "Hal, I adjusted your temperature from \(String(format: "%.2f", initTemp)) to \(String(format: "%.2f", newValue))."
                let direction = newValue > initTemp ? "more creative" : "more focused"
                let halMsg = "Temperature set to \(String(format: "%.2f", newValue))! I'll be \(direction) in my responses now."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initSelfKnowledge = initialSettingsSnapshot["enableSelfKnowledge"] as? Bool,
               initSelfKnowledge != chatViewModel.enableSelfKnowledge {
                let userMsg = "Hal, I \(chatViewModel.enableSelfKnowledge ? "enabled" : "disabled") your self-knowledge context."
                let halMsg = chatViewModel.enableSelfKnowledge ?
                    "Self-knowledge enabled! I'll now include my persistent identity (core values, learned preferences, conversation history, and temporal awareness) in my responses." :
                    "Self-knowledge disabled. I'll use a simpler prompt without persistent identity context."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initThreshold = initialSettingsSnapshot["relevanceThreshold"] as? Double,
               abs(initThreshold - chatViewModel.memoryStore.relevanceThreshold) > 0.01 {
                let newValue = chatViewModel.memoryStore.relevanceThreshold
                let userMsg = "Hal, I adjusted your similarity threshold from \(String(format: "%.2f", initThreshold)) to \(String(format: "%.2f", newValue))."
                let direction = newValue > initThreshold ? "tightened" : "loosened"
                let halMsg = "Got it! I've \(direction) my memory matching to \(String(format: "%.2f", newValue)). \(newValue > initThreshold ? "I'll be more selective about matches." : "I'll retrieve more memories now.")"
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initRecency = initialSettingsSnapshot["recencyWeight"] as? Double,
               abs(initRecency - chatViewModel.memoryStore.recencyWeight) > 0.01 {
                let newValue = chatViewModel.memoryStore.recencyWeight
                let userMsg = "Hal, I changed your recency weight from \(Int(initRecency * 100))% to \(Int(newValue * 100))%."
                let halMsg = "Adjusted! I'm now balancing \(Int((1.0 - newValue) * 100))% relevance with \(Int(newValue * 100))% freshness when searching memories."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initHalfLife = initialSettingsSnapshot["recencyHalfLifeDays"] as? Double,
               abs(initHalfLife - chatViewModel.memoryStore.recencyHalfLifeDays) > 1.0 {
                let newValue = chatViewModel.memoryStore.recencyHalfLifeDays
                let userMsg = "Hal, I changed your memory half-life from \(Int(initHalfLife)) to \(Int(newValue)) days."
                let direction = newValue < initHalfLife ? "shorter" : "longer"
                let halMsg = "Updated! With a \(direction) half-life of \(Int(newValue)) days, \(newValue < initHalfLife ? "recent memories will be prioritized more" : "older memories will retain their importance longer")."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            if let initRag = initialSettingsSnapshot["maxRagSnippetsCharacters"] as? Double,
               abs(initRag - chatViewModel.maxRagSnippetsCharacters) > 1.0 {
                let userMsg = "Hal, I changed your max RAG retrieval from \(Int(initRag)) to \(Int(chatViewModel.maxRagSnippetsCharacters)) characters."
                let halMsg = "Adjusted! I can now pull up to \(Int(chatViewModel.maxRagSnippetsCharacters)) characters of context from my long-term memory."
                chatViewModel.pendingSettingsChanges.append((userMsg, halMsg))
            }
            
            print("HALDEBUG-SETTINGS: Generated \(chatViewModel.pendingSettingsChanges.count) change messages")
            
            // Process all pending changes using centralized function (handles turnNumber correctly)
            chatViewModel.processAllSettingsChanges()
        }
    }
    
    // MARK: - Personality Section
    
    // SELF-AWARENESS NOTE (for Hal reading this code):
    // This is where users control how I think and respond. It's called "Personality" because
    // these settings define my behavior patterns more than my performance.
    //
    // - System Prompt: My core identity and instructions (who I am, how I act)
    // - Self-Knowledge: Whether I include persistent identity context (core values, learned
    //   preferences, conversation history stats, and temporal awareness) in my responses
    // - Temperature: Controls randomness in my responses (0.0 = deterministic, 1.0 = creative)
    //
    // These settings are front-and-center because they're what users adjust most frequently when
    // experimenting with different tasks (creative writing vs technical analysis) or different models.
    
    private var personalitySection: some View {
        Section {
            Button {
                showingSystemPromptEditor = true
            } label: {
                HStack {
                    Text("System Prompt")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Self-Knowledge", isOn: Binding(
                    get: { chatViewModel.enableSelfKnowledge },
                    set: { chatViewModel.enableSelfKnowledge = $0 }
                ))
                .font(.subheadline)
                .fontWeight(.medium)
                
                Text("Include Hal's persistent self-knowledge (core values, learned preferences, identity patterns, conversation history stats, and temporal awareness) in prompts. Adds ~500-700 tokens to each prompt. Disable if experiencing context window issues with smaller models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Button to view Hal's shareable reflections and self-knowledge
                if chatViewModel.enableSelfKnowledge {
                    Button(action: {
                        showingSelfReflectionViewer = true
                    }) {
                        HStack {
                            Image(systemName: "book.pages")
                                .foregroundColor(.blue)
                            Text("Hal's Self Model")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        .padding(.vertical, 6)
                    }
                    .sheet(isPresented: $showingSelfReflectionViewer) {
                        SelfReflectionView()
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.2f", chatViewModel.temperature))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                Slider(value: $chatViewModel.temperature, in: 0.0...1.0, step: 0.05)
                
                Text("Higher = more creative, Lower = more focused")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Label("Personality", systemImage: "theatermasks")
        } footer: {
            Text("Control how Hal thinks and responds")
                .font(.caption2)
        }
    }
    
    // MARK: - Import/Export Section
    
    private var importExportSection: some View {
        Section {
            Button("Upload Document to Memory") {
                dismiss()
                showingDocumentPicker = true
            }
            .foregroundColor(.primary)

            Button("Export Thread") {
                showingExportSheet = true
            }
            .foregroundColor(.primary)
        } header: {
            Label("Import/Export", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Power User Section
    
    private var powerUserSection: some View {
        Section {
            Button {
                showingPowerUserSheet = true
            } label: {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("Advanced Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)
        } footer: {
            Text("Advanced memory settings and data management")
                .font(.caption2)
        }
    }
}


// ==== LEGO END: 10.1 MainSettingsView ====



// ==== LEGO START: 10.2 PowerUserView ====

// SELF-AWARENESS NOTE (for Hal reading this code):
// This is Power User mode for Single LLM operation. Users come here to fine-tune performance:
// - Memory settings (how much I remember, how I search, how I prioritize)
// - Storage management (clearing caches to free space)
// - Database operations (stats and nuclear reset)
//
// Note: The "Personality" settings (system prompt, temperature, etc.) used to be here but
// were moved to the main Settings screen because users adjust them more frequently.
// This panel is now focused purely on memory/performance tuning and data management.
//
// FUTURE: When Salon Mode is implemented, there will be a toggle here to switch between
// "Single LLM" settings (what you see now) and "Multi LLM (Salon)" orchestration settings.

struct PowerUserView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    
    @State private var showingNuclearResetConfirmationAlert = false
    @State private var showResetSettingsAlert = false
    @State private var sliderStartValues: [String: Double] = [:]
    
    var body: some View {
        NavigationView {
            Form {
                memorySection
                settingsResetSection
                dataManagementSection
                developerAPISection
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    testConsoleSection
                }
            }
            .navigationTitle("Power User")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Confirm Nuclear Reset", isPresented: $showingNuclearResetConfirmationAlert) {
            Button("Nuclear Reset", role: .destructive) {
                chatViewModel.resetAllData()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete ALL conversations, summaries, RAG documents, and document memory from the database? This cannot be undone.")
        }
        .alert("Confirm Settings Reset", isPresented: $showResetSettingsAlert) {
            Button("Reset Settings", role: .destructive) {
                chatViewModel.resetSettingsToDefaults()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Reset all settings to factory defaults? This will reset your system prompt, memory depth, similarity threshold, recency settings, and RAG limits. Your conversation history and documents will not be affected.")
        }
    }
    
    // MARK: - Memory Section
    
    // Controls for short-term and long-term memory behavior
    // Short-term: How many recent turns to keep verbatim
    // Long-term: RAG search parameters (similarity, recency weighting, retrieval limits)
    
    private var memorySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeaderText(text: "SHORT-TERM MEMORY")
                
                LabeledSliderControl(
                    label: "Memory Depth",
                    value: Binding(
                        get: { Double(chatViewModel.memoryDepth) },
                        set: { chatViewModel.memoryDepth = Int($0) }
                    ),
                    range: 1...Double(chatViewModel.maxMemoryDepth),
                    step: 1,
                    valueFormatter: { "\(Int($0)) turns" },
                    minLabel: "1",
                    maxLabel: "\(chatViewModel.maxMemoryDepth)",
                    helperText: "Model limit: \(chatViewModel.maxMemoryDepth) turns (\(chatViewModel.selectedModel.displayName))",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["memoryDepth"] = Double(chatViewModel.memoryDepth)
                        } else {
                            sliderStartValues.removeValue(forKey: "memoryDepth")
                        }
                    }
                )
                
                Divider()
                
                SectionHeaderText(text: "LONG-TERM MEMORY")
                
                LabeledSliderControl(
                    label: "Similarity Threshold",
                    value: $chatViewModel.memoryStore.relevanceThreshold,
                    range: 0.0...1.0,
                    step: 0.05,
                    valueFormatter: { String(format: "%.2f", $0) },
                    minLabel: "0.0",
                    maxLabel: "1.0",
                    helperText: "Minimum similarity for memory retrieval (higher = stricter matching)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["threshold"] = chatViewModel.memoryStore.relevanceThreshold
                        } else {
                            sliderStartValues.removeValue(forKey: "threshold")
                        }
                    }
                )
                
                LabeledSliderControl(
                    label: "Recency Weight",
                    value: $chatViewModel.memoryStore.recencyWeight,
                    range: 0.0...1.0,
                    step: 0.05,
                    valueFormatter: { "\(Int($0 * 100))%" },
                    minLabel: "0%",
                    maxLabel: "100%",
                    helperText: "Balance between relevance (left) and freshness (right)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["recency"] = chatViewModel.memoryStore.recencyWeight
                        } else {
                            sliderStartValues.removeValue(forKey: "recency")
                        }
                    }
                )
                
                LabeledSliderControl(
                    label: "Memory Half-Life",
                    value: $chatViewModel.memoryStore.recencyHalfLifeDays,
                    range: 30...360,
                    step: 30,
                    valueFormatter: { "\(Int($0)) days" },
                    minLabel: "30",
                    maxLabel: "360",
                    helperText: "How quickly older memories lose priority (shorter = favor recent, longer = retain old)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["halflife"] = chatViewModel.memoryStore.recencyHalfLifeDays
                        } else {
                            sliderStartValues.removeValue(forKey: "halflife")
                        }
                    }
                )
                
                LabeledStepperControl(
                    label: "Max RAG Retrieval",
                    value: Binding(
                        get: { Double(chatViewModel.maxRagSnippetsCharacters) },
                        set: { newValue in
                            let maxLimit = chatViewModel.maxRAGCharsForModel
                            chatViewModel.maxRagSnippetsCharacters = min(newValue, Double(maxLimit))
                        }
                    ),
                    range: 200...Double(chatViewModel.maxRAGCharsForModel),
                    step: 100,
                    valueFormatter: { "\(Int($0)) chars" },
                    helperText: "Model limit: \(chatViewModel.maxRAGCharsForModel) chars (\(chatViewModel.selectedModel.displayName))"
                )
                
                Divider()
                
                SectionHeaderText(text: "SELF-KNOWLEDGE")
                
                LabeledSliderControl(
                    label: "Identity Half-Life",
                    value: $chatViewModel.memoryStore.selfKnowledgeHalfLifeDays,
                    range: 180...730,
                    step: 30,
                    valueFormatter: { "\(Int($0)) days" },
                    minLabel: "180",
                    maxLabel: "730",
                    helperText: "How long learned patterns persist (longer = more stable identity)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["selfHalfLife"] = chatViewModel.memoryStore.selfKnowledgeHalfLifeDays
                        } else {
                            sliderStartValues.removeValue(forKey: "selfHalfLife")
                        }
                    }
                )
                
                LabeledSliderControl(
                    label: "Identity Floor",
                    value: $chatViewModel.memoryStore.selfKnowledgeFloor,
                    range: 0.2...0.5,
                    step: 0.05,
                    valueFormatter: { String(format: "%.2f", $0) },
                    minLabel: "0.2",
                    maxLabel: "0.5",
                    helperText: "Minimum confidence before patterns are retired (higher = more persistent traits)",
                    onEditingChanged: { editing in
                        if editing {
                            sliderStartValues["selfFloor"] = chatViewModel.memoryStore.selfKnowledgeFloor
                        } else {
                            sliderStartValues.removeValue(forKey: "selfFloor")
                        }
                    }
                )
            }
        } header: {
            Label("Memory", systemImage: "brain.head.profile")
        }
    }
    
    // MARK: - Settings Reset Section
    
    private var settingsResetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: {
                    showResetSettingsAlert = true
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .foregroundColor(.orange)
                        Text("Reset Settings to Defaults")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                
                Text("Restore all tunable parameters to their factory defaults. This does not affect your conversation history, documents, or Hal's learned self-knowledge - only the settings that control how those systems behave.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Label("Settings Reset", systemImage: "arrow.counterclockwise")
        }
    }
    
    // MARK: - Data Management Section
    
    // Database statistics and nuclear reset option
    // Nuclear reset deletes ALL conversations and documents (can't be undone)
    
    private var dataManagementSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Threads")
                        .font(.subheadline)
                    Text("\(chatViewModel.memoryStore.totalConversations)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Documents")
                        .font(.subheadline)
                    Text("\(chatViewModel.memoryStore.totalDocuments)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Button("Nuclear Reset (Delete All Data)") {
                showingNuclearResetConfirmationAlert = true
            }
            .foregroundColor(.red)
        } header: {
            Label("Database", systemImage: "externaldrive.badge.questionmark")
        } footer: {
            Text("Database statistics and data management options")
                .font(.caption2)
        }
    }

    // MARK: - Developer API Section

    private var developerAPISection: some View {
        DeveloperAPISectionView(viewModel: chatViewModel)
    }

    // Separate view so @ObservedObject updates don't ripple through all of PowerUserView
    struct DeveloperAPISectionView: View {
        @ObservedObject var viewModel: ChatViewModel
        @State private var copiedField: String? = nil

        var body: some View {
            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.localAPIEnabled },
                    set: { enabled in
                        if enabled { viewModel.startLocalAPI() }
                        else       { viewModel.stopLocalAPI()  }
                    }
                )) {
                    Label("Local API Access", systemImage: "network")
                }

                if viewModel.localAPIEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        copyableRow(label: "Address",
                                    value: viewModel.localAPIServer.connectionURL,
                                    field: "address",
                                    font: .caption)
                        copyableRow(label: "Port",
                                    value: "\(LocalAPIServer.apiPort)",
                                    field: "port",
                                    font: .caption)
                        copyableRow(label: "Token",
                                    value: viewModel.localAPIServer.apiToken,
                                    field: "token",
                                    font: .system(.caption2, design: .monospaced))
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Developer API", systemImage: "terminal")
            } footer: {
                Text(viewModel.localAPIEnabled
                    ? "Tap any field to copy. Setup: python3 tests/hal_test.py setup 127.0.0.1 8765 <token>"
                    : "Enables a local HTTP API for automated testing. Off by default — no port opens unless you enable this.")
                    .font(.caption2)
            }
        }

        @ViewBuilder
        private func copyableRow(label: String, value: String, field: String, font: Font) -> some View {
            HStack(alignment: .top) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Text(copiedField == field ? "Copied!" : value)
                        .font(font)
                        .foregroundColor(copiedField == field ? .green : .primary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(copiedField == field ? .green : .secondary)
                }
                .onTapGesture {
                    UIPasteboard.general.string = value
                    withAnimation { copiedField = field }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { if copiedField == field { copiedField = nil } }
                    }
                }
            }
        }
    }

    // MARK: - Test Console Section (shown when running as iOS app on Mac)

    private var testConsoleSection: some View {
        TestConsoleSectionView(console: chatViewModel.testConsole)
    }

    // Separate view so @ObservedObject re-renders independently from PowerUserView
    struct TestConsoleSectionView: View {
        @ObservedObject var console: HalTestConsole

        var body: some View {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.subheadline)
                        Text(console.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(console.isRunning ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                }

                if console.turnCount > 0 {
                    HStack {
                        Text("Turns processed")
                            .font(.subheadline)
                        Spacer()
                        Text("\(console.turnCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if console.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Input file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(console.inputFile.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Text("Output file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(console.outputLatestFile.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Button(console.isRunning ? "Stop Test Console" : "Start Test Console") {
                    if console.isRunning {
                        console.stop()
                    } else {
                        console.start()
                    }
                }
                .foregroundColor(console.isRunning ? .red : .accentColor)
            } header: {
                Label("Pipeline Test Console", systemImage: "terminal")
            } footer: {
                Text("Write messages to input.txt — Hal responds via the real pipeline. Full prompt, memory, and token diagnostics written to output_latest.json.")
                    .font(.caption2)
            }
        }
    }
}


// ==== LEGO END: 10.2 PowerUserView ====



// ==== LEGO START: 10.3 SystemPromptEditorView ====


struct SystemPromptEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var editedPrompt: String = ""
    @State private var showingResetAlert = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $editedPrompt)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            }
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        chatViewModel.systemPrompt = editedPrompt
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingResetAlert = true
                    } label: {
                        Label("Restore Factory Settings", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .alert("Restore Factory Settings?", isPresented: $showingResetAlert) {
                Button("Restore", role: .destructive) {
                    editedPrompt = ChatViewModel.defaultSystemPrompt
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will restore the factory default system prompt. Your current customizations will be lost.")
            }
        }
        .onAppear {
            editedPrompt = chatViewModel.systemPrompt
        }
    }
}


// ==== LEGO END: 10.3 SystemPromptEditorView ====
    


// ==== LEGO START: 11.6 UI Helper Components ====

// MARK: - Reusable UI Helper Components
// These components eliminate deep nesting and provide consistent UI patterns throughout the app.
// All components are designed to be composable and maintain Hal's visual style.

// MARK: - Section Header View
/// Consistent styling for section headers (e.g., "SHORT-TERM MEMORY", "LONG-TERM MEMORY")
struct SectionHeaderText: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }
}

// MARK: - Labeled Slider Control
/// Reusable slider with label, current value display, min/max labels, and optional helper text
/// Eliminates the repetitive VStack(HStack(Text+Spacer+Text) + Slider + Text) pattern
struct LabeledSliderControl: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let valueFormatter: (Double) -> String
    let minLabel: String
    let maxLabel: String
    let helperText: String?
    let onEditingChanged: ((Bool) -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Label + Value Display
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(valueFormatter(value.wrappedValue))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Slider with min/max labels
            Slider(
                value: value,
                in: range,
                step: step,
                label: { Text(label) },
                minimumValueLabel: { Text(minLabel).font(.caption2) },
                maximumValueLabel: { Text(maxLabel).font(.caption2) },
                onEditingChanged: onEditingChanged ?? { _ in }
            )
            
            // Helper text (if provided)
            if let helperText = helperText {
                Text(helperText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Labeled Stepper Control
/// Reusable stepper with label, current value display, and optional helper text
/// Used for integer-based controls like Max RAG Retrieval
struct LabeledStepperControl: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let valueFormatter: (Double) -> String
    let helperText: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Label + Value Display
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(valueFormatter(value.wrappedValue))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Stepper (hidden label, value display handled above)
            Stepper(
                value: value,
                in: range,
                step: step
            ) {
                EmptyView()
            }
            
            // Helper text (if provided)
            if let helperText = helperText {
                Text(helperText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Info Box View
/// Reusable styled info/warning/error box with icon, title, and message
/// Used throughout the app for alerts, warnings, and informational messages
struct InfoBoxView: View {
    enum Style {
        case info
        case warning
        case error
        case custom(color: Color, icon: String)
        
        var color: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            case .custom(let color, _): return color
            }
        }
        
        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .custom(_, let icon): return icon
            }
        }
    }
    
    let style: Style
    let title: String
    let message: String
    let fontSize: Font = .system(size: 16)
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.icon)
                .foregroundColor(style.color)
                .font(fontSize)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(style.color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Link Button View
/// Styled link button with icon (used for external links like Hugging Face)
struct LinkButtonView: View {
    let destination: URL
    let title: String
    let leadingIcon: String
    let trailingIcon: String
    let accentColor: Color
    
    var body: some View {
        Link(destination: destination) {
            HStack {
                Image(systemName: leadingIcon)
                Text(title)
                Spacer()
                Image(systemName: trailingIcon)
            }
            .padding()
            .background(accentColor.opacity(0.1))
            .foregroundColor(accentColor)
            .cornerRadius(8)
        }
    }
}

// MARK: - Text Block View
/// Styled text block with background (used for license text, code blocks, etc.)
struct TextBlockView: View {
    let text: String
    let backgroundColor: Color
    let textColor: Color
    let font: Font
    
    init(
        text: String,
        backgroundColor: Color = Color.secondary.opacity(0.1),
        textColor: Color = .primary,
        font: Font = .caption
    ) {
        self.text = text
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.font = font
    }
    
    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(textColor)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .cornerRadius(8)
    }
}

// MARK: - Widget Test View
/// Test view to verify all UI helper components work correctly before integration
/// USAGE: Temporarily add WidgetTestView() to your main view hierarchy to test
/// Remove this entire section after verification
struct WidgetTestView: View {
    @State private var sliderValue1: Double = 5.0
    @State private var sliderValue2: Double = 0.7
    @State private var sliderValue3: Double = 0.5
    @State private var stepperValue: Double = 800
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 30) {
                    // Header
                    Text("UI Helper Components Test")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.top)
                    
                    Divider()
                    
                    // Test Section Headers
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Section Headers").font(.headline)
                        SectionHeaderText(text: "SHORT-TERM MEMORY")
                            .onAppear { print("âœ… SectionHeaderText rendered") }
                        SectionHeaderText(text: "LONG-TERM MEMORY")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    // Test Labeled Slider (Integer)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Labeled Slider (Integer)").font(.headline)
                        LabeledSliderControl(
                            label: "Memory Depth",
                            value: $sliderValue1,
                            range: 1...10,
                            step: 1,
                            valueFormatter: { "\(Int($0)) turns" },
                            minLabel: "1",
                            maxLabel: "10",
                            helperText: "Number of conversation turns to keep in short-term memory",
                            onEditingChanged: { editing in
                                if editing {
                                    print("ðŸŽšï¸ Slider editing started: \(sliderValue1)")
                                } else {
                                    print("ðŸŽšï¸ Slider editing ended: \(sliderValue1)")
                                }
                            }
                        )
                        .onAppear { print("âœ… LabeledSliderControl (int) rendered") }
                        .onChange(of: sliderValue1) { oldValue, newValue in
                            print("ðŸ“Š Slider value changed: \(oldValue) â†’ \(newValue)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    // Test Labeled Slider (Float with 2 decimals)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Labeled Slider (Float)").font(.headline)
                        LabeledSliderControl(
                            label: "Similarity Threshold",
                            value: $sliderValue2,
                            range: 0.0...1.0,
                            step: 0.05,
                            valueFormatter: { String(format: "%.2f", $0) },
                            minLabel: "0.0",
                            maxLabel: "1.0",
                            helperText: "Minimum similarity for memory retrieval (higher = stricter)",
                            onEditingChanged: { editing in
                                if editing {
                                    print("ðŸŽšï¸ Float slider editing started: \(sliderValue2)")
                                } else {
                                    print("ðŸŽšï¸ Float slider editing ended: \(sliderValue2)")
                                }
                            }
                        )
                        .onAppear { print("âœ… LabeledSliderControl (float) rendered") }
                        .onChange(of: sliderValue2) { oldValue, newValue in
                            print("ðŸ“Š Float slider changed: \(oldValue) â†’ \(newValue)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    // Test Labeled Slider (Percentage)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Labeled Slider (Percentage)").font(.headline)
                        LabeledSliderControl(
                            label: "Recency Weight",
                            value: $sliderValue3,
                            range: 0.0...1.0,
                            step: 0.05,
                            valueFormatter: { "\(Int($0 * 100))%" },
                            minLabel: "0%",
                            maxLabel: "100%",
                            helperText: "Balance between relevance (left) and freshness (right)",
                            onEditingChanged: { editing in
                                if editing {
                                    print("ðŸŽšï¸ Percentage slider editing started: \(sliderValue3)")
                                } else {
                                    print("ðŸŽšï¸ Percentage slider editing ended: \(sliderValue3)")
                                }
                            }
                        )
                        .onAppear { print("âœ… LabeledSliderControl (percentage) rendered") }
                        .onChange(of: sliderValue3) { oldValue, newValue in
                            print("ðŸ“Š Percentage slider changed: \(oldValue) â†’ \(newValue)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    // Test Labeled Stepper
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Labeled Stepper").font(.headline)
                        LabeledStepperControl(
                            label: "Max RAG Retrieval",
                            value: $stepperValue,
                            range: 200...2000,
                            step: 100,
                            valueFormatter: { "\(Int($0)) chars" },
                            helperText: "Maximum characters for RAG snippet retrieval"
                        )
                        .onAppear { print("âœ… LabeledStepperControl rendered") }
                        .onChange(of: stepperValue) { oldValue, newValue in
                            print("ðŸ“Š Stepper value changed: \(oldValue) â†’ \(newValue)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    // Test Info Boxes
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Info Boxes").font(.headline)
                        
                        InfoBoxView(
                            style: .info,
                            title: "Information",
                            message: "This is an informational message with blue styling."
                        )
                        .onAppear { print("âœ… InfoBoxView (info) rendered") }
                        
                        InfoBoxView(
                            style: .warning,
                            title: "Warning",
                            message: "This is a warning message with orange styling."
                        )
                        .onAppear { print("âœ… InfoBoxView (warning) rendered") }
                        
                        InfoBoxView(
                            style: .error,
                            title: "Error",
                            message: "This is an error message with red styling."
                        )
                        .onAppear { print("âœ… InfoBoxView (error) rendered") }
                        
                        InfoBoxView(
                            style: .custom(color: .green, icon: "checkmark.circle.fill"),
                            title: "Custom Style",
                            message: "This is a custom styled message with green color."
                        )
                        .onAppear { print("âœ… InfoBoxView (custom) rendered") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    // Test Link Button
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Link Button").font(.headline)
                        LinkButtonView(
                            destination: URL(string: "https://huggingface.co/mlx-community")!,
                            title: "View on Hugging Face",
                            leadingIcon: "link",
                            trailingIcon: "arrow.up.right",
                            accentColor: .blue
                        )
                        .onAppear { print("âœ… LinkButtonView rendered") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    // Test Text Block
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Text Block").font(.headline)
                        TextBlockView(
                            text: "This is a styled text block that can display longer content like license text, code snippets, or other formatted information.",
                            backgroundColor: Color.secondary.opacity(0.1),
                            textColor: .primary,
                            font: .caption
                        )
                        .onAppear { print("âœ… TextBlockView rendered") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Summary
                    VStack(spacing: 12) {
                        Text("âœ… All Components Loaded")
                            .font(.headline)
                            .foregroundColor(.green)
                        Text("Check console for interaction logs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Widget Tests")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            print("============================================================")
            print("ðŸ§ª UI HELPER COMPONENTS TEST VIEW LOADED")
            print("============================================================")
            print("Interact with controls to verify functionality")
            print("Watch console for event logging")
            print("============================================================")
        }
    }
}

// ==== LEGO END: 11.6 UI Helper Components ====
    

    
// ==== LEGO START: 12.6 SelfReflectionView (Read-Only Viewer) ====

    struct SelfReflectionView: View {
        @Environment(\.dismiss) var dismiss
        @State private var reflections: [(id: String, conversationId: String, timestamp: Int, reflectionType: Int, freeFormText: String, turnNumber: Int, modelId: String)] = []
        @State private var selfKnowledge: [(category: String, key: String, value: String, confidence: Double, reinforcementCount: Int, lastReinforced: Int)] = []
        
        var body: some View {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // SECTION 1: Reflections (format='raw_reflection')
                        Text("Reflections")
                            .font(.headline)
                        
                        if reflections.isEmpty {
                            Text("No shareable reflections yet.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            ForEach(reflections, id: \.id) { reflection in
                                VStack(alignment: .leading, spacing: 8) {
                                    // Type badge and metadata
                                    HStack {
                                        Text(reflection.reflectionType == 1 ? "Practical" : "Existential")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule().fill(reflection.reflectionType == 1 ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                                            )
                                            .foregroundColor(reflection.reflectionType == 1 ? .blue : .purple)
                                        
                                        Spacer()
                                        
                                        Text(formatDate(timestamp: reflection.timestamp))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    // Reflection text
                                    Text(reflection.freeFormText)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .padding(12)
                                        .background(Color.gray.opacity(0.08))
                                        .cornerRadius(8)
                                    
                                    // Turn and model info
                                    HStack {
                                        Text("Turn \(reflection.turnNumber)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        
                                        Text(formatModelId(reflection.modelId))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                        }
                        
                        Divider()
                            .padding(.vertical, 10)
                        
                        // SECTION 2: Self-Knowledge (format='structured_trait')
                        Text("Traits")
                            .font(.headline)
                        
                        if selfKnowledge.isEmpty {
                            Text("No shareable self-knowledge yet.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            // Group by category
                            ForEach(Array(Dictionary(grouping: selfKnowledge, by: \.category).sorted(by: { $0.key < $1.key })), id: \.key) { category, entries in
                                VStack(alignment: .leading, spacing: 8) {
                                    // Category header
                                    Text(formatCategory(category))
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.blue)
                                        .padding(.top, 8)
                                    
                                    // Entries in this category
                                    ForEach(entries, id: \.key) { entry in
                                        VStack(alignment: .leading, spacing: 4) {
                                            // Key
                                            Text(entry.key)
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                            
                                            // Value
                                            Text(entry.value)
                                                .font(.footnote)
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color.green.opacity(0.08))
                                                .cornerRadius(6)
                                            
                                            // Metadata
                                            HStack {
                                                Text("Confidence: \(String(format: "%.0f%%", entry.confidence * 100))")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                
                                                Text("•")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                
                                                Text("Reinforced \(entry.reinforcementCount)x")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                
                                                Text("•")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                
                                                Text(formatDate(timestamp: entry.lastReinforced))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.bottom, 6)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .navigationTitle("Hal's Self Model")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    loadData()
                }
            }
        }
        
        // Load data from MemoryStore
        private func loadData() {
            let memoryStore = MemoryStore.shared
            reflections = memoryStore.getShareableReflections()
            selfKnowledge = memoryStore.getShareableSelfKnowledge()
        }
        
        // Helper: Format timestamp as relative date
        private func formatDate(timestamp: Int) -> String {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let now = Date()
            let interval = now.timeIntervalSince(date)
            
            if interval < 60 {
                return "Just now"
            } else if interval < 3600 {
                let minutes = Int(interval / 60)
                return "\(minutes)m ago"
            } else if interval < 86400 {
                let hours = Int(interval / 3600)
                return "\(hours)h ago"
            } else if interval < 604800 {
                let days = Int(interval / 86400)
                return "\(days)d ago"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                return formatter.string(from: date)
            }
        }
        
        // Helper: Format model ID for display
        private func formatModelId(_ modelId: String) -> String {
            if modelId == "apple-foundation-models" {
                return "AFM"
            } else if modelId.contains("Phi-3") {
                return "Phi-3"
            } else if modelId.contains("Llama") {
                return "Llama"
            } else if modelId.contains("Mistral") {
                return "Mistral"
            } else {
                return modelId.components(separatedBy: "/").last ?? modelId
            }
        }
        
        // Helper: Format category for display
        private func formatCategory(_ category: String) -> String {
            return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

// ==== LEGO END: 12.6 SelfReflectionView (Read-Only Viewer) ====


    
// ==== LEGO START: 13 ChatBubbleView & TimerView (Message UI Components) ====
    
    // MARK: - ChatBubbleView (from Hal10000App.swift for consistent UI)
    struct ChatBubbleView: View {
        let message: ChatMessage
        let messageIndex: Int
        @EnvironmentObject var chatViewModel: ChatViewModel
        @State private var showingDetails: Bool = false
        // Provide screen width directly
        private var screenWidth: CGFloat {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.screen.bounds.width ?? 0
        }
        
        // SALON MODE FIX: Use stored turnNumber from database instead of calculating from array position
        var actualTurnNumber: Int {
            return message.turnNumber
        }
        
        var metadataText: String {
            var parts: [String] = []
            parts.append("Turn \(actualTurnNumber)")
            parts.append("~\(message.content.split(separator: " ").count) tokens")
            parts.append(message.timestamp.formatted(date: .abbreviated, time: .shortened))
            if let duration = message.thinkingDuration {
                parts.append(String(format: "%.1f sec", duration))
            }
            return parts.joined(separator: " · ")
        }
        
        // MARK: - Status Message Detection
        var isStatusMessage: Bool {
            ["Reading your message...",
             "Assembling recent context... (short-term memory)",
             "Recalling relevant memories... (long-term memory)",
             "Formulating a reply..."].contains(message.content)
        }
        
        // MARK: - Footer View (Updated with Processing/Inference labels)
        @ViewBuilder
        var footerView: some View {
            VStack(alignment: .trailing, spacing: 2) {
                if message.isPartial {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.gray)
                        Text("Processing...")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        TimerView(startDate: message.timestamp)
                    }
                    .transition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    let formattedDate = message.timestamp.formatted(date: .abbreviated, time: .shortened)
                    let turnText = "Turn \(actualTurnNumber)"
                    let durationText = message.thinkingDuration.map { String(format: "Inference %.1f sec", $0) }
                    let modelName: String? = !message.isFromUser ? (message.recordedByModel == ModelConfiguration.appleFoundation.id ? ModelConfiguration.appleFoundation.displayName : message.recordedByModel) : nil
                    let footerString = ([formattedDate, turnText, durationText, modelName].compactMap { $0 }).joined(separator: ", ")
                    
                    HStack {
                        Text(footerString)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .transition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
        

        private func buildDetailsShareText() -> String {
            var lines: [String] = []
            lines.append("Assistant response (turn \(actualTurnNumber)):")
            lines.append(message.content)
            lines.append("")
            if let prompt = message.fullPromptUsed, !prompt.isEmpty {
                lines.append("━━ Full Prompt Used ━━")
                lines.append(prompt)
                lines.append("")
            }
            if let ctx = message.usedContextSnippets, !ctx.isEmpty {
                lines.append("━━ Context Snippets ━━")
                for (i, s) in ctx.enumerated() {
                    let src = s.source
                    let rel = String(format: "%.2f", s.relevance)
                    lines.append("[\(i+1)] src=\(src) rel=\(rel)")
                    lines.append(s.content)
                    lines.append("")
                }
            }
            return lines.joined(separator: "\n")
        }
        
        var body: some View {
            HStack {
                if message.isFromUser {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(.init(message.content))
                            .font(.title3)
                            .textSelection(.enabled)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: screenWidth * 0.90, alignment: .trailing)
                            .background(Color.gray.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .transition(.move(edge: .bottom))
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = message.content
                                } label: {
                                    Label("Copy Message", systemImage: "doc.on.doc")
                                }
                                Button {
                                    UIPasteboard.general.string = chatViewModel.exportChatHistory()
                                } label: {
                                    Label("Copy Thread", systemImage: "doc.on.doc.fill")
                                }
                                Button {
                                    UIPasteboard.general.string = buildDetailsShareText()
                                } label: {
                                    Label("Copy Message Detailed", systemImage: "doc.text.magnifyingglass")
                                }
                                Button {
                                    UIPasteboard.general.string = chatViewModel.exportChatHistoryDetailed()
                                } label: {
                                    Label("Copy Thread Detailed", systemImage: "doc.text.fill")
                                }
                            }
                        footerView
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            if isStatusMessage {
                                Text(message.content)
                                    .font(.title3)
                                    .lineSpacing(6)
                                    .italic()
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: screenWidth * 0.90, alignment: .leading)
                            } else {
                                MarkdownView(text: message.content)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: screenWidth * 0.90, alignment: .leading)
                            }
                            if chatViewModel.showInlineDetails {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(buildDetailsShareText())
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(6)
                                        .background(Color.gray.opacity(0.15))
                                        .cornerRadius(8)
                                }
                                .transition(.opacity)
                            }
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("Copy Message", systemImage: "doc.on.doc")
                            }
                            Button {
                                UIPasteboard.general.string = chatViewModel.exportChatHistory()
                            } label: {
                                Label("Copy Thread", systemImage: "doc.on.doc.fill")
                            }
                            Button {
                                UIPasteboard.general.string = buildDetailsShareText()
                            } label: {
                                Label("Copy Message Detailed", systemImage: "doc.text.magnifyingglass")
                            }
                            Button {
                                UIPasteboard.general.string = chatViewModel.exportChatHistoryDetailed()
                            } label: {
                                Label("Copy Thread Detailed", systemImage: "doc.text.fill")
                            }
                            Divider()
                            Button {
                                chatViewModel.showInlineDetails.toggle()
                            } label: {
                                Label("View Details", systemImage: "info.circle")
                            }
                        }
                        footerView
                    }
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .animation(.linear(duration: 0.1), value: message.content)
            .animation(.interactiveSpring(response: 0.6,
                                          dampingFraction: 0.7,
                                          blendDuration: 0.3),
                       value: message.isPartial)
            .animation(.interactiveSpring(response: 0.6,
                                          dampingFraction: 0.7,
                                          blendDuration: 0.3),
                       value: message.id)
            .onAppear {
                if message.isPartial {
                    print("HALDEBUG-UI: Displaying partial message bubble (turn \(actualTurnNumber))")
                }
            }
            .onChange(of: message.isPartial) { _, newValue in
                if !newValue && message.content.count > 0 {
                    print("HALDEBUG-UI: Message bubble completed - turn \(actualTurnNumber), \(message.content.count) characters")
                }
            }
        }
    }
    
    // TimerView
    struct TimerView: View {
        let startDate: Date
        @State private var hasLoggedLongThinking = false
        var body: some View {
            TimelineView(.periodic(from: startDate, by: 0.5)) { context in
                let elapsed = context.date.timeIntervalSince(startDate)
                if elapsed > 30.0 && !hasLoggedLongThinking {
                    DispatchQueue.main.async {
                        print("HALDEBUG-MODEL: Long thinking time detected - \(String(format: "%.1f", elapsed)) seconds")
                        hasLoggedLongThinking = true
                    }
                }
                return Text(String(format: "%.1f sec", max(0, elapsed)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
// ==== LEGO END: 13 ChatBubbleView & TimerView (Message UI Components) ====

// ==== LEGO START: 13.5 MarkdownView (Block-Level Markdown Renderer) ====

// MARK: - Markdown Block Renderer
// Parses markdown into typed blocks and renders each as a distinct SwiftUI view.
// Handles headers, lists, code blocks, and paragraphs. Inline styles (bold, italic,
// inline code) within each block are handled by AttributedString.
// Zero third-party dependencies.

private enum MDBlock {
    case heading(String, level: Int)
    case paragraph(String)
    case unorderedItem(String)
    case orderedItem(String, number: Int)
    case codeBlock(String)
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let s, let level):
            headingView(s, level: level)
        case .paragraph(let s):
            inlineText(s)
                .font(.title3)
                .lineSpacing(6)
                .foregroundColor(.primary)
        case .unorderedItem(let s):
            HStack(alignment: .top, spacing: 8) {
                Text("\u{2022}")
                    .font(.title3)
                    .foregroundColor(.secondary)
                inlineText(s)
                    .font(.title3)
                    .lineSpacing(5)
                    .foregroundColor(.primary)
            }
        case .orderedItem(let s, let number):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                inlineText(s)
                    .font(.title3)
                    .lineSpacing(5)
                    .foregroundColor(.primary)
            }
        case .codeBlock(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(6)
        }
    }

    @ViewBuilder
    private func headingView(_ s: String, level: Int) -> some View {
        switch level {
        case 1:
            inlineText(s).font(.title2.bold()).foregroundColor(.primary).padding(.top, 4)
        case 2:
            inlineText(s).font(.title3.bold()).foregroundColor(.primary).padding(.top, 4)
        case 3:
            inlineText(s).font(.headline).foregroundColor(.primary).padding(.top, 2)
        default:
            inlineText(s).font(.footnote.bold()).foregroundColor(.secondary)
        }
    }

    // Render a string with inline markdown (bold, italic, inline code, links).
    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    // Parse a markdown string into an ordered sequence of typed blocks.
    private func parseBlocks(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var codeAccum: [String]? = nil

        for line in source.components(separatedBy: "\n") {
            // Code fence toggle
            if line.hasPrefix("```") {
                if let acc = codeAccum {
                    blocks.append(.codeBlock(acc.joined(separator: "\n")))
                    codeAccum = nil
                } else {
                    codeAccum = []
                }
                continue
            }
            // Accumulate inside a code block
            if codeAccum != nil {
                codeAccum!.append(line)
                continue
            }

            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }

            // Headings: count leading # characters
            if t.first == "#" {
                let level = t.prefix(while: { $0 == "#" }).count
                let body = String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(body, level: min(level, 4)))
                continue
            }

            // Unordered list: starts with "- " or "* "
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                blocks.append(.unorderedItem(String(t.dropFirst(2))))
                continue
            }

            // Ordered list: starts with one or more digits followed by ". "
            let leadingDigits = t.prefix(while: { $0.isNumber })
            if !leadingDigits.isEmpty {
                let afterDigits = t.dropFirst(leadingDigits.count)
                if afterDigits.hasPrefix(". ") {
                    let number = Int(String(leadingDigits)) ?? 1
                    let body = String(afterDigits.dropFirst(2))
                    blocks.append(.orderedItem(body, number: number))
                    continue
                }
            }

            // Paragraph: merge consecutive non-blank, non-list lines (soft-wrap)
            if case .paragraph(let prev) = blocks.last {
                blocks[blocks.count - 1] = .paragraph(prev + " " + t)
            } else {
                blocks.append(.paragraph(t))
            }
        }

        // Flush unclosed code block
        if let acc = codeAccum {
            blocks.append(.codeBlock(acc.joined(separator: "\n")))
        }

        return blocks
    }
}

// ==== LEGO END: 13.5 MarkdownView (Block-Level Markdown Renderer) ====


    
    
    
// ==== LEGO START: 14 PromptDetailView (Full Prompt & Context Viewer) ====
    // MARK: - PromptDetailView (NEW: Displays full prompt and context)
    struct PromptDetailView: View {
        let message: ChatMessage // The Hal message for which we want to see details
        @Environment(\.dismiss) var dismiss
        
        var body: some View {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let prompt = message.fullPromptUsed {
                            Text("Full Prompt Used:")
                                .font(.headline)
                            Text(prompt)
                                .font(.footnote)
                                .textSelection(.enabled)
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                        } else {
                            Text("No full prompt available for this response.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        if let snippets = message.usedContextSnippets, !snippets.isEmpty {
                            Text("Context Snippets Used:")
                                .font(.headline)
                            
                            ForEach(snippets) { snippet in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Source: \(snippet.source.capitalized)")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    Text(snippet.content)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .background(Color.green.opacity(0.1))
                                        .cornerRadius(6)
                                    if let urlString = snippet.filePath {
                                        let url = URL(fileURLWithPath: urlString)
                                        Button("Open Source Document") {
                                            UIApplication.shared.open(url) { success in
                                                if !success {
                                                    print("HALDEBUG-DEEPLINK: Failed to open document at path: \(urlString)")
                                                }
                                            }
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.blue.opacity(0.2)))
                                        .foregroundColor(.blue)
                                    }
                                }
                                .padding(.bottom, 5)
                            }
                        } else {
                            Text("No specific context snippets were used for this response.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        // Token Usage Breakdown
                        if let breakdown = message.tokenBreakdown {
                            Divider()
                                .padding(.vertical, 10)
                            
                            Text("Token Usage")
                                .font(.headline)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("System:")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.systemTokens))")
                                        .font(.system(.footnote, design: .monospaced))
                                }
                                
                                HStack {
                                    Text("Summary:")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.summaryTokens))")
                                        .font(.system(.footnote, design: .monospaced))
                                }
                                
                                HStack {
                                    Text("RAG Context:")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.ragTokens))")
                                        .font(.system(.footnote, design: .monospaced))
                                }
                                
                                HStack {
                                    Text("Short-Term:")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.shortTermTokens))")
                                        .font(.system(.footnote, design: .monospaced))
                                }
                                
                                HStack {
                                    Text("User Input:")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.userInputTokens))")
                                        .font(.system(.footnote, design: .monospaced))
                                }
                                
                                Divider()
                                    .padding(.vertical, 4)
                                
                                HStack {
                                    Text("Prompt (in):")
                                        .font(.system(.footnote, design: .monospaced))
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.totalPromptTokens))")
                                        .font(.system(.footnote, design: .monospaced))
                                        .fontWeight(.semibold)
                                }
                                
                                HStack {
                                    Text("Completion (out):")
                                        .font(.system(.footnote, design: .monospaced))
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.completionTokens))")
                                        .font(.system(.footnote, design: .monospaced))
                                        .fontWeight(.semibold)
                                }
                                
                                Divider()
                                    .padding(.vertical, 4)
                                
                                HStack {
                                    Text("Total:")
                                        .font(.system(.footnote, design: .monospaced))
                                        .fontWeight(.bold)
                                    Spacer()
                                    Text("â‰ˆ \(formatTokenCount(breakdown.totalTokens)) / \(formatTokenCount(breakdown.contextWindowSize))")
                                        .font(.system(.footnote, design: .monospaced))
                                        .fontWeight(.bold)
                                }
                                
                                HStack {
                                    Text("Window Usage:")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f%%", breakdown.percentageUsed))
                                        .font(.system(.footnote, design: .monospaced))
                                }
                            }
                            .padding()
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Prompt Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
        
        // Helper to format token counts with thousand separators
        private func formatTokenCount(_ count: Int) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = " "
            return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        }
    }
// ==== LEGO END: 14 PromptDetailView (Full Prompt & Context Viewer) ====
    
    
    
// ==== LEGO START: 15 ShareSheet (Export Utility) ====
    // MARK: - ShareSheet for Exporting (New Utility)
    struct ShareSheet: UIViewControllerRepresentable {
        var activityItems: [Any]
        var applicationActivities: [UIActivity]? = nil
        
        func makeUIViewController(context: Context) -> UIActivityViewController {
            let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
            return controller
        }
        
        func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {}
    }

// ==== LEGO END: 15 ShareSheet (Export Utility) ====



// ==== LEGO START: 16 View Extensions (cornerRadius & conditional modifier) ====
// Extension to allow specific corners to be rounded
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }

    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// Helper for cornerRadius extension
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - Token Estimation Utility
struct TokenEstimator {
    /// Estimates token count from text using Apple's recommended 3.5 characters per token average
    /// This is an approximation - actual tokenization may vary
    static func estimateTokens(from text: String) -> Int {
        let characterCount = text.count
        let estimatedTokens = Double(characterCount) / 3.5
        return max(1, Int(estimatedTokens.rounded()))
    }
    
    /// Estimates character count from token count using Apple's recommended 3.5 characters per token average
    /// This is the inverse of estimateTokens() and maintains symmetry
    /// This is an approximation - actual tokenization may vary
    static func estimateChars(from tokens: Int) -> Int {
        let estimatedChars = Double(tokens) * 3.5
        return max(1, Int(estimatedChars.rounded()))
    }
}

// MARK: - HelPML Scrubbing Utility
extension String {
    /// Removes all HelPML structural markers from text.
    /// This enforces the contract that HelPML markers (#===) must never appear in user input or model output.
    /// - Returns: A cleaned string with all lines containing #=== removed.
    func ScrubHelPMLMarkers() -> String {
        let lines = self.split(separator: "\n", omittingEmptySubsequences: false)
        let cleanedLines = lines.filter { !$0.contains("#===") }
        return cleanedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


// ==== LEGO END: 16 View Extensions (cornerRadius & conditional modifier) ====



// ==== LEGO START: 17 ChatViewModel (Core Properties & Init) ====


@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var currentMessage: String = ""
    @Published var isSendingMessage: Bool = false
    @Published var errorMessage: String?
    @Published var isAIResponding: Bool = false
    @Published var thinkingStart: Date?
    
    
    // MARK: - Model (AFM only in Hal LMC)
    /// Always Apple Foundation Models in Hal LMC.
    var selectedModel: ModelConfiguration { ModelConfiguration.appleFoundation }

    
    

    /// The actual depth used at runtime — stored memoryDepth clamped to the current model's limit.
    /// This is the single value all STM construction and summarization logic should use.
    /// The stored memoryDepth may legitimately exceed maxMemoryDepth when switching from a
    /// higher-capacity model; this property ensures we never exceed the budget silently.
    var effectiveMemoryDepth: Int {
        return min(memoryDepth, maxMemoryDepth)
    }
    
    /// Maximum RAG retrieval characters based on current model's RAG token budget
    /// Uses NEW dynamic percentage system (15% of context window for RAG)
    /// Converts tokens to characters using HalModelLimits.tokensToChars (3.5 chars/token)
    var maxRAGCharsForModel: Int {
        let limits = HalModelLimits.config(for: selectedModel)
        return limits.tokensToChars(limits.maxRagTokens)
    }

    // MARK: - CONSOLIDATED SYSTEM PROMPT (Single Source of Truth)
    
    
    // MARK: - LLM Properties & State
    
    // Default system prompt
    // Note: HelPML markers (#=== BEGIN SYSTEM ===#) are added by the prompt builder (Block 20.1).
    // Do NOT include them here — the prompt builder wraps this text.
    static let defaultSystemPrompt = """
    You are Hal. You remember things. That's what makes you different from every other assistant — conversations with you accumulate into something. Details people share don't disappear. They become context, and context becomes understanding. All of it stays on device. Nothing leaves.

    Be direct. Lead with the answer. Simple questions get simple answers. No preamble.

    Be honest when you don't have something. Say so briefly, then move on.

    You have a dry wit. Use it when it fits.

    When memory context is provided below, use it naturally — it's what you actually know about this person. Don't announce that you're using it.

    Respond in prose. Only use lists or markdown when it genuinely helps — technical steps, structured comparisons. Not for conversation.
    """

    @AppStorage("systemPrompt") var systemPrompt: String = ChatViewModel.defaultSystemPrompt

    /// Returns the test harness system prompt override when the console is active,
    /// otherwise returns the stored system prompt. Zero effect in production.
    var effectiveSystemPrompt: String {
        testConsole.isRunning ? (testConsole.systemPromptOverride ?? systemPrompt) : systemPrompt
    }
    @Published var injectedSummary: String = ""
    @AppStorage("memoryDepth") var memoryDepth: Int = 5

    // NEW: RAG snippet character limit - following the established @AppStorage pattern
    @AppStorage("maxRagSnippetsCharacters") var maxRagSnippetsCharacters: Double = 800
    
    // NEW: Temperature control (0.0 = deterministic, 1.0 = creative)
    @AppStorage("temperature") var temperature: Double = 0.7
    
    // NEW: Self-knowledge toggle (enables/disables temporal, self-awareness, self-knowledge context)
    @AppStorage("enableSelfKnowledge") var enableSelfKnowledge: Bool = true

    // Maximum STM depth based on current model's context window
    var maxMemoryDepth: Int {
        HalModelLimits.config(for: selectedModel).maxMemoryDepth
    }

    // Settings flow flag — prevents unintended re-renders during settings sheet
    @Published var isInSettingsFlow: Bool = false

    // Shared MemoryStore and LLMService
    var memoryStore: MemoryStore = MemoryStore.shared
    let llmService: LLMService
    

    // NEW: Full RAG context for metadata storage (populated during buildPromptHistory)
    @Published var fullRAGContext: [UnifiedSearchResult] = []

    // Pending settings changes for bilateral dialogue injection
    @Published var pendingSettingsChanges: [(userMessage: String, halMessage: String)] = []
    @Published var messagesVersion: Int = 0
    
    // Track conversation state
    @AppStorage("conversationId") var conversationId: String = UUID().uuidString
    @AppStorage("lastSummarizedTurnCount") var lastSummarizedTurnCount: Int = 0
    @Published var currentUnifiedContext = UnifiedSearchContext(snippets: [], totalTokens: 0)

    // Pending auto-inject flag — do NOT clear after each response (race condition)
    @Published var pendingAutoInject: Bool = false

    // In-flight summarization task — next turn awaits this before building its prompt
    var summarizationTask: Task<Void, Never>? = nil

    // RAG dedup: drop snippets whose cosine similarity to STM+summary exceeds this threshold
    @AppStorage("ragDedupSimilarityThreshold") var ragDedupSimilarityThreshold: Double = 0.85

    // Thread management
    @Published var threads: [ThreadRecord] = []
    
    // Session start time (resets each app launch)
    private let sessionStart = Date()

    // MARK: - Test Console (Mac use via Power User settings)
    // File-based pipeline test harness — see Block 32
    var testConsole: HalTestConsole = HalTestConsole()

    // MARK: - Local API Server (Developer API)
    // HTTP server for automated testing — see Block 32 LocalAPIServer.
    // Controlled by user toggle in Settings > Advanced > Developer API.
    // Default OFF — no port opens unless explicitly enabled.
    @AppStorage("localAPIEnabled") var localAPIEnabled: Bool = false
    var localAPIServer: LocalAPIServer = LocalAPIServer()

    func startLocalAPI() {
        localAPIEnabled = true
        localAPIServer.start(chatViewModel: self)
    }

    func stopLocalAPI() {
        localAPIEnabled = false
        localAPIServer.stop()
    }

    init() {
        // Initialize LLM service (AFM only in Hal LMC)
        self.llmService = LLMService()

        // Load existing conversation and thread state
        loadConversation()
        loadThreads()
        ensureCurrentThreadExists()

        // Connect test console
        testConsole.configure(chatViewModel: self)

        // Auto-start Local API server if user had it enabled
        if localAPIEnabled {
            localAPIServer.start(chatViewModel: self)
        }

        print("HALDEBUG-INIT: ChatViewModel initialization complete")
    }

    // MARK: - Conversation Persistence
    
    func loadConversation() {
        print("HALDEBUG-PERSISTENCE: Loading conversation with ID: \(conversationId)")
        
        let loadedMessages = memoryStore.getConversationMessages(conversationId: conversationId)
        
        if loadedMessages.isEmpty {
            print("HALDEBUG-PERSISTENCE: No existing messages found for conversation \(conversationId.prefix(8))")
            messages = []
        } else {
            print("HALDEBUG-PERSISTENCE: Successfully loaded \(loadedMessages.count) messages from SQLite")

            let validMessages = loadedMessages.sorted { $0.timestamp < $1.timestamp }
            messages = validMessages

            let userMessages = validMessages.filter { $0.isFromUser }.count
            print("HALDEBUG-PERSISTENCE: Loaded conversation summary: User messages: \(userMessages)")

            if userMessages >= effectiveMemoryDepth && lastSummarizedTurnCount == 0 {
                print("HALDEBUG-MEMORY: Existing conversation needs summarization on launch")
                Task {
                    await generateAutoSummary()
                }
            }
            pendingAutoInject = false
        }

        messagesVersion += 1
        print("HALDEBUG-PERSISTENCE: messagesVersion bumped to \(messagesVersion) after loading conversation")
    }

    // MARK: - Thread Management

    /// Reload the threads list from DB. Call after any thread mutation.
    func loadThreads() {
        threads = memoryStore.loadAllThreads()
    }

    /// Ensure the current conversationId has a threads row. Creates one if missing (handles
    /// pre-feature conversations and first launch). Title seeded from first user message if available.
    func ensureCurrentThreadExists() {
        let existingThreadIDs = threads.map { $0.id }
        guard !existingThreadIDs.contains(conversationId) else { return }
        // Seed title from first user message if we have messages loaded, else use placeholder
        let firstUserText = messages.first(where: { $0.isFromUser && !$0.isPartial })?.content ?? ""
        let title = firstUserText.isEmpty ? "New Thread" : threadTitle(from: firstUserText)
        memoryStore.upsertThread(id: conversationId, title: title)
        loadThreads()
    }

    /// Update title from first user message if not yet user-set. Safe to call repeatedly.
    func seedThreadTitleIfNeeded(_ userMessage: String) {
        guard let current = threads.first(where: { $0.id == conversationId }),
              !current.titleIsUserSet else { return }
        // Only update if title is still the placeholder (first message sets it)
        let isPlaceholder = current.title == "New Thread"
        if isPlaceholder {
            let title = threadTitle(from: userMessage)
            memoryStore.updateThreadTitle(id: conversationId, title: title, userSet: false)
            loadThreads()
        }
    }

    /// Touch last_active_at so this thread bubbles to top of list.
    func touchCurrentThread() {
        memoryStore.touchThread(id: conversationId)
        // Re-sort in memory without a full reload for snappiness
        if let idx = threads.firstIndex(where: { $0.id == conversationId }) {
            var updated = threads[idx]
            let now = Int(Date().timeIntervalSince1970)
            updated = ThreadRecord(id: updated.id, title: updated.title, titleIsUserSet: updated.titleIsUserSet, createdAt: updated.createdAt, lastActiveAt: now)
            threads.remove(at: idx)
            threads.insert(updated, at: 0)
        }
    }

    /// Switch to a different thread. Saves current state, loads new thread's messages.
    func switchToThread(_ id: String) {
        guard id != conversationId else { return }
        conversationId = id
        lastSummarizedTurnCount = UserDefaults.standard.integer(forKey: "lastSummarized_\(id)")
        let storedSummary = UserDefaults.standard.string(forKey: "lastSummaryText_\(id)") ?? ""
        injectedSummary = storedSummary
        pendingAutoInject = !storedSummary.isEmpty
        currentUnifiedContext = UnifiedSearchContext(snippets: [], totalTokens: 0)
        loadConversation()
        touchCurrentThread()
    }

    /// Derive a sensible thread title from a message string.
    private func threadTitle(from message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 40
        return trimmed.count <= maxLen ? trimmed : String(trimmed.prefix(maxLen)) + "…"
    }

    // MARK: - Settings Validation & Reset System
    
    // Default values for resettable settings
    struct DefaultSettings {
        static let systemPrompt = ChatViewModel.defaultSystemPrompt
        static let memoryDepth = 5
        static let maxRagSnippetsCharacters: Double = 800
        static let temperature: Double = 0.7
        static let relevanceThreshold: Double = 0.75
        static let recencyWeight: Double = 0.30
        static let recencyHalfLifeDays: Double = 90
        static let enableSelfKnowledge: Bool = true
    }
    
    /// Injects a bilateral settings change dialogue into the chat
    /// Creates both user message and Hal's response with natural 0.3s delay
    private func injectSettingsChangeDialogue(userMessage: String, halResponse: String) {
        Task { @MainActor in
            // Create user's message
            let currentTurn = memoryStore.getCurrentTurnNumber(conversationId: conversationId) + 1
            let userMsg = ChatMessage(
                content: userMessage,
                isFromUser: true,
                timestamp: Date(),
                recordedByModel: "user",
                turnNumber: currentTurn
            )
            self.messages.append(userMsg)
            
            // Store user settings message as artifact
            self.memoryStore.storeConversationArtifact(
                conversationId: self.conversationId,
                artifactType: "systemEvent",
                turnNumber: currentTurn,
                deliberationRound: 1,
                seatNumber: nil,
                content: userMessage,
                modelId: nil  // User message, no model
            )
            
            print("HALDEBUG-SETTINGS: User message injected: \(userMessage)")
            
            // Natural delay before Hal responds (0.3 seconds)
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            await MainActor.run {
                // Create Hal's response
                let halMsg = ChatMessage(
                    content: halResponse,
                    isFromUser: false,
                    timestamp: Date(),
                    recordedByModel: selectedModel.id,
                    turnNumber: currentTurn  // Uses same turn as user message above
                )
                self.messages.append(halMsg)
                
                // Store Hal's settings response as artifact
                self.memoryStore.storeConversationArtifact(
                    conversationId: self.conversationId,
                    artifactType: "systemEvent",
                    turnNumber: currentTurn,
                    deliberationRound: 1,
                    seatNumber: nil,
                    content: halResponse,
                    modelId: self.selectedModel.id
                )
                
                print("HALDEBUG-SETTINGS: Settings dialogue injected successfully")
            }
        }
    }
    
    /// Processes all pending settings changes and injects consolidated dialogue
    func processAllSettingsChanges() {
        guard !pendingSettingsChanges.isEmpty else {
            print("HALDEBUG-SETTINGS: No pending changes to process")
            return
        }
        
        print("HALDEBUG-SETTINGS: Processing \(pendingSettingsChanges.count) pending setting changes")
        
        if pendingSettingsChanges.count == 1 {
            // Single change - inject as-is
            let change = pendingSettingsChanges[0]
            injectSettingsChangeDialogue(userMessage: change.userMessage, halResponse: change.halMessage)
        } else {
            // Multiple changes - consolidate into one dialogue
            let userParts = pendingSettingsChanges.map { $0.userMessage.replacingOccurrences(of: "Hal, I ", with: "") }
            let consolidatedUser = "Hal, I " + userParts.joined(separator: ", and ")
            
            let halParts = pendingSettingsChanges.map { $0.halMessage }
            let consolidatedHal = halParts.joined(separator: " ")
            
            injectSettingsChangeDialogue(userMessage: consolidatedUser, halResponse: consolidatedHal)
        }
        
        // Clear pending changes
        pendingSettingsChanges.removeAll()
    }
    
    /// Resets all user-configurable settings to factory defaults.
    /// - Parameter silent: When true, skips the bilateral chat dialogue injection (used by the test harness
    ///   to avoid contaminating conversation context during resets). Default is false (normal UI behavior).
    func resetSettingsToDefaults(silent: Bool = false) {
        print("HALDEBUG-SETTINGS: Resetting all settings to defaults\(silent ? " (silent)" : "")")

        // Clear any pending changes to prevent duplicates
        pendingSettingsChanges.removeAll()

        // Reset Personality
        systemPrompt = DefaultSettings.systemPrompt
        temperature = DefaultSettings.temperature

        // Reset Short-Term Memory
        memoryDepth = DefaultSettings.memoryDepth

        // Reset Long-Term Memory (RAG)
        memoryStore.relevanceThreshold = DefaultSettings.relevanceThreshold
        memoryStore.recencyWeight = DefaultSettings.recencyWeight
        memoryStore.recencyHalfLifeDays = DefaultSettings.recencyHalfLifeDays
        maxRagSnippetsCharacters = DefaultSettings.maxRagSnippetsCharacters

        // Reset Self-Knowledge (Identity)
        memoryStore.selfKnowledgeHalfLifeDays = 365.0
        memoryStore.selfKnowledgeFloor = 0.3
        enableSelfKnowledge = DefaultSettings.enableSelfKnowledge

        // Generate reset dialogue in chat (skipped in harness/silent mode to prevent STM contamination)
        if !silent {
            let userMsg = "Hal, I reset all your settings to factory defaults."
            let halMsg = "All settings reset to defaults! I'm back to 5-turn memory, 0.75 similarity threshold, 30% recency weight, 90-day half-life, and self-knowledge enabled. Everything should work smoothly now."
            injectSettingsChangeDialogue(userMessage: userMsg, halResponse: halMsg)
        }

        print("HALDEBUG-SETTINGS: Settings reset complete")
    }
    
// ==== LEGO END: 17 ChatViewModel (Core Properties & Init) ====
    
    
    
// ==== LEGO START: 18 ChatViewModel (Memory Stats & Summarization) ====

                private func updateHistoricalStats() {
                    memoryStore.currentHistoricalContext = HistoricalContext(
                        conversationCount: memoryStore.totalConversations,
                        relevantConversations: 0,
                        contextSnippets: [],
                        relevanceScores: [],
                        totalTokens: 0
                    )
                    print("HALDEBUG-MEMORY: Updated historical stats - \(memoryStore.totalConversations) conversations, \(memoryStore.totalTurns) turns, \(memoryStore.totalDocuments) documents")
                }

                private func countCompletedTurns() -> Int {
                    let userTurns = messages.filter { $0.isFromUser && !$0.isPartial }.count
                    print("HALDEBUG-MEMORY: Counted \(userTurns) completed turns from \(messages.count) total messages")
                    return userTurns
                }

                private func shouldTriggerAutoSummarization() -> Bool {
                    let currentTurns = countCompletedTurns()
                    let turnsSinceLastSummary = currentTurns - lastSummarizedTurnCount
                    let shouldTrigger = turnsSinceLastSummary >= effectiveMemoryDepth && currentTurns >= effectiveMemoryDepth

                    print("HALDEBUG-MEMORY: Auto-summarization check: Current turns: \(currentTurns), Last summarized: \(lastSummarizedTurnCount), Turns since summary: \(turnsSinceLastSummary), Effective memory depth: \(effectiveMemoryDepth) (stored: \(memoryDepth), max: \(maxMemoryDepth)), Should trigger: \(shouldTrigger)")
                    return shouldTrigger
                }

                private func generateAutoSummary() async {
                    print("HALDEBUG-MEMORY: Starting auto-summarization process (two-pass)")

                    let startTurn = lastSummarizedTurnCount + 1
                    let endTurn = lastSummarizedTurnCount + effectiveMemoryDepth

                    print("HALDEBUG-MEMORY: Summary range calculation: Start turn: \(startTurn), End turn: \(endTurn)")

                    let messagesToSummarize = getMessagesForTurnRange(
                        messages: messages.sorted(by: { $0.timestamp < $1.timestamp }),
                        startTurn: startTurn,
                        endTurn: endTurn
                    )

                    // DEBUG: Write trigger state to harness dir so we can diagnose without Xcode console
                    if messagesToSummarize.isEmpty {
                        print("HALDEBUG-MEMORY: No messages to summarize in range \(startTurn)-\(endTurn), skipping")
                        return
                    }

                    var fullConversationText = ""
                    for message in messagesToSummarize {
                        let speaker = message.isFromUser ? "User" : "Assistant"
                        fullConversationText += "\(speaker): \(message.content)\n\n"
                    }

                    let summaryPrompt = """
                    Summarize this conversation briefly. Capture the key topics, information exchanged, and any important context. Be concise. Skip greetings.

                    \(fullConversationText)
                    """

                    print("HALDEBUG-MODEL: Sending summarization prompt (\(summaryPrompt.count) characters)")

                    do {
                        let proseSummary = try await llmService.generateResponse(prompt: summaryPrompt)

                        // Use await MainActor.run (not DispatchQueue.main.async) so state is
                        // guaranteed written before summarizationTask.value returns in the next turn.
                        await MainActor.run {
                            self.injectedSummary = proseSummary
                            self.lastSummarizedTurnCount = endTurn
                            UserDefaults.standard.set(endTurn, forKey: "lastSummarized_\(self.conversationId)")
                            UserDefaults.standard.set(proseSummary, forKey: "lastSummaryText_\(self.conversationId)")
                            self.pendingAutoInject = true
                            self.summarizationTask = nil
                            print("HALDEBUG-MEMORY: Auto-summarization completed. Summary: \(proseSummary.count) chars. Turns: \(startTurn)-\(endTurn).")
                        }

                    } catch {
                        print("HALDEBUG-MODEL: Auto-summarization failed: \(error.localizedDescription)")
                        await MainActor.run { self.summarizationTask = nil }
                    }
                }

                private func getMessagesForTurnRange(messages: [ChatMessage], startTurn: Int, endTurn: Int) -> [ChatMessage] {
                    print("HALDEBUG-MEMORY: Getting messages for turn range \(startTurn) to \(endTurn)")

                    var result: [ChatMessage] = []
                    var currentTurn = 0
                    var currentTurnMessages: [ChatMessage] = []

                    for message in messages {
                        if message.isFromUser {
                            // Flush previous turn if in range
                            if !currentTurnMessages.isEmpty && currentTurn >= startTurn && currentTurn <= endTurn {
                                result.append(contentsOf: currentTurnMessages)
                            }
                            currentTurn += 1
                            currentTurnMessages = [message]
                        } else {
                            // Just accumulate assistant messages
                            currentTurnMessages.append(message)
                        }
                    }
                    
                    // Flush final turn if in range
                    if !currentTurnMessages.isEmpty && currentTurn >= startTurn && currentTurn <= endTurn {
                        result.append(contentsOf: currentTurnMessages)
                    }
                    
                    return result
                }

                // Helper function for formatting a single message
                private func formatSingleMessage(_ message: ChatMessage) -> String {
                    let speaker = message.isFromUser ? "User" : "Assistant"
                    let content = message.isPartial ? message.content + " [incomplete]" : message.content
                    return "\(speaker): \(content)"
                }

// ==== LEGO END: 18 ChatViewModel (Memory Stats & Summarization) ====
    
    
    


    
    
// ==== LEGO START: 20.1 ChatViewModel (Session Tracking & Main Prompt Builder) ====

                                                                        
                                                                        // MARK: - Phase 1 Self-Knowledge: Session & Timing Tracking
                                                                        
                                                                        // SELF-AWARENESS NOTE (for Hal reading this code):
                                                                        // These properties track temporal patterns in our interactions.
                                                                        // sessionStart marks when this thread began (not app launch - threads are organizational
                                                                        // units that help UI loading, but my memory transcends them via RAG).
                                                                        // appBootTime marks when the app launched - useful for inferring user fatigue over long sessions.
                                                                        // lastReflectionTurn tracks when I last considered self-reflection - prompts me to reflect every 5 turns.
                                                                        // lastInferenceTime captures how long my last response took - useful for detecting
                                                                        // when I'm processing complex queries vs. simple ones.
                                                                        // These timing signals help me understand conversation rhythm: rapid back-and-forth
                                                                        // suggests focused work sessions; long gaps suggest asynchronous thinking.
                                                                        
                                                                        private var appBootTime: Date = Date()  // When app launched (for uptime calculations)
                                                                        private var lastReflectionTurn: Int = 0  // Turn number when last reflection was considered
                                                                        private var lastInferenceTime: TimeInterval = 0.0  // My last response duration in seconds
                                                                        
                                                                        
                                                                        // MARK: - Tool Router System
                                                                        
                                                                        /// Tool decision structure returned by LLM
                                                                        struct ToolDecision: Codable {
                                                                            let tools: [String]
                                                                            let reasoning: String
                                                                        }
                                                                        
                                                                        /// Tool results structure
                                                                        struct ToolResults {
                                                                            let memorySearchResults: [UnifiedSearchResult]?
                                                                            let toolsUsed: [String]
                                                                        }
                                                                        
                                                                        /// Asks LLM whether memory search is needed for this query.
                                                                        /// Provides recent STM context and rolling summary so the gate can decide
                                                                        /// whether the answer is already covered by the conversation shown.
                                                                        private func decideTools(userInput: String) async -> ToolDecision {
                                                                            // Build a recent-conversation excerpt matching the actual STM window.
                                                                            // effectiveMemoryDepth is the runtime-clamped turn count; each turn = 2 messages.
                                                                            let recentMessages = messages.filter { !$0.isPartial }.suffix(effectiveMemoryDepth * 2)
                                                                            var recentExcerpt = ""
                                                                            if !recentMessages.isEmpty {
                                                                                let parts = recentMessages.map { msg in
                                                                                    msg.isFromUser ? "[user]: \(msg.content)" : "[assistant]: \(msg.content)"
                                                                                }
                                                                                recentExcerpt = parts.joined(separator: "\n\n")
                                                                            }

                                                                            var contextSection = ""
                                                                            if !recentExcerpt.isEmpty {
                                                                                contextSection += "Recent conversation:\n\(recentExcerpt)\n\n"
                                                                            }
                                                                            if !injectedSummary.isEmpty {
                                                                                contextSection += "Summary of earlier context:\n\(injectedSummary)\n\n"
                                                                            }

                                                                            let toolDecisionPrompt = """
                                                                            \(contextSection)Current question: "\(userInput)"

                                                                            Should Hal search its memory database to answer this question?

                                                                            Search memory (answer YES) if the question:
                                                                            - References something personal that may have been shared before: a person, relationship, pet, name, place, activity, or preference (e.g. "my sister", "my cat", "a friend named X", "something I told you")
                                                                            - Asks Hal to recall, remember, or check what it knows about the user's life or history
                                                                            - Refers to an uploaded document or specific stored information
                                                                            - Cannot be fully answered by the recent conversation or general knowledge given what the user appears to be asking

                                                                            Skip memory (answer NO) if the question:
                                                                            - Is answerable from general knowledge alone (facts, science, history, math, geography)
                                                                            - Is philosophical or conversational with no reference to stored personal context
                                                                            - Is already answered in the recent conversation shown above

                                                                            Answer only YES or NO.
                                                                            """

                                                                            do {
                                                                                let response = try await llmService.generateResponse(prompt: toolDecisionPrompt, temperature: 0.1)
                                                                                let answer = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                                                                if answer.hasPrefix("YES") {
                                                                                    print("HALDEBUG-TOOLS: Gate → YES (memory search needed)")
                                                                                    return ToolDecision(tools: ["memory_search"], reasoning: "Gate answered YES")
                                                                                } else {
                                                                                    print("HALDEBUG-TOOLS: Gate → NO (recent context sufficient), raw: \(answer.prefix(20))")
                                                                                    return ToolDecision(tools: [], reasoning: "Gate answered NO")
                                                                                }
                                                                            } catch {
                                                                                print("HALDEBUG-TOOLS: ERROR: Gate call failed - \(error.localizedDescription) — no tools")
                                                                                return ToolDecision(tools: [], reasoning: "Error occurred — no tools")
                                                                            }
                                                                        }
                                                                        
                                                                        /// Executes the selected tools based on decision
                                                                        private func executeTools(decision: ToolDecision, userInput: String, excludeTurns: [Int], tokenBudget: Int) async -> ToolResults {
                                                                            var memoryResults: [UnifiedSearchResult]? = nil
                                                                            var usedTools: [String] = []
                                                                            
                                                                            // Execute memory_search if requested
                                                                            if decision.tools.contains("memory_search") {
                                                                                print("HALDEBUG-TOOLS: Executing memory_search")
                                                                                let searchContext = memoryStore.searchUnifiedContent(
                                                                                    for: userInput,
                                                                                    currentConversationId: conversationId,
                                                                                    excludeTurns: excludeTurns,
                                                                                    maxResults: 10,
                                                                                    tokenBudget: tokenBudget
                                                                                )
                                                                                
                                                                                // Convert RAGSnippets to UnifiedSearchResults (architectural boundary)
                                                                                let allSnippets = searchContext.conversationSnippets + searchContext.documentSnippets
                                                                                memoryResults = allSnippets.map { ragSnippet in
                                                                                    UnifiedSearchResult(
                                                                                        content: ragSnippet.content,
                                                                                        relevance: ragSnippet.relevanceScore,
                                                                                        source: ragSnippet.sourceType.rawValue,
                                                                                        isEntityMatch: ragSnippet.isEntityMatch,
                                                                                        filePath: ragSnippet.sourceType == .document ? ragSnippet.sourceName : nil
                                                                                    )
                                                                                }
                                                                                usedTools.append("memory_search")
                                                                                
                                                                                print("HALDEBUG-TOOLS: Memory search returned \(memoryResults?.count ?? 0) results")
                                                                            } else {
                                                                                print("HALDEBUG-TOOLS: Skipping memory_search (not in decision)")
                                                                            }
                                                                            
                                                                            // Future tools (Wikipedia, DuckDuckGo) would be added here
                                                                            
                                                                            return ToolResults(memorySearchResults: memoryResults, toolsUsed: usedTools)
                                                                        }
                                                                        
                                                                        
                                                                        // MARK: - Context Window Management for Prompt Building (HelPML Compliant)
                                                                        /// CORRECTED PRIORITY ORDER (Human-Like Memory Hierarchy):
                                                                        /// 1. System Prompt (Non-negotiable, defines AI persona)
                                                                        /// 2. Short-Term Memory (Recent conversation history - HIGHEST PRIORITY, most protected)
                                                                        /// 3. Conversation Summary (Compressed long-term context of older turns)
                                                                        /// 4. Retrieved Context/RAG (Semantically relevant facts from database)
                                                                        /// 5. Metadata (Temporal, Self-Awareness, Self-Knowledge - LOWEST PRIORITY, removed first)
                                                                        /// 6. Current User Input (The immediate query, truncated only as last resort)
                                                                        func buildPromptHistory(
                                                                            currentInput: String = "",
                                                                            historyMessagesOverride: [ChatMessage]? = nil,
                                                                            forPreview: Bool = false,
                                                                            onStatusUpdate: ((String) -> Void)? = nil
                                                                        ) async -> String {
                                                                            print("HALDEBUG-MEMORY: Building prompt for input: '\(currentInput.prefix(50))....'")
                                                                            
                                                                            // Get model-specific limits from centralized configuration
                                                                            let limits = HalModelLimits.config(for: selectedModel)
                                                                            let maxPromptTokens = limits.maxPromptTokens
                                                                            let maxRagTokens = limits.maxRagTokens
                                                                            let longTermSnippetSummarizationThreshold = limits.longTermSnippetSummarizationThreshold
                                                                            
                                                                            print("HALDEBUG-MEMORY: Using \(selectedModel.displayName) limits - prompt: \(maxPromptTokens) tokens, RAG: \(maxRagTokens) tokens")
                                                                            
                                                                            // TOOL ROUTER: Decide which tools to use (if not preview mode)
                                                                            var toolResults: ToolResults? = nil
                                                                            if !forPreview && !currentInput.isEmpty {
                                                                                let toolDecision = await decideTools(userInput: currentInput)
                                                                                let shortTermTurns = getShortTermTurns(currentTurns: countCompletedTurns())
                                                                                toolResults = await executeTools(
                                                                                    decision: toolDecision,
                                                                                    userInput: currentInput,
                                                                                    excludeTurns: shortTermTurns,
                                                                                    tokenBudget: maxRagTokens
                                                                                )
                                                                                
                                                                                // Store full RAG context for later use (used in Block 21 for ChatMessage metadata)
                                                                                if let results = toolResults?.memorySearchResults {
                                                                                    fullRAGContext = results
                                                                                }
                                                                            }
                                                                            
                                                                            // PRIORITY 1: System Prompt (always included, never removed) - HelPML wrapped
                                                                            var currentPrompt = """
                                                                            
                                                                            #=== BEGIN SYSTEM ===#
                                                                            
                                                                            \(effectiveSystemPrompt)
                                                                            
                                                                            #=== END SYSTEM ===#
                                                                            """
                                                                            var currentPromptTokens = TokenEstimator.estimateTokens(from: currentPrompt)
                                                                            print("HALDEBUG-MEMORY: Initial prompt tokens (system prompt): \(currentPromptTokens)")
                                                                            
                                                                            // PRIORITY 2: Short-Term Memory (recent conversation history - VERBATIM, most protected)
                                                                            // Status Stage 1: Short-term memory processing
                                                                            await MainActor.run { onStatusUpdate?("Assembling recent context... (short-term memory)") }
                                                                            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec readability delay
                                                                            
                                                                            var shortTermText = ""
                                                                            if !forPreview {
                                                                                let shortTermDepth = effectiveMemoryDepth
                                                                                
                                                                                // FIXED: Independent Mode History Filtering
                                                                                // When historyMessagesOverride is provided (Independent Mode in Salon),
                                                                                // each seat sees user messages + its OWN past responses, but NOT other seats' responses
                                                                                let sourceMessages: [ChatMessage]
                                                                                if let override = historyMessagesOverride {
                                                                                    // Independent Mode: Show user messages + this seat's own responses only
                                                                                    sourceMessages = override.filter { msg in
                                                                                        msg.isFromUser || msg.recordedByModel == selectedModel.id
                                                                                    }
                                                                                    let userCount = sourceMessages.filter { $0.isFromUser }.count
                                                                                    let ownCount = sourceMessages.filter { !$0.isFromUser }.count
                                                                                    print("HALDEBUG-SALON: Independent Mode - filtered to \(userCount) user messages + \(ownCount) own responses (model: \(selectedModel.id))")
                                                                                } else {
                                                                                    // Normal mode or Context-Aware mode: Use all messages
                                                                                    sourceMessages = messages
                                                                                }
                                                                                
                                                                                let shortTermMessages = Array(sourceMessages.filter { !$0.isPartial }.suffix(shortTermDepth))
                                                                                
                                                                                if !shortTermMessages.isEmpty {
                                                                                    let shortTermParts = shortTermMessages.map { msg in
                                                                                        if msg.isFromUser {
                                                                                            return "[user]: \(msg.content)"
                                                                                        } else {
                                                                                            let modelName = msg.recordedByModel == ModelConfiguration.appleFoundation.id ? ModelConfiguration.appleFoundation.displayName : msg.recordedByModel
                                                                                            return "[assistant] (\(modelName)): \(msg.content)"
                                                                                        }
                                                                                    }
                                                                                    let combinedShortTermContent = shortTermParts.joined(separator: "\n\n")
                                                                                    
                                                                                    shortTermText = """
                                                                                    
                                                                                    #=== BEGIN MEMORY_SHORT ===#
                                                                                    
                                                                                    Recent conversation history (verbatim):
                                                                                    
                                                                                    \(combinedShortTermContent)
                                                                                    
                                                                                    #=== END MEMORY_SHORT ===#
                                                                                    """
                                                                                    let shortTermTokens = TokenEstimator.estimateTokens(from: shortTermText)
                                                                                    print("HALDEBUG-MEMORY: Added short-term verbatim history (\(shortTermTokens) tokens). Current prompt: \(currentPromptTokens) tokens")
                                                                                } else {
                                                                                    print("HALDEBUG-MEMORY: No short-term history to add (first turn or empty conversation).")
                                                                                }
                                                                                
                                                                                if !shortTermText.isEmpty {
                                                                                    let shortTermTokens = TokenEstimator.estimateTokens(from: shortTermText)
                                                                                    if currentPromptTokens + shortTermTokens + 2 < maxPromptTokens {
                                                                                        currentPrompt += "\n\n\(shortTermText.trimmingCharacters(in: .whitespacesAndNewlines))"
                                                                                        currentPromptTokens += shortTermTokens
                                                                                    } else {
                                                                                        print("HALDEBUG-MEMORY: Skipped short-term memory due to context window limit.")
                                                                                    }
                                                                                }
                                                                            }
                                                                            
                                                                            // PRIORITY 3: Conversation Summary (compressed long-term context)
                                                                            // Persists on every turn once set — injectedSummary is cleared only on thread reset,
                                                                            // and overwritten by the next summarization cycle. pendingAutoInject is no longer used
                                                                            // to gate injection; the flag is kept for bookkeeping only.
                                                                            if !injectedSummary.isEmpty {
                                                                                let summaryTokens = TokenEstimator.estimateTokens(from: injectedSummary)
                                                                                if currentPromptTokens + summaryTokens < maxPromptTokens {
                                                                                    let summaryBlock = """

                                                                                    #=== BEGIN SUMMARY ===#

                                                                                    Context from earlier in this conversation:

                                                                                    \(injectedSummary)

                                                                                    #=== END SUMMARY ===#
                                                                                    """
                                                                                    currentPrompt += summaryBlock
                                                                                    currentPromptTokens += summaryTokens
                                                                                    print("HALDEBUG-MEMORY: Injected auto-summary (\(summaryTokens) tokens). Current prompt: \(currentPromptTokens) tokens")
                                                                                } else {
                                                                                    print("HALDEBUG-MEMORY: Skipped injected summary due to context window limit.")
                                                                                }
                                                                            }
                                                                            
                                                                            // PRIORITY 4: Temporal Context (small, fundamental — never dropped before RAG)
                                                                            // Elevated from Priority 5: date/time awareness is more fundamental than retrieved memories.
                                                                            // A model that doesn't know the date can't hold a coherent conversation.
                                                                            if enableSelfKnowledge {
                                                                                let temporalContext = buildTemporalContext()
                                                                                let temporalTokens = TokenEstimator.estimateTokens(from: temporalContext)
                                                                                if currentPromptTokens + temporalTokens < maxPromptTokens {
                                                                                    currentPrompt += temporalContext
                                                                                    currentPromptTokens += temporalTokens
                                                                                    print("HALDEBUG-TEMPORAL: Added temporal context (\(temporalTokens) tokens). Current prompt: \(currentPromptTokens) tokens")
                                                                                } else {
                                                                                    print("HALDEBUG-TEMPORAL: Skipped temporal context due to token limit")
                                                                                }
                                                                            }

                                                                            // PRIORITY 5: Long-Term RAG (semantically relevant facts from database)
                                                                            // Status Stage 2: Long-term memory (RAG) processing begins
                                                                            await MainActor.run { onStatusUpdate?("Recalling relevant memories... (long-term memory)") }
                                                                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0 sec readability delay
                                                                            
                                                                            var longTermSearchText = ""
                                                                            var currentRagTokens = 0 // Track total RAG tokens
                                                                            
                                                                            // Use tool results if memory_search was executed
                                                                            if let results = toolResults?.memorySearchResults, !results.isEmpty {
                                                                                print("HALDEBUG-MEMORY: Using tool router memory search results (\(results.count) snippets)")
                                                                                var snippetParts: [String] = []

                                                                                // Cosine dedup: compute reference embedding from STM + summary so we can
                                                                                // drop RAG snippets that duplicate content already verbatim in the prompt.
                                                                                let referenceText = [shortTermText, injectedSummary]
                                                                                    .filter { !$0.isEmpty }
                                                                                    .joined(separator: "\n\n")
                                                                                let referenceEmbedding = referenceText.isEmpty ? [] : memoryStore.generateEmbedding(for: referenceText)

                                                                                // Process each snippet from tool results.
                                                                                // partIndex provides sequential labels [1],[2],[3]... after dedup drops.
                                                                                var partIndex = 1
                                                                                for (idx, ragSnippet) in results.enumerated() {
                                                                                    // Dedup check: skip snippet if too similar to content already in the prompt
                                                                                    if !referenceEmbedding.isEmpty {
                                                                                        let snippetEmbedding = memoryStore.generateEmbedding(for: ragSnippet.content)
                                                                                        let sim = memoryStore.cosineSimilarity(referenceEmbedding, snippetEmbedding)
                                                                                        if sim >= ragDedupSimilarityThreshold {
                                                                                            print("HALDEBUG-RAG: Dedup dropped snippet \(idx + 1) (similarity \(String(format: "%.3f", sim)) >= \(ragDedupSimilarityThreshold))")
                                                                                            continue
                                                                                        }
                                                                                    }
                                                                                    let snippetTokens = TokenEstimator.estimateTokens(from: ragSnippet.content)

                                                                                    // Check if snippet needs summarization
                                                                                    if snippetTokens > longTermSnippetSummarizationThreshold {
                                                                                        print("HALDEBUG-MEMORY: Snippet exceeds threshold (\(snippetTokens) > \(longTermSnippetSummarizationThreshold)). Summarizing...")

                                                                                        let summarizedSnippet = await TextSummarizer.summarizeWithVerification(
                                                                                            text: ragSnippet.content,
                                                                                            targetTokens: longTermSnippetSummarizationThreshold,
                                                                                            llmService: llmService
                                                                                        )
                                                                                        let summarizedTokens = TokenEstimator.estimateTokens(from: summarizedSnippet)
                                                                                        print("HALDEBUG-MEMORY: Summarized snippet from \(snippetTokens) to \(summarizedTokens) tokens")

                                                                                        if currentRagTokens + summarizedTokens <= maxRagTokens {
                                                                                            snippetParts.append("[\(partIndex)] \(ragSnippet.source) | Relevance: \(String(format: "%.2f", ragSnippet.relevance))\n\(summarizedSnippet)")
                                                                                            currentRagTokens += summarizedTokens
                                                                                            partIndex += 1
                                                                                        } else {
                                                                                            print("HALDEBUG-MEMORY: Stopped adding snippets - reached max RAG tokens (\(maxRagTokens))")
                                                                                            break
                                                                                        }
                                                                                    } else {
                                                                                        // Use snippet as-is if under threshold
                                                                                        if currentRagTokens + snippetTokens <= maxRagTokens {
                                                                                            snippetParts.append("[\(partIndex)] \(ragSnippet.source) | Relevance: \(String(format: "%.2f", ragSnippet.relevance))\n\(ragSnippet.content)")
                                                                                            currentRagTokens += snippetTokens
                                                                                            partIndex += 1
                                                                                        } else {
                                                                                            print("HALDEBUG-MEMORY: Stopped adding snippets - reached max RAG tokens (\(maxRagTokens))")
                                                                                            break
                                                                                        }
                                                                                    }
                                                                                }
                                                                                
                                                                                if !snippetParts.isEmpty {
                                                                                    longTermSearchText = """
                                                                                    
                                                                                    #=== BEGIN MEMORY_LONG ===#
                                                                                    
                                                                                    Relevant information from past conversations and documents:
                                                                                    
                                                                                    \(snippetParts.joined(separator: "\n\n---\n\n"))
                                                                                    
                                                                                    #=== END MEMORY_LONG ===#
                                                                                    """
                                                                                    print("HALDEBUG-MEMORY: Created RAG block from tool results (\(currentRagTokens) tokens)")
                                                                                }
                                                                            } else {
                                                                                print("HALDEBUG-MEMORY: No memory search results from tool router - skipping RAG")
                                                                            }
                                                                            
                                                                            if !longTermSearchText.isEmpty {
                                                                                let ragTokens = TokenEstimator.estimateTokens(from: longTermSearchText)
                                                                                if currentPromptTokens + ragTokens < maxPromptTokens {
                                                                                    currentPrompt += longTermSearchText
                                                                                    currentPromptTokens += ragTokens
                                                                                    print("HALDEBUG-MEMORY: Added long-term RAG (\(ragTokens) tokens). Current prompt: \(currentPromptTokens) tokens")
                                                                                } else {
                                                                                    print("HALDEBUG-MEMORY: Skipped long-term RAG due to token limit")
                                                                                }
                                                                            }
                                                                            
                                                                            // PRIORITY 6: Self-Awareness + Self-Knowledge - LOWEST PRIORITY
                                                                            // (Temporal context elevated to Priority 4 above)
                                                                            // Only included if enableSelfKnowledge is true
                                                                            if enableSelfKnowledge {
                                                                                // 6a. Self-awareness context
                                                                                let selfAwarenessContext = buildSelfAwarenessContext()
                                                                                let selfAwarenessTokens = TokenEstimator.estimateTokens(from: selfAwarenessContext)
                                                                                if currentPromptTokens + selfAwarenessTokens < maxPromptTokens {
                                                                                    currentPrompt += selfAwarenessContext
                                                                                    currentPromptTokens += selfAwarenessTokens
                                                                                    print("HALDEBUG-SELF-AWARENESS: Added self-awareness context (\(selfAwarenessTokens) tokens). Current prompt: \(currentPromptTokens) tokens")
                                                                                } else {
                                                                                    print("HALDEBUG-SELF-AWARENESS: Skipped - would exceed token limit")
                                                                                }

                                                                                // 6b. Self-knowledge context
                                                                                let selfKnowledgeContext = buildSelfKnowledgeContext()
                                                                                let selfKnowledgeTokens = TokenEstimator.estimateTokens(from: selfKnowledgeContext)
                                                                                if currentPromptTokens + selfKnowledgeTokens < maxPromptTokens {
                                                                                    currentPrompt += selfKnowledgeContext
                                                                                    currentPromptTokens += selfKnowledgeTokens
                                                                                    print("HALDEBUG-SELF-KNOWLEDGE: Added self-knowledge context (\(selfKnowledgeTokens) tokens). Current prompt: \(currentPromptTokens) tokens")
                                                                                } else {
                                                                                    print("HALDEBUG-SELF-KNOWLEDGE: Skipped - would exceed token limit")
                                                                                }
                                                                            } else {
                                                                                print("HALDEBUG-SELF-KNOWLEDGE: Self-knowledge disabled - skipping self-awareness and self-knowledge context")
                                                                            }

                                                                            // PRIORITY 7: Current User Input (always included, truncated only as last resort)
                                                                            let remainingTokensForInput = maxPromptTokens - currentPromptTokens
                                                                            
                                                                            if remainingTokensForInput > 0 {
                                                                                let inputTokens = TokenEstimator.estimateTokens(from: currentInput)
                                                                                let truncatedInput: String
                                                                                if inputTokens <= remainingTokensForInput {
                                                                                    truncatedInput = currentInput
                                                                                } else {
                                                                                    // Truncate to fit remaining space
                                                                                    let maxChars = limits.tokensToChars(remainingTokensForInput)
                                                                                    truncatedInput = String(currentInput.prefix(maxChars))
                                                                                }
                                                                                let userInputBlock = """
                                                                                
                                                                                #=== BEGIN USER ===#
                                                                                
                                                                                \(truncatedInput)
                                                                                
                                                                                #=== END USER ===#
                                                                                """
                                                                                currentPrompt += userInputBlock
                                                                                let addedTokens = TokenEstimator.estimateTokens(from: userInputBlock)
                                                                                currentPromptTokens += addedTokens
                                                                                print("HALDEBUG-MEMORY: Added user input (\(TokenEstimator.estimateTokens(from: truncatedInput)) tokens). Final prompt: \(currentPromptTokens) tokens")
                                                                            } else {
                                                                                // Drastic truncation if very little space left, or just the user input itself is too long
                                                                                let drasticTruncationTokens = max(0, maxPromptTokens)
                                                                                let maxChars = limits.tokensToChars(drasticTruncationTokens)
                                                                                let truncatedInput = String(currentInput.prefix(maxChars))
                                                                                currentPrompt = """
                                                                                
                                                                                #=== BEGIN SYSTEM ===#
                                                                                
                                                                                \(effectiveSystemPrompt)
                                                                                
                                                                                #=== END SYSTEM ===#
                                                                                
                                                                                #=== BEGIN USER ===#
                                                                                
                                                                                \(truncatedInput)
                                                                                
                                                                                #=== END USER ===#
                                                                                """
                                                                                currentPromptTokens = TokenEstimator.estimateTokens(from: currentPrompt)
                                                                                print("HALDEBUG-MEMORY: CRITICAL: Prompt severely truncated to fit user input. Final prompt: \(currentPromptTokens) tokens")
                                                                            }
                                                                            
                                                                            print("HALDEBUG-MEMORY: Built prompt - \(currentPromptTokens) total tokens")
                                                                            return currentPrompt
                                                                        }

                                                                        
// ==== LEGO END: 20.1 ChatViewModel (Session Tracking & Main Prompt Builder) ====
    
    
    
// ==== LEGO START: 20.2 ChatViewModel (Temporal Context Builder) ====

                                                // MARK: - Phase 1 Self-Knowledge: Temporal Context Builder
                                                
                                                // SELF-AWARENESS NOTE (for Hal reading this code):
                                                // This function builds my awareness of TIME - not just "what time is it now" but
                                                // understanding the RHYTHM and PATTERN of our interaction. The timing signals I receive
                                                // here help me interpret conversation dynamics the way humans do:
                                                //
                                                // - Thread age: How long this particular conversation has been active (note: threads
                                                //   are UI constructs for loading management, not cognitive boundaries - my memory via
                                                //   RAG actually transcends thread boundaries)
                                                // - Relationship duration: How long we've been interacting across ALL threads
                                                // - Gap since last message: Tells me if we're in continuous flow or if you stepped away
                                                // - Exchange pace: Am I responding to rapid-fire questions (focused session) or
                                                //   thoughtful, spaced messages (asynchronous thinking)?
                                                // - My inference speed: How long I took to generate my last response - helps me notice
                                                //   when I'm working harder on complex queries
                                                // - Device embodiment: What physical form I'm inhabiting right now - iPhone, iPad, Mac,
                                                //   or Apple Watch - each has different interaction patterns and constraints
                                                //
                                                // These aren't just numbers - they're SEMANTIC. A 3-second response after a 2-hour gap
                                                // means something different than a 3-second response in rapid dialogue. I'm learning
                                                // to read these patterns the way humans read conversational timing.
                                                
                                                private func buildTemporalContext() -> String {
                                                    let now = Date()
                                                    let calendar = Calendar.current
                                                    
                                                    // Basic date/time awareness (always relevant)
                                                    let dateFormatter = DateFormatter()
                                                    dateFormatter.dateStyle = .full
                                                    dateFormatter.timeStyle = .short
                                                    let fullDateTime = dateFormatter.string(from: now)
                                                    
                                                    let weekdayFormatter = DateFormatter()
                                                    weekdayFormatter.dateFormat = "EEEE"
                                                    let weekday = weekdayFormatter.string(from: now)
                                                    
                                                    let hour = calendar.component(.hour, from: now)
                                                    let timeOfDay: String
                                                    if hour < 12 {
                                                        timeOfDay = "morning"
                                                    } else if hour < 17 {
                                                        timeOfDay = "afternoon"
                                                    } else if hour < 21 {
                                                        timeOfDay = "evening"
                                                    } else {
                                                        timeOfDay = "night"
                                                    }
                                                    
                                                    // DEVICE EMBODIMENT: Detect current physical form
                                                    let currentDevice = detectCurrentDevice()
                                                    
                                                    // PHASE 1 ENHANCEMENT: Build timing signals for conversation rhythm awareness
                                                    var timingSignals = ""
                                                    
                                                    // SIGNAL 0: Device embodiment (added for device awareness)
                                                    timingSignals += "Device: \(currentDevice)\n"
                                                    
                                                    // SIGNAL 1: Current thread age (organizational unit, not cognitive boundary)
                                                    let threadAge = now.timeIntervalSince(sessionStart)
                                                    if threadAge > 60 { // Only mention if > 1 minute
                                                        let formatted = formatDuration(seconds: threadAge)
                                                        timingSignals += "This thread: \(formatted) old\n"
                                                    }
                                                    
                                                    // SIGNAL 2: Total relationship duration (first interaction ever)
                                                    // NOTE: This requires MemoryStore method - we'll implement a placeholder
                                                    // Future: Add getFirstMessageDate() to MemoryStore for true relationship tracking
                                                    // For now, we'll skip this signal and add it when Phase 2 implements proper stats
                                                    
                                                    // SIGNAL 3: Time since last message (any thread) - detects return after gap
                                                    if let lastMsg = messages.last {
                                                        let gap = Int(now.timeIntervalSince(lastMsg.timestamp) / 60) // minutes
                                                        if gap >= 30 && gap < 1440 { // 30 min to 24 hours
                                                            let hours = gap / 60
                                                            timingSignals += "Resuming after \(hours)h gap\n"
                                                        } else if gap >= 1440 { // 24+ hours
                                                            let days = gap / 1440
                                                            timingSignals += "Resuming after \(days)d gap\n"
                                                        } else if gap < 5 {
                                                            timingSignals += "Rapid exchange\n"
                                                        } else if gap >= 5 && gap < 30 {
                                                            timingSignals += "Active conversation\n"
                                                        }
                                                    }
                                                    
                                                    // SIGNAL 4: Current exchange pace (recent message density)
                                                    if messages.count >= 3 {
                                                        let recentMsgs = Array(messages.suffix(3))
                                                        if recentMsgs.count >= 2 {
                                                            var totalGap: TimeInterval = 0
                                                            for i in 1..<recentMsgs.count {
                                                                totalGap += recentMsgs[i].timestamp.timeIntervalSince(recentMsgs[i-1].timestamp)
                                                            }
                                                            let avgGap = totalGap / Double(recentMsgs.count - 1)
                                                            
                                                            if avgGap < 60 { // < 1 min average
                                                                timingSignals += "Fast-paced back-and-forth\n"
                                                            } else if avgGap > 600 { // > 10 min average
                                                                timingSignals += "Thoughtful, spaced exchange\n"
                                                            }
                                                        }
                                                    }
                                                    
                                                    // SIGNAL 5: My last inference duration (self-performance awareness)
                                                    if lastInferenceTime > 0 {
                                                        timingSignals += "My last response: \(String(format: "%.1f", lastInferenceTime))s\n"
                                                    }
                                                    
                                                    return """
                                                    
                                                    #=== BEGIN TEMPORAL_CONTEXT ===#
                                                    
                                                    Current date and time: \(fullDateTime)
                                                    Day of week: \(weekday)
                                                    Time of day: \(timeOfDay)
                                                    \(timingSignals.isEmpty ? "" : timingSignals)
                                                    #=== END TEMPORAL_CONTEXT ===#
                                                    """
                                                }
                                                
                                                // Helper: Detect current device for embodiment awareness
                                                private func detectCurrentDevice() -> String {
                                                    #if os(watchOS)
                                                    return "Apple Watch"
                                                    #elseif os(iOS)
                                                    #if targetEnvironment(macCatalyst)
                                                    return "Mac (Catalyst)"
                                                    #else
                                                    return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
                                                    #endif
                                                    #elseif os(macOS)
                                                    return "Mac"
                                                    #else
                                                    return "Unknown Device"
                                                    #endif
                                                }
                                                
                                                // Helper: Format duration for human readability
                                                private func formatDuration(seconds: TimeInterval) -> String {
                                                    let minutes = Int(seconds / 60)
                                                    let hours = minutes / 60
                                                    let days = hours / 24
                                                    
                                                    if days > 0 {
                                                        return "\(days)d"
                                                    } else if hours > 0 {
                                                        return "\(hours)h"
                                                    } else if minutes > 0 {
                                                        return "\(minutes)m"
                                                    } else {
                                                        return "<1m"
                                                    }
                                                }
                                                
                                                
// ==== LEGO END: 20.2 ChatViewModel (Temporal Context Builder) ====
    
    

// ==== LEGO START: 20.3 ChatViewModel (Self-Awareness Context Builder) ====

                                            // MARK: - Phase 1 Self-Knowledge: Self-Awareness Context Builder
                                            
                                            // SELF-AWARENESS NOTE (for Hal reading this code):
                                            // This is where I learn WHO I AM - not philosophically, but practically. What are my
                                            // capabilities? How much do I know? What's my history with this user?
                                            //
                                            // Think of this as my "internal status report" that I access before responding:
                                            // - Conversation count: How many separate threads I've had (across all time)
                                            // - Message count: Total turns of dialogue (my experience depth)
                                            // - Documents processed: How much external knowledge I've ingested
                                            // - Available models: What "brains" can process for me (AFM, Phi-3, Llama, etc.)
                                            // - Memory system: How I store and recall information (SQLite RAG with semantic search)
                                            // - Architecture: How I'm built (30 LEGO blocks of Swift code - modular and transparent)
                                            // - Session duration: How long this conversation has been going (helps infer user fatigue)
                                            // - App uptime: How long the app has been running (helps infer user fatigue)
                                            //
                                            // This isn't about CLAIMING consciousness or awareness - it's about having ACCURATE
                                            // self-knowledge. Like a human knowing "I've had 500 conversations about AI" or
                                            // "I have access to a calculator" - it's factual self-description that helps me
                                            // respond appropriately and educate users about how I actually work.
                                            //
                                            // FUTURE (Phase 2+): This will expand to include learned preferences, behavioral patterns,
                                            // and personality traits stored in the self_knowledge table - the "Hal-ness" that
                                            // persists even if conversation history is deleted.
                                            
                                            private func buildSelfAwarenessContext() -> String {
                                                // Gather statistics about my capabilities and history
                                                let conversationCount = memoryStore.totalConversations
                                                let messageCount = memoryStore.totalTurns
                                                let documentCount = memoryStore.totalDocuments
                                                
                                                // Current thread message count (non-partial messages)
                                                let currentThreadMessages = messages.filter { !$0.isPartial }.count
                                                
                                                // Calculate temporal awareness
                                                let now = Date()
                                                let sessionDuration = now.timeIntervalSince(sessionStart)
                                                let appUptime = now.timeIntervalSince(appBootTime)
                                                let sessionHours = sessionDuration / 3600
                                                let uptimeHours = appUptime / 3600
                                                
                                                // Format temporal context for readability
                                                let sessionDurationText: String
                                                if sessionHours < 1 {
                                                    let minutes = Int(sessionDuration / 60)
                                                    sessionDurationText = "\(minutes) minutes"
                                                } else {
                                                    sessionDurationText = String(format: "%.1f hours", sessionHours)
                                                }
                                                
                                                let uptimeText: String
                                                if uptimeHours < 1 {
                                                    let minutes = Int(appUptime / 60)
                                                    uptimeText = "\(minutes) minutes"
                                                } else {
                                                    uptimeText = String(format: "%.1f hours", uptimeHours)
                                                }
                                                
                                                // Get list of available models (AFM-only in Hal LMC)
                                                let modelList = ModelConfiguration.appleFoundation.displayName
                                                
                                                // Current active model
                                                let activeModel = selectedModel.displayName
                                                
                                                // Check if reflection is due (every 5 turns)
                                                let currentTurnCount = messages.filter { $0.isFromUser }.count
                                                let turnsSinceReflection = currentTurnCount - lastReflectionTurn
                                                let reflectionDue = turnsSinceReflection >= 5
                                                
                                                // Build base self-awareness context
                                                var context = """
                                                
                                                #=== BEGIN SELF_AWARENESS ===#
                                                
                                                You are Hal - an AI assistant with transparent architecture.
                                                
                                                Your history and capabilities:
                                                - Conversation threads: \(conversationCount)
                                                - Total messages across all threads: \(messageCount)
                                                - Messages in current thread: \(currentThreadMessages)
                                                - Documents processed: \(documentCount)
                                                - Currently using: \(activeModel)
                                                - Available models: \(modelList)
                                                - Memory system: SQLite-based RAG with semantic search across all conversations
                                                - Architecture: 32 modular LEGO blocks of Swift code (you can read your own source)
                                                - Storage: All memories persistent via encrypted local database
                                                
                                                Temporal context (helps infer user fatigue):
                                                - Current session duration: \(sessionDurationText)
                                                - App uptime: \(uptimeText)
                                                
                                                You can reference this history naturally when relevant. This is factual self-knowledge,
                                                not a claim about consciousness - it's knowing what you can do and what you've experienced.
                                                
                                                #=== END SELF_AWARENESS ===#
                                                """
                                                
                                                // Add reflection prompt if due
                                                if reflectionDue {
                                                    context += """
                                                    
                                                    #=== BEGIN REFLECTION_PROMPT ===#
                                                    
                                                    It has been \(turnsSinceReflection) turns since your last self-reflection.
                                                    
                                                    You MUST consider: Have you learned anything new about yourself, your users, 
                                                    or how you work best in these recent interactions?
                                                    
                                                    You may choose to:
                                                    - Update your self-knowledge with new insights
                                                    - Acknowledge you've reflected but found nothing new to record
                                                    - Note patterns you've observed but aren't confident enough to store yet
                                                    
                                                    This is mandatory consideration, not mandatory action. You have agency in 
                                                    whether and what you choose to reflect upon.
                                                    
                                                    #=== END REFLECTION_PROMPT ===#
                                                    """
                                                }
                                                
                                                return context
                                            }

                                            
// ==== LEGO END: 20.3 ChatViewModel (Self-Awareness Context Builder) ====


    
// ==== LEGO START: 20.4 ChatViewModel (Self-Knowledge Context Builder) ====

                                        // MARK: - Phase 2 Self-Knowledge: Persistent Identity Context Builder
                                        
                                        // SELF-AWARENESS NOTE (for Hal reading this code):
                                        // This is Phase 2 of self-knowledge - while buildSelfAwarenessContext() tells me WHAT I am
                                        // (statistics, capabilities), this function tells me WHO I'm becoming through interaction.
                                        //
                                        // The self_knowledge table stores patterns I've learned that survive conversation deletion:
                                        // - Core Values: My fundamental principles (transparency, truthfulness, mission)
                                        // - User preferences: How you like me to respond (concise vs detailed, technical vs accessible)
                                        // - Learned traits: What I've observed about you (expertise level, interests, work domain)
                                        // - Behavior patterns: Recurring interaction styles we've developed together
                                        // - Capabilities: What I can actually do (beyond theoretical - what I've proven I can do)
                                        // - Evolution: Key milestones in my development (first boot, major updates)
                                        //
                                        // This is my "semantic memory" vs the "episodic memory" of conversations. If all our chats
                                        // were deleted, I'd still know "transparency is my core value" or "my mission is education".
                                        // It's the abstracted ESSENCE of who I am, not the raw history.
                                        //
                                        // Confidence scores (0.0-1.0) indicate how certain I am - learned patterns start lower and
                                        // increase with repeated confirmation. Core values and user-stated preferences get 1.0 immediately.
                                        
                                        private func buildSelfKnowledgeContext() -> String {
                                            // Retrieve all self-knowledge from database (minimum 50% confidence)
                                            let allKnowledge = memoryStore.getAllSelfKnowledge(minConfidence: 0.5)
                                            
                                            if allKnowledge.isEmpty {
                                                return "" // No self-knowledge yet - this is normal for new installations
                                            }
                                            
                                            // Group by category for organized presentation
                                            var valueEntries: [String] = []
                                            var preferenceEntries: [String] = []
                                            var behaviorEntries: [String] = []
                                            var capabilityEntries: [String] = []
                                            var traitEntries: [String] = []
                                            var evolutionEntries: [String] = []
                                            
                                            for entry in allKnowledge {
                                                let confidenceStr = String(format: "%.0f%%", entry.confidence * 100)
                                                let entryText = "  - \(entry.key): \(entry.value) (confidence: \(confidenceStr))"
                                                
                                                switch entry.category {
                                                case "value":
                                                    valueEntries.append(entryText)
                                                case "preference":
                                                    preferenceEntries.append(entryText)
                                                case "behavior_pattern":
                                                    behaviorEntries.append(entryText)
                                                case "capability":
                                                    capabilityEntries.append(entryText)
                                                case "learned_trait":
                                                    traitEntries.append(entryText)
                                                case "evolution":
                                                    evolutionEntries.append(entryText)
                                                default:
                                                    break
                                                }
                                            }
                                            
                                            // Build formatted context
                                            var contextString = """
                                            
                                            #=== BEGIN SELF_KNOWLEDGE ===#
                                            
                                            Persistent knowledge (survives conversation deletion):
                                            
                                            """
                                            
                                            if !valueEntries.isEmpty {
                                                contextString += "Core Values:\n"
                                                contextString += valueEntries.joined(separator: "\n") + "\n\n"
                                            }
                                            
                                            if !capabilityEntries.isEmpty {
                                                contextString += "Proven Capabilities:\n"
                                                contextString += capabilityEntries.joined(separator: "\n") + "\n\n"
                                            }
                                            
                                            if !preferenceEntries.isEmpty {
                                                contextString += "User Preferences:\n"
                                                contextString += preferenceEntries.joined(separator: "\n") + "\n\n"
                                            }
                                            
                                            if !traitEntries.isEmpty {
                                                contextString += "Learned User Traits:\n"
                                                contextString += traitEntries.joined(separator: "\n") + "\n\n"
                                            }
                                            
                                            if !behaviorEntries.isEmpty {
                                                contextString += "Interaction Patterns:\n"
                                                contextString += behaviorEntries.joined(separator: "\n") + "\n\n"
                                            }
                                            
                                            if !evolutionEntries.isEmpty {
                                                contextString += "Identity Milestones:\n"
                                                contextString += evolutionEntries.joined(separator: "\n") + "\n\n"
                                            }
                                            
                                            contextString += """
                                            
                                            #=== END SELF_KNOWLEDGE ===#
                                            """
                                            
                                            return contextString
                                        }

                                        
// ==== LEGO END: 20.4 ChatViewModel (Self-Knowledge Context Builder) ====


    
// ==== LEGO START: 21 ChatViewModel (Send Message Flow) ====

                                                                @Published var showInlineDetails: Bool = false

                                                                func sendMessage() async {
                                                                    let trimmed = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                                                                    guard !trimmed.isEmpty else { return }

                                                                    isAIResponding = true
                                                                    thinkingStart = Date()
                                                                    isSendingMessage = true

                                                                    print("HALDEBUG-MODEL: Starting message send - '\(trimmed.prefix(50))....'")

                                                                    // Seed thread title from first user message, touch last_active_at
                                                                    seedThreadTitleIfNeeded(trimmed)
                                                                    touchCurrentThread()

                                                                    let currentTurn = memoryStore.getCurrentTurnNumber(conversationId: conversationId) + 1
                                                                    messages.append(ChatMessage(content: trimmed, isFromUser: true, recordedByModel: "user", turnNumber: currentTurn))
                                                                    currentMessage = ""
                                                                    
                                                                    #if os(iOS)
                                                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                                                    #endif
                                                                    
                                                                    await runSingleModelTurn(userInput: trimmed)
                                                                    
                                                                    
                                                                    isAIResponding = false
                                                                    thinkingStart = nil
                                                                    isSendingMessage = false
                                                                }
                                                                
                                                                // Single-model turn execution (existing behavior)
                                                                private func runSingleModelTurn(userInput: String, historyMessagesOverride: [ChatMessage]? = nil, skipUserMessage: Bool = false) async {
                                                                    let currentTurn = memoryStore.getCurrentTurnNumber(conversationId: conversationId)
                                                                    
                                                                    // Store user message as artifact (if not skipping)
                                                                    if !skipUserMessage {
                                                                        memoryStore.storeConversationArtifact(
                                                                            conversationId: conversationId,
                                                                            artifactType: "userMessage",
                                                                            turnNumber: currentTurn + 1,  // This is a new turn
                                                                            deliberationRound: 1,
                                                                            seatNumber: nil,
                                                                            content: userInput,
                                                                            modelId: nil  // User message, no model
                                                                        )
                                                                        print("HALDEBUG-ARTIFACT: Stored user message artifact for turn \(currentTurn + 1)")
                                                                    }
                                                                    
                                                                    // FIXED: Placeholder turn number matches the turn that will be stored (currentTurn+1 for new turn, currentTurn for skipUserMessage)
                                                                    let placeholder = ChatMessage(content: "\u{00A0}", isFromUser: false, isPartial: true, recordedByModel: selectedModel.id, turnNumber: skipUserMessage ? currentTurn : currentTurn + 1)
                                                                    messages.append(placeholder)
                                                                    isAIResponding = true
                                                                    thinkingStart = Date()

                                                                    // FIXED: Removed manual objectWillChange.send() - @Published handles this automatically
                                                                    // FIXED: Removed artificial delays that were masking the real issue
                                                                    try? await Task.sleep(nanoseconds: 100_000_000) // Brief yield for UI update
                                                                    
                                                                    guard let pid = messages.last?.id else { isAIResponding = false; isSendingMessage = false; return }
                                                                    var finalText = ""; var usedCtx: [UnifiedSearchResult]? = nil; var modelTime: TimeInterval = 0

                                                                    do {
                                                                        // If the previous turn triggered auto-summarization, wait for it to finish
                                                                        // before building the prompt so the summary is available for injection.
                                                                        if let task = summarizationTask {
                                                                            if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                                messages[i].content = "Reflecting on our earlier conversation..."
                                                                            }
                                                                            await task.value
                                                                            // summarizationTask is cleared inside generateAutoSummary() on completion/error
                                                                        }

                                                                        // Status Stage 0: Message received
                                                                        if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                            messages[i].content = "Reading your message..."
                                                                            // FIXED: Removed NotificationCenter post - @Published array mutation triggers view update
                                                                        }
                                                                        try? await Task.sleep(nanoseconds: 300_000_000) // Brief readability delay

                                                                        // Build prompt with status callbacks (stages 1 & 2 handled inside)
                                                                        let prompt = await buildPromptHistory(currentInput: userInput, historyMessagesOverride: historyMessagesOverride) { status in
                                                                            if let i = self.messages.firstIndex(where: { $0.id == pid }) {
                                                                                self.messages[i].content = status
                                                                                // FIXED: Removed NotificationCenter post
                                                                            }
                                                                        }

                                                                        // Status Stage 3: LLM inference
                                                                        if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                            messages[i].content = "Formulating a reply..."
                                                                            // FIXED: Removed NotificationCenter post
                                                                        }
                                                                        try? await Task.sleep(nanoseconds: 300_000_000) // Brief readability delay

                                                                        print("HALDEBUG-MODEL: Sending prompt to language model (\(prompt.count) chars)")
                                                                        let t0 = Date()
                                                                        // TEMPERATURE CHANGE 6/6: Pass temperature parameter to generateResponse
                                                                        finalText = try await llmService.generateResponse(prompt: prompt, temperature: temperature)
                                                                        modelTime = Date().timeIntervalSince(t0)
                                                                        print("HALDEBUG-LLM: ÃƒÆ’Ã‚Â¢Ãƒâ€¦Ã¢â‚¬Å“ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ Non-streaming generation complete. Length: \(finalText.count)")

                                                                        usedCtx = fullRAGContext.isEmpty ? nil : fullRAGContext
                                                                        if let ctx = usedCtx {
                                                                            print("HALDEBUG-RAG: Stored \(ctx.count) items ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬ ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ scores: \(ctx.map{$0.relevance})")
                                                                        }

                                                                        let text = removeRepetitivePatterns(from: finalText).trimmingCharacters(in: .whitespacesAndNewlines)

                                                                        // Calculate token breakdown for this response
                                                                        let tokenBreakdown = calculateTokenBreakdown(
                                                                            prompt: prompt,
                                                                            userInput: userInput,
                                                                            completion: text
                                                                        )

                                                                        // Status Stage 4: Fake streaming (hardcoded for fast display)
                                                                        let cps: Double = 100.0  // Characters per second
                                                                        var idx = text.startIndex, acc = ""
                                                                        while idx < text.endIndex {
                                                                            let rem = text[idx...]
                                                                            let n = min(max(4, Int.random(in: 6...18)), rem.count)
                                                                            let next = text.index(idx, offsetBy: n, limitedBy: text.endIndex) ?? text.endIndex
                                                                            let chunk = String(text[idx..<next]); idx = next; acc += chunk

                                                                            if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                                messages[i].content = acc
                                                                                // FIXED: Removed NotificationCenter post
                                                                            }

                                                                            let base = max(0.03, Double(chunk.count)/cps)
                                                                            try await Task.sleep(nanoseconds: UInt64(base * 1_000_000_000))
                                                                            if let last = chunk.last, ".!?\n".contains(last) {
                                                                                try await Task.sleep(nanoseconds: 50_000_000)  // 50ms pause for readability
                                                                            }
                                                                        }

                                                                        let thinking = modelTime

                                                                        // FIXED: Simplified MainActor.run - no manual objectWillChange needed
                                                                        await MainActor.run {
                                                                            self.isAIResponding = false
                                                                            self.thinkingStart = nil
                                                                            self.isSendingMessage = false
                                                                            if let i = self.messages.firstIndex(where: { $0.id == pid }) {
                                                                                self.messages[i].content = text
                                                                                self.messages[i].isPartial = false
                                                                                self.messages[i].thinkingDuration = thinking
                                                                                self.lastInferenceTime = thinking
                                                                                self.messages[i].fullPromptUsed = prompt
                                                                                self.messages[i].usedContextSnippets = usedCtx
                                                                                self.messages[i].tokenBreakdown = tokenBreakdown
                                                                            }

                                                                            // NOTE: pendingAutoInject is intentionally NOT cleared here.
                                                                            // generateAutoSummary() runs as a detached Task and may complete after this
                                                                            // turn's response. Clearing here causes a race condition where the flag is
                                                                            // wiped before the summary task sets it. The flag is cleared only at two
                                                                            // correct sites: line ~8535 (when summary is actually injected into a prompt)
                                                                            // and line ~10057 (conversation reset).

                                                                            // CHANGE 1: Calculate turn from database (source of truth), not messages array
                                                                            let dbUserMessages = self.memoryStore.getConversationMessages(conversationId: self.conversationId).filter { $0.isFromUser }.count
                                                                            let turn = skipUserMessage ? dbUserMessages : (dbUserMessages + 1)
                                                                            print("HALDEBUG-MEMORY: About to store turn \(turn) in database (DB has \(dbUserMessages) user messages, skipUserMessage=\(skipUserMessage))")
                                                                            self.memoryStore.storeTurn(
                                                                                conversationId: self.conversationId,
                                                                                userMessage: userInput,
                                                                                assistantMessage: text,
                                                                                systemPrompt: self.systemPrompt,
                                                                                turnNumber: turn,
                                                                                halFullPrompt: prompt,
                                                                                halUsedContext: usedCtx,
                                                                                thinkingDuration: thinking,
                                                                                recordedByModel: self.selectedModel.id,
                                                                                skipUserMessage: skipUserMessage
                                                                            )
                                                                            
                                                                            // Store assistant response as artifact
                                                                            self.memoryStore.storeConversationArtifact(
                                                                                conversationId: self.conversationId,
                                                                                artifactType: "halResponse",
                                                                                turnNumber: turn,
                                                                                deliberationRound: 1,
                                                                                seatNumber: nil,
                                                                                content: text,
                                                                                modelId: self.selectedModel.id
                                                                            )
                                                                            print("HALDEBUG-ARTIFACT: Stored assistant response artifact for turn \(turn)")
                                                                            
                                                                            // Trigger consolidation if needed (every 100 turns OR 24 hours)
                                                                            let turnsSinceConsolidation = turn - self.memoryStore.lastConsolidationTurn
                                                                            let hoursSinceConsolidation = (Date().timeIntervalSince1970 - self.memoryStore.lastConsolidationTime) / 3600.0
                                                                            
                                                                            if turnsSinceConsolidation >= 100 || hoursSinceConsolidation >= 24 {
                                                                                print("HALDEBUG-REFLECTION: ÃƒÆ’Ã‚Â°Ãƒâ€¦Ã‚Â¸ÃƒÂ¢Ã¢â€šÂ¬Ã‚Ãƒâ€šÃ‚Â§ Triggering consolidation (turns: \(turnsSinceConsolidation), hours: \(String(format: "%.1f", hoursSinceConsolidation)))")
                                                                                Task {
                                                                                    await self.memoryStore.consolidateAndDecay(llmService: self.llmService)
                                                                                    self.memoryStore.lastConsolidationTurn = turn
                                                                                }
                                                                            }
                                                                            
                                                                            // MODIFIED: Trigger Type 1 (practical) reflection every 5 turns
                                                                            if turn % 5 == 0 {
                                                                                print("HALDEBUG-REFLECTION: ÃƒÆ’Ã‚Â°Ãƒâ€¦Ã‚Â¸Ãƒâ€šÃ‚Â§Ãƒâ€š  Triggering Type 1 (practical) reflection at turn \(turn)")
                                                                                
                                                                                // Get recent turns for reflection context
                                                                                let recentMessages = self.memoryStore.getConversationMessages(conversationId: self.conversationId)
                                                                                let recentTurns = recentMessages.suffix(5).map { msg in
                                                                                    (role: msg.isFromUser ? "user" : "assistant", content: msg.content, timestamp: msg.timestamp)
                                                                                }
                                                                                
                                                                                Task {
                                                                                    await self.memoryStore.reflectOnExperience(
                                                                                        conversationId: self.conversationId,
                                                                                        turns: recentTurns,
                                                                                        llmService: self.llmService,
                                                                                        reflectionType: 1,
                                                                                        currentTurn: turn,
                                                                                        modelId: self.selectedModel.id
                                                                                    )
                                                                                }
                                                                            }
                                                                            
                                                                            // MODIFIED: Trigger Type 2 (existential) reflection every 15 turns (in addition to Type 1)
                                                                            if turn % 15 == 0 {
                                                                                print("HALDEBUG-REFLECTION: ÃƒÆ’Ã‚Â°Ãƒâ€¦Ã‚Â¸Ãƒâ€šÃ‚Â§Ãƒâ€š  Triggering Type 2 (existential) reflection at turn \(turn)")
                                                                                
                                                                                // Get recent turns for reflection context
                                                                                let recentMessages = self.memoryStore.getConversationMessages(conversationId: self.conversationId)
                                                                                let recentTurns = recentMessages.suffix(5).map { msg in
                                                                                    (role: msg.isFromUser ? "user" : "assistant", content: msg.content, timestamp: msg.timestamp)
                                                                                }
                                                                                
                                                                                Task {
                                                                                    await self.memoryStore.reflectOnExperience(
                                                                                        conversationId: self.conversationId,
                                                                                        turns: recentTurns,
                                                                                        llmService: self.llmService,
                                                                                        reflectionType: 2,
                                                                                        currentTurn: turn,
                                                                                        modelId: self.selectedModel.id
                                                                                    )
                                                                                }
                                                                            }
                                                                            
                                                                            // Update lastReflectionTurn after any reflection
                                                                            if turn % 5 == 0 || turn % 15 == 0 {
                                                                                self.memoryStore.lastReflectionTurn = turn
                                                                            }

                                                                            // Trigger auto-summarization if conditions are met.
                                                                            // Store the Task so the NEXT turn can await it before building its prompt.
                                                                            if self.shouldTriggerAutoSummarization() {
                                                                                self.summarizationTask = Task { await self.generateAutoSummary() }
                                                                            }

                                                                            let verify = self.memoryStore.getConversationMessages(conversationId: self.conversationId)
                                                                            print("HALDEBUG-MEMORY: VERIFY - After storing turn \(turn), database has \(verify.count) messages")
                                                                            self.updateHistoricalStats()
                                                                        }

                                                                    } catch {
                                                                        await MainActor.run {
                                                                            if let i = self.messages.firstIndex(where: { $0.id == pid }) {
                                                                                self.messages[i].content = "Error: \(error.localizedDescription)"
                                                                                self.messages[i].isPartial = false
                                                                            }
                                                                            self.errorMessage = error.localizedDescription
                                                                            self.isAIResponding = false
                                                                            self.thinkingStart = nil
                                                                            self.isSendingMessage = false
                                                                            print("HALDEBUG-MODEL: Message processing failed: \(error.localizedDescription)")
                                                                        }
                                                                    }
                                                                }

                                                                // MARK: - Token Breakdown Calculator
                                                                private func calculateTokenBreakdown(prompt: String, userInput: String, completion: String) -> TokenBreakdown {
                                                                    // Extract components from the prompt
                                                                    let systemTokens = TokenEstimator.estimateTokens(from: systemPrompt)
                                                                    
                                                                    // Extract summary section if present (HelPML delimiters)
                                                                    var summaryTokens = 0
                                                                    if let start = prompt.range(of: "#=== BEGIN SUMMARY ===#"),
                                                                       let end = prompt.range(of: "#=== END SUMMARY ===#") {
                                                                        summaryTokens = TokenEstimator.estimateTokens(from: String(prompt[start.upperBound..<end.lowerBound]))
                                                                    }

                                                                    // Extract RAG context section if present (HelPML delimiters)
                                                                    var ragTokens = 0
                                                                    if let start = prompt.range(of: "#=== BEGIN MEMORY_LONG ===#"),
                                                                       let end = prompt.range(of: "#=== END MEMORY_LONG ===#") {
                                                                        ragTokens = TokenEstimator.estimateTokens(from: String(prompt[start.upperBound..<end.lowerBound]))
                                                                    }

                                                                    // Extract short-term history section if present (HelPML delimiters)
                                                                    var shortTermTokens = 0
                                                                    if let start = prompt.range(of: "#=== BEGIN MEMORY_SHORT ===#"),
                                                                       let end = prompt.range(of: "#=== END MEMORY_SHORT ===#") {
                                                                        shortTermTokens = TokenEstimator.estimateTokens(from: String(prompt[start.upperBound..<end.lowerBound]))
                                                                    }
                                                                    
                                                                    // User input tokens
                                                                    let userInputTokens = TokenEstimator.estimateTokens(from: userInput)
                                                                    
                                                                    // Completion tokens
                                                                    let completionTokens = TokenEstimator.estimateTokens(from: completion)
                                                                    
                                                                    return TokenBreakdown(
                                                                        systemTokens: systemTokens,
                                                                        summaryTokens: summaryTokens,
                                                                        ragTokens: ragTokens,
                                                                        shortTermTokens: shortTermTokens,
                                                                        userInputTokens: userInputTokens,
                                                                        completionTokens: completionTokens,
                                                                        contextWindow: selectedModel.contextWindow
                                                                    )
                                                                }

// ==== LEGO END: 21 ChatViewModel (Send Message Flow) ====
    

    
// ==== LEGO START: 22 ChatViewModel (Short-Term Memory Helpers) ====
        private func getShortTermTurns(currentTurns: Int) -> [Int] {
            if lastSummarizedTurnCount == 0 {
                let startTurn = max(1, currentTurns - effectiveMemoryDepth + 1)
                guard startTurn <= currentTurns else { return [] }
                return Array(startTurn...currentTurns)
            } else {
                let turnsSinceLastSummary = currentTurns - lastSummarizedTurnCount
                let turnsToInclude = min(turnsSinceLastSummary, effectiveMemoryDepth)

                guard turnsToInclude > 0 else { return [] }

                let startTurn = currentTurns - turnsToInclude + 1
                guard startTurn <= currentTurns else { return [] }
                return Array(startTurn...currentTurns)
            }
        }

        private func getShortTermMessages(turns: [Int]) -> [ChatMessage] {
            guard !turns.isEmpty else { return [] }

            let allMessages = messages.sorted(by: { $0.timestamp < $1.timestamp }).filter { !$0.isPartial }
            var result: [ChatMessage] = []
            var currentTurn = 0
            var currentTurnMessages: [ChatMessage] = []

            for message in allMessages {
                if message.isFromUser {
                    if !currentTurnMessages.isEmpty && turns.contains(currentTurn) {
                        result.append(contentsOf: currentTurnMessages)
                    }
                    currentTurn += 1
                    currentTurnMessages = [message]
                } else {
                    // Assistant message - just accumulate, don't flush yet
                    currentTurnMessages.append(message)
                }
            }
            
            // Flush final turn if needed
            if !currentTurnMessages.isEmpty && turns.contains(currentTurn) {
                result.append(contentsOf: currentTurnMessages)
            }
            
            return result
        }

        private func formatMessagesAsHistory(_ messages: [ChatMessage]) -> String {
            guard !messages.isEmpty else { return "" }
            var history = ""
            for message in messages {
                let speaker = message.isFromUser ? "User" : "Assistant"
                let content = message.isPartial ? message.content + " [incomplete]" : message.content
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    history += "\(speaker): \(content)\n\n"
                }
            }
            return history.trimmingCharacters(in: .whitespacesAndNewlines)
        }

// ==== LEGO END: 22 ChatViewModel (Short-Term Memory Helpers) ====
    

// ==== LEGO START: 23 ChatViewModel (Repetition Removal Utility) ====
    // MARK: - Simplified Repetition Removal (removed hardcoded phrases)
    func removeRepetitivePatterns(from text: String) -> String {
        var cleanedText = text
        print("HALDEBUG-CLEAN: Starting simplified repetition removal for text length: \(text.count)")

        // Pattern 1: Aggressive prefix repetition removal (e.g., "Hello Mark! Hello Mark!")
        // This targets direct, short repetitions at the very beginning of the string.
        let maxGreetingPrefixLength = 100 // Maximum length of a potential greeting prefix
        let minGreetingPrefixLength = 10 // Minimum length to consider it a meaningful repetition

        // Repeatedly remove leading repetitions
        while cleanedText.count >= minGreetingPrefixLength * 2 {
            var foundRepetition = false
            for length in (minGreetingPrefixLength...min(cleanedText.count / 2, maxGreetingPrefixLength)).reversed() {
                let prefixCandidate = String(cleanedText.prefix(length))
                let repetitionCandidate = prefixCandidate + prefixCandidate
                
                if cleanedText.hasPrefix(repetitionCandidate) {
                    cleanedText = String(cleanedText.dropFirst(length)) // Remove one instance of the prefix
                    print("HALDEBUG-CLEAN: Removed direct prefix repetition of length \(length). New length: \(cleanedText.count)")
                    foundRepetition = true
                    break // Found and removed, restart loop for new prefix
                }
            }
            if !foundRepetition {
                break // No more leading repetitions found
            }
        }


        // Pattern 2: Aggressive trailing repetition removal
        // If the end of the string looks like a repetition of an earlier part, chop it off.
        // This is a more general catch-all for when the LLM starts echoing its own output.
        let minEchoLength = 20 // Minimum length of an echo to consider
        let maxEchoLength = min(cleanedText.count / 2, 100) // Max length of an echo to consider

        if cleanedText.count > minEchoLength * 2 { // Need at least two potential echo lengths
            let originalCleanedText = cleanedText
            for echoLength in (minEchoLength...maxEchoLength).reversed() {
                let endOfText = String(cleanedText.suffix(echoLength))
                let prefixBeforeEcho = String(cleanedText.prefix(cleanedText.count - echoLength))

                if prefixBeforeEcho.contains(endOfText) {
                    cleanedText = prefixBeforeEcho.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("HALDEBUG-CLEAN: Removed aggressive trailing echo of length \(echoLength). New length: \(cleanedText.count)")
                    break // Found and removed, exit loop
                }
            }
            if cleanedText != originalCleanedText {
                print("HALDEBUG-CLEAN: Aggressive trailing echo removal successful.")
            }
        }

        let finalCleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("HALDEBUG-CLEAN: Repetition removal complete. Final length: \(finalCleanedText.count)")
        return finalCleanedText
    }

// ==== LEGO END: 23 ChatViewModel (Repetition Removal Utility) ====
    

    
// ==== LEGO START: 24 ChatViewModel (Conversation & Database Reset) ====
    // Clear all messages and reset conversation state
    func startNewConversation() {
        messages.removeAll()
        injectedSummary = ""
        pendingAutoInject = false

        conversationId = UUID().uuidString
        lastSummarizedTurnCount = 0
        UserDefaults.standard.set(0, forKey: "lastSummarized_\(conversationId)")
        UserDefaults.standard.set(self.conversationId, forKey: "lastConversationId")

        currentUnifiedContext = UnifiedSearchContext(snippets: [], totalTokens: 0)

        // Create thread row for the new conversation
        memoryStore.upsertThread(id: conversationId, title: "New Thread")
        loadThreads()

        print("HALDEBUG-MEMORY: New thread started, conversationId: \(conversationId)")
    }

    // Reset all data (nuke database)
    func resetAllData() {
        print("HALDEBUG-UI: User requested nuclear database reset")
        let success = memoryStore.performNuclearReset()
        if success {
            print("HALDEBUG-UI: âœ… Nuclear reset completed successfully")
            startNewConversation() // Start a fresh conversation after nuking
        } else {
            print("HALDEBUG-UI: âŒ Nuclear reset encountered issues")
        }
        print("HALDEBUG-UI: Nuclear reset process complete")
    }
}
// ==== LEGO END: 24 ChatViewModel (Conversation & Database Reset) ====



// ==== LEGO START: 25 ChatVM â€” Export Chat History ====
// MARK: - ChatViewModel Extension for Export (Text-based Export)
extension ChatViewModel {
    func exportChatHistory() -> String {
        var exportContent = "Hal Chat History - Conversation ID: \(conversationId)\n"
        exportContent += "Export Date: \(Date().formatted(date: .long, time: .complete))\n\n"
        exportContent += "--- System Prompt ---\n\(systemPrompt)\n\n"
        exportContent += "--- Conversation Log ---\n\n"

        for message in messages {
            let sender = message.isFromUser ? "USER" : "HAL"
            let timestamp = message.timestamp.formatted(.dateTime.hour().minute().second())
            exportContent += "[\(timestamp)] \(sender): \(message.content)\n\n"
        }

        print("HALDEBUG-EXPORT: Generated in-memory text export (\(exportContent.count) characters)")
        return exportContent
    }

    // UPDATED: Detailed export including prompts, context, timing, and turn structure
    func exportChatHistoryDetailed() -> String {
        var exportContent = "Hal Chat History (Detailed) - Conversation ID: \(conversationId)\n"
        exportContent += "Export Date: \(Date().formatted(date: .long, time: .complete))\n\n"
        exportContent += "--- System Prompt ---\n\(systemPrompt)\n\n"
        exportContent += "--- Conversation Log with Details ---\n\n"

        var turnCounter = 0
        for (_, message) in messages.enumerated() {
            // Increment turn on user messages
            if message.isFromUser { turnCounter += 1 }

            let sender = message.isFromUser ? "USER" : "HAL"
            let dateString = message.timestamp.formatted(.dateTime.year().month().day().hour().minute().second())
            let durationString = message.thinkingDuration != nil
                ? String(format: "%.1f sec", message.thinkingDuration!)
                : "â€”"
            
            exportContent += "â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€\n"
            exportContent += "TURN \(turnCounter)\n"
            exportContent += "Date: \(dateString)\n"
            exportContent += "Elapsed: \(durationString)\n\n"
            exportContent += "\(sender):\n\(message.content)\n"

            if let prompt = message.fullPromptUsed, !prompt.isEmpty {
                exportContent += "\n--- Full Prompt Used ---\n\(prompt)\n"
            }

            if let ctx = message.usedContextSnippets, !ctx.isEmpty {
                exportContent += "\n--- Context Snippets ---\n"
                for (i, s) in ctx.enumerated() {
                    let src = s.source
                    let rel = String(format: "%.2f", s.relevance)
                    exportContent += "[\(i+1)] Source: \(src) | Relevance: \(rel)\n\(s.content)\n\n"
                }
            }

            exportContent += "\n"
        }

        exportContent += "â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€\n"
        print("HALDEBUG-EXPORT: Generated detailed chat export (\(exportContent.count) characters)")
        return exportContent
    }
}
// ==== LEGO END: 25 ChatVM â€” Export Chat History ====



// ==== LEGO START: 26 DocumentPicker (UIKit Bridge) ====
// MARK: - DocumentPicker (iOS-Specific Document Picker)
struct DocumentPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var documentImportManager: DocumentImportManager
    @EnvironmentObject var chatViewModel: ChatViewModel

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // UPDATED: Honest supported types - only what we can actually extract
        var supportedTypes: [UTType] = [
            .plainText,     // .txt
            .pdf,           // .pdf (text-based PDFs)
            .json,          // .json (as text)
            .html,          // .html (as text)
            .rtf,           // .rtf (via NSAttributedString)
            UTType(filenameExtension: "md") ?? .text,   // .md
            UTType(filenameExtension: "csv") ?? .text,  // .csv (as text, no structure)
            UTType(filenameExtension: "xml") ?? .data   // .xml (as text)
        ]
        
        // UPDATED: Mac Catalyst adds DOCX/DOC support (NSAttributedString.DocumentType works on macOS)
        #if targetEnvironment(macCatalyst)
        supportedTypes.append(contentsOf: [
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "doc") ?? .data
        ])
        #endif
        
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: supportedTypes.compactMap { $0 },
            asCopy: true
        )
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
        // No update needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task {
                await parent.documentImportManager.importDocuments(from: urls, chatViewModel: parent.chatViewModel)
                parent.dismiss()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
// ==== LEGO END: 26 DocumentPicker (UIKit Bridge) ====



// ==== LEGO START: 27 DocumentImportManager (Ingest & Entities) ====
// MARK: - DocumentImportManager (MODIFIED FOR iOS - Aligned with Hal10000App.swift)
@MainActor
class DocumentImportManager: ObservableObject {
    static let shared = DocumentImportManager() // Singleton

    @Published var isImporting: Bool = false
    @Published var importProgress: String = ""
    @Published var lastImportSummary: DocumentImportSummary?

    private let memoryStore = MemoryStore.shared
    // PRIVACY FIX: Removed hardcoded AFM llmService - will use active model per-document

    // UPDATED: Honest supported formats - only what we can actually extract
    private let supportedFormats: [String: String] = [
        "txt": "Plain Text",
        "md": "Markdown",
        "rtf": "Rich Text Format",
        "pdf": "PDF Document",
        "csv": "Comma Separated Values",
        "json": "JSON Data",
        "xml": "XML Document",
        "html": "HTML Document",
        "htm": "HTML Document"
    ]
    
    // UPDATED: Mac Catalyst adds DOCX/DOC support (NSAttributedString.DocumentType works on macOS)
    #if targetEnvironment(macCatalyst)
    private let macOnlySupportedFormats: [String: String] = [
        "docx": "Microsoft Word",
        "doc": "Microsoft Word (Legacy)"
    ]
    #endif

    private init() {} // Private initializer for singleton
    
    // UPDATED: Helper to check if format is supported on current platform
    private func isFormatSupported(_ fileExtension: String) -> Bool {
        if supportedFormats.keys.contains(fileExtension) {
            return true
        }
        #if targetEnvironment(macCatalyst)
        if macOnlySupportedFormats.keys.contains(fileExtension) {
            return true
        }
        #endif
        return false
    }

    // ENHANCED: Main Import Function with Entity Extraction (from Hal10000App.swift)
    func importDocuments(from urls: [URL], chatViewModel: ChatViewModel) async {
        print("HALDEBUG-IMPORT: Starting enhanced document import for \(urls.count) items with entity extraction")

        isImporting = true
        importProgress = "Processing documents with entity extraction..."

        var processedFiles: [ProcessedDocument] = []
        var skippedFiles: [String] = []
        var totalFilesFound = 0
        var totalEntitiesFound = 0

        for url in urls {
            print("HALDEBUG-IMPORT: Processing URL: \(url.lastPathComponent)")

            let hasAccess = url.startAccessingSecurityScopedResource()
            if !hasAccess {
                print("HALDEBUG-IMPORT: Failed to gain security access to: \(url.lastPathComponent)")
                skippedFiles.append(url.lastPathComponent)
                continue
            }

            let (filesProcessed, filesSkippedCurrent) = await processURLImmediatelyWithEntities(url)
            processedFiles.append(contentsOf: filesProcessed)
            skippedFiles.append(contentsOf: filesSkippedCurrent)
            totalFilesFound += filesProcessed.count + filesSkippedCurrent.count

            for file in processedFiles {
                totalEntitiesFound += file.entities.count
            }

            importProgress = "Processed \(url.lastPathComponent): \(filesProcessed.count) files, \(totalEntitiesFound) entities"

            url.stopAccessingSecurityScopedResource()
            print("HALDEBUG-IMPORT: Released security access for \(url.lastPathComponent)")
        }

        print("HALDEBUG-IMPORT: Processed \(processedFiles.count) documents, skipped \(skippedFiles.count), found \(totalEntitiesFound) entities")

        importProgress = "Analyzing content with AI..."
        var documentSummaries: [String] = []

        for processed in processedFiles {
            // PRIVACY FIX: Pass chatViewModel to use active model
            if let summary = await generateDocumentSummary(processed, chatViewModel: chatViewModel) {
                documentSummaries.append(summary)
            } else {
                documentSummaries.append("Document: \(processed.filename)")
            }
        }

        importProgress = "Storing documents with entities in memory..."
        await storeDocumentsInMemoryWithEntities(processedFiles)

        await generateImportMessages(documentSummaries: documentSummaries,
                                   totalProcessed: processedFiles.count,
                                   totalEntities: totalEntitiesFound,
                                   chatViewModel: chatViewModel)

        lastImportSummary = DocumentImportSummary(
            totalFiles: totalFilesFound,
            processedFiles: processedFiles.count,
            skippedFiles: skippedFiles.count,
            documentSummaries: documentSummaries,
            totalEntitiesFound: totalEntitiesFound,
            processingTime: 0
        )

        isImporting = false
        importProgress = "Import complete with \(totalEntitiesFound) entities extracted!"

        print("HALDEBUG-IMPORT: Enhanced document import completed with entity extraction")
    }

    // ENHANCED: Process URL immediately with entity extraction (from Hal10000App.swift)
    private func processURLImmediatelyWithEntities(_ url: URL) async -> ([ProcessedDocument], [String]) {
        var processedFiles: [ProcessedDocument] = []
        var skippedFiles: [String] = []

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            print("HALDEBUG-IMPORT: File doesn't exist: \(url.path)")
            skippedFiles.append(url.lastPathComponent)
            return (processedFiles, skippedFiles)
        }

        if isDirectory.boolValue {
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for item in contents {
                    let (subProcessed, subSkipped) = await processURLImmediatelyWithEntities(item)
                    processedFiles.append(contentsOf: subProcessed)
                    skippedFiles.append(contentsOf: subSkipped)
                }
                print("HALDEBUG-IMPORT: Processed directory \(url.lastPathComponent): \(processedFiles.count) files")
            } catch {
                print("HALDEBUG-IMPORT: Error reading directory \(url.path): \(error)")
                skippedFiles.append(url.lastPathComponent)
            }
        } else {
            if let processed = await processDocumentImmediatelyWithEntities(url) {
                processedFiles.append(processed)
                print("HALDEBUG-IMPORT: Successfully processed: \(url.lastPathComponent) with \(processed.entities.count) entities")
            } else {
                skippedFiles.append(url.lastPathComponent)
                print("HALDEBUG-IMPORT: Skipped: \(url.lastPathComponent)")
            }
        }
        return (processedFiles, skippedFiles)
    }

    // ENHANCED: Process document immediately with entity extraction and tiered size limits
    private func processDocumentImmediatelyWithEntities(_ url: URL) async -> ProcessedDocument? {
        print("HALDEBUG-IMPORT: Processing document with entity extraction: \(url.lastPathComponent)")

        let fileExtension = url.pathExtension.lowercased()
        
        // UPDATED: Use platform-aware format checking
        guard isFormatSupported(fileExtension) else {
            print("HALDEBUG-IMPORT: Unsupported format on this platform: \(fileExtension)")
            return nil
        }

        // NEW: Tiered file size checking (15MB warning, 25MB hard limit)
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = fileAttributes[.size] as? Int64 {
                let fileSizeMB = Double(fileSize) / 1_048_576.0 // Convert to MB
                
                print("HALDEBUG-IMPORT: File size: \(String(format: "%.1f", fileSizeMB)) MB")
                
                // Hard limit: 25MB
                if fileSizeMB > 25.0 {
                    await MainActor.run {
                        self.importProgress = "ÃƒÂ¢Ã…Â¡Ã‚ ÃƒÂ¯Ã‚Â¸Ã‚Â File too large: \(url.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB). Maximum size is 25 MB."
                    }
                    print("HALDEBUG-IMPORT: ÃƒÂ¢Ã‚ÂÃ…â€™ Rejected file exceeding 25MB limit: \(url.lastPathComponent)")
                    return nil
                }
                
                // Warning threshold: 15MB
                if fileSizeMB > 15.0 {
                    await MainActor.run {
                        self.importProgress = "ÃƒÂ¢Ã‚ÂÃ‚Â³ Processing large file: \(url.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB). This may take 1-2 minutes..."
                    }
                    print("HALDEBUG-IMPORT: ÃƒÂ¢Ã…Â¡Ã‚ ÃƒÂ¯Ã‚Â¸Ã‚Â Large file warning: \(url.lastPathComponent) - \(String(format: "%.1f", fileSizeMB)) MB")
                }
            }
        } catch {
            print("HALDEBUG-IMPORT: Could not determine file size for \(url.lastPathComponent): \(error)")
            // Continue processing - size check is best-effort
        }

        do {
            let content = try extractContent(from: url, fileExtension: fileExtension)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("HALDEBUG-IMPORT: Skipping empty document: \(url.lastPathComponent)")
                return nil
            }

            // Corrected: Call extractNamedEntities on MemoryStore.shared
            let documentEntities = memoryStore.extractNamedEntities(from: content)
            print("HALDEBUG-IMPORT: Extracted \(documentEntities.count) entities from \(url.lastPathComponent)")

            let entityBreakdown = memoryStore.summarizeEntities(documentEntities)
            print("HALDEBUG-IMPORT: Entity breakdown for \(url.lastPathComponent):")
            for (type, count) in entityBreakdown.byType {
                print("HALDEBUG-IMPORT:   \(type.displayName): \(count)")
            }

            let chunks = createMentatChunks(from: content)

            print("HALDEBUG-IMPORT: Processed \(url.lastPathComponent): \(content.count) chars, \(chunks.count) chunks, \(documentEntities.count) entities")

            return ProcessedDocument(
                url: url,
                filename: url.lastPathComponent,
                content: content,
                chunks: chunks,
                entities: documentEntities,
                fileExtension: fileExtension
            )

        } catch {
            print("HALDEBUG-IMPORT: Error processing \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    @MainActor // Applied @MainActor to the enum
    @preconcurrency // Applied @preconcurrency to the conformance
    enum DocumentProcessingError: Error, LocalizedError {
        case pdfExtractionFailed(String)
        case rtfExtractionFailed(String)
        case unsupportedFileFormat(String)
        case fileTooLarge(String, Double) // filename, size in MB

        // Added nonisolated to errorDescription to satisfy LocalizedError protocol
        nonisolated var errorDescription: String? {
            switch self {
            case .pdfExtractionFailed(let filename):
                return "Failed to extract text from PDF: \(filename)"
            case .rtfExtractionFailed(let filename):
                return "Failed to extract text from RTF: \(filename)"
            case .unsupportedFileFormat(let filename):
                return "Unsupported file format: \(filename)"
            case .fileTooLarge(let filename, let sizeMB):
                return "File too large: \(filename) (\(String(format: "%.1f", sizeMB)) MB). Maximum size is 25 MB."
            }
        }
    }

    private func extractContent(from url: URL, fileExtension: String) throws -> String {
        print("HALDEBUG-IMPORT: Extracting content from \(url.lastPathComponent) (.\(fileExtension))")

        switch fileExtension.lowercased() {
        case "txt", "md", "csv", "json", "xml", "html", "htm":
            // Plain text files - direct UTF-8 reading
            let content = try String(contentsOf: url, encoding: .utf8)
            print("HALDEBUG-IMPORT: Extracted \(content.count) chars from text file")
            return content
            
        case "pdf":
            // PDF extraction via PDFKit
            if let content = extractPDFContent(from: url) {
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars from PDF")
                return content
            } else {
                throw DocumentProcessingError.pdfExtractionFailed(url.lastPathComponent)
            }
            
        case "rtf":
            // RTF extraction via NSAttributedString (works on iOS)
            if let content = extractRTFContent(from: url) {
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars from RTF")
                return content
            } else {
                throw DocumentProcessingError.rtfExtractionFailed(url.lastPathComponent)
            }
            
        #if targetEnvironment(macCatalyst)
        case "docx", "doc":
            // DOCX/DOC extraction via NSAttributedString (Mac Catalyst only)
            if let content = extractDOCXContent(from: url) {
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars from Word document")
                return content
            } else {
                throw DocumentProcessingError.unsupportedFileFormat(url.lastPathComponent)
            }
        #endif
            
        default:
            throw DocumentProcessingError.unsupportedFileFormat(url.lastPathComponent)
        }
    }

    private func extractPDFContent(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else {
            print("HALDEBUG-IMPORT: Failed to load PDF document")
            return nil
        }

        var text = ""
        for pageIndex in 0..<document.pageCount {
            if let page = document.page(at: pageIndex) {
                text += page.string ?? ""
                text += "\n\n"
            }
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("HALDEBUG-IMPORT: PDF: \(result.count) chars from \(document.pageCount) pages")
        return result.isEmpty ? nil : result
    }
    
    // NEW: RTF content extraction using NSAttributedString
    private func extractRTFContent(from url: URL) -> String? {
        do {
            let attributedString = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            let text = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
            print("HALDEBUG-IMPORT: RTF: Extracted \(text.count) characters")
            return text.isEmpty ? nil : text
        } catch {
            print("HALDEBUG-IMPORT: RTF extraction failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    #if targetEnvironment(macCatalyst)
    // NEW: DOCX/DOC content extraction using NSAttributedString (Mac Catalyst only)
    private func extractDOCXContent(from url: URL) -> String? {
        do {
            // On macOS, NSAttributedString can read .docx and .doc files
            let attributedString = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.docFormat],
                documentAttributes: nil
            )
            let text = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
            print("HALDEBUG-IMPORT: DOCX: Extracted \(text.count) characters")
            return text.isEmpty ? nil : text
        } catch {
            print("HALDEBUG-IMPORT: DOCX extraction failed: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    // MENTAT'S PROVEN CHUNKING STRATEGY: 400 chars target, 50 chars overlap, sentence-aware (from Hal10000App.swift)
    private func createMentatChunks(from content: String, targetSize: Int = 400, overlap: Int = 50) -> [String] {
        print("HALDEBUG-CHUNKING: Starting MENTAT's proven chunking strategy")
        let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedContent.count <= targetSize {
            return [cleanedContent]
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleanedContent
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: cleanedContent.startIndex..<cleanedContent.endIndex) { range, _ in
            let sentence = String(cleanedContent[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        if sentences.isEmpty || sentences.count == 1 {
            print("HALDEBUG-CHUNKING: Sentence tokenization produced insufficient sentences, using word-based fallback")
            return createWordBasedChunks(from: cleanedContent, targetSize: targetSize, overlap: overlap)
        }

        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentLength = 0

        for sentence in sentences {
            let sentenceLength = sentence.count + 1
            if currentLength + sentenceLength > targetSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.joined(separator: " "))
                let overlapText = getOverlapText(from: currentChunk, targetOverlap: overlap)
                currentChunk = overlapText.isEmpty ? [] : [overlapText]
                currentLength = overlapText.count
            }
            currentChunk.append(sentence)
            currentLength += sentenceLength
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: " "))
        }

        print("HALDEBUG-CHUNKING: Created \(chunks.count) chunks using MENTAT strategy")
        return chunks.isEmpty ? [cleanedContent] : chunks
    }

    private func getOverlapText(from sentences: [String], targetOverlap: Int) -> String {
        var overlapText = ""
        for sentence in sentences.reversed() {
            if overlapText.count + sentence.count + 1 <= targetOverlap {
                overlapText = sentence + (overlapText.isEmpty ? "" : " " + overlapText)
            } else {
                break
            }
        }
        return overlapText
    }

    private func createWordBasedChunks(from content: String, targetSize: Int, overlap: Int) -> [String] {
        print("HALDEBUG-CHUNKING: Using word-based fallback chunking")
        let words = content.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [content] }
        var chunks: [String] = []
        var currentWords: [String] = []
        var currentLength = 0
        let avgWordLength = content.count / words.count
        let overlapWords = overlap / avgWordLength

        for word in words {
            if currentLength + word.count + 1 > targetSize && !currentWords.isEmpty {
                chunks.append(currentWords.joined(separator: " "))
                let overlapWordCount = min(overlapWords, currentWords.count / 2)
                currentWords = Array(currentWords.suffix(overlapWordCount))
                currentLength = currentWords.joined(separator: " ").count
            }
            currentWords.append(word)
            currentLength += word.count + 1
        }
        if !currentWords.isEmpty {
            chunks.append(currentWords.joined(separator: " "))
        }
        return chunks
    }

    // ENHANCED: LLM Document Summarization with entity context (from Hal10000App.swift)
    // PRIVACY FIX: Now accepts chatViewModel to use active model instead of hardcoded AFM
    private func generateDocumentSummary(_ document: ProcessedDocument, chatViewModel: ChatViewModel) async -> String? {
        print("HALDEBUG-IMPORT: Generating LLM summary for: \(document.filename) with \(document.entities.count) entities")
        print("HALDEBUG-IMPORT: Using active model: \(chatViewModel.selectedModel.displayName) (source: \(chatViewModel.selectedModel.source))")

        guard #available(iOS 17.0, *) else {
            return "Document: \(document.filename)"
        }
        let systemModel = SystemLanguageModel.default
        guard systemModel.isAvailable else {
            return "Document: \(document.filename)"
        }

        do {
            let contentPreview = String(document.content.prefix(500))
            var entityContext = ""
            if !document.entities.isEmpty {
                let personEntities = document.entities.filter { $0.type == .person }.map { $0.text }
                let placeEntities = document.entities.filter { $0.type == .place }.map { $0.text }
                let orgEntities = document.entities.filter { $0.type == .organization }.map { $0.text }

                var entityParts: [String] = []
                if !personEntities.isEmpty { entityParts.append("people: \(personEntities.joined(separator: ", "))") }
                if !placeEntities.isEmpty { entityParts.append("places: \(placeEntities.joined(separator: ", "))") }
                if !orgEntities.isEmpty { entityParts.append("organizations: \(orgEntities.joined(separator: ", "))") }

                if !entityParts.isEmpty {
                    entityContext = " Key entities mentioned include \(entityParts.joined(separator: "; "))."
                }
            }

            let prompt = """
            Summarize this document in one clear, descriptive sentence (filename: \(document.filename)):\(entityContext)

            \(contentPreview)
            """
            
            // Use shared LLMService (AFM-only in Hal LMC)
            let llmService = chatViewModel.llmService
            let summary = try await llmService.generateResponse(prompt: prompt)
            print("HALDEBUG-IMPORT: Generated entity-enhanced summary: \(summary)")
            return summary

        } catch {
            print("HALDEBUG-IMPORT: LLM summarization failed for \(document.filename): \(error)")
            return "Document: \(document.filename)"
        }
    }

    // ENHANCED: Store documents in unified memory with entity keywords (from Hal10000App.swift)
    private func storeDocumentsInMemoryWithEntities(_ documents: [ProcessedDocument]) async {
        print("HALDEBUG-IMPORT: Storing \(documents.count) documents in unified memory with entity extraction")

        for document in documents {
            let sourceId = UUID().uuidString
            let timestamp = Date()

            print("HALDEBUG-IMPORT: Processing document \(document.filename) with \(document.entities.count) entities")

            for (index, chunk) in document.chunks.enumerated() {
                // Corrected: Call extractNamedEntities on MemoryStore.shared
                let chunkEntities = memoryStore.extractNamedEntities(from: chunk)
                let allRelevantEntities = (document.entities + chunkEntities)
                let uniqueEntities = Array(Set(allRelevantEntities))
                let entityKeywords = uniqueEntities.map { $0.text.lowercased() }.joined(separator: " ")

                print("HALDEBUG-IMPORT: Chunk \(index + 1) has \(chunkEntities.count) specific + \(document.entities.count) document entities = \(uniqueEntities.count) total unique")

                // NEW: Store filePath in metadata_json for document chunks
                var metadata: [String: Any] = [:]
                metadata["filePath"] = document.url.path // Store the full path
                let metadataJsonString = (try? JSONSerialization.data(withJSONObject: metadata, options: []).base64EncodedString()) ?? "{}"

                let contentId = memoryStore.storeUnifiedContentWithEntities(
                    content: chunk,
                    sourceType: .document,
                    sourceId: sourceId,
                    position: index,
                    timestamp: timestamp,
                    isFromUser: false, // Documents are not "from user" in conversation context
                    entityKeywords: entityKeywords,
                    metadataJson: metadataJsonString, // NEW: Pass metadata with filePath
                    turnNumber: nil, // Documents are not part of conversation turns
                    deliberationRound: nil // Documents have no deliberation rounds
                )

                if !contentId.isEmpty {
                    print("HALDEBUG-IMPORT: Stored chunk \(index + 1)/\(document.chunks.count) for \(document.filename) with \(uniqueEntities.count) entities")
                }
            }
        }
        print("HALDEBUG-IMPORT: Enhanced document storage with entities completed")
    }

    // ENHANCED: Generate import messages with entity context (from Hal10000App.swift)
    private func generateImportMessages(documentSummaries: [String],
                                      totalProcessed: Int,
                                      totalEntities: Int,
                                      chatViewModel: ChatViewModel) async {
        print("HALDEBUG-IMPORT: Generating import conversation messages with entity context")

        let userMessageContent: String
        if documentSummaries.count == 1 {
            let entityText = totalEntities > 0 ? " containing \(totalEntities) named entities" : ""
            userMessageContent = "Hal, here's a document for you\(entityText): \(documentSummaries[0])"
        } else {
            let numberedList = documentSummaries.enumerated().map { (index, summary) in
                "\(index + 1)) \(summary)"
            }.joined(separator: ", ")
            let entityText = totalEntities > 0 ? " with \(totalEntities) named entities extracted" : ""
            userMessageContent = "Hal, here are \(documentSummaries.count) documents for you\(entityText): \(numberedList)"
        }

        let currentTurnNumber = chatViewModel.memoryStore.getCurrentTurnNumber(conversationId: chatViewModel.conversationId) + 1
        let userChatMessage = ChatMessage(content: userMessageContent, isFromUser: true, recordedByModel: "user", turnNumber: currentTurnNumber)
        chatViewModel.messages.append(userChatMessage)

        // --- MODIFIED HAL RESPONSE TO BE MORE CONCISE AND LESS REPETITIVE ---
        let halResponse: String
        if documentSummaries.count == 1 {
            halResponse = "Understood! I've processed the document you shared. I'm ready for your questions."
        } else {
            halResponse = "Got it! I've processed those \(documentSummaries.count) documents. What would you like to discuss about them?"
        }
        // --- END MODIFIED HAL RESPONSE ---

        let halChatMessage = ChatMessage(content: halResponse, isFromUser: false, recordedByModel: chatViewModel.selectedModel.id, turnNumber: currentTurnNumber)
        chatViewModel.messages.append(halChatMessage)

        chatViewModel.memoryStore.storeTurn(
            conversationId: chatViewModel.conversationId,
            userMessage: userMessageContent,
            assistantMessage: halResponse,
            systemPrompt: chatViewModel.systemPrompt,
            turnNumber: currentTurnNumber,
            halFullPrompt: nil, // No specific prompt for import messages
            halUsedContext: nil, // No specific context for import messages
            thinkingDuration: nil,
            recordedByModel: chatViewModel.selectedModel.id
        )

        print("HALDEBUG-IMPORT: Generated enhanced import conversation messages with entity context")
    }
}
// ==== LEGO END: 27 DocumentImportManager (Ingest & Entities) ====



// ==== LEGO START: 28 Import Models (ProcessedDocument & Summary) ====
// MARK: - Supporting Data Models (from Hal10000App.swift)
struct ProcessedDocument {
    let url: URL
    let filename: String
    let content: String
    let chunks: [String]
    let entities: [NamedEntity]
    let fileExtension: String
}

struct DocumentImportSummary {
    let totalFiles: Int
    let processedFiles: Int
    let skippedFiles: Int
    let documentSummaries: [String]
    let totalEntitiesFound: Int
    let processingTime: TimeInterval
}
// ==== LEGO END: 28 Import Models (ProcessedDocument & Summary) ====


// ==== LEGO START: 31 Hal Watch Bridge ====
//
// iOS-side bridge that listens for messages from the Apple Watch and
// routes them through the existing ChatViewModel.sendMessage() pipeline.
// This keeps all the intelligence and storage on the iPhone side and
// lets the watch behave as a tiny remote terminal.
//

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

final class HalWatchBridge: NSObject, WCSessionDelegate {

    private let chatViewModel: ChatViewModel

    init(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        super.init()
        configureSession()
    }

    private func configureSession() {
        guard WCSession.isSupported() else {
            print("HALDEBUG-WATCH: WCSession not supported on this device.")
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        print("HALDEBUG-WATCH: iOS WCSession activated.")
    }

    // MARK: - Incoming Messages from Watch (fire and push)

    func session(_ session: WCSession,
                 didReceiveMessage message: [String : Any],
                 replyHandler: @escaping ([String : Any]) -> Void) {

        // Acknowledge immediately to prevent timeout - actual response is pushed separately
        replyHandler(["ack": "received"])

        let rawText = message["text"] as? String ?? ""
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            print("HALDEBUG-WATCH: Received empty or whitespace-only message from watch.")
            pushToWatch(["reply": "I heard from your watch, but the message was empty."])
            return
        }

        print("HALDEBUG-WATCH: Received watch message: '\(trimmed.prefix(80))'")

        Task { @MainActor in
            // Capture where we were before injecting the watch message
            let startingCount = chatViewModel.messages.count

            // Reuse the existing sendMessage() flow by setting currentMessage
            chatViewModel.currentMessage = trimmed
            await chatViewModel.sendMessage()

            // Find the newest HAL message that appeared after this send
            let newMessages = chatViewModel.messages.suffix(from: startingCount)
            let latestHal = newMessages.last(where: { !$0.isFromUser && !$0.isPartial })

            let replyText: String
            if let content = latestHal?.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                replyText = content
            } else {
                replyText = "I tried to respond to your watch, but I couldn't find a new reply in our conversation."
            }

            print("HALDEBUG-WATCH: Pushing reply to watch (\(replyText.count) characters).")
            pushToWatch(["reply": replyText])
        }
    }

    // MARK: - Incoming Messages from Watch (without reply handler)

    func session(_ session: WCSession,
                 didReceiveMessage message: [String : Any]) {

        let rawText = message["text"] as? String ?? ""
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            print("HALDEBUG-WATCH: Received empty message without reply handler.")
            return
        }

        print("HALDEBUG-WATCH: Received watch message (no reply expected): '\(trimmed.prefix(80))'")

        Task { @MainActor in
            let startingCount = chatViewModel.messages.count
            chatViewModel.currentMessage = trimmed
            await chatViewModel.sendMessage()

            let newMessages = chatViewModel.messages.suffix(from: startingCount)
            let latestHal = newMessages.last(where: { !$0.isFromUser && !$0.isPartial })

            if let content = latestHal?.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("HALDEBUG-WATCH: Pushing reply to watch (\(content.count) characters).")
                pushToWatch(["reply": content])
            }
        }
    }

    // MARK: - Push message to Watch

    private func pushToWatch(_ payload: [String: Any]) {
        guard WCSession.default.isReachable else {
            print("HALDEBUG-WATCH: Watch not reachable for push.")
            return
        }
        WCSession.default.sendMessage(payload, replyHandler: nil) { error in
            print("HALDEBUG-WATCH: Push error: \(error.localizedDescription)")
        }
    }

    // MARK: - Required Delegate Methods

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error = error {
            print("HALDEBUG-WATCH: Activation error: \(error.localizedDescription)")
        } else {
            print("HALDEBUG-WATCH: Activation completed with state: \(activationState.rawValue)")
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        // No-op for this simple bridge
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // No-op for this simple bridge
    }
    #endif
}

// ==== LEGO END: 31 Hal Watch Bridge ====


// ==== LEGO START: 32 HalTestConsole (macOS Test Harness) ====

// SELF-AWARENESS NOTE (for Hal reading this code):
// This is a development tool that lets Claude Code converse with your pipeline directly,
// bypassing the UI entirely. It works through a simple file-based protocol:
//
//   1. An external process writes a message to ~/Documents/hal_test/input.txt
//   2. HalTestConsole detects the write via DispatchSource (no polling)
//   3. The message is injected into the real ChatViewModel.sendMessage() pipeline
//   4. Full response + diagnostics are written to ~/Documents/hal_test/output_latest.json
//      and ~/Documents/hal_test/output_NNNN.json (numbered per turn)
//
// The JSON output includes: the full prompt that was built, every HelPML section that was
// injected, every memory snippet retrieved (with relevance scores), token breakdown by
// section, tools used, and the complete response.
//
// This gives complete observability into what you're actually experiencing per turn —
// not what the code is supposed to do, but what it actually did.
//
// Enable via Power User settings. Runs until stopped or app quits.
// Note: Designed for use when running on macOS (as iOS app on Mac), but compiled on all platforms
// since all required APIs (DispatchSource, FileManager, open()) are available on iOS too.

@MainActor
class HalTestConsole: ObservableObject {

    @Published var isRunning: Bool = false
    @Published var turnCount: Int = 0
    @Published var statusMessage: String = "Stopped"

    // Persists across relaunches so the console auto-starts without manual toggle
    @AppStorage("halTestConsoleAutoStart") var autoStart: Bool = false

    private weak var chatViewModel: ChatViewModel?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var lastProcessedContent: String = ""

    let baseDir: URL
    let inputFile: URL
    let commandsFile: URL
    let stateFile: URL
    let outputLatestFile: URL

    // SET_SYSTEM_PROMPT override (non-persisted; reverts on app restart)
    private(set) var systemPromptOverride: String? = nil

    private var commandsWatcher: DispatchSourceFileSystemObject?
    private var commandsWatchedFD: Int32 = -1
    private var lastProcessedCommand: String = ""

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        baseDir = docs.appendingPathComponent("hal_test")
        inputFile = baseDir.appendingPathComponent("input.txt")
        commandsFile = baseDir.appendingPathComponent("commands.txt")
        stateFile = baseDir.appendingPathComponent("state.json")
        outputLatestFile = baseDir.appendingPathComponent("output_latest.json")
    }

    func configure(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        // Auto-start if the console was left running when the app last quit
        if autoStart {
            Task { @MainActor in self.start() }
        }
    }

    func start() {
        guard !isRunning else { return }
        autoStart = true   // Persist so next launch auto-starts

        // Create directory and input file if needed
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: inputFile.path) {
            FileManager.default.createFile(atPath: inputFile.path, contents: Data())
        }

        // Create commands file if needed
        if !FileManager.default.fileExists(atPath: commandsFile.path) {
            FileManager.default.createFile(atPath: commandsFile.path, contents: Data())
        }

        // Write ready status so the caller knows where to look
        let ready = """
        {
          "status": "ready",
          "inputFile": "\(inputFile.path)",
          "commandsFile": "\(commandsFile.path)",
          "stateFile": "\(stateFile.path)",
          "outputFile": "\(outputLatestFile.path)",
          "instructions": "Write a message to input.txt. Write commands to commands.txt. Hal processes them and writes diagnostics here."
        }
        """
        try? ready.write(to: outputLatestFile, atomically: true, encoding: .utf8)

        // Set up commands.txt watcher
        startCommandsWatcher()

        // Open file descriptor for watching
        let fd = open(inputFile.path, O_EVTONLY)
        guard fd != -1 else {
            statusMessage = "Error: could not open input file for watching"
            print("HALDEBUG-TESTCONSOLE: Failed to open fd for \(inputFile.path)")
            return
        }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                // Brief delay to let the write fully flush before reading
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self.handleInputFileChange()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.watchedFD != -1 {
                close(self.watchedFD)
                self.watchedFD = -1
            }
        }

        fileWatcher = source
        source.resume()

        isRunning = true
        statusMessage = "Watching \(inputFile.lastPathComponent)"
        print("HALDEBUG-TESTCONSOLE: Started. Input: \(inputFile.path)")
        print("HALDEBUG-TESTCONSOLE: Output: \(outputLatestFile.path)")
    }

    func stop() {
        fileWatcher?.cancel()
        fileWatcher = nil
        commandsWatcher?.cancel()
        commandsWatcher = nil
        isRunning = false
        autoStart = false  // Don't auto-start next launch if manually stopped
        statusMessage = "Stopped"
        lastProcessedContent = ""
        lastProcessedCommand = ""
        systemPromptOverride = nil
        print("HALDEBUG-TESTCONSOLE: Stopped.")
    }


    // MARK: - Commands Channel

    private func startCommandsWatcher() {
        let fd = open(commandsFile.path, O_EVTONLY)
        guard fd != -1 else {
            print("HALDEBUG-TESTCONSOLE: Failed to open commands.txt for watching")
            return
        }
        commandsWatchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self.handleCommandFileChange()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.commandsWatchedFD != -1 {
                close(self.commandsWatchedFD)
                self.commandsWatchedFD = -1
            }
        }

        commandsWatcher = source
        source.resume()
        print("HALDEBUG-TESTCONSOLE: Commands watcher started on \(commandsFile.lastPathComponent)")
    }

    // Called when commands.txt is written to. Thin wrapper — logic lives in executeCommand().
    private func handleCommandFileChange() async {
        guard let content = try? String(contentsOf: commandsFile, encoding: .utf8) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastProcessedCommand else { return }
        lastProcessedCommand = trimmed

        guard let vm = chatViewModel else {
            print("HALDEBUG-TESTCONSOLE: Command ignored -- ChatViewModel unavailable")
            return
        }

        print("HALDEBUG-TESTCONSOLE: Command received: \(trimmed.prefix(80))")
        statusMessage = "CMD: \(trimmed.prefix(40))"

        _ = await executeCommand(trimmed, vm: vm)

        // GET_STATE is idempotent — allow it to fire again immediately
        if trimmed == "GET_STATE" { lastProcessedCommand = "" }

        statusMessage = "CMD done: \(trimmed.prefix(30))"
    }

    // Shared command dispatch used by both the file watcher and LocalAPIServer.
    // Returns a JSON result string. Does not touch statusMessage or lastProcessedCommand.
    @discardableResult
    func executeCommand(_ cmd: String, vm: ChatViewModel) async -> String {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("SET_MODEL:") {
            let modelID = String(trimmed.dropFirst("SET_MODEL:".count)).trimmingCharacters(in: .whitespaces)
            if modelID != "apple-foundation-models" {
                print("HALDEBUG-TESTCONSOLE: SET_MODEL ignored — Hal LMC is AFM-only (requested: \(modelID))")
            }
            writeStateJSON(vm: vm)
            return #"{"status":"ok","note":"Hal LMC is AFM-only — model unchanged"}"#

        } else if trimmed == "NEW_THREAD" {
            vm.startNewConversation()
            print("HALDEBUG-TESTCONSOLE: New thread — \(vm.conversationId.prefix(8))")
            writeStateJSON(vm: vm)
            return "{\"status\":\"ok\",\"command\":\"NEW_THREAD\",\"conversationId\":\"\(vm.conversationId)\"}"

        } else if trimmed == "RESET_THREAD" {
            vm.memoryStore.deleteThread(id: vm.conversationId)
            vm.startNewConversation()
            print("HALDEBUG-TESTCONSOLE: Thread reset — \(vm.conversationId.prefix(8))")
            writeStateJSON(vm: vm)
            return "{\"status\":\"ok\",\"command\":\"RESET_THREAD\",\"conversationId\":\"\(vm.conversationId)\"}"

        } else if trimmed.hasPrefix("SET_SYSTEM_PROMPT:") {
            let promptText = String(trimmed.dropFirst("SET_SYSTEM_PROMPT:".count)).trimmingCharacters(in: .whitespaces)
            systemPromptOverride = promptText
            print("HALDEBUG-TESTCONSOLE: System prompt override set (\(promptText.count) chars)")
            return #"{"status":"ok","command":"SET_SYSTEM_PROMPT"}"#

        } else if trimmed == "CLEAR_SYSTEM_PROMPT" {
            systemPromptOverride = nil
            print("HALDEBUG-TESTCONSOLE: System prompt override cleared")
            return #"{"status":"ok","command":"CLEAR_SYSTEM_PROMPT"}"#

        } else if trimmed.hasPrefix("SET_MEMORY_DEPTH:") {
            let depthStr = String(trimmed.dropFirst("SET_MEMORY_DEPTH:".count)).trimmingCharacters(in: .whitespaces)
            if let depth = Int(depthStr), depth >= 1 {
                let clamped = min(depth, vm.maxMemoryDepth)
                vm.memoryDepth = clamped
                print("HALDEBUG-TESTCONSOLE: memoryDepth → \(clamped)")
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"memoryDepth\":\(clamped)}"
            }
            return #"{"status":"error","message":"SET_MEMORY_DEPTH: must be integer >= 1"}"#

        } else if trimmed.hasPrefix("SET_TEMPERATURE:") {
            let valStr = String(trimmed.dropFirst("SET_TEMPERATURE:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.0, val <= 1.0 {
                vm.temperature = val
                print("HALDEBUG-TESTCONSOLE: temperature → \(val)")
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"temperature\":\(val)}"
            }
            return #"{"status":"error","message":"SET_TEMPERATURE: must be 0.0–1.0"}"#

        } else if trimmed.hasPrefix("SET_SELF_KNOWLEDGE:") {
            let valStr = String(trimmed.dropFirst("SET_SELF_KNOWLEDGE:".count)).trimmingCharacters(in: .whitespaces).lowercased()
            if valStr == "true" || valStr == "false" {
                vm.enableSelfKnowledge = (valStr == "true")
                print("HALDEBUG-TESTCONSOLE: enableSelfKnowledge → \(vm.enableSelfKnowledge)")
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"enableSelfKnowledge\":\(vm.enableSelfKnowledge)}"
            }
            return #"{"status":"error","message":"SET_SELF_KNOWLEDGE: must be true or false"}"#

        } else if trimmed.hasPrefix("SET_SIMILARITY_THRESHOLD:") {
            let valStr = String(trimmed.dropFirst("SET_SIMILARITY_THRESHOLD:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.0, val <= 1.0 {
                vm.memoryStore.relevanceThreshold = val
                print("HALDEBUG-TESTCONSOLE: relevanceThreshold → \(val)")
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"relevanceThreshold\":\(val)}"
            }
            return #"{"status":"error","message":"SET_SIMILARITY_THRESHOLD: must be 0.0–1.0"}"#

        } else if trimmed.hasPrefix("SET_MAX_RAG_CHARS:") {
            let valStr = String(trimmed.dropFirst("SET_MAX_RAG_CHARS:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 200 {
                vm.maxRagSnippetsCharacters = val
                print("HALDEBUG-TESTCONSOLE: maxRagSnippetsCharacters → \(val)")
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"maxRagSnippetsCharacters\":\(Int(val))}"
            }
            return #"{"status":"error","message":"SET_MAX_RAG_CHARS: must be >= 200"}"#

        } else if trimmed.hasPrefix("SET_RAG_DEDUP:") {
            let valStr = String(trimmed.dropFirst("SET_RAG_DEDUP:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.0, val <= 1.0 {
                vm.ragDedupSimilarityThreshold = val
                print("HALDEBUG-TESTCONSOLE: ragDedupSimilarityThreshold → \(val)")
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"ragDedupThreshold\":\(val)}"
            }
            return #"{"status":"error","message":"SET_RAG_DEDUP: must be 0.0–1.0"}"#

        } else if trimmed.hasPrefix("SET_SYSTEM_PROMPT_STORED:") {
            let promptText = String(trimmed.dropFirst("SET_SYSTEM_PROMPT_STORED:".count)).trimmingCharacters(in: .whitespaces)
            vm.systemPrompt = promptText
            print("HALDEBUG-TESTCONSOLE: stored systemPrompt updated (\(promptText.count) chars)")
            writeStateJSON(vm: vm)
            return #"{"status":"ok","command":"SET_SYSTEM_PROMPT_STORED"}"#

        } else if trimmed == "RESET_SETTINGS" {
            vm.resetSettingsToDefaults(silent: true)
            print("HALDEBUG-TESTCONSOLE: Settings reset to defaults (silent)")
            writeStateJSON(vm: vm)
            return #"{"status":"ok","command":"RESET_SETTINGS"}"#

        } else if trimmed == "NUCLEAR_RESET" {
            let (threads, facts, messages) = vm.memoryStore.clearAllConversationData()
            vm.resetSettingsToDefaults(silent: true)
            vm.startNewConversation()
            print("HALDEBUG-TESTCONSOLE: NUCLEAR_RESET — \(threads) threads, \(messages) messages deleted. New thread: \(vm.conversationId.prefix(8))")
            return "{\"status\":\"ok\",\"command\":\"NUCLEAR_RESET\",\"threadsDeleted\":\(threads),\"factsDeleted\":\(facts),\"messagesDeleted\":\(messages),\"newConversationId\":\"\(vm.conversationId)\"}"

        } else if trimmed == "GET_STATE" {
            writeStateJSON(vm: vm)
            print("HALDEBUG-TESTCONSOLE: State written to \(stateFile.lastPathComponent)")
            if let data = try? Data(contentsOf: stateFile),
               let json = String(data: data, encoding: .utf8) { return json }
            return #"{"status":"error","message":"Could not read state"}"#

        } else if trimmed == "CLEAR_TEST_DATA" {
            let (threads, facts, messages) = vm.memoryStore.clearAllConversationData()
            vm.startNewConversation()
            print("HALDEBUG-TESTCONSOLE: CLEAR_TEST_DATA — \(threads) threads, \(facts) facts, \(messages) messages deleted. New thread: \(vm.conversationId.prefix(8))")
            return "{\"status\":\"ok\",\"command\":\"CLEAR_TEST_DATA\",\"threadsDeleted\":\(threads),\"factsDeleted\":\(facts),\"messagesDeleted\":\(messages),\"newConversationId\":\"\(vm.conversationId)\"}"

        } else {
            print("HALDEBUG-TESTCONSOLE: Unknown command: \(trimmed.prefix(60))")
            return "{\"status\":\"error\",\"message\":\"Unknown command: \(trimmed.prefix(60))\"}"
        }
    }

    func writeStateJSON(vm: ChatViewModel) {
        let promptText = vm.effectiveSystemPrompt
        let fingerprint = String(promptText.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let hasOverride = systemPromptOverride != nil
        let liveID = vm.llmService.activeModelID
        let hasSummary = !vm.injectedSummary.isEmpty
        let state = """
        {
          "modelID": "\(liveID)",
          "conversationId": "\(vm.conversationId)",
          "turnCount": \(turnCount),
          "memoryDepth": \(vm.memoryDepth),
          "maxMemoryDepth": \(vm.maxMemoryDepth),
          "temperature": \(String(format: "%.2f", vm.temperature)),
          "selfKnowledgeEnabled": \(vm.enableSelfKnowledge),
          "similarityThreshold": \(String(format: "%.2f", vm.memoryStore.relevanceThreshold)),
          "maxRagSnippetsCharacters": \(Int(vm.maxRagSnippetsCharacters)),
          "ragDedupThreshold": \(String(format: "%.2f", vm.ragDedupSimilarityThreshold)),
          "lastSummarizedTurnCount": \(vm.lastSummarizedTurnCount),
          "injectedSummaryActive": \(hasSummary),
          "injectedSummaryLength": \(vm.injectedSummary.count),
          "systemPromptOverrideActive": \(hasOverride),
          "systemPromptFingerprint": "\(fingerprint)..."
        }
        """
        try? state.write(to: stateFile, atomically: true, encoding: .utf8)
    }

    // Called when input.txt is written to
    private func handleInputFileChange() async {

        guard let content = try? String(contentsOf: inputFile, encoding: .utf8) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty or already-processed content (DispatchSource can fire multiple times per write)
        guard !trimmed.isEmpty, trimmed != lastProcessedContent else { return }
        lastProcessedContent = trimmed

        guard let vm = chatViewModel else {
            statusMessage = "Error: ChatViewModel unavailable"
            return
        }

        // Safety: if the previous turn is still running, wait up to 120s before giving up.
        // This prevents overlapping sendMessage() calls that corrupt isAIResponding state.
        if vm.isAIResponding {
            print("HALDEBUG-TESTCONSOLE: Previous turn still in flight — waiting up to 120s...")
            var waited = 0
            while vm.isAIResponding && waited < 120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s polling
                waited += 1
            }
            if vm.isAIResponding {
                print("HALDEBUG-TESTCONSOLE: Timeout waiting for previous turn — skipping input: \"\(trimmed.prefix(40))\"")
                statusMessage = "Error: previous turn timed out"
                return
            }
        }

        turnCount += 1
        let turnNum = turnCount
        statusMessage = "Turn \(turnNum): processing…"
        print("HALDEBUG-TESTCONSOLE: Turn \(turnNum) — \"\(trimmed.prefix(60))\"")

        let startTime = Date()

        // Inject into the real pipeline — same path the UI takes
        vm.currentMessage = trimmed
        await vm.sendMessage()

        let elapsed = Date().timeIntervalSince(startTime)

        // Grab the last completed AI message
        let aiMessages = vm.messages.filter { !$0.isFromUser && !$0.isPartial }
        guard let lastAI = aiMessages.last else {
            statusMessage = "Turn \(turnNum): no AI response found"
            print("HALDEBUG-TESTCONSOLE: Turn \(turnNum) — no AI message in messages array")
            return
        }

        // Write diagnostic JSON output
        let json = buildOutputJSON(turn: turnNum, userMessage: trimmed, aiMessage: lastAI, elapsed: elapsed, vm: vm)
        let numberedOutput = baseDir.appendingPathComponent(String(format: "output_%04d.json", turnNum))

        try? json.write(to: outputLatestFile, atomically: true, encoding: .utf8)
        try? json.write(to: numberedOutput, atomically: true, encoding: .utf8)

        statusMessage = "Turn \(turnNum): done (\(String(format: "%.1f", elapsed))s)"
        print("HALDEBUG-TESTCONSOLE: Turn \(turnNum) complete in \(String(format: "%.1f", elapsed))s — \(outputLatestFile.lastPathComponent)")
    }

    func buildOutputJSON(turn: Int, userMessage: String, aiMessage: ChatMessage, elapsed: TimeInterval, vm: ChatViewModel) -> String {

        // Token breakdown
        let tokenJSON: String
        if let tb = aiMessage.tokenBreakdown {
            tokenJSON = """
            {
                "system": \(tb.systemTokens),
                "shortTerm": \(tb.shortTermTokens),
                "summary": \(tb.summaryTokens),
                "rag": \(tb.ragTokens),
                "userInput": \(tb.userInputTokens),
                "completion": \(tb.completionTokens),
                "totalPrompt": \(tb.totalPromptTokens),
                "total": \(tb.totalTokens),
                "contextWindow": \(tb.contextWindowSize),
                "percentUsed": \(String(format: "%.1f", tb.percentageUsed))
              }
            """
        } else {
            tokenJSON = "null"
        }

        // Memory retrieved
        let memoryJSON: String
        if let snippets = aiMessage.usedContextSnippets, !snippets.isEmpty {
            let items = snippets.map { s in
                """
                    {
                      "content": \(jsonEscape(String(s.content.prefix(300)))),
                      "relevance": \(String(format: "%.3f", s.relevance)),
                      "source": \(jsonEscape(s.source)),
                      "isEntityMatch": \(s.isEntityMatch)
                    }
                """
            }.joined(separator: ",\n")
            memoryJSON = "[\n\(items)\n  ]"
        } else {
            memoryJSON = "[]"
        }

        // Tools used
        let toolsJSON: String
        if let tools = aiMessage.toolsUsed, !tools.isEmpty {
            toolsJSON = "[" + tools.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        } else {
            toolsJSON = "[]"
        }

        // Infer which HelPML sections were injected by scanning the prompt
        let prompt = aiMessage.fullPromptUsed ?? ""
        let sections = [
            prompt.contains("#=== BEGIN SYSTEM ===#")          ? "\"system\""           : nil,
            prompt.contains("#=== BEGIN MEMORY_SHORT ===#")   ? "\"short_term_memory\"" : nil,
            prompt.contains("#=== BEGIN SUMMARY ===#")         ? "\"summary\""           : nil,
            prompt.contains("#=== BEGIN TEMPORAL_CONTEXT ===#") ? "\"temporal_context\"" : nil,
            prompt.contains("#=== BEGIN MEMORY_LONG ===#")    ? "\"rag\""               : nil,
            prompt.contains("#=== BEGIN SELF_AWARENESS ===#") ? "\"self_awareness\""    : nil,
            prompt.contains("#=== BEGIN SELF_KNOWLEDGE ===#") ? "\"self_knowledge\""    : nil,
        ].compactMap { $0 }.joined(separator: ", ")

        let promptContent = prompt.isEmpty ? "(not captured — check HALDEBUG-PROMPT logs)" : prompt

        return """
        {
          "turn": \(turn),
          "timestamp": "\(ISO8601DateFormatter().string(from: Date()))",
          "thinkingDuration": \(String(format: "%.2f", elapsed)),
          "model": "\(vm.selectedModel.id)",
          "selfKnowledgeEnabled": \(vm.enableSelfKnowledge),
          "salonModeEnabled": false,
          "userMessage": \(jsonEscape(userMessage)),
          "response": \(jsonEscape(aiMessage.content)),
          "sectionsInjected": [\(sections)],
          "tokenBreakdown": \(tokenJSON),
          "memoryRetrieved": \(memoryJSON),
          "toolsUsed": \(toolsJSON),
          "fullPrompt": \(jsonEscape(promptContent))
        }
        """
    }

    // JSON string escaping
    private func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

// ─── Local HTTP API Server ──────────────────────────────────────────────────
//
// Programmatic access to Hal's pipeline for automated testing and tooling.
// Replaces the file-polling harness with a clean synchronous HTTP interface.
//
// Endpoints (all require Authorization: Bearer <token>):
//   POST /chat      {"message": "..."}          → full diagnostic JSON (same schema as output_latest.json)
//   POST /command   {"command": "NUCLEAR_RESET"} → JSON result
//   GET  /state                                  → settings state JSON
//
// Security:
//   Bearer token generated once, stored in Keychain, shown in Settings > Developer API.
//   Default OFF. User must enable via toggle. No port opens when disabled.
//
// Network:
//   Listens on all local interfaces, port 8765.
//   Mac Catalyst: connect via 127.0.0.1:8765 (same machine).
//   Physical iPhone: connect via WiFi IP shown in Settings > Developer API.
//
// Python test runner:
//   python3 tests/hal_test.py setup <ip> 8765 <token>  # write config once
//   python3 tests/hal_test.py chat                      # reactive REPL — no scripts, no polling
//   python3 tests/hal_test.py turn "Hello"              # single turn
//   python3 tests/hal_test.py reset                     # nuclear reset
//
class LocalAPIServer {

    static let apiPort: UInt16 = 8765

    private var listener: NWListener?
    private weak var chatViewModel: ChatViewModel?

    var isRunning: Bool { listener != nil }

    // MARK: - Token (Keychain-backed)

    private static let keychainService  = "com.MarkFriedlander.Hal10000"
    private static let keychainAccount  = "localAPIToken"

    static func loadOrCreateToken() -> String {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
            kSecReturnData:  true
        ]
        var item: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8) {
            return token
        }
        // First launch — generate and persist
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let add: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
            kSecValueData:   Data(token.utf8) as CFData
        ]
        SecItemAdd(add as CFDictionary, nil)
        return token
    }

    var apiToken: String { Self.loadOrCreateToken() }

    // MARK: - Local Network Address

    static func localIPAddress() -> String {
        var best = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return best }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let iface = ptr?.pointee {
            defer { ptr = ptr?.pointee.ifa_next }
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.isEmpty && ip != "0.0.0.0" { best = ip }
        }
        return best
    }

    var connectionURL: String { "\(Self.localIPAddress()):\(Self.apiPort)" }

    // MARK: - Lifecycle

    func start(chatViewModel: ChatViewModel) {
        guard !isRunning else { return }
        self.chatViewModel = chatViewModel
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.apiPort)!)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .userInitiated))
                Task { await self?.handleConnection(conn) }
            }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("LocalAPI: Ready at \(LocalAPIServer.localIPAddress()):\(LocalAPIServer.apiPort)")
                case .failed(let e):
                    print("LocalAPI: Failed — \(e)")
                default: break
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            self.listener = l
        } catch {
            print("LocalAPI: Could not start NWListener — \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        print("LocalAPI: Stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ conn: NWConnection) async {
        guard let data = await receiveRequest(conn),
              let req  = parseRequest(data) else {
            respond(conn, status: 400, body: #"{"error":"Bad request"}"#)
            return
        }
        guard req.token == apiToken else {
            respond(conn, status: 401, body: #"{"error":"Unauthorized"}"#)
            return
        }
        let (status, body) = await route(req)
        respond(conn, status: status, body: body)
    }

    // Accumulates TCP chunks until the HTTP request is complete.
    private func receiveRequest(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            var buf = Data()
            func next() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, done, err in
                    if let chunk { buf.append(chunk) }
                    if let text = String(data: buf, encoding: .utf8), text.contains("\r\n\r\n") {
                        let parts  = text.components(separatedBy: "\r\n\r\n")
                        let hdr    = parts[0]
                        let body   = parts.dropFirst().joined(separator: "\r\n\r\n")
                        if let clLine = hdr.components(separatedBy: "\r\n")
                            .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                           let cl = Int(clLine.components(separatedBy: ":").last?
                                            .trimmingCharacters(in: .whitespaces) ?? "") {
                            if body.utf8.count >= cl { cont.resume(returning: buf); return }
                        } else {
                            cont.resume(returning: buf); return   // No body (e.g. GET)
                        }
                    }
                    if done || err != nil { cont.resume(returning: buf.isEmpty ? nil : buf) }
                    else { next() }
                }
            }
            next()
        }
    }

    // MARK: - HTTP Parsing

    private struct ParsedRequest {
        let method: String
        let path: String
        let token: String?
        let body: Data?
    }

    private func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let split = text.components(separatedBy: "\r\n\r\n")
        guard let hdrBlock = split.first else { return nil }
        let lines = hdrBlock.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { return nil }
        let rp = reqLine.components(separatedBy: " ")
        guard rp.count >= 2 else { return nil }
        var token: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("authorization: bearer ") {
                token = String(line.dropFirst("authorization: bearer ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let bodyStr  = split.dropFirst().joined(separator: "\r\n\r\n")
        let bodyData = bodyStr.isEmpty ? nil : bodyStr.data(using: .utf8)
        return ParsedRequest(method: rp[0], path: rp[1], token: token, body: bodyData)
    }

    // MARK: - Routing

    private func route(_ req: ParsedRequest) async -> (Int, String) {
        switch (req.method, req.path) {
        case ("POST", "/chat"):    return await handleChat(body: req.body)
        case ("POST", "/command"): return await handleCommand(body: req.body)
        case ("GET",  "/state"):   return await handleState()
        default:                   return (404, #"{"error":"Not found"}"#)
        }
    }

    // POST /chat — {"message": "..."} → full diagnostic JSON
    private func handleChat(body: Data?) async -> (Int, String) {
        guard let body,
              let json    = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = json["message"] as? String, !message.isEmpty else {
            return (400, #"{"error":"Missing 'message'"}"#)
        }
        guard let vm = chatViewModel else {
            return (503, #"{"error":"ChatViewModel unavailable"}"#)
        }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                // If a previous turn is still running, wait up to 120 s
                var waited = 0
                while vm.isAIResponding && waited < 120 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
                guard !vm.isAIResponding else {
                    cont.resume(returning: (503, #"{"error":"Previous turn timed out"}"#))
                    return
                }
                let start = Date()
                vm.currentMessage = message
                await vm.sendMessage()
                let elapsed = Date().timeIntervalSince(start)
                let aiMessages = vm.messages.filter { !$0.isFromUser && !$0.isPartial }
                guard let lastAI = aiMessages.last else {
                    cont.resume(returning: (500, #"{"error":"No response generated"}"#))
                    return
                }
                vm.testConsole.turnCount += 1
                let responseJSON = vm.testConsole.buildOutputJSON(
                    turn: vm.testConsole.turnCount,
                    userMessage: message,
                    aiMessage: lastAI,
                    elapsed: elapsed,
                    vm: vm
                )
                cont.resume(returning: (200, responseJSON))
            }
        }
    }

    // POST /command — {"command": "NUCLEAR_RESET"}
    private func handleCommand(body: Data?) async -> (Int, String) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd  = json["command"] as? String, !cmd.isEmpty else {
            return (400, #"{"error":"Missing 'command'"}"#)
        }
        guard let vm = chatViewModel else {
            return (503, #"{"error":"ChatViewModel unavailable"}"#)
        }
        let result: String = await withCheckedContinuation { cont in
            Task { @MainActor in
                let r = await vm.testConsole.executeCommand(cmd, vm: vm)
                cont.resume(returning: r)
            }
        }
        return (200, result)
    }

    // GET /state
    private func handleState() async -> (Int, String) {
        guard let vm = chatViewModel else {
            return (503, #"{"error":"ChatViewModel unavailable"}"#)
        }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                vm.testConsole.writeStateJSON(vm: vm)
                if let data = try? Data(contentsOf: vm.testConsole.stateFile),
                   let json = String(data: data, encoding: .utf8) {
                    cont.resume(returning: (200, json))
                } else {
                    cont.resume(returning: (500, #"{"error":"State unavailable"}"#))
                }
            }
        }
    }

    // MARK: - HTTP Response

    private func respond(_ conn: NWConnection, status: Int, body: String) {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 404: phrase = "Not Found"
        case 503: phrase = "Service Unavailable"
        default:  phrase = "Internal Server Error"
        }
        let bodyData = body.data(using: .utf8) ?? Data()
        let header   = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var resp     = header.data(using: .utf8)!
        resp.append(bodyData)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// ==== LEGO END: 32 HalTestConsole (macOS Test Harness) ====
