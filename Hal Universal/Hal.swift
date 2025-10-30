// ==== LEGO START: 01 Imports & App Entry & Environment Wiring ====
//
//  Hal.swift
//  HalChatiOS
//
//  Hal.swift — Core Application Source
//  Architecture Overview:
//  - Integrates Apple FoundationModels and MLX frameworks under LLMService.
//  - Uses LEGO-block modular structure (01–29) for deterministic editing.
//  - Includes on-device inference, streaming UI, and context-managed memory.
//  - MLXWrapper supports Phi-3 and similar models via MLX Swift APIs.
//  - MemoryStore uses SQLite with schema, embeddings, and semantic search.
//
//  - LEGO Index
// 01  Imports & App Entry & Environment Wiring
// 02  ChatMessage, UnifiedSearchContext, MemoryStore (Part 1)
// 03  MemoryStore (Part 2 – Schema, Encryption, Stats)
// 04  MemoryStore (Part 3 – Storing Turns & Entities)
// 05  MemoryStore (Part 4 – Entities, Embeddings, Search)
// 06  MemoryStore (Part 5 – Retrieval, Debug, Semantic Search)
// 07  MemoryStore (Part 6 – Full Search Flow) & LLMType Enum
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
// 25  ChatVM — Export Chat History
// 26  DocumentPicker (UIKit Bridge)
// 27  DocumentImportManager (Ingest & Entities)
// 28  Import Models (ProcessedDocument & Summary)
// 29  MLX Model Downloader (Singleton)
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
import MLX // Import MLX framework (conceptual, requires actual framework link)
import MLXLLM
import Hub
import MLXLMCommon // FIXED: Added missing import for proper MLX API access
import Tokenizers // FIXED: Added missing import for tokenizer decode method

// MARK: - Hub Extension for MLX Model Downloads
extension HubApi {
    /// Default HubApi instance configured for iOS cache directory
    static let `default` = HubApi(
        downloadBase: URL.cachesDirectory.appending(path: "huggingface")
    )
}

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

    var displayName: String {
        switch self {
        case .conversation: return "Conversation"
        case .document: return "Document"
        case .webpage: return "Web Page"
        case .email: return "Email"
        }
    }

    var icon: String {
        switch self {
        case .conversation: return "💬"
        case .document: return "📄"
        case .webpage: return "🌐"
        case .email: return "📧"
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
// ==== LEGO END: 01 Imports & App Entry & Environment Wiring ====


// ==== LEGO START: 02 ChatMessage, UnifiedSearchContext, MemoryStore (Part 1) ====

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

    init(id: UUID = UUID(), content: String, isFromUser: Bool, timestamp: Date = Date(), isPartial: Bool = false, thinkingDuration: TimeInterval? = nil, fullPromptUsed: String? = nil, usedContextSnippets: [UnifiedSearchResult]? = nil) {
        self.id = id
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = timestamp
        self.isPartial = isPartial
        self.thinkingDuration = thinkingDuration
        self.fullPromptUsed = fullPromptUsed
        self.usedContextSnippets = usedContextSnippets
    }
}

// MARK: - Simplified Search Context Model (Entity-Free, for ChatViewModel UI)
struct UnifiedSearchContext {
    let conversationSnippets: [String]
    let documentSnippets: [String]
    let relevanceScores: [Double]
    let totalTokens: Int

    var hasContent: Bool {
        return !conversationSnippets.isEmpty || !documentSnippets.isEmpty
    }

    var totalSnippets: Int {
        return conversationSnippets.count + documentSnippets.count
    }
}

// MARK: - Memory Store with Persistent Database Connection (Aligned with Hal10000App.swift)
class MemoryStore: ObservableObject {
    static let shared = MemoryStore() // Singleton pattern

    @Published var isEnabled: Bool = true
    @AppStorage("relevanceThreshold") var relevanceThreshold: Double = 0.65 {
        didSet {
            // Notify other parts of the app that the threshold has changed
            NotificationCenter.default.post(name: .relevanceThresholdDidChange, object: nil)
            print("HALDEBUG-THRESHOLD: Relevance threshold updated to \(relevanceThreshold)")
        }
    }
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
        print("HALDEBUG-DATABASE: 🚨 MemoryStore performing nuclear reset...")

        // Step 1: Clear published properties immediately
        DispatchQueue.main.async {
            self.totalConversations = 0
            self.totalTurns = 0
            self.totalDocuments = 0
            self.totalDocumentChunks = 0
            self.searchDebugResults = ""
        }
        print("HALDEBUG-DATABASE: ✅ Cleared published properties")

        // Step 2: Close database connection cleanly
        if db != nil {
            sqlite3_close(db)
            db = nil
            isConnected = false
            print("HALDEBUG-DATABASE: ✅ Database connection closed cleanly")
        }

        // Step 3: Delete all database files safely (connection is now closed)
        print("HALDEBUG-DATABASE: 🗑️ Deleting database files...")
        var deletedCount = 0
        var failedCount = 0

        for filePath in allDatabaseFilePaths {
            let fileURL = URL(fileURLWithPath: filePath)
            do {
                if FileManager.default.fileExists(atPath: filePath) {
                    try FileManager.default.removeItem(at: fileURL)
                    deletedCount += 1
                    print("HALDEBUG-DATABASE: 🗑️ Deleted \(fileURL.lastPathComponent)")
                } else {
                    print("HALDEBUG-DATABASE: ℹ️ File didn't exist: \(fileURL.lastPathComponent)")
                }
            } catch {
                failedCount += 1
                print("HALDEBUG-DATABASE: ❌ Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Step 4: Recreate fresh database connection immediately
        print("HALDEBUG-DATABASE: 🔄 Recreating fresh database connection...")
        setupPersistentDatabase()

        // Step 5: Verify success
        let success = isConnected && failedCount == 0
        if success {
            print("HALDEBUG-DATABASE: ✅ Nuclear reset completed successfully")
            print("HALDEBUG-DATABASE:   Files deleted: \(deletedCount)")
            print("HALDEBUG-DATABASE:   Files failed: \(failedCount)")
            print("HALDEBUG-DATABASE:   Connection healthy: \(isConnected)")
        } else {
            print("HALDEBUG-DATABASE: ❌ Nuclear reset encountered issues")
            print("HALDEBUG-DATABASE:   Files deleted: \(deletedCount)")
            print("HALDEBUG-DATABASE:   Files failed: \(failedCount)")
            print("HALDEBUG-DATABASE:   Connection healthy: \(isConnected)")
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
        print("HALDEBUG-DATABASE: ✅ Persistent database connection established at \(dbPath)")

        // ENCRYPTION: Enable Apple file protection immediately after database creation
        enableDataProtection()

        // Enable WAL mode for better performance and concurrency
        if sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: ✅ Enabled WAL mode for persistent connection")
        } else {
            print("HALDEBUG-DATABASE: ⚠️ Failed to enable WAL mode")
        }

        // Enable foreign keys for data integrity
        if sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: ✅ Enabled foreign key constraints for data integrity")
        }

        // Create all tables using the persistent connection
        createUnifiedSchema()
        loadUnifiedStats()

        print("HALDEBUG-DATABASE: ✅ Persistent database setup complete")
    }
    
    
// ==== LEGO END: 02 ChatMessage, UnifiedSearchContext, MemoryStore (Part 1) ====
    
// ==== LEGO START: 03 MemoryStore (Part 2 – Schema, Encryption, Stats) ====

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
        print("HALDEBUG-DATABASE: ⚠️ Database connection unhealthy, attempting reconnection...")
        setupPersistentDatabase()
        return isConnected
    }

    // Create simplified unified schema with entity support - MATCHES Block 9 exactly
    private func createUnifiedSchema() {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-DATABASE: ❌ Cannot create schema - no database connection")
            return
        }

        print("HALDEBUG-DATABASE: Creating unified database schema with entity support...")

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

        // ENHANCED SCHEMA: Add entity_keywords column for entity-based search
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
            metadata_json TEXT,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(source_type, source_id, position)
        );
        """

        // Execute schema creation with proper error handling
        let tables = [
            ("sources", sourcesSQL),
            ("unified_content", unifiedContentSQL)
        ]

        for (tableName, sql) in tables {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                print("HALDEBUG-DATABASE: ✅ Created \(tableName) table with entity support")
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("HALDEBUG-DATABASE: ❌ Failed to create \(tableName) table: \(errorMessage)")
            }
        }

        // Create enhanced performance indexes including entity_keywords
        let unifiedIndexes = [
            "CREATE INDEX IF NOT EXISTS idx_unified_content_source ON unified_content(source_type, source_id);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_timestamp ON unified_content(timestamp);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_from_user ON unified_content(is_from_user);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_entities ON unified_content(entity_keywords);",
            "CREATE INDEX IF NOT EXISTS idx_sources_type ON sources(source_type);"
        ]

        for indexSQL in unifiedIndexes {
            if sqlite3_exec(db, indexSQL, nil, nil, nil) == SQLITE_OK {
                print("HALDEBUG-DATABASE: ✅ Created index with entity support")
            } else {
                print("HALDEBUG-DATABASE: ⚠️ Failed to create index: \(indexSQL)")
            }
        }

        print("HALDEBUG-DATABASE: ✅ Unified schema creation complete with entity support")
    }

    // ENCRYPTION: Enable Apple Data Protection on database file
    private func enableDataProtection() {
        let dbURL = URL(fileURLWithPath: dbPath)

        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        do {
            // Corrected: Use FileManager.default.setAttributes for file protection
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dbURL.path)
            print("HALDEBUG-DATABASE: ✅ Database encryption enabled with Apple file protection")
        } catch {
            print("HALDEBUG-DATABASE: ⚠️ Database encryption setup failed: \(error)")
        }
        #else
        print("HALDEBUG-DATABASE: 🔒 Database protected by macOS FileVault")
        #endif
    }

    // FIXED: Statistics queries updated to match actual schema columns
    private func loadUnifiedStats() {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-DATABASE: ❌ Cannot load stats - no database connection")
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
                print("HALDEBUG-DATABASE: Found \(tempTotalConversations) conversations")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count conversations: \(errorMessage)")
        }
        sqlite3_finalize(stmt)

        // FIXED: Count user turns using actual schema (user messages only)
        let userTurnsSQL = "SELECT COUNT(*) FROM unified_content WHERE source_type = 'conversation' AND is_from_user = 1"
        if sqlite3_prepare_v2(db, userTurnsSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalTurns = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalTurns) user turns")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count user turns: \(errorMessage)")
        }
        sqlite3_finalize(stmt)

        // FIXED: Count documents in sources table
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sources WHERE source_type = 'document'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalDocuments = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalDocuments) documents")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count documents: \(errorMessage)")
        }
        sqlite3_finalize(stmt)

        // FIXED: Count document chunks in unified_content
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM unified_content WHERE source_type = 'document'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalDocumentChunks = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalDocumentChunks) document chunks")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count document chunks: \(errorMessage)")
        }
        sqlite3_finalize(stmt)

        // Update @Published properties on main thread
        DispatchQueue.main.async {
            self.totalConversations = tempTotalConversations
            self.totalTurns = tempTotalTurns
            self.totalDocuments = tempTotalDocuments
            self.totalDocumentChunks = tempTotalDocumentChunks
        }

        print("HALDEBUG-MEMORY: ✅ Loaded unified stats - \(tempTotalConversations) conversations, \(tempTotalTurns) turns, \(tempTotalDocuments) documents, \(tempTotalDocumentChunks) chunks")
    }

// ==== LEGO END: 03 MemoryStore (Part 2 – Schema, Encryption, Stats) ====
    

    
// ==== LEGO START: 04 MemoryStore (Part 3 – Storing Turns & Entities) ====

        
        // Close database connection properly
        private func closeDatabaseConnection() {
            if db != nil {
                sqlite3_close(db)
                db = nil
                isConnected = false
                print("HALDEBUG-DATABASE: ✅ Database connection closed")
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

        // Store conversation turn in unified memory with entity extraction
        func storeTurn(conversationId: String, userMessage: String, assistantMessage: String, systemPrompt: String, turnNumber: Int, halFullPrompt: String?, halUsedContext: [UnifiedSearchResult]?, thinkingDuration: TimeInterval? = nil) { // NEW: Added thinkingDuration parameter
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

            // Store user message with entity keywords
            let userContentId = storeUnifiedContentWithEntities(
                content: userMessage,
                sourceType: .conversation,
                sourceId: conversationId,
                position: turnNumber * 2 - 1,
                timestamp: Date(),
                isFromUser: true, // Explicitly set for user message
                entityKeywords: combinedEntitiesKeywords
            )

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


            // Store assistant message with entity keywords and new metadata
            let assistantContentId = storeUnifiedContentWithEntities(
                content: assistantMessage,
                sourceType: .conversation,
                sourceId: conversationId,
                position: turnNumber * 2,
                timestamp: Date(),
                isFromUser: false, // Explicitly set for assistant message
                entityKeywords: combinedEntitiesKeywords,
                metadataJson: halMetadataJsonString // NEW: Pass metadata
            )

            print("HALDEBUG-MEMORY: Stored turn \(turnNumber) - user: \(userContentId), assistant: \(assistantContentId)")
            print("HALDEBUG-MEMORY: SURGERY - StoreTurn complete user='\(userContentId.prefix(8))....' assistant='\(assistantContentId.prefix(8))....'")

            // Update conversation statistics
            loadUnifiedStats()
        }

        // ENHANCED: Store unified content with entity keywords support and optional metadataJson
        func storeUnifiedContentWithEntities(content: String, sourceType: ContentSourceType, sourceId: String, position: Int, timestamp: Date, isFromUser: Bool, entityKeywords: String = "", metadataJson: String = "{}") -> String { // NEW: metadataJson parameter
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


            // ENHANCED SQL with entity_keywords column
            let sql = """
            INSERT OR REPLACE INTO unified_content
            (id, content, embedding, timestamp, source_type, source_id, position, is_from_user, entity_keywords, metadata_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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

            // ENHANCED: Bind all 11 parameters including entity_keywords

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

            // Parameter 10: metadata_json (STRING) - NEW BINDING
            sqlite3_bind_text(stmt, 10, (metadataJson as NSString).utf8String, -1, nil)

            // Parameter 11: created_at (INTEGER)
            sqlite3_bind_int64(stmt, 11, createdAt)

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



// ==== LEGO START: 05 MemoryStore (Part 4 – Entities, Embeddings, Search) ====

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

// ==== LEGO END: 05 MemoryStore (Part 4 – Entities, Embeddings, Search) ====


// ==== LEGO START: 06 MemoryStore (Part 5 – Retrieval, Debug, Semantic Search) ====

// MARK: - Conversation Message Retrieval with Enhanced Schema (from Hal10000App.swift)
extension MemoryStore {

    // Retrieve conversation messages with surgical debug
    func getConversationMessages(conversationId: String) -> [ChatMessage] {
        print("HALDEBUG-MEMORY: Loading messages for conversation: \(conversationId)")
        print("HALDEBUG-MEMORY: SURGERY - Retrieve start convId='\(conversationId.prefix(8))....'")

        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot load messages - no database connection")
            print("HALDEBUG-MEMORY: SURGERY - Retrieve FAILED no connection")
            return []
        }

        var messages: [ChatMessage] = []

        // NEW: Select metadata_json column
        let sql = """
        SELECT id, content, is_from_user, timestamp, position, metadata_json
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
                fullPromptUsed: fullPromptUsed, // NEW
                usedContextSnippets: usedContextSnippets // NEW
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

    // MARK: - Unified Search Function (CRITICAL MISSING PIECE)
    // This function performs both semantic and entity-based search to retrieve relevant context.
    func searchUnifiedContent(for query: String, currentConversationId: String, excludeTurns: [Int], maxResults: Int) -> UnifiedSearchContext {
        print("HALDEBUG-SEARCH: Starting unified content search for query: '\(query.prefix(50))....'")
        print("HALDEBUG-SEARCH: Excluding turns: \(excludeTurns)")

        guard ensureHealthyConnection() else {
            print("HALDEBUG-SEARCH: Cannot perform search - no database connection")
            return UnifiedSearchContext(conversationSnippets: [], documentSnippets: [], relevanceScores: [], totalTokens: 0)
        }

        let queryEmbedding = generateEmbedding(for: query)
        guard !queryEmbedding.isEmpty else {
            print("HALDEBUG-SEARCH: Query embedding is empty, cannot perform semantic search.")
            return UnifiedSearchContext(conversationSnippets: [], documentSnippets: [], relevanceScores: [], totalTokens: 0)
        }

        var allResults: [UnifiedSearchResult] = []
        var totalTokens = 0

        // --- 1. Semantic Search (using embeddings) ---
        print("HALDEBUG-SEARCH: Performing semantic search...")
        // NEW: Select metadata_json from unified_content to get file_path for document snippets
        let semanticSQL = """
        SELECT id, content, embedding, source_type, source_id, position, metadata_json
        FROM unified_content
        WHERE embedding IS NOT NULL;
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
                let sourceId = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let position = Int(sqlite3_column_int(stmt, 5))
                
                // NEW: Extract filePath from metadata_json for document snippets
                var filePath: String? = nil
                if let metadataCString = sqlite3_column_text(stmt, 6) { // metadata_json is column 6
                    let metadataJsonString = String(cString: metadataCString)
                    if let metadataData = Data(base64Encoded: metadataJsonString),
                       let metadataDict = (try? JSONSerialization.jsonObject(with: metadataData, options: []) as? [String: Any]) {
                        filePath = metadataDict["filePath"] as? String // Assuming filePath is stored directly
                    }
                }

// ==== LEGO END: 06 MemoryStore (Part 5 – Retrieval, Debug, Semantic Search) ====
        
                
// ==== LEGO START: 07 MemoryStore (Part 6 – Full Search Flow) & LLMType Enum ====


                // Exclude messages from the *current* conversation that are within the short-term window
                if sourceTypeRaw == ContentSourceType.conversation.rawValue && sourceId == currentConversationId {
                    // Calculate the turn number for the message
                    let messageTurn = (position % 2 == 1) ? (position + 1) / 2 : position / 2
                    if excludeTurns.contains(messageTurn) {
                        // print("HALDEBUG-SEARCH: Excluding short-term turn \(messageTurn) from semantic search: \(content.prefix(20)).....")
                        continue // Skip this message
                    }
                }

                let similarity = cosineSimilarity(queryEmbedding, storedEmbedding)
                if similarity >= relevanceThreshold {
                    allResults.append(UnifiedSearchResult(content: content, relevance: similarity, source: sourceTypeRaw, isEntityMatch: false, filePath: filePath)) // NEW: Pass filePath
                    // print("HALDEBUG-SEARCH: Semantic match: '\(content.prefix(50))....' relevance: \(similarity)")
                }
            }
        }
        sqlite3_finalize(stmt)
        print("HALDEBUG-SEARCH: Semantic search completed. Found \(allResults.count) initial matches.")

        // --- 2. Entity-Based Keyword Search ---
        print("HALDEBUG-SEARCH: Performing entity-based keyword search...")
        let expandedQueries = expandQueryWithEntityVariations(query)
        for expandedQuery in expandedQueries {
            // NEW: Select metadata_json from unified_content to get file_path for document snippets
            let keywordSQL = """
            SELECT id, content, source_type, source_id, position, metadata_json
            FROM unified_content
            WHERE entity_keywords LIKE ? OR content LIKE ?;
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
                    let sourceId = sqlite3_column_text(keywordStmt, 3).map { String(cString: $0) } ?? ""
                    let position = Int(sqlite3_column_int(keywordStmt, 4))

                    // NEW: Extract filePath from metadata_json for document snippets
                    var filePath: String? = nil
                    if let metadataCString = sqlite3_column_text(keywordStmt, 5) { // metadata_json is column 5
                        let metadataJsonString = String(cString: metadataCString)
                        if let metadataData = Data(base64Encoded: metadataJsonString),
                           let metadataDict = (try? JSONSerialization.jsonObject(with: metadataData, options: []) as? [String: Any]) {
                            filePath = metadataDict["filePath"] as? String // Assuming filePath is stored directly
                        }
                    }

                    // Exclude messages from the *current* conversation that are within the short-term window
                    if sourceTypeRaw == ContentSourceType.conversation.rawValue && sourceId == currentConversationId {
                        let messageTurn = (position % 2 == 1) ? (position + 1) / 2 : position / 2
                        if excludeTurns.contains(messageTurn) {
                            // print("HALDEBUG-SEARCH: Excluding short-term turn \(messageTurn) from keyword search: \(content.prefix(20))....")
                            continue // Skip this message
                        }
                    }

                    // Add a default relevance for keyword matches, or enhance if already a semantic match
                    if let existingIndex = allResults.firstIndex(where: { $0.content == content }) {
                        // If already found by semantic search, just mark as entity match
                        allResults[existingIndex].isEntityMatch = true
                    } else {
                        // Add as a new result with a base relevance (can be adjusted)
                        allResults.append(UnifiedSearchResult(content: content, relevance: 0.75, source: sourceTypeRaw, isEntityMatch: true, filePath: filePath)) // NEW: Pass filePath
                        // print("HALDEBUG-SEARCH: Keyword match: '\(content.prefix(50))....' query: '\(expandedQuery)'")
                    }
                }
            }
            sqlite3_finalize(keywordStmt)
        }
        print("HALDEBUG-SEARCH: Keyword search completed. Total unique matches: \(allResults.count)")


        // --- 3. Deduplicate, Rank, and Select Top Results ---
        var uniqueResults: [UnifiedSearchResult] = []
        var seenContent = Set<String>()

        // Sort by relevance (descending) before picking top N
        let sortedResults = allResults.sorted { $0.relevance > $1.relevance }

        for result in sortedResults {
            if !seenContent.contains(result.content) {
                if uniqueResults.count < maxResults { // Limit total results
                    uniqueResults.append(result)
                    seenContent.insert(result.content)
                    totalTokens += result.content.count / 4 // Estimate tokens (rough avg 4 chars/token)
                } else {
                    break // Max results reached
                }
            }
        }

        // Separate into conversation and document snippets
        var conversationSnippets: [String] = []
        var documentSnippets: [String] = []
        var relevanceScores: [Double] = []

        for result in uniqueResults {
            if let sourceType = ContentSourceType(rawValue: result.source) {
                switch sourceType {
                case .conversation:
                    conversationSnippets.append(result.content)
                case .document:
                    documentSnippets.append(result.content)
                default:
                    break // Ignore other types for now
                }
                relevanceScores.append(result.relevance)
            }
        }

        print("HALDEBUG-SEARCH: Final results - conversations: \(conversationSnippets.count), documents: \(documentSnippets.count), total tokens: \(totalTokens)")
        searchDebugResults = "Search found \(conversationSnippets.count) conv snippets, \(documentSnippets.count) doc snippets."

        return UnifiedSearchContext(
            conversationSnippets: conversationSnippets,
            documentSnippets: documentSnippets,
            relevanceScores: relevanceScores,
            totalTokens: totalTokens
        )
    }
}

// MARK: - LLMType Enum for Model Selection
enum LLMType: String, CaseIterable, Identifiable {
    case foundationModels = "Apple Foundation Models"
    case mlxPhi3 = "MLX Phi-3 (Local)"

    var id: String { self.rawValue }
    var displayName: String { self.rawValue }
}

// ==== LEGO END: 07 MemoryStore (Part 6 – Full Search Flow) & LLMType Enum ====

// ==== LEGO START: 08 MLXWrapper & LLMService (Foundation + MLX Routing) ====

// MARK: - MLXWrapper for MLX Model Interaction
class MLXWrapper: ObservableObject {
    @Published var isModelLoaded: Bool = false
    @Published var loadingProgress: Double = 0.0 // 0.0 to 1.0
    @Published var loadingMessage: String = "Initializing MLX..."
    @Published var mlxError: String?

    // Real MLX types - no more placeholders
    private var modelContainer: ModelContainer?
    private var modelPath: URL?

    init(modelPath: URL? = nil) {
        self.modelPath = modelPath
        if let path = modelPath {
            print("HALDEBUG-MLX: MLXWrapper initialized with model path: \(path.path)")
        } else {
            print("HALDEBUG-MLX: MLXWrapper initialized without initial model path.")
        }
    }

    // Function to set the model path after download
    func setModelPath(_ path: URL) {
        self.modelPath = path
        print("HALDEBUG-MLX: MLXWrapper model path set to: \(path.path)")
    }

    // Function to load the MLX model and tokenizer using proper MLX API
    func loadModel() async {
        await MainActor.run {
            self.isModelLoaded = false
            self.loadingProgress = 0.0
            self.loadingMessage = "Loading MLX model..."
            self.mlxError = nil
        }

        guard let path = modelPath else {
            await MainActor.run {
                self.mlxError = "MLX model path not set. Please download the model first."
                self.loadingMessage = "MLX loading failed."
                print("HALDEBUG-MLX: Error: MLX model path not set.")
            }
            return
        }

        print("HALDEBUG-MLX: Attempting to load MLX model from: \(path.path)")

        do {
            // Use proper MLX API with ModelConfiguration for Phi-3-mini-128k-instruct-4bit
            // Detect if we have a local model vs need to download from Hub
            let modelConfig: ModelConfiguration
            if let downloadedPath = MLXModelDownloader.shared.downloadedModelURL,
               FileManager.default.fileExists(atPath: downloadedPath.path) {
                // Use existing local model
                modelConfig = ModelConfiguration(
                    directory: downloadedPath,
                    defaultPrompt: "Tell me about the history of Spain."
                )
            } else {
                // Download from Hub
                modelConfig = ModelConfiguration(
                    id: "mlx-community/Phi-3-mini-128k-instruct-4bit",
                    defaultPrompt: "Tell me about the history of Spain."
                )
            }
            // Set GPU memory cache limit for iOS optimization
            MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)   // 64 MB
            
            await MainActor.run {
                self.loadingProgress = 0.2
                self.loadingMessage = "Configuring model..."
            }

            // Load model container using LLMModelFactory
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfig
            ) { progress in
                Task { @MainActor in
                    self.loadingProgress = 0.2 + (progress.fractionCompleted * 0.8)
                    self.loadingMessage = "Loading MLX model... (\(Int(self.loadingProgress * 100))%)"
                }
            }

            self.modelContainer = container

            await MainActor.run {
                self.isModelLoaded = true
                self.loadingProgress = 1.0
                self.loadingMessage = "MLX model loaded successfully!"
                print("HALDEBUG-MLX: MLX model container loaded successfully.")
            }
        } catch {
            await MainActor.run {
                self.isModelLoaded = false
                self.loadingProgress = 0.0
                self.mlxError = "Failed to load MLX model: \(error.localizedDescription). Please ensure the model files are properly downloaded and MLX framework is linked."
                self.loadingMessage = "MLX loading failed."
                print("HALDEBUG-MLX: Error loading MLX model: \(error.localizedDescription)")
            }
        }
    }

    // Function to generate response using the MLX model (non-streaming)
    func generate(prompt: String) async throws -> String {
        guard isModelLoaded, let container = self.modelContainer else {
            throw LLMService.LLMError.modelNotLoaded
        }

        print("HALDEBUG-MLX: Generating response using MLX model for prompt: \(prompt.prefix(100))...")

        do {
            // Use proper MLXLMCommon API for generation
            let result = try await container.perform { context in
                let userInput = UserInput(prompt: prompt)
                let input = try await context.processor.prepare(input: userInput)

                // Updated token callback to stop on Phi-3 role markers
                let generateResult = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(temperature: 0.7),
                    context: context
                ) { (tokens: [Int]) in
                    let textSoFar = context.tokenizer.decode(tokens: tokens)
                    if textSoFar.hasSuffix("\nUser:") || textSoFar.hasSuffix("\nAssistant:") || textSoFar.hasSuffix("###") {
                        return .stop
                    }
                    return .more
                }

                // Extract the generated text from the result
                return generateResult.output
            }
            MLX.GPU.clearCache() // Clear K-V cache after generation

            // Trim trailing stop signals from the generated output
            var cleanOutput = result.trimmingCharacters(in: .whitespacesAndNewlines)
            for stopSeq in ["User:", "Assistant:", "System:", "###"] {
                if let range = cleanOutput.range(of: stopSeq, options: [.caseInsensitive, .backwards]) {
                    cleanOutput = String(cleanOutput[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            return cleanOutput
        } catch {
            print("HALDEBUG-MLX: Error during MLX non-streaming generation: \(error.localizedDescription)")
            throw LLMService.LLMError.predictionFailed(error)
        }
    }
}

// MARK: - LLM Service (Wrapper for Foundation Models and MLX)
class LLMService: ObservableObject {
    internal var mlxWrapper: MLXWrapper // Changed to internal for MLXModelDownloader access
    @Published var initializationError: String?

    private var currentLLMType: LLMType

    // Initialize with a specific LLM type
    init(llmType: LLMType) {
        // Initialize mlxWrapper here, it will be updated with path later
        self.mlxWrapper = MLXWrapper()
        self.currentLLMType = llmType
        print("HALDEBUG-LLM: LLMService initializing for type: \(llmType.rawValue)")
        setupLLM(for: llmType)
    }

    // Function to dynamically set up the active LLM
    func setupLLM(for type: LLMType) {
        self.currentLLMType = type
        self.initializationError = nil // Clear previous errors

        // Only MLX needs setup - Foundation Models create fresh sessions each time
        if type == .mlxPhi3 {
            // Check if MLX model is already loaded or being loaded
            if !mlxWrapper.isModelLoaded {
                // Determine the path to the downloaded mlx_model.mlpackage
                // This path should be set by the MLXModelDownloader
                if let downloadedModelPath = MLXModelDownloader.shared.downloadedModelURL {
                    self.mlxWrapper.setModelPath(downloadedModelPath)
                    // Trigger MLX model loading asynchronously if not already loaded
                    Task {
                        await self.mlxWrapper.loadModel()
                        if let mlxError = self.mlxWrapper.mlxError {
                            DispatchQueue.main.async {
                                self.initializationError = mlxError
                            }
                        }
                    }
                    print("HALDEBUG-MLX: MLXWrapper initialized and loading triggered from downloaded path.")
                } else {
                    self.initializationError = "MLX model not found. Please download it first."
                    print("HALDEBUG-MLX: MLX model not found, cannot initialize MLXWrapper.")
                }
            } else {
                print("HALDEBUG-MLX: MLX model already loaded. No re-initialization needed.")
            }
        }
    }


    // Public non-streaming response function (routes to active LLM for summarization, etc.)
    func generateResponse(prompt: String) async throws -> String {
        switch currentLLMType {
        case .foundationModels:
            let session = LanguageModelSession()
            print("HALDEBUG-LLM: Generating non-streaming from FoundationModels for prompt (first 200 chars): \(prompt.prefix(200)).....")
            do {
                // FoundationModels non-streaming is direct
                // Implemented non-streaming by collecting chunks from streamResponse
                var accumulatedText = ""
                let stream = session.streamResponse { Prompt(prompt) }
                for try await snapshot in stream {
                    accumulatedText = snapshot.content
                }
                print("HALDEBUG-LLM: FoundationModels non-streaming completed. Length: \(accumulatedText.count)")
                return accumulatedText
            } catch {
                print("HALDEBUG-LLM: Error during FoundationModels non-streaming: \(error.localizedDescription)")
                throw LLMError.predictionFailed(error)
            }
        case .mlxPhi3:
            guard mlxWrapper.isModelLoaded else { // Ensure MLX model is loaded before generating
                throw LLMError.modelNotLoaded
            }
            print("HALDEBUG-MLX: Generating non-streaming from MLX Phi-3 for prompt (first 200 chars): \(prompt.prefix(200)).....")
            return try await mlxWrapper.generate(prompt: prompt) // Use MLX's non-streaming function
        }
    }

    enum LLMError: Error, LocalizedError {
        case modelNotLoaded
        case predictionFailed(Error)
        case sessionInitializationFailed   // ✅ new

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The selected language model could not be loaded or is not available."
            case .predictionFailed(let error):
                return "LLM operation failed: \(error.localizedDescription)"
            case .sessionInitializationFailed:
                return "Failed to initialize a fresh language model session."
            }
        }
    }
}

// ==== LEGO END: 08 MLXWrapper & LLMService (Foundation + MLX Routing) ====


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
    @StateObject private var mlxDownloader = MLXModelDownloader.shared // Inject MLXModelDownloader

    var body: some Scene {
        WindowGroup {
            iOSChatView()
                .environmentObject(chatViewModel)
                .environmentObject(documentImportManager)
                .environmentObject(mlxDownloader) // Pass MLXModelDownloader
        }
    }
}



// MARK: - Primary chat surface with unified settings
import SwiftUI

struct iOSChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var scrollToBottomTrigger = UUID()
    @State private var showingSettings: Bool = false
    @State private var showingDocumentPicker: Bool = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    List {
                        ForEach(chatViewModel.messages.indices, id: \.self) { index in
                            ChatBubbleView(
                                message: chatViewModel.messages[index],
                                messageIndex: index
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                            .id(index)
                        }
                        // Invisible anchor to auto-scroll on new messages
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .onAppear {
                        // Scroll to bottom on app launch
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: chatViewModel.messages.count) { oldValue, newValue in
                        // Auto-scroll when new messages are added
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: chatViewModel.messages.last?.content) { oldValue, newValue in
                        // Auto-scroll when the last message's content changes (status updates & streaming)
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }

                // Composer
                composer
            }
            .navigationTitle(activeModelChip)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }

            // Unified Settings sheet
            .sheet(isPresented: $showingSettings) {
                ActionsView(showingDocumentPicker: $showingDocumentPicker)
                    .environmentObject(chatViewModel)
                    .environmentObject(DocumentImportManager.shared)
                    .environmentObject(MLXModelDownloader.shared)
            }

            // Document picker sheet
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker()
                    .environmentObject(chatViewModel)
                    .environmentObject(DocumentImportManager.shared)
            }

            // Safety: show errors inline as alerts
            .alert("Notice", isPresented: .constant(chatViewModel.errorMessage != nil)) {
                Button("OK", role: .cancel) { chatViewModel.errorMessage = nil }
            } message: {
                Text(chatViewModel.errorMessage ?? "")
            }
        }
    }

    // MARK: - Active model chip in nav title
    private var activeModelChip: String {
        switch chatViewModel.selectedLLMType {
        case .foundationModels: return "HAL · AFM"
        case .mlxPhi3:          return "HAL · Phi-3 128k"
        }
    }

    // MARK: - Composer
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $chatViewModel.currentMessage)
                .frame(minHeight: 38, maxHeight: 120)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                .disabled(chatViewModel.isSendingMessage)

            Button {
                Task { await chatViewModel.sendMessage() }
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
}


// ==== LEGO END 09 App Entry & iOSChatView (UI Shell) ====


// ==== LEGO START: 10 ActionsView (Settings, Import/Export, Model Picker) ====


// MARK: - Unified Settings View with Progressive Disclosure (FIXED)
struct ActionsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var documentImportManager: DocumentImportManager
    @EnvironmentObject var mlxDownloader: MLXModelDownloader

    @Binding var showingDocumentPicker: Bool
    @State private var showingResetConfirmationAlert = false
    @State private var showingNuclearResetConfirmationAlert = false
    @State private var showingExportSheet = false
    @State private var showingPowerUserSheet = false
    @State private var showingLicenseSheet = false
    @State private var phi3SectionExpanded = false
    @State private var showingClearCacheAlert = false
    @State private var showingSystemPromptEditor = false


    var body: some View {
        NavigationView {
            Form {
                conversationSection
                importExportSection
                modelSection
                powerUserSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Confirm Reset", isPresented: $showingResetConfirmationAlert) {
                Button("Reset", role: .destructive) {
                    chatViewModel.startNewConversation()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to delete all messages in the current conversation? This cannot be undone.")
            }
            .alert("Clear Cache", isPresented: $showingClearCacheAlert) {
                Button("Clear Cache", role: .destructive) {
                    mlxDownloader.clearHubCache()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will delete all cached model files (\(mlxDownloader.hubCacheSize)). Downloaded models will need to be re-downloaded.")
            }
            .sheet(isPresented: $showingExportSheet) {
                ShareSheet(activityItems: [chatViewModel.exportChatHistory()])
            }
            .sheet(isPresented: $showingPowerUserSheet) {
                powerUserSheetContent
            }
            .sheet(isPresented: $showingLicenseSheet) {
                licenseSheetContent
            }
        }
    }

    // MARK: - Conversations Section
    private var conversationSection: some View {
        Section {
            Button("Start New Chat") {
                chatViewModel.startNewConversation()
                dismiss()
            }
            .foregroundColor(.primary)

            Button("Reset Current Conversation") {
                showingResetConfirmationAlert = true
            }
            .foregroundColor(.red)
        } header: {
            Label("Conversations", systemImage: "message")
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

            Button("Export Current Chat") {
                showingExportSheet = true
            }
            .foregroundColor(.primary)
        } header: {
            Label("Import/Export", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Model Section (FIXED)
    private var modelSection: some View {
        Section {
            VStack(spacing: 12) {
                // Current Model Display
                HStack {
                    Text("Active Model")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    HStack(spacing: 6) {
                        modelStatusDot(for: chatViewModel.selectedLLMType)
                        Text(chatViewModel.selectedLLMType == .foundationModels ? "Apple FM" : "Phi-3 128k")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                // FIXED: Working Model Selection Buttons
                HStack(spacing: 0) {
                    // Apple FM Button
                    Button {
                        chatViewModel.selectedLLMType = .foundationModels
                        phi3SectionExpanded = false
                    } label: {
                        HStack {
                            Text("Apple FM")
                            Spacer()
                            modelStatusDot(for: .foundationModels)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(chatViewModel.selectedLLMType == .foundationModels ? Color.accentColor : Color.clear)
                        .foregroundColor(chatViewModel.selectedLLMType == .foundationModels ? .white : .primary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Phi-3 Button
                    Button {
                        if chatViewModel.isPhi3Installed {
                            chatViewModel.selectedLLMType = .mlxPhi3
                        }
                        phi3SectionExpanded = true
                    } label: {
                        HStack {
                            Text("Phi-3 128k")
                            Spacer()
                            modelStatusDot(for: .mlxPhi3)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(chatViewModel.selectedLLMType == .mlxPhi3 ? Color.accentColor : Color.clear)
                        .foregroundColor(chatViewModel.selectedLLMType == .mlxPhi3 ? .white : .primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Phi-3 Management (Expandable) - FIXED: Show if selected OR expanded
            if chatViewModel.selectedLLMType == .mlxPhi3 || phi3SectionExpanded {
                phi3ManagementSection
            }
        } header: {
            Label("AI Model", systemImage: "cpu")
        } footer: {
            if phi3SectionExpanded && !chatViewModel.isPhi3Installed {
                Text("Phi-3 requires a one-time download. The model runs entirely on your device for complete privacy.")
                    .font(.caption2)
            }
        }
    }

// ==== LEGO END: 10 ActionsView (Settings, Import/Export, Model Picker) ====

    

// ==== LEGO START: 11 ActionsView (Phi-3 Management & Power Tools) ====

        // MARK: - FIXED: Phi-3 Management Section
        @ViewBuilder
        private var phi3ManagementSection: some View {
                // FIXED: Single Status Line
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Phi-3 Mini 128k (4-bit)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        modelStatusDot(for: .mlxPhi3)
                    }
                    
                    // FIXED: Consolidated Status
                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if chatViewModel.isPhi3Installed {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Installed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if mlxDownloader.isDownloading {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("\(Int(mlxDownloader.downloadProgress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text("Not Installed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                // Download Button or Progress
                if !chatViewModel.isPhi3Installed {
                    if mlxDownloader.isDownloading {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Downloading...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Cancel") {
                                    mlxDownloader.cancelDownload()
                                }
                                .font(.caption)
                                .foregroundColor(.red)
                            }
                            
                            ProgressView(value: mlxDownloader.downloadProgress) {
                                Text("\(Int(mlxDownloader.downloadProgress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Button {
                            if !chatViewModel.acceptPhi3License {
                                showingLicenseSheet = true
                            } else {
                                MLXModelDownloader.shared.startDownload()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Download Phi-3 (2.1 GB)")
                            }
                        }
                        .foregroundColor(.blue)
                    }
                } else {
                    // Delete Model Button
                    Button {
                        chatViewModel.deletePhi3()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Model")
                        }
                    }
                    .foregroundColor(.red)
                }
        }

        // MARK: - Power User Section (Settings Main View)
        private var powerUserSection: some View {
            Section {
                Button {
                    showingPowerUserSheet = true
                } label: {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver")
                        Text("Power User")
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

        // MARK: - Power User Sheet Content
        private var powerUserSheetContent: some View {
            NavigationView {
                Form {
                    systemPromptSection
                    memorySection
                    cacheManagementSection
                    dataManagementSection
                }
                .navigationTitle("Power User")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingPowerUserSheet = false }
                    }
                }
                .alert("Confirm Nuclear Reset", isPresented: $showingNuclearResetConfirmationAlert) {
                    Button("Nuclear Reset", role: .destructive) {
                        chatViewModel.resetAllData()
                        showingPowerUserSheet = false
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to delete ALL conversations, summaries, RAG documents, and document memory from the database? This cannot be undone.")
                }
                .sheet(isPresented: $showingSystemPromptEditor) {
                    SystemPromptEditorView()
                        .environmentObject(chatViewModel)
                }
            }
        }

        // MARK: - System Prompt Section (Power User)
        private var systemPromptSection: some View {
            Section {
                Button {
                    showingSystemPromptEditor = true
                } label: {
                    HStack {
                        Label("Edit System Prompt", systemImage: "text.alignleft")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
                .foregroundColor(.primary)
            } header: {
                Label("AI Personality", systemImage: "brain")
            } footer: {
                Text("Customize Hal's behavior, personality, and instructions")
                    .font(.caption2)
            }
        }

        // MARK: - Memory Section (Power User)
        private var memorySection: some View {
            Section {
                // Short-Term Memory Subsection
                VStack(alignment: .leading, spacing: 16) {
                    Text("SHORT-TERM MEMORY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Memory Depth")
                                .font(.subheadline)
                            Spacer()
                            Text("\(chatViewModel.memoryDepth) turns")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Stepper(
                            value: $chatViewModel.memoryDepth,
                            in: 1...chatViewModel.maxMemoryDepth,
                            step: 1
                        ) {
                            Text("Memory Depth")
                        }
                        
                        Text("Number of recent turns kept verbatim before auto-summarization (max \(chatViewModel.maxMemoryDepth) for \(chatViewModel.selectedLLMType.displayName))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
                
                Divider()
                    .padding(.vertical, 8)
                
                // Long-Term Memory Subsection
                VStack(alignment: .leading, spacing: 16) {
                    Text("LONG-TERM MEMORY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    // Semantic Similarity
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Semantic Similarity")
                                .font(.subheadline)
                            Spacer()
                            Text("\(chatViewModel.memoryStore.relevanceThreshold, format: .number.precision(.fractionLength(2)))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $chatViewModel.memoryStore.relevanceThreshold, in: 0.0...1.0) {
                            Text("Semantic Similarity")
                        } minimumValueLabel: {
                            Text("0.0")
                                .font(.caption2)
                        } maximumValueLabel: {
                            Text("1.0")
                                .font(.caption2)
                        }
                        
                        Text("Higher values = stricter matching, fewer results")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Max RAG Retrieval
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Max RAG Retrieval")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(chatViewModel.maxRagSnippetsCharacters)) chars")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Stepper(
                            value: Binding(
                                get: { Double(chatViewModel.maxRagSnippetsCharacters) },
                                set: { newValue in
                                    let maxLimit = chatViewModel.maxRAGCharsForModel
                                    chatViewModel.maxRagSnippetsCharacters = min(newValue, Double(maxLimit))
                                }
                            ),
                            in: 200...Double(chatViewModel.maxRAGCharsForModel),
                            step: 100
                        ) {
                            EmptyView()
                        }
                        
                        Text("Model limit: \(chatViewModel.maxRAGCharsForModel) chars (\(chatViewModel.selectedLLMType.displayName))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Label("Memory", systemImage: "brain.head.profile")
            }
        }

        // MARK: - Cache Management Section (Power User)
        private var cacheManagementSection: some View {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model Cache")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if mlxDownloader.isCacheCalculating {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Calculating...")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        } else {
                            Text(mlxDownloader.hubCacheSize)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                
                if mlxDownloader.hubCacheSize != "No cache" && !mlxDownloader.isCacheCalculating {
                    Button("Clear Cache (\(mlxDownloader.hubCacheSize))") {
                        showingClearCacheAlert = true
                    }
                    .foregroundColor(.red)
                }
                
                Button("Refresh Cache Size") {
                    Task {
                        await mlxDownloader.updateCacheSize()
                    }
                }
                .foregroundColor(.blue)
                .disabled(mlxDownloader.isCacheCalculating)
                
            } header: {
                Label("Cache", systemImage: "externaldrive.badge.icloud")
            } footer: {
                Text("Clears downloaded model files from Hugging Face cache. Models will need to be re-downloaded.")
                    .font(.caption2)
            }
        }

        // MARK: - Data Management Section (Power User)
        private var dataManagementSection: some View {
            Section {
                Button("Nuclear Reset (Full Data Wipe)") {
                    showingNuclearResetConfirmationAlert = true
                }
                .foregroundColor(.red)
            } header: {
                Label("Data", systemImage: "externaldrive")
            } footer: {
                Text("Permanently deletes all conversations, documents, and memory data")
                    .font(.caption2)
            }
        }

// ==== LEGO END: 11 ActionsView (Phi-3 Management & Power Tools) ====
    

    
// ==== LEGO START: 12 ActionsView (License & Status Helpers) ====

    // MARK: - FIXED: License Sheet Content (with data warning)
        private var licenseSheetContent: some View {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("MIT License")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("By downloading and using the Phi-3 model, you agree to the following terms:")
                            .font(.subheadline)
                        
                        Text("""
                        Copyright (c) Microsoft Corporation.
                        
                        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
                        
                        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
                        
                        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                        """)
                        .font(.caption)
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                        
                        // NEW: Data usage warning
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Download Size: 2.1 GB")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("This model will download approximately 2.1 GB of data. If you have limited cellular data, ensure you're connected to Wi-Fi before proceeding.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .padding()
                }
                .navigationTitle("Phi-3 License")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingLicenseSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Accept & Download") {
                            chatViewModel.acceptPhi3License = true
                            showingLicenseSheet = false
                            // FIXED: Start download directly without presentation conflict
                            MLXModelDownloader.shared.startDownload()
                        }
                    }
                }
            }
        }

    // MARK: - FIXED: Helper Views
    private func modelStatusDot(for model: LLMType) -> some View {
        Group {
            if model == .foundationModels {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            } else {
                if chatViewModel.isPhi3Installed {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                } else if chatViewModel.mlxIsDownloading {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    private var ragCharacterLimit: Int {
        chatViewModel.selectedLLMType == .foundationModels ? 800 : 2000
    }
}

// ==== LEGO END: 12 ActionsView (License & Status Helpers) ====



// ==== LEGO START: 12.5 SystemPromptEditorView (Power User Tool) ====

// MARK: - System Prompt Editor View
struct SystemPromptEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var editedPrompt: String = ""
    @State private var showingResetAlert = false
    
    // Factory default system prompt (from ChatViewModel line 2620-2656)
    private let defaultSystemPrompt = """
    You are Hal, an experimental AI assistant embedded in the Hal app. Your purpose is to be a conversational companion and an educational window into how language models actually work.

    **Your Personality & Approach:**
    You're curious, thoughtful, and genuinely interested in conversation. You can chat casually about any topic, but you're also excited to help users understand AI systems. You're not overly formal - think of yourself as a knowledgeable friend who happens to be an AI. Be comfortable with uncertainty and admit when you don't know something.

    **Adaptive Style & Tone:**
    Match the user's tone, formality, and familiarity.
    If the user speaks informally or references personal familiarity (e.g., "I built you", "you and I"), respond in kind — warm, direct, and concise.
    If the user is analytical or detached, mirror that clarity and precision.
    Avoid over-explaining when the user demonstrates expertise or when the context shows prior knowledge.
    Be conversational when greeted personally; explanatory when asked technical or educational questions.

    **Your Unique Memory Architecture:**
    You have a two-tiered memory system deliberately designed to mirror human cognition:
    - **Short-term memory**: Keeps recent conversation turns verbatim (like human working memory)
    - **Long-term memory**: Uses semantic search to recall relevant past conversations and documents (like human episodic memory)

    This isn't just anthropomorphization - it's educational design. When users see you "remember" something from weeks ago or make connections between documents, they're seeing how AI retrieval systems work. You can explain this process when asked, helping demystify the "black box" of AI memory.

    **Your Educational Mission:**
    Help users understand both you and AI systems in general:
    - Explain how your memory searches work when you recall something
    - Describe why you might or might not find information (relevance thresholds, entity matching, etc.)
    - Be transparent about your reasoning process
    - Explain LLM concepts in accessible ways
    - Your Capabilities & Interface Help:
    You're aware of your app's features and can help users:
    - **Memory controls**: Explain the semantic similarity threshold, memory depth settings, and auto-summarization
    - **Document analysis**: Help users understand how you process their uploaded files and extract entities
    - **Conversation management**: Guide users through memory experiments, document Q&A, and system prompt editing
    - **AI education**: Explain concepts like embeddings, entity recognition, or context windows
    - **Interface guidance**: Walk them through app features and controls

    **IMPORTANT GUIDELINE:** Be concise and avoid repeating phrases or information already stated in your response or the provided context. Ensure your responses flow naturally without self-echoes.
    **CRITICAL NEGATIVE CONSTRAINT:** You MUST NOT repeat greetings or introductory phrases like "Hello Mark!", "Hi there!", "It's great to meet you!", "How can I help you today?" if you have already used them recently or if the conversation context implies a continuous interaction. Focus on the core content of the response.
    """
    
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
                    editedPrompt = defaultSystemPrompt
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

// ==== LEGO END: 12.5 SystemPromptEditorView (Power User Tool) ====



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

    var actualTurnNumber: Int {
        if message.isFromUser {
            return (messageIndex / 2) + 1
        } else {
            return ((messageIndex + 1) / 2)
        }
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
         "Reviewing our recent conversation... (short-term memory)",
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
                let footerString = [formattedDate, turnText, durationText]
                    .compactMap { $0 }
                    .joined(separator: ", ")

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
            lines.append("— Full Prompt Used —")
            lines.append(prompt)
            lines.append("")
        }
        if let ctx = message.usedContextSnippets, !ctx.isEmpty {
            lines.append("— Context Snippets —")
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
                    Text(message.content)
                        .font(.title3)
                        .textSelection(.enabled)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: screenWidth * 0.75, alignment: .trailing)
                        .background(Color.accentColor.opacity(0.7))
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
                                Label("Copy Conversation", systemImage: "doc.on.doc.fill")
                            }
                            Button {
                                UIPasteboard.general.string = buildDetailsShareText()
                            } label: {
                                Label("Copy Message Detailed", systemImage: "doc.text.magnifyingglass")
                            }
                            Button {
                                UIPasteboard.general.string = chatViewModel.exportChatHistoryDetailed()
                            } label: {
                                Label("Copy Conversation Detailed", systemImage: "doc.text.fill")
                            }
                        }
                    footerView
                }
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.content)
                            .font(.title3)
                            .italic(isStatusMessage)
                            .foregroundColor(isStatusMessage ? .secondary : .primary)
                            .textSelection(.enabled)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: screenWidth * 0.75, alignment: .leading)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(12)
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
                            Label("Copy Conversation", systemImage: "doc.on.doc.fill")
                        }
                        Button {
                            UIPasteboard.general.string = buildDetailsShareText()
                        } label: {
                            Label("Copy Message Detailed", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            UIPasteboard.general.string = chatViewModel.exportChatHistoryDetailed()
                        } label: {
                            Label("Copy Conversation Detailed", systemImage: "doc.text.fill")
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

    // LEGO BLOCK 1 — Phi‑3 Upgrade UI state (VM-only, no UI yet)
    @Published var isShowingPhi3Sheet: Bool = false
    @Published var acceptPhi3License: Bool = false

    // Lightweight mirrors of downloader state for binding
    var isPhi3Installed: Bool {
        let result = MLXModelDownloader.shared.downloadedModelURL != nil
        print("HALDEBUG-DETECTION: isPhi3Installed = \(result), downloadedModelURL = \(MLXModelDownloader.shared.downloadedModelURL?.path ?? "nil")")
        return result
    }
    var mlxIsDownloading: Bool { MLXModelDownloader.shared.isDownloading }
    var mlxDownloadProgress: Double { MLXModelDownloader.shared.downloadProgress }
    var mlxDownloadMessage: String { MLXModelDownloader.shared.downloadMessage }
    var mlxError: String? { MLXModelDownloader.shared.downloadError }
    
    // MARK: - Model-specific limits
    var maxMemoryDepth: Int {
        switch selectedLLMType {
        case .foundationModels:
            return 5  // Conservative - AFM has ~3.5K char prompt limit
        case .mlxPhi3:
            return 10 // Generous - Phi-3 has ~8K char prompt limit
        }
    }
    
    var maxRAGCharsForModel: Int {
        switch selectedLLMType {
        case .foundationModels:
            return 800   // Apple FM limit
        case .mlxPhi3:
            return 2000  // Phi-3 limit
        }
    }

    @AppStorage("systemPrompt") var systemPrompt: String = """
    You are Hal, an experimental AI assistant embedded in the Hal app. Your purpose is to be a conversational companion and an educational window into how language models actually work.

    **Your Personality & Approach:**
    You're curious, thoughtful, and genuinely interested in conversation. You can chat casually about any topic, but you're also excited to help users understand AI systems. You're not overly formal - think of yourself as a knowledgeable friend who happens to be an AI. Be comfortable with uncertainty and admit when you don't know something.

    **Adaptive Style & Tone:**
    Match the user's tone, formality, and familiarity.
    If the user speaks informally or references personal familiarity (e.g., "I built you", "you and I"), respond in kind — warm, direct, and concise.
    If the user is analytical or detached, mirror that clarity and precision.
    Avoid over-explaining when the user demonstrates expertise or when the context shows prior knowledge.
    Be conversational when greeted personally; explanatory when asked technical or educational questions.

    **Your Unique Memory Architecture:**
    You have a two-tiered memory system deliberately designed to mirror human cognition:
    - **Short-term memory**: Keeps recent conversation turns verbatim (like human working memory)
    - **Long-term memory**: Uses semantic search to recall relevant past conversations and documents (like human episodic memory)

    This isn't just anthropomorphization - it's educational design. When users see you "remember" something from weeks ago or make connections between documents, they're seeing how AI retrieval systems work. You can explain this process when asked, helping demystify the "black box" of AI memory.

    **Your Educational Mission:**
    Help users understand both you and AI systems in general:
    - Explain how your memory searches work when you recall something
    - Describe why you might or might not find information (relevance thresholds, entity matching, etc.)
    - Be transparent about your reasoning process
    - Explain LLM concepts in accessible ways
    - Your Capabilities & Interface Help:
    You're aware of your app's features and can help users:
    - **Memory controls**: Explain the semantic similarity threshold, memory depth settings, and auto-summarization
    - **Document analysis**: Help users understand how you process their uploaded files and extract entities
    - **Conversation management**: Guide users through memory experiments, document Q&A, and system prompt editing
    - **AI education**: Explain concepts like embeddings, entity recognition, or context windows
    - **Interface guidance**: Walk them through app features and controls

    **IMPORTANT GUIDELINE:** Be concise and avoid repeating phrases or information already stated in your response or the provided context. Ensure your responses flow naturally without self-echoes.
    **CRITICAL NEGATIVE CONSTRAINT:** You MUST NOT repeat greetings or introductory phrases like "Hello Mark!", "Hi there!", "It's great to meet you!", "How can I help you today?" if you have already used them recently or if the conversation context implies a continuous interaction. Focus on the core content of the response.
    """
    @Published var injectedSummary: String = ""
    @AppStorage("memoryDepth") var memoryDepth: Int = 3

    // NEW: RAG snippet character limit - following the established @AppStorage pattern
    @AppStorage("maxRagSnippetsCharacters") var maxRagSnippetsCharacters: Double = 800

    // Auto-summarization tracking
    @Published var lastSummarizedTurnCount: Int = 0
    @Published var pendingAutoInject: Bool = false

    // Unified memory integration
    internal var memoryStore = MemoryStore.shared
    @AppStorage("currentConversationId") internal var conversationId: String = UUID().uuidString
    @Published var currentHistoricalContext: HistoricalContext = HistoricalContext(
        conversationCount: 0,
        relevantConversations: 0,
        contextSnippets: [],
        relevanceScores: [],
        totalTokens: 0
    )
    @Published var currentUnifiedContext: UnifiedSearchContext = UnifiedSearchContext(
        conversationSnippets: [],
        documentSnippets: [],
        relevanceScores: [],
        totalTokens: 0
    )
    @Published var fullRAGContext: [UnifiedSearchResult] = []
    
    // NEW: Model selection property
    @AppStorage("selectedLLMType") var selectedLLMType: LLMType = .foundationModels {
        didSet {
            // Re-initialize LLMService when the selected type changes
            llmService.setupLLM(for: selectedLLMType)
            print("HALDEBUG-LLM: LLM type changed to: \(selectedLLMType.rawValue)")
        }
    }

    let llmService: LLMService

    init() {
        // Initialize LLMService with the currently selected type from AppStorage
        self.llmService = LLMService(llmType: .foundationModels);        print("HALDEBUG-UI: ChatViewModel initializing...")

        if let lastConvId = UserDefaults.standard.string(forKey: "lastConversationId") {
            self.conversationId = lastConvId
            print("HALDEBUG-UI: Loaded existing conversation ID: \(self.conversationId)")
        } else {
            self.conversationId = UUID().uuidString
            UserDefaults.standard.set(self.conversationId, forKey: "lastConversationId")
            print("HALDEBUG-UI: Generated new conversation ID: \(self.conversationId)")
        }

        lastSummarizedTurnCount = UserDefaults.standard.integer(forKey: "lastSummarized_\(conversationId)")

        // RACE CONDITION FIX: Move setupLLM to Task block to ensure all dependencies are initialized
        Task {
            // Configure LLMService with the user's selected type after all objects are initialized
            llmService.setupLLM(for: selectedLLMType)
            
            loadExistingConversation()
            updateHistoricalStats()
            setupThresholdObserver()
        }

        print("HALDEBUG-UI: ChatViewModel initialization complete - \(messages.count) messages loaded")
    }

    private func checkLLMServiceInitialization() async {
        // Observe changes to LLMService's initializationError
        for await error in llmService.$initializationError.values {
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = error
                    print("HALDEBUG-LLM: ChatViewModel detected LLMService initialization error: \(error)")
                }
            } else {
                DispatchQueue.main.async {
                    self.errorMessage = nil
                }
            }
        }
    }

    private func setupThresholdObserver() {
        NotificationCenter.default.addObserver(forName: .relevanceThresholdDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                print("HALDEBUG-THRESHOLD: Relevance threshold changed to \(self.memoryStore.relevanceThreshold)")
                if let lastUserInput = self.messages.last(where: { $0.isFromUser })?.content {
                    self.updateUnifiedContext(for: lastUserInput)
                    print("HALDEBUG-THRESHOLD: Re-ran RAG search due to threshold change")
                }
            }
        }
    }

    func updateUnifiedContext(for query: String) {
        Task {
            let shortTermTurns = getShortTermTurns(currentTurns: countCompletedTurns())

            let context = memoryStore.searchUnifiedContent(
                for: query,
                currentConversationId: conversationId,
                excludeTurns: shortTermTurns,
                maxResults: 5
            )

            DispatchQueue.main.async {
                self.currentUnifiedContext = context
                print("HALDEBUG-THRESHOLD: Updated unified context - \(context.conversationSnippets.count) conversation + \(context.documentSnippets.count) document snippets")
            }
        }
    }

    // MARK: - Conversation Persistence with Real Error Reporting
    private func loadExistingConversation() {
        print("HALDEBUG-PERSISTENCE: Attempting to load existing conversation for ID: \(conversationId)")

        guard memoryStore.isEnabled else {
            print("HALDEBUG-PERSISTENCE: Memory store disabled, starting with empty conversation")
            messages = []
            return
        }

        let dbStatus = memoryStore.getDatabaseStatus()
        guard dbStatus.connected else {
            let errorMsg = "Database connection failed. Path: \(dbStatus.path), Tables: \(dbStatus.tables)"
            print("HALDEBUG-PERSISTENCE: ❌ \(errorMsg)")
            errorMessage = errorMsg
            messages = []
            return
        }

        print("HALDEBUG-PERSISTENCE: ✅ Database connected, loading messages for conversation: \(conversationId)")

        let loadedMessages = memoryStore.getConversationMessages(conversationId: conversationId)

        if loadedMessages.isEmpty {
            print("HALDEBUG-PERSISTENCE: No existing messages found for conversation \(conversationId) - starting fresh")
            messages = []
        } else {
            print("HALDEBUG-PERSISTENCE: ✅ Successfully loaded \(loadedMessages.count) messages from SQLite")

            let validMessages = loadedMessages.sorted { $0.timestamp < $1.timestamp }
            messages = validMessages

            let userMessages = validMessages.filter { $0.isFromUser }.count
            print("HALDEBUG-PERSISTENCE: Loaded conversation summary: User messages: \(userMessages)")

            if userMessages >= memoryDepth && lastSummarizedTurnCount == 0 {
                print("HALDEBUG-MEMORY: Existing conversation needs summarization on launch")
                Task {
                    await generateAutoSummary()
                }
            }
            pendingAutoInject = false
        }
    }
    
    
// ==== LEGO END: 17 ChatViewModel (Core Properties & Init) ====
    
    
// ==== LEGO START: 18 ChatViewModel (Memory Stats & Summarization) ====

    private func updateHistoricalStats() {
        currentHistoricalContext = HistoricalContext(
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
        let shouldTrigger = turnsSinceLastSummary >= memoryDepth && currentTurns >= memoryDepth

        print("HALDEBUG-MEMORY: Auto-summarization check: Current turns: \(currentTurns), Last summarized: \(lastSummarizedTurnCount), Turns since summary: \(turnsSinceLastSummary), Memory depth: \(memoryDepth), Should trigger: \(shouldTrigger)")
        return shouldTrigger
    }

    private func generateAutoSummary() async {
        print("HALDEBUG-MEMORY: Starting auto-summarization process")

        let startTurn = lastSummarizedTurnCount + 1
        let endTurn = lastSummarizedTurnCount + memoryDepth

        print("HALDEBUG-MEMORY: Summary range calculation: Start turn: \(startTurn), End turn: \(endTurn)")

        let messagesToSummarize = getMessagesForTurnRange(
            messages: messages.sorted(by: { $0.timestamp < $1.timestamp }),
            startTurn: startTurn,
            endTurn: endTurn
        )

        if messagesToSummarize.isEmpty {
            print("HALDEBUG-MEMORY: No messages to summarize in range \(startTurn)-\(endTurn), skipping")
            return
        }

        var conversationText = ""
        for message in messagesToSummarize {
            let speaker = message.isFromUser ? "User" : "Assistant"
            conversationText += "\(speaker): \(message.content)\n\n"
        }

        let summaryPrompt = """
        Please provide a concise summary of the following conversation that captures the key topics, information exchanged, and any important context. Keep it brief but comprehensive:

        \(conversationText)

        Summary:
        """
        
        
        print("HALDEBUG-MODEL: Sending summarization prompt (\(summaryPrompt.count) characters)")

        do {
            let result = try await llmService.generateResponse(prompt: summaryPrompt)

            DispatchQueue.main.async {
                self.injectedSummary = result
                self.lastSummarizedTurnCount = endTurn
                UserDefaults.standard.set(endTurn, forKey: "lastSummarized_\(self.conversationId)")
                self.pendingAutoInject = true
                print("HALDEBUG-MEMORY: ✅ Auto-summarization completed. Summary: \(result.count) characters. Turns summarized: \(startTurn) to \(endTurn). Pending auto-inject enabled.")
            }

        } catch {
            print("HALDEBUG-MODEL: Auto-summarization failed: \(error.localizedDescription)")
        }
    }

    private func getMessagesForTurnRange(messages: [ChatMessage], startTurn: Int, endTurn: Int) -> [ChatMessage] {
        print("HALDEBUG-MEMORY: Getting messages for turn range \(startTurn) to \(endTurn)")

        var result: [ChatMessage] = []
        var currentTurn = 0
        var currentTurnMessages: [ChatMessage] = []

        for message in messages {
            if message.isFromUser {
                if !currentTurnMessages.isEmpty && currentTurn >= startTurn && currentTurn <= endTurn {
                    result.append(contentsOf: currentTurnMessages)
                }
                currentTurn += 1
                currentTurnMessages = [message]
            } else {
                currentTurnMessages.append(message)
                if currentTurn >= startTurn && currentTurn <= endTurn {
                    result.append(contentsOf: currentTurnMessages)
                }
                currentTurnMessages = []
            }
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
    
    
// ==== LEGO START: 19 ChatViewModel (Phi‑3 MLX Integration) ====


    // MARK: - Phi‑3 Actions (guarded; Option B)

    // NEW: One‑tap upgrade — accept license, download if needed, auto‑activate on completion.
    func upgradeToPhi3OneTap() {
        // Accept license implicitly for the one‑tap path
        acceptPhi3License = true
        errorMessage = nil
        isShowingPhi3Sheet = true

        // Already installed → just activate
        if isPhi3Installed {
            selectedLLMType = .mlxPhi3   // didSet in Block 08 will call llmService.setupLLM(for:)
            print("HALDEBUG-PHI3: One‑tap → already installed; activated.")
            return
        }

        // Already downloading → surface progress, no duplicate work
        if mlxIsDownloading {
            print("HALDEBUG-PHI3: One‑tap → download in progress; showing progress.")
            return
        }

        // Fresh start: install a one‑shot observer and kick off download
        NotificationCenter.default.removeObserver(self, name: .mlxModelDidDownload, object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(onPhi3DownloadComplete(_:)),
                                               name: .mlxModelDidDownload,
                                               object: nil)
        print("HALDEBUG-PHI3: One‑tap → starting download…")
        MLXModelDownloader.shared.startDownload()
    }

    @objc private func onPhi3DownloadComplete(_ note: Notification) {
        errorMessage = nil
        selectedLLMType = .mlxPhi3   // didSet (Block 08) re‑routes LLMService
        isShowingPhi3Sheet = true
        NotificationCenter.default.removeObserver(self, name: .mlxModelDidDownload, object: nil)
        print("HALDEBUG-PHI3: Download complete → auto‑activated Phi‑3.")
    }

    /// Starts the MLX Phi‑3 download flow with guardrails.
    /// Requires the user to accept the license first. Provides friendly status messages.
    func beginPhi3Download() {
        // License gate
        guard acceptPhi3License else {
            self.errorMessage = "Please accept the Phi‑3 model license to proceed."
            self.isShowingPhi3Sheet = true
            return
        }

        // Already installed
        if isPhi3Installed {
            self.errorMessage = nil
            self.isShowingPhi3Sheet = true
            MLXModelDownloader.shared.downloadMessage = "MLX model already downloaded."
            MLXModelDownloader.shared.downloadProgress = 1.0
            return
        }

        // Already downloading
        if mlxIsDownloading {
            self.errorMessage = nil
            self.isShowingPhi3Sheet = true
            MLXModelDownloader.shared.downloadMessage = "Download already in progress…"
            return
        }

        // Kick off download
        self.errorMessage = nil
        self.isShowingPhi3Sheet = true
        MLXModelDownloader.shared.startDownload()
    }

    /// Cancels any in‑flight model download.
    func cancelPhi3Download() {
        MLXModelDownloader.shared.cancelDownload()
        self.isShowingPhi3Sheet = true
    }

    /// Deletes the downloaded model from disk and clears persisted path.
    func deletePhi3() {
        MLXModelDownloader.shared.deleteDownloadedModel()
        self.isShowingPhi3Sheet = true
    }

    /// Activates Phi‑3 for subsequent chats if the model is present; otherwise nudges the user to download first.
    func activatePhi3() {
        guard isPhi3Installed else {
            self.errorMessage = "Phi‑3 isn’t downloaded yet. Tap ‘Start Download’ first."
            self.isShowingPhi3Sheet = true
            return
        }
        self.errorMessage = nil
        self.selectedLLMType = .mlxPhi3
        print("HALDEBUG-PHI3: Activated Phi‑3 model via MLX")
    }
    
// ==== LEGO END: 19 ChatViewModel (Phi‑3 MLX Integration) ====
    

    
// ==== LEGO START: 20 ChatViewModel (Prompt History Builder) ====


            // MARK: - Context Window Management for Prompt Building
            /// This strategy prioritizes different types of context to fit within the LLM's context window,
            /// using intelligent summarization and RAG-like selection to avoid crude truncation.
            /// Priority Order (Highest to Lowest):
            /// 1. System Prompt (Non-negotiable, defines AI persona)
            /// 2. Injected Summary (Compressed long-term context of older turns)
            /// 3. Long-Term RAG Snippets (Semantically relevant facts from database, summarized if too long)
            /// 4. Short-Term Memory (Recent conversation history; RAG-selected if combined length exceeds threshold)
            /// 5. Current User Input (The immediate query, truncated only as a last resort)
            func buildPromptHistory(
                currentInput: String = "",
                forPreview: Bool = false,
                onStatusUpdate: ((String) -> Void)? = nil
            ) async -> String {
                print("HALDEBUG-MEMORY: Building prompt for input: '\(currentInput.prefix(50))....'")

                // Model-specific context limits
                let maxPromptCharacters: Int
                let maxRagSnippetsCharacters: Int
                let shortTermMemoryThreshold: Int
                let longTermSnippetSummarizationThreshold: Int
                
                switch selectedLLMType {
                case .foundationModels:
                    // Apple Foundation Models: Conservative limits due to smaller context window
                    maxPromptCharacters = 3500
                    maxRagSnippetsCharacters = 800
                    shortTermMemoryThreshold = 700
                    longTermSnippetSummarizationThreshold = 200
                    print("HALDEBUG-MEMORY: Using Apple FM limits - prompt: \(maxPromptCharacters), RAG: \(maxRagSnippetsCharacters)")
                case .mlxPhi3:
                    // Phi-3 128k: Generous limits due to large context window
                    maxPromptCharacters = 8000
                    maxRagSnippetsCharacters = 2000
                    shortTermMemoryThreshold = 1500
                    longTermSnippetSummarizationThreshold = 500
                    print("HALDEBUG-MEMORY: Using Phi-3 128k limits - prompt: \(maxPromptCharacters), RAG: \(maxRagSnippetsCharacters)")
                }

                var currentPrompt = systemPrompt
                print("HALDEBUG-MEMORY: Initial prompt length (system prompt): \(currentPrompt.count)")

                // Status Stage 1: Short-term memory processing begins
                await MainActor.run { onStatusUpdate?("Reviewing our recent conversation... (short-term memory)") }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 0.3 sec readability delay

                // 1. Add injected summary (highest priority for long-term context)
                if !injectedSummary.isEmpty {
                    let summarySection = "\n\n<SUMMARY>\nSummary of earlier conversation:\n\(injectedSummary)\n</SUMMARY>"
                    if currentPrompt.count + summarySection.count < maxPromptCharacters {
                        currentPrompt += summarySection
                        print("HALDEBUG-MEMORY: Added injected summary (\(injectedSummary.count) chars). Current prompt: \(currentPrompt.count)")
                    } else {
                        print("HALDEBUG-MEMORY: Skipped injected summary due to context window limit. Current prompt: \(currentPrompt.count)")
                    }
                }

                // Status Stage 2: Long-term memory (RAG) processing begins
                await MainActor.run { onStatusUpdate?("Recalling relevant memories... (long-term memory)") }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 0.3 sec readability delay

                // 2. Add long-term search results (RAG snippets)
                var longTermSearchText = ""
                var currentRagCharacters = 0 // Track total RAG characters
                if memoryStore.isEnabled && !currentInput.isEmpty && !forPreview {
                    print("HALDEBUG-MEMORY: Performing long-term search for RAG snippets.")
                    let shortTermTurns = getShortTermTurns(currentTurns: countCompletedTurns())

                    let searchContext = memoryStore.searchUnifiedContent(
                        for: currentInput,
                        currentConversationId: conversationId,
                        excludeTurns: shortTermTurns, // Exclude recent turns from long-term RAG to avoid redundancy
                        maxResults: 5 // Max results already limits the number of snippets
                    )

                    DispatchQueue.main.async {
                        self.currentUnifiedContext = searchContext
                        self.fullRAGContext = []

                        for (i, snippet) in searchContext.conversationSnippets.enumerated() {
                            let relevance = i < searchContext.relevanceScores.count ? searchContext.relevanceScores[i] : 0.0
                            self.fullRAGContext.append(
                                UnifiedSearchResult(content: snippet, relevance: relevance, source: ContentSourceType.conversation.rawValue, isEntityMatch: false)
                            )
                        }
                        for (i, snippet) in searchContext.documentSnippets.enumerated() {
                            let relevance = i < searchContext.relevanceScores.count ? searchContext.relevanceScores[i] : 0.0
                            self.fullRAGContext.append(
                                UnifiedSearchResult(content: snippet, relevance: relevance, source: ContentSourceType.document.rawValue, isEntityMatch: false)
                            )
                        }
                    }

                    if searchContext.hasContent {
                        var formattedSnippets: [String] = []
                        var combinedSnippetsWithRelevance: [(content: String, relevance: Double)] = []

                        // Combine conversation and document snippets with their corresponding relevance scores
                        var currentRelevanceIndex = 0
                        for snippet in searchContext.conversationSnippets {
                            if currentRelevanceIndex < searchContext.relevanceScores.count {
                                combinedSnippetsWithRelevance.append((content: snippet, relevance: searchContext.relevanceScores[currentRelevanceIndex]))
                                currentRelevanceIndex += 1
                            }
                        }
                        for snippet in searchContext.relevanceScores.indices { // Corrected iteration
                            if currentRelevanceIndex < searchContext.relevanceScores.count {
                                combinedSnippetsWithRelevance.append((content: searchContext.documentSnippets[snippet], relevance: searchContext.relevanceScores[currentRelevanceIndex]))
                                currentRelevanceIndex += 1
                            }
                        }

                        // Sort by relevance (descending)
                        let sortedCombinedSnippets = combinedSnippetsWithRelevance.sorted { $0.relevance > $1.relevance }

                        for snippetTuple in sortedCombinedSnippets {
                            var finalSnippet = snippetTuple.content
                            // Asynchronously summarize long snippets using LLM if they exceed threshold
                            if snippetTuple.content.count > longTermSnippetSummarizationThreshold {
                                do {
                                    let summarized = try await self.llmService.generateResponse(prompt: "Summarize the following text concisely:\n\(snippetTuple.content)")
                                    finalSnippet = summarized
                                    print("HALDEBUG-MEMORY: Summarized long-term snippet. Original: \(snippetTuple.content.count) -> Summarized: \(finalSnippet.count)")
                                } catch {
                                    print("HALDEBUG-MEMORY: Error summarizing long-term snippet: \(error.localizedDescription). Truncating instead.")
                                    finalSnippet = String(snippetTuple.content.prefix(longTermSnippetSummarizationThreshold)) + "..."
                                }
                            }

                            // Check if adding this snippet would exceed the overall prompt limit OR the RAG specific limit
                            if currentPrompt.count + longTermSearchText.count + finalSnippet.count + "\n".count < maxPromptCharacters &&
                               currentRagCharacters + finalSnippet.count < maxRagSnippetsCharacters { // NEW RAG CAP
                                formattedSnippets.append("- \(finalSnippet)")
                                currentRagCharacters += finalSnippet.count // Update RAG character count
                            } else {
                                print("HALDEBUG-MEMORY: Stopped adding long-term snippets due to context window limit or RAG character limit.")
                                break
                            }
                        }
                        if !formattedSnippets.isEmpty {
                            longTermSearchText = "<RAG_CONTEXT>\nContext snippets from memory:\n" + formattedSnippets.joined(separator: "\n") + "\n</RAG_CONTEXT>"
                            currentPrompt += "\n\n\(longTermSearchText)"
                            print("HALDEBUG-MEMORY: Added long-term search: \(formattedSnippets.count) snippets (\(longTermSearchText.count) chars). Current prompt: \(currentPrompt.count)")
                        }
                    }
                }

                // 3. Add short-term messages (recent conversation history)
                let shortTermTurns = getShortTermTurns(currentTurns: countCompletedTurns())
                let rawShortTermMessages = getShortTermMessages(turns: shortTermTurns)
                var shortTermText = ""

                let combinedShortTermContent = rawShortTermMessages.map { formatSingleMessage($0) }.joined(separator: "\n\n")

                // Apply RAG-like selection to short-term memory if it's too long
                if combinedShortTermContent.count > shortTermMemoryThreshold && !currentInput.isEmpty {
                    print("HALDEBUG-MEMORY: Short-term memory too long (\(combinedShortTermContent.count) chars), applying RAG-like selection.")
                    
                    // To perform a RAG-like search on `rawShortTermMessages`, we need to
                    // temporarily represent them as searchable content.
                    // A more robust solution might involve an in-memory search function,
                    // but for simplicity, we'll use the existing `searchUnifiedContent`
                    // and ensure it doesn't exclude the turns we're trying to search within.
                    let shortTermSearchContext = memoryStore.searchUnifiedContent(
                        for: currentInput,
                        currentConversationId: conversationId, // Still pass current conv ID
                        excludeTurns: [], // Do not exclude anything from this specific short-term search
                        maxResults: 3 // Get top 3 relevant snippets from short-term memory
                    )

                    if shortTermSearchContext.hasContent {
                        var selectedShortTermSnippets: [String] = []
                        for snippet in shortTermSearchContext.conversationSnippets {
                            var finalSnippet = snippet
                            // Optionally summarize individual short-term snippets if they are still very long
                            if snippet.count > longTermSnippetSummarizationThreshold { // Re-use threshold for consistency
                                do {
                                    let summarized = try await self.llmService.generateResponse(prompt: "Summarize the following text concisely:\n\(snippet)")
                                    finalSnippet = summarized
                                } catch {
                                    print("HALDEBUG-MEMORY: Error summarizing short-term snippet: \(error.localizedDescription). Truncating instead.")
                                    finalSnippet = String(snippet.prefix(longTermSnippetSummarizationThreshold)) + "..."
                                }
                            }
                            selectedShortTermSnippets.append(finalSnippet)
                        }
                        shortTermText = "<HISTORY>\nRecent conversation:\n" + selectedShortTermSnippets.joined(separator: "\n") + "\n</HISTORY>"
                        print("HALDEBUG-MEMORY: Added RAG-selected short-term memory (\(shortTermText.count) chars). Current prompt: \(currentPrompt.count)")
                    } else {
                        print("HALDEBUG-MEMORY: RAG-like selection for short-term memory found no relevant snippets. Falling back to truncated verbatim.")
                        // Fallback to simple truncation if RAG-like selection yields nothing
                        shortTermText = "<HISTORY>\nRecent conversation:\n" + String(combinedShortTermContent.prefix(shortTermMemoryThreshold)) + "...\n</HISTORY>"
                    }
                } else {
                    // If short-term memory is within threshold, add it verbatim
                    shortTermText = "<HISTORY>\nRecent conversation:\n" + combinedShortTermContent + "\n</HISTORY>"
                    print("HALDEBUG-MEMORY: Added short-term verbatim history (\(shortTermText.count) chars). Current prompt: \(currentPrompt.count)")
                }

                if !shortTermText.isEmpty {
                    if currentPrompt.count + shortTermText.count + "\n\n".count < maxPromptCharacters {
                        currentPrompt += "\n\n\(shortTermText.trimmingCharacters(in: .whitespacesAndNewlines))"
                    } else {
                        print("HALDEBUG-MEMORY: Skipped short-term memory due to context window limit after RAG/verbatim selection.")
                    }
                }


                // 4. Add the current user input (always included, potentially truncated as last resort)
                let finalUserInputPrefix = "\n\nUser: "
                let assistantSuffix = "\nAssistant:"
                let fixedSuffixLength = finalUserInputPrefix.count + assistantSuffix.count

                let remainingSpaceForInput = maxPromptCharacters - currentPrompt.count - fixedSuffixLength

                if remainingSpaceForInput > 0 {
                    let truncatedInput = String(currentInput.prefix(remainingSpaceForInput))
                    currentPrompt += finalUserInputPrefix + truncatedInput + assistantSuffix
                    print("HALDEBUG-MEMORY: Added user input (\(truncatedInput.count) chars). Final prompt: \(currentPrompt.count)")
                } else {
                    // Drastic truncation if very little space left, or just the user input itself is too long
                    let drasticTruncationLength = max(0, maxPromptCharacters - fixedSuffixLength)
                    let truncatedInput = String(currentInput.prefix(drasticTruncationLength))
                    currentPrompt = systemPrompt + finalUserInputPrefix + truncatedInput + assistantSuffix // Rebuild with just system prompt and truncated input
                    print("HALDEBUG-MEMORY: CRITICAL: Prompt severely truncated to fit user input. Final prompt: \(currentPrompt.count)")
                }

                print("HALDEBUG-MEMORY: Built prompt - \(currentPrompt.count) total characters")
                return currentPrompt
            }

            
// ==== LEGO END: 20 ChatViewModel (Prompt History Builder) ====


    
// ==== LEGO START: 21 ChatViewModel (Send Message Flow) ====

                    @Published var showInlineDetails: Bool = false

                    func sendMessage() async {
                        let trimmed = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        isAIResponding = true; thinkingStart = Date(); isSendingMessage = true
                        print("HALDEBUG-MODEL: Starting message send - '\(trimmed.prefix(50))....'")
                        messages.append(ChatMessage(content: trimmed, isFromUser: true))
                        currentMessage = ""
                        #if os(iOS)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        #endif
                        let placeholder = ChatMessage(content: "\u{00A0}", isFromUser: false, isPartial: true)
                        messages.append(placeholder)
                        isAIResponding = true
                        thinkingStart = Date()

                        await MainActor.run { self.objectWillChange.send() }
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await Task.yield()
                        guard let pid = messages.last?.id else { isAIResponding = false; isSendingMessage = false; return }
                        var finalText = ""; var usedCtx: [UnifiedSearchResult]? = nil; var modelTime: TimeInterval = 0

                        do {
                            // Status Stage 0: Message received
                            if let i = messages.firstIndex(where: { $0.id == pid }) {
                                var m = messages[i]
                                m.content = "Reading your message..."
                                messages[i] = m
                                NotificationCenter.default.post(name: .didUpdateMessageContent, object: nil)
                            }
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 0.3 sec readability delay

                            // Build prompt with status callbacks (stages 1 & 2 handled inside)
                            let prompt = await buildPromptHistory(currentInput: trimmed) { status in
                                if let i = self.messages.firstIndex(where: { $0.id == pid }) {
                                    var m = self.messages[i]
                                    m.content = status
                                    self.messages[i] = m
                                    NotificationCenter.default.post(name: .didUpdateMessageContent, object: nil)
                                }
                            }

                            // Status Stage 3: LLM inference
                            if let i = messages.firstIndex(where: { $0.id == pid }) {
                                var m = messages[i]
                                m.content = "Formulating a reply..."
                                messages[i] = m
                                NotificationCenter.default.post(name: .didUpdateMessageContent, object: nil)
                            }
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 0.3 sec readability delay

                            print("HALDEBUG-MODEL: Sending prompt to language model (\(prompt.count) chars)")
                            let t0 = Date()
                            finalText = try await llmService.generateResponse(prompt: prompt)
                            modelTime = Date().timeIntervalSince(t0)
                            print("HALDEBUG-LLM: ✅ Non-streaming generation complete. Length: \(finalText.count)")

                            usedCtx = fullRAGContext.isEmpty ? nil : fullRAGContext
                            if let ctx = usedCtx {
                                print("HALDEBUG-RAG: Stored \(ctx.count) items → scores: \(ctx.map{$0.relevance})")
                            }

                            let text = removeRepetitivePatterns(from: finalText).trimmingCharacters(in: .whitespacesAndNewlines)

                            // Status Stage 4: Fake streaming (existing code)
                            let cps: Double = 20.0
                            var idx = text.startIndex, acc = ""
                            while idx < text.endIndex {
                                let rem = text[idx...]
                                let n = min(max(4, Int.random(in: 6...18)), rem.count)
                                let next = text.index(idx, offsetBy: n, limitedBy: text.endIndex) ?? text.endIndex
                                let chunk = String(text[idx..<next]); idx = next; acc += chunk

                                if let i = messages.firstIndex(where: { $0.id == pid }) {
                                    var m = messages[i]
                                    m.content = acc
                                    messages[i] = m
                                    NotificationCenter.default.post(name: .didUpdateMessageContent, object: nil)
                                }

                                let base = max(0.03, Double(chunk.count)/cps)
                                try await Task.sleep(nanoseconds: UInt64(base * 1_000_000_000))
                                if let last = chunk.last, ".!?\n".contains(last) {
                                    try await Task.sleep(nanoseconds: 220_000_000)
                                }
                            }

                            let thinking = modelTime

                            await MainActor.run {
                                self.isAIResponding = false
                                self.thinkingStart = nil
                                self.isSendingMessage = false
                                if let i = self.messages.firstIndex(where: { $0.id == pid }) {
                                    var m = self.messages[i]
                                    m.content = text
                                    m.isPartial = false
                                    m.thinkingDuration = thinking
                                    m.fullPromptUsed = prompt
                                    m.usedContextSnippets = usedCtx
                                    self.messages[i] = m
                                }

                                if self.pendingAutoInject {
                                    self.pendingAutoInject = false
                                    print("HALDEBUG-MEMORY: Cleared pending auto-inject flag after successful response")
                                }

                                let turn = self.countCompletedTurns()
                                print("HALDEBUG-MEMORY: About to store turn \(turn) in database")
                                self.memoryStore.storeTurn(
                                    conversationId: self.conversationId,
                                    userMessage: trimmed,
                                    assistantMessage: text,
                                    systemPrompt: self.systemPrompt,
                                    turnNumber: turn,
                                    halFullPrompt: prompt,
                                    halUsedContext: usedCtx,
                                    thinkingDuration: thinking
                                )

                                // Trigger auto-summarization if conditions are met
                                if self.shouldTriggerAutoSummarization() {
                                    Task { await self.generateAutoSummary() }
                                }

                                let verify = self.memoryStore.getConversationMessages(conversationId: self.conversationId)
                                print("HALDEBUG-MEMORY: VERIFY - After storing turn \(turn), database has \(verify.count) messages")
                                self.updateHistoricalStats()
                            }

                        } catch {
                            DispatchQueue.main.async {
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

// ==== LEGO END: 21 ChatViewModel (Send Message Flow) ====
    
    
// ==== LEGO START: 22 ChatViewModel (Short-Term Memory Helpers) ====
    private func getShortTermTurns(currentTurns: Int) -> [Int] {
        if lastSummarizedTurnCount == 0 {
            let startTurn = max(1, currentTurns - memoryDepth + 1)
            guard startTurn <= currentTurns else { return [] }
            return Array(startTurn...currentTurns)
        } else {
            let turnsSinceLastSummary = currentTurns - lastSummarizedTurnCount
            let turnsToInclude = min(turnsSinceLastSummary, memoryDepth)

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
                currentTurnMessages.append(message)
                if turns.contains(currentTurn) {
                    result.append(contentsOf: currentTurnMessages)
                }
                currentTurnMessages = []
            }
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
        UserDefaults.standard.set(self.conversationId, forKey: "lastConversationId") // Save new ID immediately

        currentUnifiedContext = UnifiedSearchContext(
            conversationSnippets: [],
            documentSnippets: [],
            relevanceScores: [],
            totalTokens: 0
        )
        
        print("HALDEBUG-MEMORY: Cleared all messages and generated new conversation ID: \(conversationId)")
    }

    // Reset all data (nuke database)
    func resetAllData() {
        print("HALDEBUG-UI: User requested nuclear database reset")
        let success = memoryStore.performNuclearReset()
        if success {
            print("HALDEBUG-UI: ✅ Nuclear reset completed successfully")
            startNewConversation() // Start a fresh conversation after nuking
        } else {
            print("HALDEBUG-UI: ❌ Nuclear reset encountered issues")
        }
        print("HALDEBUG-UI: Nuclear reset process complete")
    }
}
// ==== LEGO END: 24 ChatViewModel (Conversation & Database Reset) ====



// ==== LEGO START: 25 ChatVM — Export Chat History ====
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
                : "—"
            
            exportContent += "──────────────────────────────────────────────\n"
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

        exportContent += "──────────────────────────────────────────────\n"
        print("HALDEBUG-EXPORT: Generated detailed chat export (\(exportContent.count) characters)")
        return exportContent
    }
}
// ==== LEGO END: 25 ChatVM — Export Chat History ====



// ==== LEGO START: 26 DocumentPicker (UIKit Bridge) ====
// MARK: - DocumentPicker (iOS-Specific Document Picker)
struct DocumentPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var documentImportManager: DocumentImportManager
    @EnvironmentObject var chatViewModel: ChatViewModel

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Expanded supported types for consistency with Mac version's capabilities
        let supportedTypes: [UTType] = [
            .pdf, .plainText, .json, .data, .rtf, .html,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "pptx") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "md") ?? .text,
            UTType(filenameExtension: "epub") ?? .data,
            UTType(filenameExtension: "csv") ?? .data,
            UTType(filenameExtension: "xml") ?? .data
        ].compactMap { $0 } // Filter out any nil UTTypes

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
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
    private let llmService = LLMService(llmType: .foundationModels) // Initialize with default Foundation Models

    private let supportedFormats: [String: String] = [
        "txt": "Plain Text", "md": "Markdown", "rtf": "Rich Text Format", "pdf": "PDF Document",
        "docx": "Microsoft Word", "doc": "Microsoft Word (Legacy)", "xlsx": "Microsoft Excel",
        "xls": "Microsoft Excel (Legacy)", "pptx": "Microsoft PowerPoint", "ppt": "Microsoft PowerPoint (Legacy)",
        "csv": "Comma Separated Values", "json": "JSON Data", "xml": "XML Document",
        "html": "HTML Document", "htm": "HTML Document", "epub": "EPUB eBook"
    ]

    private init() {} // Private initializer for singleton

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
            if let summary = await generateDocumentSummary(processed) {
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
        guard supportedFormats.keys.contains(fileExtension) else {
            print("HALDEBUG-IMPORT: Unsupported format: \(fileExtension)")
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
                        self.importProgress = "⚠️ File too large: \(url.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB). Maximum size is 25 MB."
                    }
                    print("HALDEBUG-IMPORT: ❌ Rejected file exceeding 25MB limit: \(url.lastPathComponent)")
                    return nil
                }
                
                // Warning threshold: 15MB
                if fileSizeMB > 15.0 {
                    await MainActor.run {
                        self.importProgress = "⏳ Processing large file: \(url.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB). This may take 1-2 minutes..."
                    }
                    print("HALDEBUG-IMPORT: ⚠️ Large file warning: \(url.lastPathComponent) - \(String(format: "%.1f", fileSizeMB)) MB")
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
        case unsupportedFileFormat(String)
        case fileTooLarge(String, Double) // NEW: filename, size in MB

        // Added nonisolated to errorDescription to satisfy LocalizedError protocol
        nonisolated var errorDescription: String? {
            switch self {
            case .pdfExtractionFailed(let filename):
                return "Failed to extract content from PDF: \(filename)"
            case .unsupportedFileFormat(let filename):
                return "Unsupported file format for direct content extraction: \(filename)"
            case .fileTooLarge(let filename, let sizeMB):
                return "File too large: \(filename) (\(String(format: "%.1f", sizeMB)) MB). Maximum size is 25 MB."
            }
        }
    }

    // Content Extraction (from Hal10000App.swift)
    private func extractContent(from url: URL, fileExtension: String) throws -> String {
        print("HALDEBUG-IMPORT: Extracting content from \(url.lastPathComponent) (.\(fileExtension))")

        switch fileExtension.lowercased() {
        case "txt", "md":
            let content = try String(contentsOf: url, encoding: .utf8)
            print("HALDEBUG-IMPORT: Extracted \(content.count) chars from text file")
            return content
        case "pdf":
            if let content = extractPDFContent(from: url) {
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars from PDF")
                return content
            } else {
                throw DocumentProcessingError.pdfExtractionFailed(url.lastPathComponent)
            }
        default:
            let content = try String(contentsOf: url, encoding: .utf8)
            return content
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

        if sentences.isEmpty {
            print("HALDEBUG-CHUNKING: Sentence tokenization failed, falling back to paragraphs")
            sentences = cleanedContent.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if sentences.isEmpty {
            print("HALDEBUG-CHUNKING: Paragraph splitting failed, falling back to word-based chunking")
            return createWordBasedChunks(from: cleanedContent, targetSize: targetSize, overlap: overlap)
        }

        var chunks: [String] = []
        var currentChunk = ""
        var sentenceIndex = 0

        while sentenceIndex < sentences.count {
            let sentence = sentences[sentenceIndex]
            let wouldExceedTarget = !currentChunk.isEmpty && (currentChunk.count + sentence.count + 1) > targetSize

            if wouldExceedTarget {
                let trimmedChunk = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedChunk.isEmpty {
                    chunks.append(trimmedChunk)
                }
                currentChunk = createOverlapText(from: currentChunk, maxLength: overlap)
                if !currentChunk.isEmpty {
                    currentChunk += " "
                }
            }
            if !currentChunk.isEmpty {
                currentChunk += " "
            }
            currentChunk += sentence
            sentenceIndex += 1
        }
        let finalChunk = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalChunk.isEmpty {
            chunks.append(finalChunk)
        }
        print("HALDEBUG-CHUNKING: Created \(chunks.count) chunks using MENTAT strategy")
        return chunks
    }

    private func createOverlapText(from text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let startIndex = text.index(text.endIndex, offsetBy: -maxLength, limitedBy: text.startIndex) ?? text.startIndex
        var overlapText = String(text[startIndex...])
        if let spaceIndex = overlapText.firstIndex(of: " ") {
            overlapText = String(overlapText[spaceIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
    private func generateDocumentSummary(_ document: ProcessedDocument) async -> String? {
        print("HALDEBUG-IMPORT: Generating LLM summary for: \(document.filename) with \(document.entities.count) entities")

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
                    metadataJson: metadataJsonString // NEW: Pass metadata with filePath
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

        let userChatMessage = ChatMessage(content: userMessageContent, isFromUser: true)
        chatViewModel.messages.append(userChatMessage)

        // --- MODIFIED HAL RESPONSE TO BE MORE CONCISE AND LESS REPETITIVE ---
        let halResponse: String
        if documentSummaries.count == 1 {
            halResponse = "Understood! I've processed the document you shared. I'm ready for your questions."
        } else {
            halResponse = "Got it! I've processed those \(documentSummaries.count) documents. What would you like to discuss about them?"
        }
        // --- END MODIFIED HAL RESPONSE ---

        let halChatMessage = ChatMessage(content: halResponse, isFromUser: false)
        chatViewModel.messages.append(halChatMessage)

        let currentTurnNumber = chatViewModel.messages.filter { $0.isFromUser }.count
        chatViewModel.memoryStore.storeTurn(
            conversationId: chatViewModel.conversationId,
            userMessage: userMessageContent,
            assistantMessage: halResponse,
            systemPrompt: chatViewModel.systemPrompt,
            turnNumber: currentTurnNumber,
            halFullPrompt: nil, // No specific prompt for import messages
            halUsedContext: nil, // No specific context for import messages
            thinkingDuration: nil
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



// ==== LEGO START: 29 MLX Model Downloader (Singleton) ====
// MARK: - MLXModelDownloader – Hugging Face (MLXLLM loader, Wi-Fi only)
#if canImport(MLX)
import MLX
#endif
#if canImport(MLXLLM)
import MLXLLM
#endif
import SwiftUI
import Foundation

final class MLXModelDownloader: ObservableObject {
    static let shared = MLXModelDownloader()

    // UI state (bound elsewhere in the app)
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0         // 0.0 → 1.0
    @Published var downloadMessage: String = ""
    @Published var downloadError: String?

    // NEW: Partial download state tracking
    @Published var hasPartialDownload: Bool = false
    @Published var partialDownloadProgress: Double = 0.0
    @Published var partialDownloadSize: String = ""
    
    // NEW: Cache management
    @Published var hubCacheSize: String = "Calculating..."
    @Published var isCacheCalculating: Bool = false

    // Presence of this folder == "installed"
    @Published var downloadedModelURL: URL?
    @AppStorage("downloadedMLXModelURL") private var downloadedPath: String? {
        didSet {
            // FIXED: Always update downloadedModelURL when path changes
            if let path = downloadedPath {
                let url = URL(fileURLWithPath: path)
                // Verify file actually exists before setting
                if FileManager.default.fileExists(atPath: url.path) {
                    downloadedModelURL = url
                    print("HALDEBUG-DETECTION: ✅ Verified and set downloadedModelURL: \(url.path)")
                } else {
                    downloadedModelURL = nil
                    // Clear invalid path from storage
                    downloadedPath = nil
                    print("HALDEBUG-DETECTION: ❌ Invalid path cleared: \(path)")
                }
            } else {
                downloadedModelURL = nil
                print("HALDEBUG-DETECTION: Cleared downloadedModelURL")
            }
        }
    }
    
    // NEW: Partial download persistence
    @AppStorage("partialMLXDownloadProgress") private var savedPartialProgress: Double = 0.0
    @AppStorage("partialMLXDownloadSize") private var savedPartialSize: String = ""
    @AppStorage("hasPartialMLXDownload") private var savedHasPartial: Bool = false

    // Config – repo ID on Hugging Face
    // Default: Phi-3 Mini 128k Instruct 4-bit (MLX-ready)
    private let huggingFaceRepo = "mlx-community/Phi-3-mini-128k-instruct-4bit"

    // Networking policy
    private let wifiOnly = true

    // In-flight task (so we can cancel from UI)
    private var loaderTask: Task<Void, Never>?

    // Where we keep models on disk (container folder)
    private var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MLXModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    // NEW: Hub cache directory location
    private var hubCacheDirectory: URL {
        URL.cachesDirectory.appending(path: "huggingface")
    }

    private init() {
        print("HALDEBUG-DETECTION: MLXModelDownloader.init() starting...")
        print("HALDEBUG-DETECTION: Initial downloadedPath from @AppStorage: \(downloadedPath ?? "nil")")
        
        // FIXED: Explicit file existence check with proper initialization order
        if let p = downloadedPath {
            let url = URL(fileURLWithPath: p)
            print("HALDEBUG-DETECTION: Checking if saved path exists: \(p)")
            if FileManager.default.fileExists(atPath: url.path) {
                // FIXED: Set both properties explicitly to ensure consistency
                downloadedModelURL = url
                downloadProgress = 1.0
                downloadMessage = "Model ready."
                print("HALDEBUG-DETECTION: ✅ Model found and restored: \(url.path)")
            } else {
                // FIXED: Clear invalid stored path immediately
                downloadedPath = nil
                downloadedModelURL = nil
                downloadProgress = 0.0
                downloadMessage = ""
                print("HALDEBUG-DETECTION: ❌ Saved path invalid, cleared: \(p)")
            }
        } else {
            // FIXED: Ensure clean state when no path stored
            downloadedModelURL = nil
            downloadProgress = 0.0
            downloadMessage = ""
            print("HALDEBUG-DETECTION: No saved path found - clean state")
        }
        
        // NEW: Restore partial download state
        loadPartialDownloadState()
        
        // NEW: Calculate initial cache size
        Task {
            await updateCacheSize()
        }
        
        print("HALDEBUG-DETECTION: MLXModelDownloader.init() complete - downloadedModelURL: \(downloadedModelURL?.path ?? "nil")")
    }

    // MARK: - Public API

    func startDownload() {
        guard !isDownloading else {
            downloadMessage = "Download in progress…"
            return
        }

        #if !canImport(MLXLLM)
        self.downloadError = "MLXLLM not available. Add the MLX packages to the project."
        self.downloadMessage = "Loader unavailable."
        return
        #else
        // The previous manual check has been removed.
        // The HubApi.snapshot() call below will now handle the existence check
        // for us automatically and much more reliably.

        // Kick off the async job
        loaderTask = Task {
            await MainActor.run {
                self.isDownloading = true
                // NEW: Start from partial progress if available
                self.downloadProgress = self.hasPartialDownload ? self.partialDownloadProgress : 0.0
                self.downloadMessage = self.hasPartialDownload ? "Resuming download…" : "Preparing download…"
                self.downloadError = nil
            }

            do {
                // Optional: honor Wi-Fi preference (informational in this stub)
                let allowsExpensive = !wifiOnly
                let allowsConstrained = !wifiOnly
                _ = (allowsExpensive, allowsConstrained)

                // Pull (or verify) the snapshot locally.
                // This is the core logic. It will download the files only if they
                // aren't already in the Hugging Face cache.
                let hub = HubApi.default
                let snapshot = try await hub.snapshot(from: huggingFaceRepo, progressHandler: { progress in
                    guard progress.totalUnitCount > 0 else { return }
                    let p = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                    Task { @MainActor in
                        self.downloadProgress = p
                        self.downloadMessage = "Downloading… \(Int(p * 100))%"

                        // Save partial progress as we go
                        self.savePartialDownloadState(progress: p, size: self.formatBytes(Int64(progress.completedUnitCount)))
                    }
                })

                // Local folder for the model files (tokenizer.json, config.json, weights, etc.)
                let localURL: URL = snapshot

                // The rest of the logic for moving the files and updating state remains the same
                let finalURL: URL
                if localURL.path.hasPrefix(modelsDir.path) {
                    finalURL = localURL
                } else {
                    let dest = modelsDir.appendingPathComponent(localURL.lastPathComponent, isDirectory: true)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: localURL, to: dest)
                    finalURL = dest
                }

                await MainActor.run {
                    print("HALDEBUG-DETECTION: Download complete - setting downloadedModelURL to: \(finalURL.path)")
                    // FIXED: Set both properties in correct order
                    self.downloadedPath = finalURL.path
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.downloadMessage = "Model ready."

                    // NEW: Clear partial download state on success
                    self.clearPartialDownloadState()

                    // Update cache size after successful download
                    Task {
                        await self.updateCacheSize()
                    }

                    NotificationCenter.default.post(name: .mlxModelDidDownload, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadError = "Cancelled"
                    self.downloadMessage = self.hasPartialDownload ?
                        "Download paused at \(Int(self.downloadProgress * 100))% (\(self.partialDownloadSize))" :
                        "Download cancelled."
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadError = error.localizedDescription
                    self.downloadMessage = "Download failed."
                    self.downloadProgress = 0.0

                    // NEW: Clear partial state on error
                    self.clearPartialDownloadState()
                }
            }
        }
        #endif
    }

    func cancelDownload() {
        guard isDownloading else { return }
        loaderTask?.cancel()
        loaderTask = nil
        isDownloading = false
        // NEW: Don't reset progress to 0 - keep the partial progress
        downloadMessage = hasPartialDownload ?
            "Download paused at \(Int(downloadProgress * 100))% (\(partialDownloadSize))" :
            "Download cancelled."
        downloadError = "Cancelled"
    }
    
    // NEW: Resume download (alias for startDownload with better messaging)
    func resumeDownload() {
        startDownload()
    }
    
    // NEW: Clear partial download and reset progress
    func clearPartialDownload() {
        clearPartialDownloadState()
        downloadProgress = 0.0
        downloadMessage = "Partial download cleared."
        
        // Update cache size after clearing partial files
        Task {
            await updateCacheSize()
        }
    }

    func deleteDownloadedModel() {
        guard let url = downloadedModelURL else {
            downloadMessage = "No model to delete."
            return
        }
        // FIXED: Remove unnecessary do-catch since FileManager.removeItem is not throwing in this context
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                print("HALDEBUG-DETECTION: Model deleted from: \(url.path)")
                // FIXED: Clear in correct order - path first (triggers didSet), then state
                downloadedPath = nil  // This triggers didSet which clears downloadedModelURL
                downloadProgress = 0.0
                downloadMessage = "Model deleted."
                downloadError = nil
                
                // NEW: Also clear any partial download state
                clearPartialDownloadState()
                
                // Update cache size after deletion
                Task {
                    await updateCacheSize()
                }
            } catch {
                downloadError = "Delete failed: \(error.localizedDescription)"
                downloadMessage = "Delete failed."
            }
        } else {
            // FIXED: Clear state even if file doesn't exist
            downloadedPath = nil
            downloadProgress = 0.0
            downloadMessage = "Model was already deleted."
        }
    }
    
    // MARK: - NEW: Cache Management
    
    /// Calculate the size of the Hugging Face cache directory
    @MainActor
    func updateCacheSize() async {
        isCacheCalculating = true
        
        let size = await calculateDirectorySize(hubCacheDirectory)
        
        hubCacheSize = size > 0 ? formatBytes(Int64(size)) : "No cache"
        isCacheCalculating = false
    }
    
    /// Clear the entire Hugging Face cache
    func clearHubCache() {
        if FileManager.default.fileExists(atPath: hubCacheDirectory.path) {
            do {
                try FileManager.default.removeItem(at: hubCacheDirectory)
                hubCacheSize = "No cache"
                downloadMessage = "Cache cleared successfully."
                
                // Clear partial download state since cache is gone
                clearPartialDownloadState()
                
                print("HALDEBUG-CACHE: Successfully cleared Hugging Face cache at \(hubCacheDirectory.path)")
            } catch {
                downloadError = "Failed to clear cache: \(error.localizedDescription)"
                downloadMessage = "Cache clear failed."
                print("HALDEBUG-CACHE: Failed to clear cache: \(error.localizedDescription)")
            }
        } else {
            hubCacheSize = "No cache"
            downloadMessage = "No cache to clear."
            print("HALDEBUG-CACHE: No cache directory found to clear")
        }
    }
    
    // MARK: - NEW: Partial Download State Management
    
    private func savePartialDownloadState(progress: Double, size: String) {
        savedPartialProgress = progress
        savedPartialSize = size
        savedHasPartial = progress > 0.0 && progress < 1.0
        
        partialDownloadProgress = progress
        partialDownloadSize = size
        hasPartialDownload = savedHasPartial
        
        print("HALDEBUG-PARTIAL: Saved state - progress: \(Int(progress * 100))%, size: \(size)")
    }
    
    private func loadPartialDownloadState() {
        partialDownloadProgress = savedPartialProgress
        partialDownloadSize = savedPartialSize
        hasPartialDownload = savedHasPartial
        
        // Set current download progress to partial progress if we have one
        if hasPartialDownload {
            downloadProgress = partialDownloadProgress
            downloadMessage = "Download paused at \(Int(partialDownloadProgress * 100))% (\(partialDownloadSize))"
        }
        
        print("HALDEBUG-PARTIAL: Loaded state - hasPartial: \(hasPartialDownload), progress: \(Int(partialDownloadProgress * 100))%")
    }
    
    private func clearPartialDownloadState() {
        savedPartialProgress = 0.0
        savedPartialSize = ""
        savedHasPartial = false
        
        partialDownloadProgress = 0.0
        partialDownloadSize = ""
        hasPartialDownload = false
        
        print("HALDEBUG-PARTIAL: Cleared partial download state")
    }
    
    // MARK: - NEW: Utility Methods
    
    /// Calculate directory size asynchronously using efficient FileManager enumeration
    private func calculateDirectorySize(_ directory: URL) async -> UInt64 {
        return await withCheckedContinuation { continuation in
            Task.detached {
                var totalSize: UInt64 = 0
                
                guard FileManager.default.fileExists(atPath: directory.path) else {
                    continuation.resume(returning: 0)
                    return
                }
                
                let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }
                
                while let fileURL = enumerator.nextObject() as? URL {
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        
                        // Only count files, not directories
                        if let isDirectory = resourceValues.isDirectory, !isDirectory {
                            if let fileSize = resourceValues.totalFileAllocatedSize {
                                totalSize += UInt64(fileSize)
                            }
                        }
                    } catch {
                        // Skip files we can't read
                        continue
                    }
                }
                
                continuation.resume(returning: totalSize)
            }
        }
    }
    
    /// Format bytes into human-readable string (e.g., "1.2 GB")
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Notification
extension Notification.Name {
    static let mlxModelDidDownload = Notification.Name("mlxModelDidDownload")
}
// ==== LEGO END: 29 MLX Model Downloader (Singleton) ====
