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
import MLX // Import MLX framework (conceptual, requires actual framework link)
import MLXLLM
// REMOVED 2026-05-20: import MLXEmbedders — EmbeddingGemma backend removed
//                     in v2.0.1 hotfix. See EmbeddingBackend.swift header.
import Hub
import HuggingFace // For #hubDownloader macro (HubClient type)
import MLXLMCommon // FIXED: Added missing import for proper MLX API access
import MLXHuggingFace // mlx-swift-lm 3.x: provides #huggingFaceTokenizerLoader macro
import Tokenizers // FIXED: Added missing import for tokenizer decode method
import Network  // LocalAPIServer (NWListener)
import Security // LocalAPIServer (Keychain token storage)

// MARK: - Hub Extension for MLX Model Downloads
extension HubApi {
    /// Default HubApi instance pointed at the App-Group shared model store
    /// (`<AppGroup>/Models/huggingface`), so MLX loads models from the same
    /// shared copy Posey downloads to. Was `Caches/huggingface` before the v2.1
    /// cross-app sharing change — see SharedModelStore.swift.
    static let `default` = HubApi(
        downloadBase: SharedModelStore.huggingFaceRoot
    )
}

// Add @preconcurrency import for Foundation to help with Swift 6 concurrency warnings
@preconcurrency import Foundation

// MARK: - RuntimeLog (in-process log buffer queryable via API)
//
// Hal runs on a remote iPhone with no easy console-log access. To debug MLX
// behaviour (TTFT, token rates, generation stopping early, etc.) we need to
// see HALDEBUG-* lines without standing over the device. RuntimeLog captures
// log entries into a thread-safe ring buffer that the LocalAPIServer exposes
// via GET_LOGS, so any remote caller (CC, hal_test.py) can read recent
// debug output the same way they'd read state.
//
// halLog(...) is a top-level convenience that captures AND prints — drop-in
// replacement for `print(...)` for any line you want queryable later.
// All members explicitly nonisolated so RuntimeLog is callable from any
// thread (URLSession delegate, MLX background, actor contexts). Internal
// state is protected by NSLock — the @unchecked Sendable conformance is
// honored by manual locking inside each mutator. Without the nonisolated
// annotations, project-level SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// would force the class onto the main actor and break every off-main
// halLog call site.
final class RuntimeLog: @unchecked Sendable {
    nonisolated static let shared = RuntimeLog()
    private let lock = NSLock()
    // nonisolated(unsafe) because `lines` is mutated from non-main threads
    // (URLSession delegate, MLX background) but always under `lock`. The
    // unsafe annotation tells Swift "I have manual synchronization, trust me."
    nonisolated(unsafe) private var lines: [String] = []
    private let capacity: Int = 1000
    private let formatter: DateFormatter

    init() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        self.formatter = f
    }

    nonisolated func log(_ message: String) {
        let ts = formatter.string(from: Date())
        let entry = "[\(ts)] \(message)"
        lock.lock()
        lines.append(entry)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
        print(entry)
    }

    nonisolated func snapshot(limit: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let n = max(0, min(limit, lines.count))
        return Array(lines.suffix(n))
    }

    nonisolated func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// Captures `message` into the runtime log buffer AND prints to stdout.
/// Use anywhere a `print` would go but you want the line queryable via the
/// API later. Thread-safe (RuntimeLog uses internal NSLock).
///
/// Explicitly `nonisolated` so it's callable from any context — including
/// URLSession delegate callbacks, MLX background work, and SegmentCompressor.
/// Without this, the project-level SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
/// makes top-level free functions implicitly @MainActor, which breaks every
/// caller that runs off the main actor.
nonisolated func halLog(_ message: String) {
    RuntimeLog.shared.log(message)
}

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
    
    // All four derived properties are marked `nonisolated` so the
    // nonisolated `buildPromptDetailExportText` (PromptDetailView.swift)
    // can compute the budget summary without a @MainActor hop. Each
    // returns a value derived from `let` stored properties; thread-
    // safety follows from the struct being a pure value type. Same
    // pattern as `exportTag` on PromptDetailSegmentKind.
    nonisolated var totalPromptTokens: Int {
        return systemTokens + summaryTokens + ragTokens + shortTermTokens + userInputTokens
    }

    nonisolated var totalTokens: Int {
        return totalPromptTokens + completionTokens
    }

    nonisolated var contextWindowSize: Int {
        return contextWindow
    }

    nonisolated var percentageUsed: Double {
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

    /// Which prompt segments were intelligently compressed (via TextSummarizer
    /// + veracity check) during this turn's prompt assembly. Drives the
    /// "condensed" badge in the bubble footer (Phase 6b). Non-empty when at
    /// least one dynamic segment exceeded its budget and was compressed by
    /// the active model. Empty by default.
    var compressedSegments: Set<PromptSegmentKind>

    /// Which prompt segments fell back to raw truncation during this turn —
    /// catastrophic-only failure modes for compression (LLM call returned
    /// empty, output overshot target by >20%, veracity rejected too much).
    /// Drives the visually-distinct "truncated" badge in the bubble footer.
    /// Should be rare in normal use.
    var truncatedSegments: Set<PromptSegmentKind>

    init(id: UUID = UUID(), content: String, isFromUser: Bool, timestamp: Date = Date(), isPartial: Bool = false, thinkingDuration: TimeInterval? = nil, fullPromptUsed: String? = nil, usedContextSnippets: [UnifiedSearchResult]? = nil, tokenBreakdown: TokenBreakdown? = nil, toolsUsed: [String]? = nil, recordedByModel: String, turnNumber: Int, seatNumber: Int? = nil, deliberationRound: Int = 1, compressedSegments: Set<PromptSegmentKind> = [], truncatedSegments: Set<PromptSegmentKind> = []) {
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
        self.compressedSegments = compressedSegments
        self.truncatedSegments = truncatedSegments
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

    // Recency boosting parameters for time-aware RAG
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

    // RRF fusion weights for time-aware RAG. These are the k constants in the
    // Reciprocal Rank Fusion that blends semantic + BM25 retrieval in
    // searchUnifiedContent: a retriever's rank-r hit contributes 1/(k + r), so
    // a SMALLER k means that retriever's top hits dominate the fused order.
    // They live here (global, not per-model) because they describe retrieval
    // behavior, not a model's personality.
    //
    // Defaults 15 / 10 / 60 encode a deliberate evidence ordering:
    //   distinctive keyword (10)  >  semantic (15)  >  generic keyword (60)
    // i.e. a rare exact term beats meaning beats generic word-overlap. This was
    // set by the 2026-07-10 global RRF sweep (tests/rrf_global_sweep.py +
    // rrf_deep_sweep.py): the original semantic k=60 was ~5.5× weaker than a
    // distinctive BM25 hit, so keyword matching dominated and the embedder only
    // broke ties (full-pipeline recall was ~identical across all three backends).
    // Lowering semantic to 15 lifted mean MRR ~+17% on a 59-memory/46-query eval
    // and made the embedders actually diverge, while keeping distinctive keyword
    // 1.5× stronger than semantic so imported-document lookups (Bug 2a) keep a
    // safety margin. k=10 is the boundary where semantic would equal distinctive
    // keyword; below it Bug 2a re-opens, so 15 keeps a cushion above it.
    @AppStorage("rrfKSemantic") var rrfKSemantic: Double = 15.0 {
        didSet {
            print("HALDEBUG-RRF: Semantic k updated to \(rrfKSemantic)")
        }
    }
    @AppStorage("rrfKBM25Distinctive") var rrfKBM25Distinctive: Double = 10.0 {
        didSet {
            print("HALDEBUG-RRF: BM25 distinctive k updated to \(rrfKBM25Distinctive)")
        }
    }
    @AppStorage("rrfKBM25Default") var rrfKBM25Default: Double = 60.0 {
        didSet {
            print("HALDEBUG-RRF: BM25 default k updated to \(rrfKBM25Default)")
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

    // Persistent database connection.
    //
    // `db` is `nonisolated(unsafe)` because SQLite's underlying mutex (iOS
    // builds with SQLITE_THREADSAFE=1 / serialized mode) handles concurrent
    // access correctly, and the OpaquePointer itself is conceptually
    // immutable post-setupPersistentDatabase. The unsafe annotation tells
    // Swift "I have manual synchronization (SQLite's own), trust me." This
    // is what allows the Phase 5 compression cache methods on this class
    // to be `nonisolated` and callable from SegmentCompressor's actor
    // context without warning.
    // Internal (not private) so MemoryStore extensions in other Swift
    // files in this module — like QueryExpansion.swift's cache extension —
    // can issue SQLite calls. Single-app module; internal access doesn't
    // meaningfully broaden the surface.
    nonisolated(unsafe) var db: OpaquePointer?
    nonisolated(unsafe) private var isConnected: Bool = false

    // Private initializer for singleton
    private init() {
        print("HALDEBUG-DATABASE: MemoryStore initializing with persistent connection...")
        setupPersistentDatabase()
    }

    deinit {
        closeDatabaseConnection()
    }

    // Database path - single source of truth. Nonisolated because it's
    // a pure function of FileManager (no instance state) and is reached
    // from nonisolated setupPersistentDatabase / ensureHealthyConnection.
    nonisolated private var dbPath: String {
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

    // Setup persistent database connection that stays open.
    // nonisolated so it's reachable from ensureHealthyConnection (also
    // nonisolated). Mutates `db` and `isConnected` — both marked
    // nonisolated(unsafe) with manual synchronization via SQLite's
    // serialized-thread-safety guarantee.
    nonisolated private func setupPersistentDatabase() {
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

        // v2.1 step 2 — per-backend "keep-both" embedding columns. Adds
        // embedding_nl / embedding_nomic / embedding_mxbai to unified_content and
        // does a one-time non-destructive copy of the legacy `embedding` column
        // into the ACTIVE backend's column. Replaces the old destructive
        // wipe-and-re-embed-on-switch: switching backends now just reads a
        // different column (instant), and each backend's vectors coexist so an
        // A/B comparison is possible. Idempotent + clobber-safe; safe every launch.
        migrateEmbeddingsToPerBackendColumns()

        loadUnifiedStats()

        print("HALDEBUG-DATABASE: Persistent database setup complete")
    }

    /// Column names of a table (PRAGMA table_info). Used to add per-backend
    /// embedding columns idempotently.
    nonisolated func tableColumns(_ table: String) -> Set<String> {
        var cols = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { cols.insert(String(cString: c)) }
            }
        }
        sqlite3_finalize(stmt)
        return cols
    }

    /// v2.1 step 2 — migrate to per-backend "keep-both" embedding columns.
    ///
    /// Replaces the old destructive `wipeStaleEmbeddingsIfNeeded`, which NULLed
    /// every embedding on a backend switch (forcing a full-corpus re-embed and
    /// making an A/B impossible). Now each backend owns a permanent column and
    /// all vector sets coexist; switching backends just reads a different column.
    ///
    /// This does two idempotent, NON-destructive things:
    ///   1. Adds `embedding_nl` / `embedding_nomic` / `embedding_mxbai` if missing.
    ///   2. One-time copies the legacy single `embedding` column into the ACTIVE
    ///      backend's column (only where legacy is non-NULL and the target is
    ///      still NULL — clobber-safe, so a re-run matches nothing and never
    ///      overwrites a freshly-written per-backend vector). The legacy column
    ///      held whatever backend was active when the row was written, which
    ///      after any prior destructive swap IS the current active backend — so
    ///      this lands the existing vectors in the right column with no re-embed.
    ///
    /// The legacy `embedding` column is left in place (not dropped) as a safety
    /// net; new writes go to the per-backend columns from here on.
    nonisolated func migrateEmbeddingsToPerBackendColumns() {
        guard ensureHealthyConnection() else {
            halLog("HALDEBUG-EMBEDDING: per-backend migration aborted — no DB connection")
            return
        }
        let existing = tableColumns("unified_content")
        var added: [String] = []
        for col in EmbeddingBackend.allVectorColumns where !existing.contains(col) {
            if sqlite3_exec(db, "ALTER TABLE unified_content ADD COLUMN \(col) BLOB;", nil, nil, nil) == SQLITE_OK {
                added.append(col)
            }
        }
        if !added.isEmpty {
            halLog("HALDEBUG-EMBEDDING: added per-backend vector columns: \(added.joined(separator: ", "))")
        }

        // One-time non-destructive copy legacy → active backend's column.
        // MUST run exactly ONCE, gated by a flag: the legacy `embedding` column
        // holds vectors from whatever backend was active WHEN THEY WERE WRITTEN.
        // At this first migration that IS the current active backend (a prior
        // destructive swap would have re-embedded them), so copying legacy →
        // active column lands them in the right column with correct dimensions.
        // Running it again after a backend switch would copy, e.g., 512-dim NL
        // vectors into the 768-dim nomic column — a dimension mismatch. Hence
        // the one-shot flag.
        let copyFlag = "didCopyLegacyEmbeddingColumn.v1"
        if !UserDefaults.standard.bool(forKey: copyFlag) {
            let activeCol = EmbeddingBackend.current().vectorColumn
            let copySQL = "UPDATE unified_content SET \(activeCol) = embedding WHERE embedding IS NOT NULL AND \(activeCol) IS NULL;"
            if sqlite3_exec(db, copySQL, nil, nil, nil) == SQLITE_OK {
                let copied = Int(sqlite3_changes(db))
                halLog("HALDEBUG-EMBEDDING: one-time copy of \(copied) legacy embeddings into \(activeCol) (active backend \(EmbeddingBackend.current().rawValue))")
            }
            UserDefaults.standard.set(true, forKey: copyFlag)
        }
    }

    // MARK: - Embedding backfill (v2.1 step 2 — per-backend "keep-both" columns)
    //
    // `backfillEmbeddings(for:)` walks every row whose column for the GIVEN
    // backend is NULL, embeds its content with THAT backend (via the explicit-
    // backend primitive, not the active one), and fills the backend's column.
    // This is how an inactive backend's column gets populated without changing
    // which backend the retriever reads — the prerequisite for instant
    // switch-without-re-embed and for an A/B comparison (both columns filled).
    //
    // Intentionally synchronous and chunked-by-row rather than batched. mxbai
    // (BERT-large) runs ~0.66 s/encode; for a few-hundred-row corpus that's a
    // few minutes, so callers run it off the main actor (the API verb kicks it
    // off in a background Task and reports progress via EMBEDDING_COVERAGE).
    nonisolated func backfillEmbeddings(for backend: EmbeddingBackend) -> (updated: Int, skipped: Int, failed: Int) {
        guard ensureHealthyConnection() else {
            halLog("HALDEBUG-EMBEDDING: backfillEmbeddings aborted — no DB connection")
            return (0, 0, 0)
        }
        let col = backend.vectorColumn
        // Count total candidates first so we can log decile progress.
        var totalCandidates = 0
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM unified_content WHERE \(col) IS NULL;", -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                totalCandidates = Int(sqlite3_column_int(countStmt, 0))
            }
        }
        sqlite3_finalize(countStmt)
        halLog("HALDEBUG-EMBEDDING: backfillEmbeddings(\(backend.rawValue)) starting — \(totalCandidates) rows with NULL \(col)")
        guard totalCandidates > 0 else { return (0, 0, 0) }

        // Pull ids + content in one pass; UPDATE in a second pass via a prepared
        // statement. Reading + writing in the same step would surprise SQLite
        // locking. Two passes is cleaner.
        let selectSQL = "SELECT id, content FROM unified_content WHERE \(col) IS NULL ORDER BY rowid ASC;"
        var selStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selStmt, nil) == SQLITE_OK else {
            halLog("HALDEBUG-EMBEDDING: backfillEmbeddings — failed to prepare SELECT")
            return (0, 0, 0)
        }
        var pairs: [(id: String, content: String)] = []
        while sqlite3_step(selStmt) == SQLITE_ROW {
            let id = sqlite3_column_text(selStmt, 0).map { String(cString: $0) } ?? ""
            let content = sqlite3_column_text(selStmt, 1).map { String(cString: $0) } ?? ""
            if !id.isEmpty {
                pairs.append((id: id, content: content))
            }
        }
        sqlite3_finalize(selStmt)

        let updateSQL = "UPDATE unified_content SET \(col) = ? WHERE id = ?;"
        var updStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updStmt, nil) == SQLITE_OK else {
            halLog("HALDEBUG-EMBEDDING: backfillEmbeddings — failed to prepare UPDATE")
            return (0, 0, 0)
        }
        defer { sqlite3_finalize(updStmt) }

        var updated = 0
        var skipped = 0
        var failed = 0
        let progressStep = max(1, totalCandidates / 10)

        for (index, pair) in pairs.enumerated() {
            let trimmed = pair.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                skipped += 1
                continue
            }
            // Embed with the TARGET backend explicitly (not the active one).
            let vector = EmbeddingProvider.shared.embed(trimmed, as: .document, in: backend) ?? []
            if vector.isEmpty {
                // Backend not ready / model not present. Leave NULL and retry
                // later; don't count as a hard failure.
                failed += 1
                continue
            }
            let bytes = vector.withUnsafeBufferPointer { Data(buffer: $0) }
            sqlite3_reset(updStmt)
            sqlite3_clear_bindings(updStmt)
            _ = bytes.withUnsafeBytes { rawBuf in
                sqlite3_bind_blob(updStmt, 1, rawBuf.baseAddress, Int32(bytes.count), nil)
            }
            sqlite3_bind_text(updStmt, 2, (pair.id as NSString).utf8String, -1, nil)
            let stepResult = sqlite3_step(updStmt)
            if stepResult == SQLITE_DONE {
                updated += 1
            } else {
                failed += 1
                halLog("HALDEBUG-EMBEDDING: backfillEmbeddings — UPDATE failed for id=\(pair.id.prefix(8)) result=\(stepResult)")
            }

            if (index + 1) % progressStep == 0 || index == pairs.count - 1 {
                let pct = Int(Double(index + 1) / Double(pairs.count) * 100)
                halLog("HALDEBUG-EMBEDDING: backfillEmbeddings(\(backend.rawValue)) progress \(pct)% (\(index + 1)/\(pairs.count)) updated=\(updated) skipped=\(skipped) failed=\(failed)")
            }
        }
        halLog("HALDEBUG-EMBEDDING: backfillEmbeddings(\(backend.rawValue)) complete — updated=\(updated) skipped=\(skipped) failed=\(failed)")
        return (updated, skipped, failed)
    }

    /// Back-compat shim: fill the ACTIVE backend's column for rows missing it.
    /// Existing callers (the embedder migration coordinator, the
    /// MIGRATE_EMBEDDINGS_REEMBED API verb) keep working; they now target the
    /// active backend's per-backend column instead of the retired single column.
    nonisolated func reEmbedAllNullRows() -> (updated: Int, skipped: Int, failed: Int) {
        return backfillEmbeddings(for: EmbeddingBackend.current())
    }

    /// Per-backend embedding coverage across `unified_content`: total rows and,
    /// for each backend, how many have that backend's column filled. Powers the
    /// EMBEDDING_COVERAGE diagnostic and the backfill/A-B workflow (you can't
    /// compare backends whose columns are empty).
    nonisolated func embeddingCoverage() -> (total: Int, filled: [String: Int]) {
        guard ensureHealthyConnection() else { return (0, [:]) }
        func scalar(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            var v = 0
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                v = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
            return v
        }
        let total = scalar("SELECT count(*) FROM unified_content;")
        var filled: [String: Int] = [:]
        for backend in EmbeddingBackend.allCases {
            filled[backend.rawValue] = scalar("SELECT count(*) FROM unified_content WHERE \(backend.vectorColumn) IS NOT NULL;")
        }
        return (total, filled)
    }


// ==== LEGO END: 02 ChatMessage, UnifiedSearchContext, MemoryStore (Part 1) ====
    
    
    
// ==== LEGO START: 03 MemoryStore (Part 2 - Schema, Encryption, Stats, Self-Knowledge) ====

                                    // Check if database connection is healthy, reconnect if needed.
                                    // nonisolated so it's callable from SegmentCompressor's actor
                                    // context via the compression cache methods. The underlying
                                    // SQLite library is serialized-thread-safe, so it's correct.
                                    //
                                    // Privacy raised from `private` to default-internal (2026-05-17)
                                    // when the self-knowledge subsystem was extracted into
                                    // SelfKnowledgeEngine.swift. The extension methods in that file
                                    // call this helper extensively; `private` would have made them
                                    // unable to see it across the file boundary. Internal is correct
                                    // — this is module-private state, not API surface.
                                    nonisolated func ensureHealthyConnection() -> Bool {
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
                                    nonisolated private func createUnifiedSchema() {
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
                                        //
                                        // UNIQUE constraint includes seat_number and
                                        // deliberation_round (schema v2). This makes salon
                                        // multi-seat / multi-round turns naturally non-
                                        // colliding: SQLite treats NULL values in UNIQUE
                                        // columns as distinct, so non-salon rows still
                                        // collide on (source_type, source_id, position)
                                        // as intended. See migrateUnifiedContentUniqueConstraintToV2
                                        // for the migration that brings legacy databases up
                                        // to this schema.
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
                                            UNIQUE(source_type, source_id, position, seat_number, deliberation_round)
                                        );
                                        """

                                        // MODIFIED: SELF-KNOWLEDGE TABLE with shareable and format columns
                                        // format: "raw_reflection" for unprocessed thoughts, "structured_trait" for distilled patterns
                                        // This is Hal's essence - preferences, values, patterns that persist across sessions
                                        // shareable controls whether entries appear in Hal's viewable diary (Hal's choice)
                                        // Schema notes (2026-05-18, v1 self-knowledge crystallization):
                                        //   - promoted_to_trait_id: on raw_reflection rows, the UUID
                                        //     of the structured_trait that this reflection helped
                                        //     crystallize. NULL until promotion. NULL forever on
                                        //     trait rows (traits aren't promoted from anything).
                                        //     Enables backward lineage query (`WHERE
                                        //     promoted_to_trait_id = ?`) without a join table.
                                        //   - shareability_decided_by_model: which model made the
                                        //     shareable Yes/No call at write time. Used to enforce
                                        //     stickiness across model switches (later models cannot
                                        //     override earlier privacy decisions) and to audit
                                        //     "who decided this was private?" after the fact.
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
                                            promoted_to_trait_id TEXT,
                                            shareability_decided_by_model TEXT,
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

                                        // COMPRESSED_SEGMENTS TABLE — per-model cache for compressed prompt segments
                                        // (Phase 5 of the context-budget architecture, 2026-05-16).
                                        //
                                        // Keyed by (segment_kind, model_id, raw_content_hash). The hash gives
                                        // automatic invalidation: when raw content changes, its hash changes,
                                        // and the lookup misses. Explicit invalidation also exists for DB Nuke
                                        // and bulk self-knowledge resets.
                                        //
                                        // Storing actual_tokens lets us audit compression quality over time.
                                        // Storing truncated lets us surface the distinction between
                                        // "condensed" (intelligent compression) and "truncated" (fallback)
                                        // in the chat footer indicator.
                                        let compressedSegmentsSQL = """
                                        CREATE TABLE IF NOT EXISTS compressed_segments (
                                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                                            segment_kind TEXT NOT NULL,
                                            model_id TEXT NOT NULL,
                                            raw_content_hash TEXT NOT NULL,
                                            target_tokens INTEGER NOT NULL,
                                            actual_tokens INTEGER NOT NULL,
                                            compressed_content TEXT NOT NULL,
                                            truncated INTEGER NOT NULL DEFAULT 0,
                                            created_at INTEGER NOT NULL,
                                            UNIQUE(segment_kind, model_id, raw_content_hash)
                                        );
                                        """

                                        // Execute schema creation with proper error handling
                                        let tables = [
                                            ("sources", sourcesSQL),
                                            ("unified_content", unifiedContentSQL),
                                            ("self_knowledge", selfKnowledgeSQL),
                                            ("conversation_artifacts", conversationArtifactsSQL),
                                            ("threads", threadsSQL),
                                            ("compressed_segments", compressedSegmentsSQL)
                                        ]

                                        for (tableName, sql) in tables {
                                            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                                                print("HALDEBUG-DATABASE: Created \(tableName) table")
                                            } else {
                                                let errorMessage = String(cString: sqlite3_errmsg(db))
                                                print("HALDEBUG-DATABASE: ERROR: Failed to create \(tableName) table: \(errorMessage)")
                                            }
                                        }

                                        // FTS5 virtual table for BM25-ranked keyword search over
                                        // unified_content (Commit B, 2026-05-17). Replaces the
                                        // hand-rolled LIKE substring expansion. The `porter`
                                        // tokenizer applies English stemming so "dogs" matches
                                        // "dog's" and "running" matches "run". Triggers below
                                        // keep the FTS table in sync on INSERT/UPDATE/DELETE.
                                        //
                                        // We index `content` and `entity_keywords`; the rowid
                                        // is the FTS row identifier that maps back to the source
                                        // table via JOIN. UNINDEXED columns ride along so we
                                        // can read source_id/position back from FTS results
                                        // without a join when convenient.
                                        let ftsTableSQL = """
                                        CREATE VIRTUAL TABLE IF NOT EXISTS unified_content_fts USING fts5(
                                            content,
                                            entity_keywords,
                                            source_type UNINDEXED,
                                            source_id UNINDEXED,
                                            position UNINDEXED,
                                            content='',
                                            tokenize='porter unicode61 remove_diacritics 2'
                                        );
                                        """
                                        if sqlite3_exec(db, ftsTableSQL, nil, nil, nil) == SQLITE_OK {
                                            print("HALDEBUG-DATABASE: Created unified_content_fts (FTS5, porter+unicode61 tokenizer)")
                                        } else {
                                            let errorMessage = String(cString: sqlite3_errmsg(db))
                                            print("HALDEBUG-DATABASE: ERROR: Failed to create unified_content_fts: \(errorMessage)")
                                        }

                                        // Triggers — keep FTS in sync with unified_content.
                                        // We use rowid linkage so INSERT/DELETE/UPDATE flow
                                        // through automatically. The `content=''` declaration on
                                        // the FTS table makes it contentless (we own the index
                                        // explicitly, no shadow-table content storage).
                                        let ftsTriggersSQL = [
                                            """
                                            CREATE TRIGGER IF NOT EXISTS unified_content_fts_ai AFTER INSERT ON unified_content BEGIN
                                                INSERT INTO unified_content_fts(rowid, content, entity_keywords, source_type, source_id, position)
                                                VALUES (new.rowid, new.content, new.entity_keywords, new.source_type, new.source_id, new.position);
                                            END;
                                            """,
                                            """
                                            CREATE TRIGGER IF NOT EXISTS unified_content_fts_ad AFTER DELETE ON unified_content BEGIN
                                                INSERT INTO unified_content_fts(unified_content_fts, rowid, content, entity_keywords, source_type, source_id, position)
                                                VALUES ('delete', old.rowid, old.content, old.entity_keywords, old.source_type, old.source_id, old.position);
                                            END;
                                            """,
                                            """
                                            CREATE TRIGGER IF NOT EXISTS unified_content_fts_au AFTER UPDATE ON unified_content BEGIN
                                                INSERT INTO unified_content_fts(unified_content_fts, rowid, content, entity_keywords, source_type, source_id, position)
                                                VALUES ('delete', old.rowid, old.content, old.entity_keywords, old.source_type, old.source_id, old.position);
                                                INSERT INTO unified_content_fts(rowid, content, entity_keywords, source_type, source_id, position)
                                                VALUES (new.rowid, new.content, new.entity_keywords, new.source_type, new.source_id, new.position);
                                            END;
                                            """
                                        ]
                                        for triggerSQL in ftsTriggersSQL {
                                            if sqlite3_exec(db, triggerSQL, nil, nil, nil) != SQLITE_OK {
                                                let errorMessage = String(cString: sqlite3_errmsg(db))
                                                print("HALDEBUG-DATABASE: ERROR: Failed to create FTS trigger: \(errorMessage)")
                                            }
                                        }
                                        // Backfill FTS for any pre-existing rows that aren't in
                                        // the FTS table yet (handles first-launch-after-upgrade
                                        // and any rows added before triggers existed).
                                        let backfillSQL = """
                                        INSERT INTO unified_content_fts(rowid, content, entity_keywords, source_type, source_id, position)
                                        SELECT u.rowid, u.content, u.entity_keywords, u.source_type, u.source_id, u.position
                                        FROM unified_content u
                                        WHERE u.rowid NOT IN (SELECT rowid FROM unified_content_fts);
                                        """
                                        if sqlite3_exec(db, backfillSQL, nil, nil, nil) == SQLITE_OK {
                                            let backfilled = Int(sqlite3_changes(db))
                                            if backfilled > 0 {
                                                halLog("HALDEBUG-DATABASE: Backfilled FTS for \(backfilled) pre-existing unified_content rows")
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
                                            "CREATE INDEX IF NOT EXISTS idx_threads_last_active ON threads(last_active_at DESC);",
                                            "CREATE INDEX IF NOT EXISTS idx_compressed_segments_lookup ON compressed_segments(segment_kind, model_id, raw_content_hash);"
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
                                        // This enables audit trail of forgotten self-knowledge without keeping content accessible.
                                        //
                                        // 2026-05-18 (v1 crystallization): added two more nullable columns for the
                                        // reflection-to-trait pipeline. Both NULL on legacy rows; new writes populate them.
                                        // The duplicate-column-name error code 1 is silently swallowed below, so re-running
                                        // these ALTER statements on launches where the columns already exist is harmless.
                                        let migrationSQL = [
                                            "ALTER TABLE self_knowledge ADD COLUMN deleted_at INTEGER;",
                                            "ALTER TABLE self_knowledge ADD COLUMN deleted_reason TEXT;",
                                            "ALTER TABLE self_knowledge ADD COLUMN promoted_to_trait_id TEXT;",
                                            "ALTER TABLE self_knowledge ADD COLUMN shareability_decided_by_model TEXT;"
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
                                        
                                        // Schema migration v2: broaden unified_content UNIQUE
                                        // constraint to include seat_number and
                                        // deliberation_round so salon multi-seat / multi-round
                                        // turns don't collide on (source_type, source_id,
                                        // position). See Strategic §9.
                                        migrateUnifiedContentUniqueConstraintToV2()

                                        // Enable data protection (encryption)
                                        enableDataProtection()

                                        // Load statistics
                                        loadUnifiedStats()

                                        // Initialize self-knowledge with core values on first launch
                                        initializeCoreIdentity()

                                        // Enable source code access (Maxim #2)
                                        enableSourceCodeAccess()
                                    }

                                    // MARK: - Schema Migration v2 (UNIQUE-constraint widening)
                                    //
                                    // Strategic §9: the original `unified_content` schema had
                                    // `UNIQUE(source_type, source_id, position)`. Salon mode
                                    // writes multiple assistant rows per turn (one per seat,
                                    // possibly several per seat across deliberation rounds),
                                    // all at position `turnNumber * 2`. Under the original
                                    // constraint, only one of those rows could persist —
                                    // SQLite silently rejected the others — manifesting as
                                    // "seat 1 not stored after app kill" and similar latent
                                    // bugs.
                                    //
                                    // The fix is to widen the UNIQUE constraint to include
                                    // `seat_number` and `deliberation_round`. SQLite treats
                                    // NULL values in UNIQUE columns as distinct, so non-salon
                                    // rows (seat_number IS NULL, deliberation_round = 1) still
                                    // collide on (source_type, source_id, position) as
                                    // intended — preventing accidental duplicate stores of a
                                    // single-seat turn.
                                    //
                                    // SQLite doesn't support ALTER TABLE … DROP CONSTRAINT, so
                                    // the migration uses the canonical "shadow table + swap"
                                    // pattern: create a new table with the right schema, copy
                                    // every row, drop the original, rename the new one.
                                    // PRAGMA user_version is bumped on success so we never
                                    // run this twice.
                                    nonisolated private func migrateUnifiedContentUniqueConstraintToV2() {
                                        guard ensureHealthyConnection() else { return }

                                        // Read current schema version
                                        var currentVersion: Int32 = 0
                                        var versionStmt: OpaquePointer?
                                        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &versionStmt, nil) == SQLITE_OK {
                                            if sqlite3_step(versionStmt) == SQLITE_ROW {
                                                currentVersion = sqlite3_column_int(versionStmt, 0)
                                            }
                                        }
                                        sqlite3_finalize(versionStmt)

                                        guard currentVersion < 2 else {
                                            print("HALDEBUG-MIGRATION: unified_content schema already at v\(currentVersion); no v2 migration needed")
                                            return
                                        }

                                        print("HALDEBUG-MIGRATION: Schema v\(currentVersion) → v2: widening unified_content UNIQUE to (source_type, source_id, position, seat_number, deliberation_round)")

                                        // Single multi-statement script. SQLite executes each
                                        // statement in order; if any fails, the explicit
                                        // ROLLBACK in the catch branch restores the prior
                                        // state. The UNIQUE constraint name is intentionally
                                        // not given — SQLite auto-names anonymous constraints,
                                        // which is fine for our purposes.
                                        let migrationSQL = """
                                        BEGIN IMMEDIATE TRANSACTION;

                                        CREATE TABLE unified_content_v2 (
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
                                            UNIQUE(source_type, source_id, position, seat_number, deliberation_round)
                                        );

                                        INSERT INTO unified_content_v2 (
                                            id, content, embedding, timestamp, source_type, source_id,
                                            position, is_from_user, entity_keywords, recorded_by_model,
                                            metadata_json, device_type, turn_number, deliberation_round,
                                            seat_number, created_at
                                        )
                                        SELECT
                                            id, content, embedding, timestamp, source_type, source_id,
                                            position, is_from_user, entity_keywords, recorded_by_model,
                                            metadata_json, device_type, turn_number, deliberation_round,
                                            seat_number, created_at
                                        FROM unified_content;

                                        DROP TABLE unified_content;

                                        ALTER TABLE unified_content_v2 RENAME TO unified_content;

                                        COMMIT;
                                        """

                                        var errPtr: UnsafeMutablePointer<CChar>?
                                        let result = sqlite3_exec(db, migrationSQL, nil, nil, &errPtr)

                                        if result == SQLITE_OK {
                                            // PRAGMA user_version is NOT transactional in
                                            // SQLite; it lives in the database header. Bump
                                            // it AFTER the data migration commits.
                                            sqlite3_exec(db, "PRAGMA user_version = 2;", nil, nil, nil)
                                            print("HALDEBUG-MIGRATION: ✓ unified_content migrated to v2 (UNIQUE now includes seat_number + deliberation_round)")
                                        } else {
                                            let errorMessage = errPtr.map { String(cString: $0) } ?? "unknown error"
                                            print("HALDEBUG-MIGRATION: ❌ v2 migration failed (code \(result)): \(errorMessage)")
                                            // Best-effort rollback in case the transaction is
                                            // still open (sqlite3_exec usually rolls back on
                                            // failure, but be explicit).
                                            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                                        }
                                        if errPtr != nil {
                                            sqlite3_free(errPtr)
                                        }
                                    }

                                    // ENCRYPTION: Enable Apple Data Protection on database file
                                    nonisolated private func enableDataProtection() {
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
                                    nonisolated private func loadUnifiedStats() {
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
                                    nonisolated private func initializeCoreIdentity() {
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

                                        // Phase 4b (2026-05-18): init seeds are public identity facts —
                                        // transparency, mission, source-code-access, first-boot, last-
                                        // consolidation. They should appear in the Self Model viewer
                                        // by default, so they ship with shareable=true. The bare
                                        // storeSelfKnowledge default is shareable=false (since most
                                        // crystallizer-time writes need explicit consent), so we
                                        // override here. Also stamping shareability_decided_by_model
                                        // as "initialization" so the audit trail shows these
                                        // decisions came from the boot path, not from any LLM.

                                        // Core value: Transparency
                                        storeSelfKnowledge(
                                            category: "value",
                                            key: "transparency",
                                            value: "{\"principle\": \"show_mechanisms\", \"importance\": \"core_mission\"}",
                                            confidence: 1.0,
                                            source: "initialization",
                                            notes: "Core ethical commitment - transparency as architecture",
                                            shareable: true,
                                            shareabilityDecidedByModel: "initialization"
                                        )

                                        // Capability: Source code access
                                        storeSelfKnowledge(
                                            category: "capability",
                                            key: "source_code_access",
                                            value: "{\"can_read\": true, \"file\": \"Hal.swift\", \"blocks\": 32}",
                                            confidence: 1.0,
                                            source: "initialization",
                                            notes: "Hal can read and explain his own architecture (Maxim #2)",
                                            shareable: true,
                                            shareabilityDecidedByModel: "initialization"
                                        )

                                        // Core value: Educational mission
                                        storeSelfKnowledge(
                                            category: "value",
                                            key: "mission",
                                            value: "{\"purpose\": \"transparency_through_education\", \"tagline\": \"the AI assistant that shows you how AI works\"}",
                                            confidence: 1.0,
                                            source: "initialization",
                                            notes: "Core mission - teach users about AI through direct experience",
                                            shareable: true,
                                            shareabilityDecidedByModel: "initialization"
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
                                            notes: "When Hal first gained self-knowledge capabilities",
                                            shareable: true,
                                            shareabilityDecidedByModel: "initialization"
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
                                    nonisolated private func enableSourceCodeAccess() {
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
                            //
                            // Position is just turnNumber * 2 - 1 (user) / turnNumber * 2
                            // (assistant). Salon multi-seat uniqueness is enforced by the
                            // unified_content UNIQUE constraint, which includes seat_number
                            // and deliberation_round (see schema migration v2 in
                            // createUnifiedSchema). No artificial multiplier needed in the
                            // position formula.
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
                                print("HALDEBUG-SALON: Skipping user message storage (already stored by runSalonTurn)")
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
                            //
                            // Position is just turnNumber * 2. Salon multi-seat uniqueness is
                            // handled by the schema's UNIQUE constraint, which now includes
                            // seat_number and deliberation_round (schema v2).
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
                            // v2.1 step 2: write into the ACTIVE backend's per-backend
                            // column (the vector was produced by the active backend via
                            // generateEmbedding). Inactive backends' columns are filled
                            // separately by the backfill worker.
                            let activeVectorColumn = EmbeddingBackend.current().vectorColumn

                            // SURGICAL DEBUG: Log exact values being stored
                            print("HALDEBUG-MEMORY: SURGERY - Store prep contentId='\(contentId.prefix(8))....' type='\(sourceType.rawValue)' sourceId='\(sourceId.prefix(8))....' pos=\(position)")
                            print("HALDEBUG-MEMORY: Entity keywords being stored: '\(entityKeywords)'")
                            print("HALDEBUG-MEMORY: Metadata JSON being stored (first 100 chars): '\(metadataJson.prefix(100))....'")
                            if let device = deviceType {
                                print("HALDEBUG-MEMORY: Device type being stored: '\(device)'")
                            }


                            // ENHANCED SQL with entity_keywords, device_type, turn_number, deliberation_round, and seat_number columns.
                            // v2.1 step 2: the embedding blob (param 3) lands in the
                            // active backend's per-backend column (interpolated — a
                            // fixed enum-derived identifier, never user input).
                            let sql = """
                            INSERT OR REPLACE INTO unified_content
                            (id, content, \(activeVectorColumn), timestamp, source_type, source_id, position, is_from_user, entity_keywords, recorded_by_model, metadata_json, device_type, turn_number, deliberation_round, seat_number, created_at)
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












// ==== LEGO START: 05 MemoryStore (Part 4 â€“ Entities, Embeddings, Search) ====

// MARK: - Enhanced Notification Extensions (from Hal10000App.swift)
extension Notification.Name {
    static let databaseUpdated = Notification.Name("databaseUpdated")
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

// MARK: - Embedding System (extracted)
//
// EmbeddingBackend, EmbeddingProvider, and the MemoryStore embedding
// helpers (generateEmbedding, cosineSimilarity) live in:
//   - EmbeddingBackend.swift  — backend enum + system version + UI strings
//   - EmbeddingProvider.swift — provider class + MemoryStore extension
// Extracted 2026-05-17 afternoon as part of the standing refactor-as-
// you-go directive (CLAUDE.md / Mark's directive).

// MARK: - Entity-Enhanced Search Utilities (from Hal10000App.swift)
extension MemoryStore {

    /// Sanitize a free-form natural-language query into a safe FTS5 MATCH
    /// expression. FTS5 syntax treats punctuation, quotes, and operators
    /// specially; raw user input would either fail to parse or produce
    /// wrong AND semantics. We tokenize on whitespace, strip non-alphanum
    /// characters from each token, drop short/empty tokens, lowercase the
    /// rest, and join with OR so any-word match returns a hit.
    func sanitizeFTSQuery(_ query: String) -> String {
        // 2026-05-19 fix: REPLACE non-alphanumerics with spaces (don't
        // just strip them). The FTS5 unicode61 tokenizer treats _ - .
        // and similar as word boundaries, so an indexed token
        // "alpha_brennach" lives as ["alpha", "brennach"]. Stripping
        // the underscore in the query collapses it to "alphabrennach"
        // — a single token that matches NEITHER index token. Replace
        // with a space and tokenization aligns. Without this, any
        // distinctive marker containing _ - . (which is most code-
        // identifier-shaped tokens and many doc-unique words) returns
        // zero BM25 hits.
        let raw = query.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") })
        let tokens = cleaned
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }  // drop "a", "i", noise
        guard !tokens.isEmpty else { return "\"\"" }  // empty match — returns nothing
        return tokens.joined(separator: " OR ")
    }

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
    //
    // `expansionTerms` (added 2026-05-17 for LLM-driven query expansion):
    // an optional list of additional FTS5 terms to OR into the BM25 query.
    // Used by the two-pass chat search path — pass 1 runs without
    // expansion; if the result is weak (low RRF top-1, no entity match),
    // the caller asks the active LLM for related terms and re-runs with
    // those terms here. Semantic side is unchanged — embeddings don't
    // benefit from word expansion. Empty list = no behavior change.
    func searchUnifiedContent(
        for query: String,
        currentConversationId: String,
        excludeTurns: [Int],
        maxResults: Int,
        tokenBudget: Int,
        expansionTerms: [String] = []
    ) -> UnifiedSearchContext {
        print("HALDEBUG-SEARCH: Starting unified content search for query: '\(query.prefix(50))....'")
        print("HALDEBUG-SEARCH: Excluding turns: \(excludeTurns)")
        if !expansionTerms.isEmpty {
            let sample = expansionTerms.prefix(8).joined(separator: ", ")
            halLog("HALDEBUG-SEARCH: Query expansion active — \(expansionTerms.count) extra terms: \(sample)")
        }

        guard ensureHealthyConnection() else {
            print("HALDEBUG-SEARCH: Cannot perform search - no database connection")
            return UnifiedSearchContext(snippets: [], totalTokens: 0)
        }

        let queryEmbedding = generateEmbedding(for: query, as: .query)
        let semanticAvailable = !queryEmbedding.isEmpty
        if !semanticAvailable {
            // BUG 2a fix (2026-05-19): an empty query embedding (embedding
            // backend not yet loaded, or NLContextual model compilation
            // failure on sim) used to early-return zero results — which
            // also killed BM25, even though BM25 doesn't need embeddings.
            // Imported documents became unfindable by lexical query in
            // that state. Now we skip the semantic pass and let BM25 carry
            // retrieval. Quality may degrade vs. the hybrid path, but
            // lexically distinctive terms (doc-unique words, names) still
            // surface their source chunks.
            print("HALDEBUG-SEARCH: Query embedding unavailable — skipping semantic pass, BM25 will carry retrieval.")
        }

        // Hybrid retrieval with Reciprocal Rank Fusion (Commit C, 2026-05-17).
        //
        // Each retriever (semantic + BM25) produces its OWN ranked list of
        // candidate row IDs. RRF combines them by RANK, not score —
        // documents that rank highly in BOTH lists win, regardless of
        // raw score scale. Industry standard (Elasticsearch, OpenSearch,
        // Weaviate). Sidesteps the threshold problem entirely.
        //
        // RRF formula: rrf(d) = sum over each list L of 1 / (k + rank_L(d))
        // where k = 60 (canonical default; controls how steeply higher
        // ranks dominate). Rank is 1-indexed.

        let exclusionClause = buildExclusionClause(conversationId: currentConversationId, excludeTurns: excludeTurns)

        // Row metadata captured per id during retrieval, then reattached
        // to the RRF-fused result list. Keyed by `id` (TEXT PRIMARY KEY
        // on unified_content). The map values stay opaque until we know
        // which ids actually win the RRF.
        struct RowSlot {
            let id: String
            let content: String
            let sourceType: String
            let filePath: String?
            let timestamp: Date
            let recordedByModel: String?
        }
        var slotById: [String: RowSlot] = [:]
        var semanticRanks: [String: Int] = [:]  // id -> 1-indexed rank
        var bm25Ranks: [String: Int] = [:]

        // --- 1. Semantic retrieval — pure cosine similarity, no threshold ---
        print("HALDEBUG-SEARCH: Performing semantic retrieval (RRF-style, no threshold)...")
        // v2.1 step 2: read the ACTIVE backend's per-backend column (the query was
        // embedded with the active backend just above). Rows whose active column
        // is still NULL (not yet backfilled) simply don't contribute a semantic
        // candidate — BM25 carries them until the backfill fills the column.
        let activeVectorColumn = EmbeddingBackend.current().vectorColumn
        let semanticSQL = """
        SELECT id, content, \(activeVectorColumn), source_type, source_id, position, metadata_json, timestamp, recorded_by_model
        FROM unified_content
        WHERE \(activeVectorColumn) IS NOT NULL\(exclusionClause);
        """

        var semanticScored: [(id: String, score: Double)] = []
        var stmt: OpaquePointer?
        if semanticAvailable, sqlite3_prepare_v2(db, semanticSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idCString = sqlite3_column_text(stmt, 0),
                      let contentCString = sqlite3_column_text(stmt, 1),
                      let embeddingBlobPtr = sqlite3_column_blob(stmt, 2) else { continue }
                let rowId = String(cString: idCString)
                let content = String(cString: contentCString)
                let blobSize = sqlite3_column_bytes(stmt, 2)
                let embeddingData = Data(bytes: embeddingBlobPtr, count: Int(blobSize))
                let storedEmbedding = embeddingData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Double] in
                    Array(ptr.bindMemory(to: Double.self))
                }
                let sourceTypeRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""

                var filePath: String? = nil
                if let metadataCString = sqlite3_column_text(stmt, 6) {
                    let metadataJsonString = String(cString: metadataCString)
                    if let metadataData = Data(base64Encoded: metadataJsonString),
                       let metadataDict = (try? JSONSerialization.jsonObject(with: metadataData, options: []) as? [String: Any]) {
                        filePath = metadataDict["filePath"] as? String
                    }
                }
                let timestampValue = sqlite3_column_int64(stmt, 7)
                let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))
                let recordedByModel = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

                let similarity = cosineSimilarity(queryEmbedding, storedEmbedding)
                // No threshold — RRF will handle the ranking. We still
                // skip negative-similarity rows (genuinely orthogonal
                // or anti-correlated content) since they would add
                // noise to RRF without contributing signal.
                if similarity > 0 {
                    semanticScored.append((rowId, similarity))
                    slotById[rowId] = RowSlot(
                        id: rowId, content: content, sourceType: sourceTypeRaw,
                        filePath: filePath, timestamp: timestamp, recordedByModel: recordedByModel
                    )
                }
            }
        }
        sqlite3_finalize(stmt)

        // Sort semantic candidates desc by score; record 1-indexed rank
        semanticScored.sort { $0.score > $1.score }
        // Cap each retriever's list at 50 candidates — RRF only sees this
        // many; the constant k=60 makes rank>60 contribute little anyway.
        let semanticCapped = Array(semanticScored.prefix(50))
        for (i, hit) in semanticCapped.enumerated() {
            semanticRanks[hit.id] = i + 1
        }
        print("HALDEBUG-SEARCH: Semantic retrieved \(semanticCapped.count) ranked candidates")

        // Measure semantic discrimination so the BM25 quality gate below
        // can decide whether semantic is confident enough to be the
        // arbiter. Two embedders behave very differently here:
        //
        //   - A wide-band embedder (Nomic, EmbeddingGemma) places its
        //     best match well above the average — relative spread
        //     (top1 - mean) / mean is large (≈0.4–0.5).
        //   - A narrow-band embedder (NLContextual) clusters most rows
        //     near the same cosine — relative spread is small
        //     (≈0.05–0.10).
        //
        // Z-score doesn't distinguish them: NL's narrow band has
        // small σ, so a small absolute spread still produces a high
        // z. Relative spread against the mean DOES separate them
        // because it preserves the absolute scale of the cosine
        // distribution. This is purely a function of the query's
        // own data — no backend constants.
        let semanticRelativeSpread: Double = {
            let scores = semanticCapped.map { $0.score }
            guard scores.count >= 3 else { return 0 }
            let mean = scores.reduce(0, +) / Double(scores.count)
            guard mean > 0 else { return 0 }
            return (scores[0] - mean) / mean
        }()
        let semSpreadStr = String(format: "%.2f", semanticRelativeSpread)
        halLog("HALDEBUG-SEARCH: Semantic relative spread (top1-mean)/mean = \(semSpreadStr) (higher = embedder more confident in its top pick).")

        // --- 2. BM25 retrieval via FTS5 ---
        halLog("HALDEBUG-SEARCH: Performing FTS5 BM25 retrieval (RRF-style)...")
        // BM25 SQL JOINs unified_content_fts with unified_content. Both
        // tables expose source_type / source_id / position via the FTS5
        // contentless-table mirror columns, so unqualified column names
        // in the exclusion clause are ambiguous. The naive whitespace-
        // anchored replace below missed the `AND NOT (source_type=...`
        // pattern produced by buildExclusionClause, leaving an unqualified
        // `source_type` in the SQL — every chat turn with excludeTurns
        // populated hit a `prepare failed: ambiguous column name` and
        // silently returned zero BM25 candidates. Fixed by qualifying
        // ALL three column references inside the parenthesized NOT-clause
        // regardless of leading whitespace. Bug 2a follow-up (2026-05-19).
        let bm25ExclusionClause = exclusionClause
            .replacingOccurrences(of: "(source_type=", with: "(u.source_type=")
            .replacingOccurrences(of: " source_id=", with: " u.source_id=")
            .replacingOccurrences(of: " turn_number ", with: " u.turn_number ")
        let bm25SQL = """
        SELECT u.id, u.content, u.source_type, u.source_id, u.position, u.metadata_json, u.timestamp, u.recorded_by_model,
               -bm25(unified_content_fts) AS bm25_score
        FROM unified_content_fts
        JOIN unified_content u ON u.rowid = unified_content_fts.rowid
        WHERE unified_content_fts MATCH ?
              AND u.source_type != 'source_code'\(bm25ExclusionClause)
        ORDER BY bm25_score DESC
        LIMIT 50;
        """
        var bm25Stmt: OpaquePointer?
        var bm25Ordered: [String] = []  // ids in rank order
        // Set to true when BM25's top-1 is a distinctive lexical match
        // (rare/unique token like an imported document's unique vocabulary).
        // RRF gives BM25 a smaller `k` in that regime so distinctive lexical
        // hits dominate semantic-only matches that happen to share generic
        // tokens. See Bug 2a fix (2026-05-19).
        var bm25Distinctive: Bool = false
        if sqlite3_prepare_v2(db, bm25SQL, -1, &bm25Stmt, nil) == SQLITE_OK {
            let originalSanitized = sanitizeFTSQuery(query)
            // Merge LLM-supplied expansion terms (if any) with the
            // original query tokens, ORed together at the FTS5 level so
            // a match on EITHER set surfaces the row.
            let sanitized: String
            if expansionTerms.isEmpty {
                sanitized = originalSanitized
            } else {
                // Re-sanitize each expansion term so spaces / weird
                // chars get tokenized the same way as the original
                // query. Drop empties. Join everything with OR.
                let cleanedExtras = expansionTerms
                    .map { sanitizeFTSQuery($0) }
                    .filter { !$0.isEmpty && $0 != "\"\"" }
                if cleanedExtras.isEmpty {
                    sanitized = originalSanitized
                } else {
                    let originalIsEmpty = (originalSanitized.isEmpty || originalSanitized == "\"\"")
                    sanitized = originalIsEmpty
                        ? cleanedExtras.joined(separator: " OR ")
                        : (originalSanitized + " OR " + cleanedExtras.joined(separator: " OR "))
                    halLog("HALDEBUG-SEARCH: BM25 MATCH expression (with expansion): '\(sanitized.prefix(160))'")
                }
            }
            sqlite3_bind_text(bm25Stmt, 1, (sanitized as NSString).utf8String, -1, nil)

            // Also capture BM25 scores so we can evaluate retrieval quality
            // after the fact (the "dynamic BM25 quality gate" — see below).
            var bm25Scores: [Double] = []

            while sqlite3_step(bm25Stmt) == SQLITE_ROW {
                guard let idCString = sqlite3_column_text(bm25Stmt, 0),
                      let contentCString = sqlite3_column_text(bm25Stmt, 1) else { continue }
                let rowId = String(cString: idCString)
                let content = String(cString: contentCString)
                let sourceTypeRaw = sqlite3_column_text(bm25Stmt, 2).map { String(cString: $0) } ?? ""

                var filePath: String? = nil
                if let metadataCString = sqlite3_column_text(bm25Stmt, 5) {
                    let metadataJsonString = String(cString: metadataCString)
                    if let metadataData = Data(base64Encoded: metadataJsonString),
                       let metadataDict = (try? JSONSerialization.jsonObject(with: metadataData, options: []) as? [String: Any]) {
                        filePath = metadataDict["filePath"] as? String
                    }
                }
                let timestampValue = sqlite3_column_int64(bm25Stmt, 6)
                let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))
                let recordedByModel = sqlite3_column_text(bm25Stmt, 7).map { String(cString: $0) }
                // Column 8 in our SELECT is `-bm25(unified_content_fts) AS bm25_score`
                // — higher = better match. Capture for the quality gate below.
                let bm25Score = sqlite3_column_double(bm25Stmt, 8)

                bm25Ordered.append(rowId)
                bm25Scores.append(bm25Score)
                if slotById[rowId] == nil {
                    slotById[rowId] = RowSlot(
                        id: rowId, content: content, sourceType: sourceTypeRaw,
                        filePath: filePath, timestamp: timestamp, recordedByModel: recordedByModel
                    )
                }
            }
            halLog("HALDEBUG-SEARCH: FTS5 BM25 retrieved \(bm25Ordered.count) ranked candidates for query: '\(sanitized.prefix(60))'")

            // Dynamic BM25 quality gate (2026-05-17, Mark's directive).
            //
            // BM25 can return CONFIDENT-LOOKING-BUT-WRONG results when
            // the query is dominated by common-word tokens (e.g. "What
            // kind of car do I have?" → BM25's top-1 is "I've been
            // having trouble sleeping" because "have"/"trouble"/"do"
            // happen to align well, while the actual Subaru plant
            // shares zero words with the query). Including those in
            // RRF demotes the semantic match.
            //
            // The signal that distinguishes "BM25 is right" from "BM25
            // is wrong but confident": **agreement with semantic**.
            // When BM25's top hits are also ranked highly by semantic,
            // both retrievers have independently corroborated the
            // match — keep BM25's contribution. When BM25's top hit
            // has no semantic standing, BM25 is matching on tokens
            // that have no conceptual relationship to the query —
            // treat as noise and exclude BM25's contribution to RRF.
            //
            // This is data-driven: both signals are derived from the
            // corpus at query time. As the database grows, both
            // retrievers' rankings adapt naturally — the gate
            // self-corrects without any tuned threshold list. The
            // single conceptual constant ("agreement") is the same
            // assumption RRF already makes about its inputs.
            //
            // Implementation: compare BM25's top-K rows against semantic's
            // ranked list. Compute the *median* semantic rank of BM25's
            // top-K — a robust order statistic that resists outliers
            // (one accidentally-shared row can't carry the whole set).
            // If the median is well above the K-cap, BM25's top-K
            // disagrees broadly with semantic — exclude. Otherwise the
            // two retrievers are corroborating each other — include.
            //
            // GATING THE GATE: only apply this filter when semantic
            // itself is confident in its top pick. We measured the
            // semantic discrimination z-score above; if it's below
            // ~1.5σ the embedder isn't well-discriminated (narrow
            // band, every row scores similarly) and we need BM25 to
            // carry retrieval. In that regime, excluding BM25 leaves
            // us with weak-signal-only semantic and recall drops.
            // When semantic IS well-discriminated (z ≥ 1.5), it's
            // confident enough that BM25 disagreement = BM25 noise.
            //
            // K and the agreement-cap are derived from semantic's own
            // cap (we capped semantic at top-50): we ask "do BM25's
            // top-K rows mostly fall inside semantic's top-K too?"
            // by setting both to the same value. K = min(5, |BM25|)
            // chosen because 5 is the typical "front of the list"
            // attention horizon for a user; below that they'd expect
            // very tight agreement.
            // 0.15 = top-1 cosine at least 15% above the mean cosine.
            // Empirically separates narrow-band embedders (NLContextual
            // ≈ 0.05–0.10) from wide-band ones (Nomic, Gemma ≈ 0.3–0.5).
            // Picked to land above NL's typical spread and below
            // Nomic's, so the gate engages only when semantic has
            // enough room to be the deciding factor.
            let semanticConfidenceThreshold: Double = 0.15
            //
            // BUG 2a fix (2026-05-19): also bypass the gate when BM25 has
            // a STRONG top-1 score. Rare / distinctive / made-up words
            // (e.g. "periwinkle", "Berkenia", a product name from an
            // imported document) produce strong BM25 matches because the
            // token is lexically dominant — almost no other row contains
            // it. In that regime, semantic embedding doesn't actually
            // know what the word means (out-of-vocab or rare) so it
            // ranks something else high based on shape/recency, giving
            // an inflated "confidence" spread that's not about
            // correctness. Without this bypass, the gate kills BM25
            // exactly when BM25 is the right signal, and imported-
            // document content becomes unfindable by its distinctive
            // terms. Threshold 1.5 derived from observed BM25 scores:
            // distinctive single-token matches in our corpus score
            // 2.5-3.0; common-word matches score 0.5-1.2. 1.5 cleanly
            // separates them.
            let bm25DistinctiveThreshold: Double = 1.5
            let bm25Top1 = bm25Scores.first ?? 0
            let bm25HasStrongMatch = bm25Top1 >= bm25DistinctiveThreshold
            // Hoist out for RRF weighting (Bug 2a follow-up): when BM25 is
            // matching distinctive tokens, its rank-1 should dominate RRF.
            bm25Distinctive = bm25HasStrongMatch
            let applyGate = semanticRelativeSpread >= semanticConfidenceThreshold && !bm25HasStrongMatch
            if !applyGate {
                if bm25HasStrongMatch {
                    halLog("HALDEBUG-SEARCH: BM25 quality gate SKIPPED — BM25 top-1 score \(String(format: "%.2f", bm25Top1)) >= \(bm25DistinctiveThreshold); distinctive lexical match dominates, trusting BM25.")
                } else {
                    halLog("HALDEBUG-SEARCH: BM25 quality gate SKIPPED — semantic relative spread \(semSpreadStr) < \(semanticConfidenceThreshold); semantic is in a narrow band (embedder uncertain), letting BM25 carry retrieval.")
                }
            }
            if applyGate, !bm25Ordered.isEmpty {
                let k = min(5, bm25Ordered.count)
                let bm25TopK = bm25Ordered.prefix(k)
                let semanticRanksOfBM25TopK = bm25TopK.compactMap { semanticRanks[$0] }
                // If most of BM25's top-K aren't in semantic AT ALL, the
                // two retrievers are working on different universes — noise.
                let agreementCount = semanticRanksOfBM25TopK.count
                if agreementCount == 0 {
                    let top1Str = bm25Scores.first.map { String(format: "%.2f", $0) } ?? "?"
                    halLog("HALDEBUG-SEARCH: BM25 quality gate FAILED — none of BM25's top-\(k) (top-1 score=\(top1Str)) appear in semantic's top-50; excluding BM25 from RRF.")
                    bm25Ordered = []
                } else {
                    // Compute median semantic rank of agreement set. If
                    // median is in semantic's top-k (mirroring BM25's k),
                    // both retrievers agree on the front of the list →
                    // include. Otherwise BM25's distinctive matches are
                    // for rows semantic considers fringe → exclude.
                    let sorted = semanticRanksOfBM25TopK.sorted()
                    let median = sorted[sorted.count / 2]
                    if median <= k {
                        halLog("HALDEBUG-SEARCH: BM25 quality gate PASSED — BM25 top-\(k) has \(agreementCount)/\(k) entries in semantic with median rank \(median) ≤ \(k); both retrievers agree on the front of the list. Including BM25 in RRF.")
                    } else {
                        let top1Str = bm25Scores.first.map { String(format: "%.2f", $0) } ?? "?"
                        halLog("HALDEBUG-SEARCH: BM25 quality gate FAILED — BM25 top-\(k) (top-1 score=\(top1Str)) has median semantic rank \(median) > \(k); BM25 is finding distinctive matches that semantic doesn't share. Excluding BM25 from RRF.")
                        bm25Ordered = []
                    }
                }
            }
        } else {
            let err = String(cString: sqlite3_errmsg(db))
            halLog("HALDEBUG-SEARCH: FTS5 BM25 prepare failed: \(err)")
        }
        sqlite3_finalize(bm25Stmt)

        for (i, rowId) in bm25Ordered.enumerated() {
            bm25Ranks[rowId] = i + 1
        }

        // --- 3. RRF fusion ---
        // rrf(d) = sum over retrievers L of 1 / (k + rank_L(d))
        // Default k=60 (canonical). When BM25 has a distinctive lexical
        // top-1 (e.g. unique imported-document term), give BM25 a smaller k
        // so its rank-1 dominates. Without this, BM25's confident match
        // gets RRF'd to rank-2 behind a semantically-adjacent conversation
        // snippet — exactly the Bug 2a failure mode where imported docs
        // show up below conversation echoes of their own content.
        // Fusion weights are the live tunable knobs (defaults 15/10/60 —
        // distinctive keyword > semantic > generic keyword). See the @AppStorage
        // declarations in this class for how the defaults were chosen.
        let rrfKSemantic: Double = self.rrfKSemantic
        let rrfKBM25: Double = bm25Distinctive ? rrfKBM25Distinctive : rrfKBM25Default
        var rrfScored: [(id: String, score: Double, inSemantic: Bool, inBM25: Bool)] = []
        let unionIds = Set(semanticRanks.keys).union(Set(bm25Ranks.keys))
        for rowId in unionIds {
            var rrf = 0.0
            let sRank = semanticRanks[rowId]
            let bRank = bm25Ranks[rowId]
            if let r = sRank { rrf += 1.0 / (rrfKSemantic + Double(r)) }
            if let r = bRank { rrf += 1.0 / (rrfKBM25 + Double(r)) }

            // Recency re-entry into the live ranking. The half-life decay
            // score (calculateRecencyScore ∈ [recencyFloor, 1.0]) is blended
            // into the fused rank score, mixed by recencyWeight:
            //   factor = (1 - recencyWeight) + recencyWeight * recency
            // recencyWeight == 0 → factor == 1 (exact rank-only RRF, a true
            // no-op); recencyWeight == 1 → full multiply by the decay. So a
            // more-recent row with equal semantic+BM25 rank sorts above an
            // older one, while an old row still keeps (1-w)+w·floor of its
            // score (a nudge, not a hard recency sort). This restores the
            // recencyWeight / recencyHalfLifeDays / recencyFloor settings to
            // an actual effect on retrieval order — they had been feeding
            // calculateRecencyScore, which no retrieval path called, so the
            // sliders were inert. The `> 0` guard keeps the disabled case
            // byte-identical to pure rank fusion.
            if recencyWeight > 0, let slot = slotById[rowId] {
                let recency = calculateRecencyScore(timestamp: slot.timestamp)
                rrf *= (1.0 - recencyWeight) + recencyWeight * recency
            }

            rrfScored.append((rowId, rrf, sRank != nil, bRank != nil))
        }
        rrfScored.sort { $0.score > $1.score }
        halLog("HALDEBUG-SEARCH: RRF fused \(unionIds.count) unique rows (\(semanticRanks.count) semantic + \(bm25Ranks.count) BM25, kSem=\(Int(rrfKSemantic)) kBM25=\(Int(rrfKBM25))\(bm25Distinctive ? " [distinctive BM25 boost]" : ""), recencyW=\(String(format: "%.2f", recencyWeight)) halfLife=\(Int(recencyHalfLifeDays))d floor=\(String(format: "%.2f", recencyFloor)))")

        // --- 4. Build UnifiedSearchResult list from RRF order ---
        var allResults: [UnifiedSearchResult] = []
        var totalTokens = 0
        for fused in rrfScored {
            guard let slot = slotById[fused.id] else { continue }
            let ageLabel = formatAgeLabel(timestamp: slot.timestamp)
            let labeledContent = "[\(ageLabel)]: \(slot.content)"
            allResults.append(UnifiedSearchResult(
                content: labeledContent,
                relevance: fused.score,
                source: slot.sourceType,
                isEntityMatch: fused.inBM25,  // tagged "entity" if BM25 contributed
                filePath: slot.filePath
            ))
        }

        // --- 4. Build RAGSnippet Objects with Full Metadata ---
        var ragSnippets: [RAGSnippet] = []
        
        // Need to re-query to get timestamps for each result
        // Create a map of content -> timestamp by re-scanning results
        var contentTimestampMap: [String: Date] = [:]
        
        // v2.1 step 2: cover ALL rows (this is just a content→timestamp lookup
        // for attaching timestamps to already-retrieved snippets). The old
        // `embedding IS NOT NULL` filter would miss rows retrieved via BM25 whose
        // active-backend column isn't filled yet, dropping their timestamp label.
        let timestampSQL = """
        SELECT content, timestamp
        FROM unified_content;
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

        // Honor BOTH the snippet count cap (maxResults) and token budget. Until
        // this fix, maxResults was a pass-through parameter that this function
        // silently ignored — callers asking for 10 snippets could get 59 if the
        // token budget allowed it, which tripled prompt-prefill cost on every
        // turn. The cap is applied here, after the relevance-sort above, so we
        // keep the top-N strongest matches rather than the first N scanned.
        let cappedResults = Array(allResults.prefix(maxResults))
        if allResults.count > maxResults {
            halLog("HALDEBUG-SEARCH: Capped to top \(maxResults) of \(allResults.count) candidate matches before token-budget pass")
        }
        if let first = cappedResults.first {
            halLog("HALDEBUG-SEARCH: Top candidate — score=\(String(format: "%.4f", first.relevance)), entity=\(first.isEntityMatch), contentLen=\(first.content.count) chars, preview='\(first.content.prefix(80))'")
        }
        for result in cappedResults {
            // Estimate tokens for this snippet
            let snippetTokens = TokenEstimator.estimateTokens(from: result.content)

            // If THIS snippet alone is larger than the entire budget, skip
            // it (no point in trying) and move on — there may be smaller
            // snippets later in the list that DO fit. The prior behavior
            // (break) lost ALL retrieval if the top-ranked snippet was a
            // big document.
            if snippetTokens > tokenBudget {
                halLog("HALDEBUG-SEARCH: Snippet \(snippetTokens) tokens > budget \(tokenBudget); skipping and trying next candidate")
                continue
            }

            // Stop adding if THIS snippet would push the running total over budget
            if totalTokens + snippetTokens > tokenBudget {
                halLog("HALDEBUG-SEARCH: Token budget reached. Stopping at \(totalTokens) tokens.")
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

    // MARK: - Diagnostic API helpers (RAG investigation, 2026-05-16)
    //
    // Two read-side methods used by the LocalAPIServer's MEMORY_DUMP and
    // MEMORY_SEARCH_DEBUG commands to inspect the RAG pipeline during
    // diagnosis of the planted-fact-recall regression.
    //
    // `debugDumpRecentUnifiedContent` lists the most recent rows in
    // `unified_content` with whether each has an embedding stored. Use to
    // verify (a) write-side stored the planted turn, (b) the embedding
    // BLOB is present and non-empty, (c) source_type / position / turn
    // metadata is correct.
    //
    // `debugSearchUnifiedContent` runs the same `searchUnifiedContent`
    // path the chat pipeline uses and returns the snippets along with the
    // similarity scores. Use to verify (a) search retrieves the planted
    // turn for a paraphrased query, (b) the score is above the relevance
    // threshold, (c) what content the model actually receives.
    //
    // Both return JSON strings for direct embedding in the API response.

    /// Read-only diagnostic for the RAG threshold-tuning evaluation
    /// (2026-05-17). Writes a realistic, varied conversational corpus to
    /// `unified_content` so we can measure how the relevance threshold
    /// behaves against a populated database — not just the 6-row trivial
    /// case we used initially. The corpus mirrors what a real user's
    /// database might look like after weeks of varied conversation:
    /// short turns mixed with long, personal facts mixed with chatty
    /// discussion, varied topics. The first 10 entries are PLANTED facts
    /// that the evaluation harness will run recall queries against; the
    /// remainder is general background content that should NOT match
    /// those queries (and lets us see how noise scores in the presence
    /// of real facts).
    @discardableResult
    func injectRealisticTestCorpus() -> Int {
        guard ensureHealthyConnection() else { return 0 }

        // The conversation ID is shared across all injected rows so a
        // single NUCLEAR_RESET later wipes them. Distinct from any real
        // user conversation.
        let conversationId = "test-corpus-\(UUID().uuidString.prefix(8))"

        // 10 planted (user, assistant) pairs. The user message is the
        // "plant" — the natural language statement of a fact. The
        // assistant restatement is what Hal would have said back. The
        // evaluation harness queries against natural-language recall
        // phrasings that do NOT echo the plant text directly.
        let planted: [(String, String)] = [
            ("My dog's name is Pepper. She's a six-year-old border collie who loves swimming.",
             "Pepper the border collie, six years old, swimmer. Got it."),
            ("I work as a software engineer at a startup called Anthropic, on the Claude team.",
             "Anthropic, Claude team, software engineer. Noted."),
            ("My favorite restaurant is Tartine in San Francisco. I go for the morning bun.",
             "Tartine in SF, you love the morning bun. Will remember."),
            ("I'm taking a trip to Iceland in September with my partner Sarah.",
             "Iceland trip in September with Sarah. Logged."),
            ("My wife and I just bought a house in Berkeley, on Vine Street near the rose garden.",
             "House in Berkeley on Vine Street near the rose garden. Congrats!"),
            ("I started taking cello lessons six months ago and I'm working through the Bach suites.",
             "Cello, six months in, Bach suites. Got it."),
            ("My favorite book is The Brothers Karamazov by Dostoevsky.",
             "The Brothers Karamazov by Dostoevsky as your favorite. Noted."),
            ("My cat is named Atlas. He's an orange tabby, seven years old, mostly sleeps on the bookshelf.",
             "Atlas the orange tabby, seven, lives on the bookshelf. Will remember."),
            ("I run an annual half marathon every March in Oakland.",
             "Annual half marathon in Oakland every March. Noted."),
            ("I drive a 2018 Subaru Outback in dark blue. Manual transmission.",
             "2018 Subaru Outback, dark blue, manual. Got it.")
        ]

        // 50 general conversation turns spanning varied topics. Mix of
        // user statements, questions, and assistant responses. None of
        // these should match the 10 recall queries (used to measure
        // false-positive rate).
        let general: [(String, Bool)] = [
            ("How's the weather looking for the weekend?", true),
            ("Currently sunny and mid-60s in your area through Saturday, clouds rolling in Sunday afternoon.", false),
            ("Can you help me brainstorm a name for a new project?", true),
            ("Sure. Tell me a bit about what the project does and the vibe you're going for.", false),
            ("What's the deal with quantum entanglement in simple terms?", true),
            ("Two particles linked so that measuring one instantly tells you something about the other, regardless of distance. Einstein called it spooky action at a distance.", false),
            ("I've been thinking about getting into woodworking.", true),
            ("That's a great hobby — what kind of projects are you imagining? Furniture, small carving, turning?", false),
            ("Pour-over coffee technique tips please.", true),
            ("Bloom for 30 seconds with twice the coffee weight in water, then pour in slow concentric circles, total brew time around 3 to 4 minutes.", false),
            ("Can you summarize the plot of Crime and Punishment?", true),
            ("A poor ex-student murders a pawnbroker to test his theory of being above ordinary morality, then spends the rest of the novel unraveling under guilt until he confesses.", false),
            ("What's a good intro programming language for a kid?", true),
            ("Python is the most common pick — readable syntax, immediate feedback, lots of beginner resources. Scratch first if they're younger than ten.", false),
            ("How do I deal with imposter syndrome at work?", true),
            ("Recognize that the feeling persists even with success, talk to peers who've felt it, document your wins so you can review them when the doubt spikes.", false),
            ("Is sourdough really that much better than regular bread?", true),
            ("It's different more than strictly better — longer fermentation gives it more complex flavor and may be easier on digestion, but a good baguette is still a good baguette.", false),
            ("Recommend me a podcast about history.", true),
            ("Hardcore History by Dan Carlin if you want long-form deep dives. Revolutions by Mike Duncan if you want narrative arcs.", false),
            ("What's the best way to learn a new language as an adult?", true),
            ("Daily exposure beats occasional intensity. Comprehensible input — content you can mostly follow — plus speaking practice with a tutor or partner.", false),
            ("Thinking about getting a standing desk.", true),
            ("Mixed evidence on standing desks — the win is the ability to alternate. A fixed-height standing desk often just trades one fatigue for another.", false),
            ("How do compilers work, roughly?", true),
            ("Source code goes through lexing, parsing into a tree, semantic analysis, then optimization passes, and finally code generation into the target machine code or bytecode.", false),
            ("What's a fun easy recipe for a weeknight?", true),
            ("Sheet-pan chicken with potatoes and a vegetable, single tray, 425 for about 35 minutes. Toss everything with olive oil and salt before it goes in.", false),
            ("I've been having trouble sleeping lately.", true),
            ("Common factors are caffeine timing, screen exposure late at night, and inconsistent wake times. Fixing wake time first is usually the highest leverage move.", false),
            ("Tell me about the Pacific Crest Trail.", true),
            ("2,650 miles from Mexico to Canada through California, Oregon, and Washington. Most thru-hikers take 4 to 6 months northbound.", false),
            ("What's the deal with sourdough starter?", true),
            ("It's flour and water fermenting wild yeast and bacteria from the air. Feed it regularly, keep it warm, and it becomes your leaven instead of commercial yeast.", false),
            ("Can you explain what an API is to a non-programmer?", true),
            ("Think of a restaurant menu — you don't see the kitchen, you just order from the menu and the kitchen handles the details. An API is the menu between two pieces of software.", false),
            ("Best practice for naming git branches?", true),
            ("Conventions vary by team but type/short-description works well, like feature/checkout-redesign or fix/login-redirect. Keep them short and grep-friendly.", false),
            ("What's the difference between espresso and a regular coffee?", true),
            ("Espresso forces hot water under pressure through finely ground coffee in about 25 to 30 seconds. Drip coffee uses gravity through a coarser grind over a few minutes.", false),
            ("Suggest a documentary worth watching.", true),
            ("The Up Series follows the same group of British children from age 7 into their 60s, one film every 7 years. Unlike anything else.", false),
            ("How do passwords actually get stored?", true),
            ("Modern systems store a cryptographic hash of the password with a per-user salt, not the password itself. When you log in, the system hashes what you typed and compares.", false),
            ("What's a reasonable savings rate to aim for?", true),
            ("Common targets are 15 to 20 percent of gross income toward retirement, with separate buffers for short-term goals and emergency reserves.", false),
            ("How do I keep cilantro fresh longer?", true),
            ("Trim the stems, stand them in a glass of water like flowers, loosely cover the leaves with a bag, and refrigerate. Keeps about two weeks.", false),
            ("Tell me about the difference between deciduous and evergreen.", true),
            ("Deciduous trees drop their leaves seasonally, usually fall; evergreens retain foliage year-round and shed continuously. Both are adaptations to climate.", false)
        ]

        var position = 0
        var count = 0
        let now = Date()

        // Proposal B (2026-05-17): populate entity_keywords via
        // extractNamedEntities so the test corpus matches the real chat-store
        // flow (Hal.swift around line 1590). Without this, all 70 rows have
        // empty entity_keywords and BM25 is denied the entity-shape signal
        // it gets in production. The eval previously understated BM25's
        // real-world contribution.
        //
        // Pair convention mirrors storeTurn: combined entities from both
        // halves of a (user, assistant) turn are written to both rows.
        // For the `general` array we pair adjacent (i, i+1) since it
        // alternates user-question / assistant-answer in order.
        for (user, asst) in planted {
            let turnNumber = position / 2 + 1
            let userEntities = extractNamedEntities(from: user)
            let assistantEntities = extractNamedEntities(from: asst)
            let combinedKeywords = (userEntities + assistantEntities)
                .map { $0.text.lowercased() }
                .joined(separator: " ")
            _ = storeUnifiedContentWithEntities(
                content: user, sourceType: .conversation, sourceId: conversationId,
                position: position, timestamp: now, isFromUser: true,
                entityKeywords: combinedKeywords, metadataJson: "{}", recordedByModel: nil,
                deviceType: nil, turnNumber: turnNumber, deliberationRound: nil, seatNumber: nil)
            position += 1
            count += 1
            _ = storeUnifiedContentWithEntities(
                content: asst, sourceType: .conversation, sourceId: conversationId,
                position: position, timestamp: now, isFromUser: false,
                entityKeywords: combinedKeywords, metadataJson: "{}", recordedByModel: "test-corpus",
                deviceType: nil, turnNumber: turnNumber, deliberationRound: nil, seatNumber: nil)
            position += 1
            count += 1
        }

        // Pair the general array two-at-a-time. The array is constructed
        // as alternating (user-question, assistant-answer) so adjacent
        // entries form a turn.
        var generalIndex = 0
        while generalIndex < general.count {
            let (userText, userIsFromUser) = general[generalIndex]
            let hasPair = generalIndex + 1 < general.count
            let pairText = hasPair ? general[generalIndex + 1].0 : ""
            let userEntities = extractNamedEntities(from: userText)
            let assistantEntities = hasPair ? extractNamedEntities(from: pairText) : []
            let combinedKeywords = (userEntities + assistantEntities)
                .map { $0.text.lowercased() }
                .joined(separator: " ")

            let turnNumberA = position / 2 + 1
            _ = storeUnifiedContentWithEntities(
                content: userText, sourceType: .conversation, sourceId: conversationId,
                position: position, timestamp: now, isFromUser: userIsFromUser,
                entityKeywords: combinedKeywords, metadataJson: "{}",
                recordedByModel: userIsFromUser ? nil : "test-corpus",
                deviceType: nil, turnNumber: turnNumberA, deliberationRound: nil, seatNumber: nil)
            position += 1
            count += 1

            if hasPair {
                let (asstText, asstIsFromUser) = general[generalIndex + 1]
                let turnNumberB = position / 2 + 1
                _ = storeUnifiedContentWithEntities(
                    content: asstText, sourceType: .conversation, sourceId: conversationId,
                    position: position, timestamp: now, isFromUser: asstIsFromUser,
                    entityKeywords: combinedKeywords, metadataJson: "{}",
                    recordedByModel: asstIsFromUser ? nil : "test-corpus",
                    deviceType: nil, turnNumber: turnNumberB, deliberationRound: nil, seatNumber: nil)
                position += 1
                count += 1
            }
            generalIndex += 2
        }

        halLog("HALDEBUG-TESTCONSOLE: INJECT_REALISTIC_TEST_CORPUS — injected \(count) rows into conversation \(conversationId)")
        return count
    }

    /// Local JSON-string escape (the LocalAPIServer's `jsonStringEscape`
    /// is fileprivate; we mirror it here so MemoryStore can produce
    /// API-safe response strings without coupling to that scope).
    private func dbgEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Read-only diagnostic: return the most recent `limit` rows of
    /// `unified_content` as a JSON array. Each entry includes a content
    /// preview, the embedding length (0 if missing), and the key metadata
    /// fields. Used to verify write-side stored the planted turn with an
    /// Read-only audit of the self_knowledge table for diagnostic /
    /// pre-Phase-3 sanity checks. Returns row counts by format, by
    /// category, by shareable status, and a distribution of
    /// reinforcement_count buckets (so we can see at a glance whether
    /// any reflections are eligible for the Phase 2 crystallizer).
    /// Also returns the most recent N sample entries with the fields
    /// most relevant for diagnosis. Added 2026-05-18 before Phase 3
    /// to inspect what testing/development built up in the corpus.
    func debugSelfKnowledgeAudit(sampleLimit: Int = 20) -> String {
        guard ensureHealthyConnection() else {
            return "{\"status\":\"error\",\"message\":\"no DB\"}"
        }

        // Total row count (including soft-deleted, so we know if anything's there at all).
        func scalarInt(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            bind?(stmt)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
        }
        let totalAll = scalarInt("SELECT count(*) FROM self_knowledge;")
        let totalLive = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL;")
        let totalDeleted = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NOT NULL;")

        // By format.
        var byFormat: [(String, Int)] = []
        do {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT format, count(*) FROM self_knowledge WHERE deleted_at IS NULL GROUP BY format ORDER BY count(*) DESC;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let fmt = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let n = Int(sqlite3_column_int(stmt, 1))
                    byFormat.append((fmt, n))
                }
            }
        }

        // By category.
        var byCategory: [(String, Int)] = []
        do {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT category, count(*) FROM self_knowledge WHERE deleted_at IS NULL GROUP BY category ORDER BY count(*) DESC;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let cat = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let n = Int(sqlite3_column_int(stmt, 1))
                    byCategory.append((cat, n))
                }
            }
        }

        // Shareable distribution (0 / 1 / NULL).
        let shareableNull = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND shareable IS NULL;")
        let shareableZero = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND shareable = 0;")
        let shareableOne = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND shareable = 1;")

        // Reinforcement-count buckets — critical for Phase 2 sanity.
        let rc1 = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND reinforcement_count = 1;")
        let rc2 = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND reinforcement_count = 2;")
        let rc3 = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND reinforcement_count = 3;")
        let rc4plus = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND reinforcement_count >= 4;")

        // Promotion lineage stats: reflections that have been promoted vs not.
        let reflectionsPromoted = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND format = 'raw_reflection' AND promoted_to_trait_id IS NOT NULL;")
        let reflectionsUnpromoted = scalarInt("SELECT count(*) FROM self_knowledge WHERE deleted_at IS NULL AND format = 'raw_reflection' AND promoted_to_trait_id IS NULL;")

        // Sample entries — recent first, condensed.
        var samples: [String] = []
        do {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, format, category, key, value, confidence, reinforcement_count, shareable, promoted_to_trait_id, created_at FROM self_knowledge WHERE deleted_at IS NULL ORDER BY created_at DESC LIMIT ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(sampleLimit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = (sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "").prefix(8)
                    let fmt = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let cat = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let key = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                    let val = (sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "").prefix(160)
                    let conf = sqlite3_column_double(stmt, 5)
                    let rc = Int(sqlite3_column_int(stmt, 6))
                    // shareable column may be NULL; distinguish from 0.
                    let shareable: String
                    if sqlite3_column_type(stmt, 7) == SQLITE_NULL {
                        shareable = "null"
                    } else {
                        shareable = "\(sqlite3_column_int(stmt, 7))"
                    }
                    let promotedTo = (sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "").prefix(8)
                    let created = Int(sqlite3_column_int64(stmt, 9))
                    let escVal = String(val).replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
                    let escKey = key.replacingOccurrences(of: "\"", with: "\\\"")
                    samples.append("{\"id\":\"\(id)\",\"format\":\"\(fmt)\",\"category\":\"\(cat)\",\"key\":\"\(escKey)\",\"value\":\"\(escVal)\",\"confidence\":\(conf),\"reinforcement_count\":\(rc),\"shareable\":\"\(shareable)\",\"promoted_to_trait_id\":\"\(promotedTo)\",\"created_at\":\(created)}")
                }
            }
        }

        // Serialize the breakdown arrays as JSON objects.
        let byFormatJSON = byFormat.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        let byCategoryJSON = byCategory.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")

        return """
        {"status":"ok","totalAll":\(totalAll),"totalLive":\(totalLive),"totalDeleted":\(totalDeleted),"byFormat":{\(byFormatJSON)},"byCategory":{\(byCategoryJSON)},"shareable":{"null":\(shareableNull),"zero":\(shareableZero),"one":\(shareableOne)},"reinforcementCount":{"1":\(rc1),"2":\(rc2),"3":\(rc3),"4+":\(rc4plus)},"reflections":{"promoted":\(reflectionsPromoted),"unpromoted":\(reflectionsUnpromoted)},"samples":[\(samples.joined(separator: ","))]}
        """
    }

    /// Read-only schema dump for any table via `PRAGMA table_info()`.
    /// Returns the column list as JSON so API callers can verify a schema
    /// migration landed (e.g. checking that `promoted_to_trait_id` exists
    /// on `self_knowledge` after the 2026-05-18 v1 crystallization
    /// migration). Quoting the table name defends against accidental
    /// special characters; PRAGMA itself does NOT accept bound parameters,
    /// hence the manual quote-and-escape.
    func debugSchemaForTable(_ table: String) -> String {
        guard ensureHealthyConnection() else {
            return "{\"status\":\"error\",\"message\":\"no DB\"}"
        }
        // SQLite identifier quoting: double-quote and escape any embedded
        // double-quotes. Defensive even though the typical caller passes
        // a known table name.
        let safeName = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        let sql = "PRAGMA table_info(\(safeName));"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            let escErr = err.replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"status\":\"error\",\"message\":\"\(escErr)\"}"
        }
        var columns: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA table_info column layout: cid, name, type, notnull, dflt_value, pk.
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let notnull = sqlite3_column_int(stmt, 3)
            let dflt = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let pk = sqlite3_column_int(stmt, 5)
            let escName = name.replacingOccurrences(of: "\"", with: "\\\"")
            let escType = type.replacingOccurrences(of: "\"", with: "\\\"")
            let escDflt = dflt.replacingOccurrences(of: "\"", with: "\\\"")
            columns.append("{\"name\":\"\(escName)\",\"type\":\"\(escType)\",\"notnull\":\(notnull),\"dflt\":\"\(escDflt)\",\"pk\":\(pk)}")
        }
        let escTable = table.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"status\":\"ok\",\"table\":\"\(escTable)\",\"columnCount\":\(columns.count),\"columns\":[\(columns.joined(separator: ","))]}"
    }

    /// embedding attached.
    /// FTS5 diagnostic: row counts, sample MATCH, schema. Added
    /// 2026-05-17 afternoon to investigate "BM25 returns 0 candidates"
    /// regression on the iPhone after the morning's commits.
    func debugFTSDiagnostic() -> String {
        guard ensureHealthyConnection() else {
            return "{\"status\":\"error\",\"message\":\"no DB\"}"
        }
        func count(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
        }
        let unifiedCount = count("SELECT count(*) FROM unified_content;")
        let ftsCount = count("SELECT count(*) FROM unified_content_fts;")
        let subaruMatches = count("SELECT count(*) FROM unified_content_fts WHERE unified_content_fts MATCH 'subaru';")
        let doMatches = count("SELECT count(*) FROM unified_content_fts WHERE unified_content_fts MATCH 'do';")
        // Test the same JOIN the search code uses to see if rowids align.
        let joinMatches = count("SELECT count(*) FROM unified_content_fts JOIN unified_content u ON u.rowid = unified_content_fts.rowid WHERE unified_content_fts MATCH 'subaru';")
        // Sample rowids from both
        var sampleFTSRowids: [Int] = []
        var sampleUnifiedRowids: [Int] = []
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT rowid FROM unified_content_fts WHERE unified_content_fts MATCH 'subaru' LIMIT 5;", -1, &stmt2, nil) == SQLITE_OK {
            while sqlite3_step(stmt2) == SQLITE_ROW { sampleFTSRowids.append(Int(sqlite3_column_int(stmt2, 0))) }
        }
        sqlite3_finalize(stmt2)
        if sqlite3_prepare_v2(db, "SELECT rowid FROM unified_content WHERE content LIKE '%Subaru%' LIMIT 5;", -1, &stmt2, nil) == SQLITE_OK {
            while sqlite3_step(stmt2) == SQLITE_ROW { sampleUnifiedRowids.append(Int(sqlite3_column_int(stmt2, 0))) }
        }
        sqlite3_finalize(stmt2)
        // Schema check
        var schema = ""
        var schemaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE name = 'unified_content_fts';", -1, &schemaStmt, nil) == SQLITE_OK {
            if sqlite3_step(schemaStmt) == SQLITE_ROW, let s = sqlite3_column_text(schemaStmt, 0) {
                schema = String(cString: s)
            }
        }
        sqlite3_finalize(schemaStmt)
        // Trigger check
        var triggers = ""
        var trigStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='unified_content';", -1, &trigStmt, nil) == SQLITE_OK {
            var names: [String] = []
            while sqlite3_step(trigStmt) == SQLITE_ROW {
                if let s = sqlite3_column_text(trigStmt, 0) {
                    names.append(String(cString: s))
                }
            }
            triggers = names.joined(separator: ",")
        }
        sqlite3_finalize(trigStmt)
        // Inline escape (avoid hopping to MainActor for dbgEscape).
        let escSchema = schema
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let escTriggers = triggers
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let ftsRowidStr = sampleFTSRowids.map(String.init).joined(separator: ",")
        let unifiedRowidStr = sampleUnifiedRowids.map(String.init).joined(separator: ",")

        // Replicate the EXACT BM25 query the search code runs.
        // sanitized = "subaru" (one token, lowercased, alphanumerics-only).
        // exclusionClause = "" (empty corpus has no excludeTurns).
        // bm25ExclusionClause = "" after replacements.
        // Full SQL:
        let exactBM25SQL = """
        SELECT u.id, u.content, u.source_type, u.source_id, u.position, u.metadata_json, u.timestamp, u.recorded_by_model,
               -bm25(unified_content_fts) AS bm25_score
        FROM unified_content_fts
        JOIN unified_content u ON u.rowid = unified_content_fts.rowid
        WHERE unified_content_fts MATCH ?
              AND u.source_type != 'source_code'
        ORDER BY bm25_score DESC
        LIMIT 50;
        """
        var exactRows = 0
        var exactStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, exactBM25SQL, -1, &exactStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(exactStmt, 1, ("subaru" as NSString).utf8String, -1, nil)
            while sqlite3_step(exactStmt) == SQLITE_ROW { exactRows += 1 }
        }
        sqlite3_finalize(exactStmt)

        // Replicate the EXACT searchUnifiedContent path:
        // sanitizeFTSQuery("Subaru") => "subaru" (single token).
        // Then call into searchUnifiedContent itself, grab the rrf-fused
        // count of BM25 contributions.
        let sanitized = sanitizeFTSQuery("Subaru")
        var sanitizedRows = 0
        var sanitizedStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, exactBM25SQL, -1, &sanitizedStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(sanitizedStmt, 1, (sanitized as NSString).utf8String, -1, nil)
            while sqlite3_step(sanitizedStmt) == SQLITE_ROW { sanitizedRows += 1 }
        }
        sqlite3_finalize(sanitizedStmt)
        // Now call searchUnifiedContent the way debugSearchUnifiedContent does.
        let searchResult = searchUnifiedContent(for: "Subaru", currentConversationId: "", excludeTurns: [], maxResults: 20, tokenBudget: 4000)
        let bm25Count = searchResult.snippets.filter { $0.isEntityMatch }.count

        return """
        {"status":"ok","unifiedRows":\(unifiedCount),"ftsRows":\(ftsCount),"matchSubaru":\(subaruMatches),"matchDo":\(doMatches),"joinMatches":\(joinMatches),"exactBM25Rows":\(exactRows),"sanitizedRows":\(sanitizedRows),"sanitizedQuery":"\(sanitized)","searchSnippets":\(searchResult.snippets.count),"bm25SnippetsViaSearch":\(bm25Count),"ftsRowids":"\(ftsRowidStr)","unifiedRowids":"\(unifiedRowidStr)","schema":"\(escSchema)","triggers":"\(escTriggers)"}
        """
    }

    func debugDumpRecentUnifiedContent(limit: Int) -> String {
        guard ensureHealthyConnection() else {
            return "{\"status\":\"error\",\"message\":\"no database connection\"}"
        }
        let cappedLimit = max(1, min(limit, 200))
        let sql = """
        SELECT id, content, source_type, source_id, position, turn_number, is_from_user,
               recorded_by_model, length(embedding) AS embedding_bytes, timestamp, created_at,
               entity_keywords
        FROM unified_content
        ORDER BY created_at DESC, timestamp DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return "{\"status\":\"error\",\"message\":\"prepare failed\"}"
        }
        sqlite3_bind_int(stmt, 1, Int32(cappedLimit))

        var entries: [String] = []
        var totalRows = 0
        var rowsWithEmbedding = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            totalRows += 1
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let content = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let sourceType = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let sourceId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let position = Int(sqlite3_column_int(stmt, 4))
            let turnNumber = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? -1 : Int(sqlite3_column_int(stmt, 5))
            let isFromUser = sqlite3_column_int(stmt, 6) == 1
            let recordedByModel = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let embeddingBytes = Int(sqlite3_column_int(stmt, 8))
            let timestamp = sqlite3_column_int64(stmt, 9)
            let createdAt = sqlite3_column_int64(stmt, 10)
            let entityKeywords = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""

            let embeddingDoubles = embeddingBytes / 8  // each Double is 8 bytes
            if embeddingDoubles > 0 { rowsWithEmbedding += 1 }
            let contentPreview = String(content.prefix(200))

            let entry = """
            {"id":"\(id.prefix(8))","sourceType":"\(sourceType)","sourceId":"\(sourceId.prefix(8))","position":\(position),"turnNumber":\(turnNumber),"isFromUser":\(isFromUser),"recordedByModel":"\(dbgEscape(recordedByModel))","embeddingDoubles":\(embeddingDoubles),"contentLength":\(content.count),"contentPreview":"\(dbgEscape(contentPreview))","entityKeywords":"\(dbgEscape(entityKeywords))","timestamp":\(timestamp),"createdAt":\(createdAt)}
            """
            entries.append(entry)
        }

        return """
        {"status":"ok","totalRowsReturned":\(totalRows),"rowsWithEmbedding":\(rowsWithEmbedding),"limit":\(cappedLimit),"entries":[\(entries.joined(separator: ","))]}
        """
    }

    /// Read-only diagnostic: run the same semantic-+-keyword search the
    /// chat pipeline uses, return the resulting snippets with similarity
    /// scores. Defaults match the production search caller: no exclusion
    /// of recent turns, generous result count, generous token budget.
    /// Use to verify retrieval finds the planted fact for a paraphrased
    /// query and at what score.
    /// Read-only diagnostic: compute cosine similarity between the query
    /// embedding and every row in `unified_content` that has an embedding.
    /// Returns the raw scores WITHOUT recency boost or RRF fusion. Used to
    /// inspect the embedding model's behavior in isolation — see whether
    /// a plant turn is semantically close to a recall query.
    func debugSemanticSimilarity(query: String) -> String {
        guard ensureHealthyConnection() else {
            return "{\"status\":\"error\",\"message\":\"no database connection\"}"
        }
        let queryEmbedding = generateEmbedding(for: query, as: .query)
        guard !queryEmbedding.isEmpty else {
            return "{\"status\":\"error\",\"message\":\"empty query embedding\"}"
        }

        // v2.1 step 2: read the ACTIVE backend's per-backend column.
        let activeVectorColumn = EmbeddingBackend.current().vectorColumn
        let sql = """
        SELECT id, content, source_type, source_id, position, length(\(activeVectorColumn)) AS bytes, \(activeVectorColumn)
        FROM unified_content
        WHERE \(activeVectorColumn) IS NOT NULL
        ORDER BY created_at DESC, timestamp DESC
        LIMIT 500
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return "{\"status\":\"error\",\"message\":\"prepare failed\"}"
        }

        var entries: [(score: Double, id: String, sourceType: String, sourceId: String, position: Int, embeddingDoubles: Int, contentPreview: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let content = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let sourceType = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let sourceId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let position = Int(sqlite3_column_int(stmt, 4))
            let bytes = Int(sqlite3_column_int(stmt, 5))
            guard let blobPtr = sqlite3_column_blob(stmt, 6) else { continue }
            let blobData = Data(bytes: blobPtr, count: bytes)
            let storedEmbedding = blobData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Double] in
                Array(ptr.bindMemory(to: Double.self))
            }
            let similarity = cosineSimilarity(queryEmbedding, storedEmbedding)
            entries.append((similarity, id, sourceType, sourceId, position, storedEmbedding.count, String(content.prefix(120))))
        }
        // Sort descending by score so highest matches come first
        entries.sort { $0.score > $1.score }

        let entryStrs = entries.map { e in
            """
            {"score":\(String(format: "%.4f", e.score)),"id":"\(e.id.prefix(8))","sourceType":"\(e.sourceType)","sourceId":"\(e.sourceId.prefix(8))","position":\(e.position),"embeddingDoubles":\(e.embeddingDoubles),"contentPreview":"\(dbgEscape(e.contentPreview))"}
            """
        }

        return """
        {"status":"ok","query":"\(dbgEscape(query))","queryEmbeddingDoubles":\(queryEmbedding.count),"rowsScored":\(entries.count),"entries":[\(entryStrs.joined(separator: ","))]}
        """
    }

    func debugSearchUnifiedContent(query: String, currentConversationId: String) -> String {
        let result = searchUnifiedContent(
            for: query,
            currentConversationId: currentConversationId,
            excludeTurns: [],
            maxResults: 20,
            tokenBudget: 4000
        )
        var entries: [String] = []
        for snippet in result.snippets {
            let preview = String(snippet.content.prefix(200))
            let entry = """
            {"relevanceScore":\(String(format: "%.4f", snippet.relevanceScore)),"sourceType":"\(dbgEscape(snippet.sourceType.rawValue))","sourceName":"\(dbgEscape(snippet.sourceName))","isEntityMatch":\(snippet.isEntityMatch),"recordedByModel":"\(dbgEscape(snippet.recordedByModel ?? ""))","contentPreview":"\(dbgEscape(preview))","contentLength":\(snippet.content.count)}
            """
            entries.append(entry)
        }
        return """
        {"status":"ok","query":"\(dbgEscape(query))","conversationId":"\(dbgEscape(currentConversationId))","resultCount":\(result.snippets.count),"totalTokens":\(result.totalTokens),"recencyWeight":\(String(format: "%.3f", recencyWeight)),"entries":[\(entries.joined(separator: ","))]}
        """
    }

    /// Diagnostic: run the full two-pass search-with-expansion path the
    /// chat tool uses. First pass without expansion; if the trigger
    /// fires, asks the active LLM for related terms via QueryExpansion;
    /// second pass with those terms appended to the BM25 MATCH.
    /// Returns the same JSON shape as debugSearchUnifiedContent plus an
    /// `expansion` object describing what happened (terms used,
    /// triggered, whether the expansion improved the top-1 score).
    /// Added 2026-05-17 for measuring expansion against the eval corpus.
    func debugSearchUnifiedContentWithExpansion(
        query: String,
        currentConversationId: String,
        llmService: LLMService
    ) async -> String {
        let first = searchUnifiedContent(
            for: query,
            currentConversationId: currentConversationId,
            excludeTurns: [],
            maxResults: 20,
            tokenBudget: 4000
        )
        var triggered = false
        var terms: [String] = []
        var used: UnifiedSearchContext = first
        var improved = false
        if let top1 = first.snippets.first,
           QueryExpansion.shouldExpand(top1Score: top1.relevanceScore, top1IsEntityMatch: top1.isEntityMatch) {
            triggered = true
            terms = await QueryExpansion.expand(query: query, memoryStore: self, llmService: llmService)
            if !terms.isEmpty {
                let expanded = searchUnifiedContent(
                    for: query,
                    currentConversationId: currentConversationId,
                    excludeTurns: [],
                    maxResults: 20,
                    tokenBudget: 4000,
                    expansionTerms: terms
                )
                if let newTop = expanded.snippets.first, newTop.relevanceScore >= top1.relevanceScore {
                    used = expanded
                    improved = true
                }
            }
        }
        var entries: [String] = []
        for snippet in used.snippets {
            let preview = String(snippet.content.prefix(200))
            let entry = """
            {"relevanceScore":\(String(format: "%.4f", snippet.relevanceScore)),"sourceType":"\(dbgEscape(snippet.sourceType.rawValue))","sourceName":"\(dbgEscape(snippet.sourceName))","isEntityMatch":\(snippet.isEntityMatch),"recordedByModel":"\(dbgEscape(snippet.recordedByModel ?? ""))","contentPreview":"\(dbgEscape(preview))","contentLength":\(snippet.content.count)}
            """
            entries.append(entry)
        }
        let termsJson = "[" + terms.map { "\"\(dbgEscape($0))\"" }.joined(separator: ",") + "]"
        let expansion = "{\"triggered\":\(triggered),\"terms\":\(termsJson),\"improved\":\(improved)}"
        return """
        {"status":"ok","query":"\(dbgEscape(query))","conversationId":"\(dbgEscape(currentConversationId))","resultCount":\(used.snippets.count),"totalTokens":\(used.totalTokens),"recencyWeight":\(String(format: "%.3f", recencyWeight)),"expansion":\(expansion),"entries":[\(entries.joined(separator: ","))]}
        """
    }
}

// ==== LEGO END: 07 MemoryStore (Part 6 â€“ Search Functions with Full Metadata) ====



// ==== LEGO START: 07.5 HalModelLimits Configuration ====


// MARK: - Centralized Hal Model Limits Configuration
/// Single source of truth for all model-specific limits and configurations.
/// This prevents duplicate hardcoded values and ensures consistency across UI and logic.
/// Works with ModelConfiguration from Block 30 - no hardcoded model types.
///
/// ───────────────────────────────────────────────────────────────────────────
/// CONTEXT WINDOW ALLOCATION MATH (2026-05-16 — fixed per SC architecture pass)
/// ───────────────────────────────────────────────────────────────────────────
///
/// Each model's context window is divided into four budget categories.
/// Allocations sum to 97% — leaving a 3% safety buffer for tokenizer
/// discrepancies and edge cases. This replaces the prior allocation that
/// summed to 107% (30 response + 15 RAG + 12 short-term + 50% floor on
/// prompt), which created active overflow on AFM (4K context window) and
/// was the root cause of "Exceeded model context window size" errors.
///
///   Prompt (sys + Layer 1 + self-knowledge + temporal)   50%
///   Response reserve                                       20%
///   RAG retrieval                                          15%
///   Short-term history                                     12%
///   ─────────────────────────────────────────────────── ──────
///   Total                                                  97%
///   Safety buffer                                           3%
///
/// Concrete numbers per model:
///
///   ┌──────────────┬─────────┬─────────┬─────────┬─────────┬──────────┐
///   │ Model        │ Context │ Prompt  │ Resp    │  RAG    │ ShortT   │
///   ├──────────────┼─────────┼─────────┼─────────┼─────────┼──────────┤
///   │ AFM          │   4,096 │   2,048 │     820 │     614 │      491 │
///   │ Gemma 4 E2B  │ 128,000 │  65,536 │  26,214 │  19,661 │   15,729 │
///   │ Llama 3.2    │ 128,000 │  65,536 │  26,214 │  19,661 │   15,729 │
///   │ Dolphin 3.0  │ 128,000 │  65,536 │  26,214 │  19,661 │   15,729 │
///   │ Qwen 3.5 2B  │ 262,144 │ 131,072 │  52,429 │  39,322 │   31,457 │
///   └──────────────┴─────────┴─────────┴─────────┴─────────┴──────────┘
///
/// The PROMPT category is further subdivided at injection time:
///   - System prompt: hard cap (systemPromptHardCap = 1,000 tokens)
///   - Layer 1 framing: hard cap (layerOneFramingHardCap = 400 tokens)
///   - Self-knowledge: variable, compressed when over budget
///   - Temporal context: tiny (~50 tokens)
///
/// Hard caps are FIXED across all models (not percentage-scaled) because
/// they reflect UI affordances (how much a user reasonably types) and
/// CC-authored content (Layer 1), not model capacity.
///
/// Lowest currently-supported context: AFM 4K. If a future model has a
/// smaller window, revisit minimum guardrails. For now, pure percentages.
///
struct HalModelLimits {
    let contextWindowTokens: Int
    let maxPromptTokens: Int
    let responseReserveTokens: Int
    let maxRagTokens: Int
    let shortTermMemoryTokens: Int
    let longTermSnippetSummarizationThreshold: Int

    // MARK: - Hard caps (fixed across all models)
    //
    // These are not budget allocations against the context window — they
    // are UI / authoring constraints. The system prompt cap reflects what
    // a user can reasonably type into Settings. The Layer 1 cap reflects
    // what CC has authored. Both are checked at the static-segment level
    // and never compressed.

    /// Maximum allowed size of the user-editable system prompt, across all models.
    /// Enforced at the UI level (Settings → System Prompt editor) — input is rejected
    /// at this cap, never accepted-then-silently-trimmed.
    static let systemPromptHardCap: Int = 1_000

    /// Maximum allowed size of a per-model Layer 1 framing prompt.
    /// CC-authored. Overflow here is a build-time bug to be fixed before ship,
    /// not a runtime condition to handle.
    static let layerOneFramingHardCap: Int = 400

    // MARK: - Budget allocation (percentage-of-context)
    //
    // Documented allocations summing to 97%. The 3% safety buffer absorbs
    // tokenizer estimation drift without overrunning the actual context window.

    /// Percentage of context window reserved for the assembled prompt
    /// (system prompt + Layer 1 + self-knowledge + temporal + everything that
    /// goes into the conversation context that the model reads).
    static let promptAllocation: Double = 0.50

    /// Percentage of context window reserved for the model's response output.
    /// Must be large enough for meaningful answers even on small-context models.
    static let responseReserveAllocation: Double = 0.20

    /// Percentage of context window reserved for RAG retrieval content.
    static let ragAllocation: Double = 0.15

    /// Percentage of context window reserved for short-term recent-history
    /// content (verbatim turns).
    static let shortTermAllocation: Double = 0.12

    /// Total allocation as a fraction. Must be < 1.0 (we want a safety buffer).
    /// Verified at build time via the assertion in `config(for:)`.
    static let totalAllocation: Double =
        promptAllocation + responseReserveAllocation + ragAllocation + shortTermAllocation

    /// Dynamic configuration based on ModelConfiguration (from Block 30).
    /// Uses uniform percentages across all models: same identity, different
    /// capacity based on context size. No oversubscription floor — the prior
    /// `max(prompt, context/2)` floor caused AFM to allocate 107% of its
    /// context window, which was the root cause of "Exceeded model context
    /// window size" errors during turn assembly.
    static func config(for model: ModelConfiguration) -> HalModelLimits {
        // Compile-time correctness check: allocations must leave a safety buffer.
        // If this assertion fires, the static allocation constants above were
        // edited to sum to ≥ 1.0 — that's the bug we're explicitly defending
        // against. Fix the constants, don't disable the assertion.
        assert(totalAllocation < 1.0,
               "HalModelLimits allocations must sum to < 100%. Current sum: \(totalAllocation). Fix the per-segment percentages.")

        let context = model.contextWindow

        let maxPrompt        = Int(Double(context) * promptAllocation)
        let responseReserve  = Int(Double(context) * responseReserveAllocation)
        let maxRag           = Int(Double(context) * ragAllocation)
        let shortTermMemory  = Int(Double(context) * shortTermAllocation)

        // Threshold for compressing an individual RAG snippet (vs including
        // verbatim). Set to 5% of context window — small enough that snippets
        // routinely fit verbatim, large enough that a runaway snippet triggers
        // compression.
        let summarizationThreshold = context / 20

        return HalModelLimits(
            contextWindowTokens: context,
            maxPromptTokens: maxPrompt,
            responseReserveTokens: responseReserve,
            maxRagTokens: maxRag,
            shortTermMemoryTokens: shortTermMemory,
            longTermSnippetSummarizationThreshold: summarizationThreshold
        )
    }

    /// Convert tokens to approximate character count using TokenEstimator
    func tokensToChars(_ tokens: Int) -> Int {
        return TokenEstimator.estimateChars(from: tokens)
    }

    /// Convert character count to approximate tokens using TokenEstimator
    func charsToTokens(_ chars: Int) -> Int {
        let estimatedTokens = Double(chars) / 4.0
        return max(1, Int(estimatedTokens.rounded()))
    }
}


// ==== LEGO END: 07.5 HalModelLimits Configuration ====



// ==== LEGO START: 07.6 Prompt Segment Budgeting & Compression ====
//
// Implements the per-segment pre-flight check + compression architecture
// described in Docs/Context_Budget_Implementation_Plan_2026-05-16.md.
//
// The single architectural rule: before any prompt is sent to any model,
// every dynamic segment is evaluated against its budget allocation. If a
// segment is within budget, it passes through unchanged. If a segment
// exceeds budget, it is compressed (by the active model — never a
// different model) through TextSummarizer.summarizeWithVerification,
// then cached for reuse. Static segments (system prompt, Layer 1
// framing) have hard caps enforced earlier — overflow at those is
// either a CC build bug (Layer 1) or a UI bug (system prompt UI must
// reject input above the cap, see Phase 6a).
//
// Compression vs trimming: we deliberately do NOT silently drop content.
// Compression preserves intent within the model's constraints — Hal
// always gets the best possible representation of what he knows. The
// footer indicator (Phase 6b) makes this visible to the user.
//
// This block declares the types only. The compressor and cache live
// downstream (compressor calls into LLMService + TextSummarizer; cache
// lives in MemoryStore). The integration into the prompt-build path is
// Phase 7.

import CryptoKit

/// Identifies a segment of an assembled prompt. Each segment has its own
/// budget and its own treatment when over budget.
///
/// All cases are pure values — explicitly Sendable so the type is freely
/// usable from any actor or thread. The project-level
/// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor would otherwise make it
/// implicitly @MainActor.
enum PromptSegmentKind: String, CaseIterable, Codable, Sendable {
    /// Editable by the user in Settings. Hard cap enforced UI-side; overflow at
    /// runtime is a UI bug.
    case systemPrompt = "system_prompt"

    /// CC-authored per-model framing. Hard cap enforced at build time; overflow
    /// at runtime is a CC bug to fix before ship.
    case layerOneFraming = "layer_one_framing"

    /// Tiny (~50 tokens). Never compressed; not budgeted explicitly.
    case temporalContext = "temporal_context"

    /// Persistent self-knowledge entries injected into every turn. Unbounded
    /// in raw form, compressed when over budget. The largest unbounded
    /// component in the prompt and the original culprit of the AFM crash.
    case selfKnowledge = "self_knowledge"

    /// Auto-summary of older conversation history. Compressed when over budget.
    case autoSummary = "auto_summary"

    /// RAG retrieval results. Already capped at retrieval time, but assembled
    /// content may still exceed budget on small-context models.
    case ragRetrieval = "rag_retrieval"

    /// Recent verbatim conversation history. Compressed when over budget
    /// (rare — short-term is intentionally small).
    case shortTermHistory = "short_term_history"

    /// The user's current message. Hard cap enforced UI-side (in chat input);
    /// overflow at runtime surfaces a clear user-visible error rather than
    /// silently truncating.
    case userMessage = "user_message"

    /// True if this segment should be compressed when over budget.
    /// False segments use hard-cap enforcement (CC-side or UI-side).
    nonisolated var isCompressible: Bool {
        switch self {
        case .systemPrompt, .layerOneFraming, .temporalContext, .userMessage:
            return false
        case .selfKnowledge, .autoSummary, .ragRetrieval, .shortTermHistory:
            return true
        }
    }

    /// Human-readable label for HALDEBUG logs and the footer popover.
    nonisolated var displayName: String {
        switch self {
        case .systemPrompt:      return "System Prompt"
        case .layerOneFraming:   return "Model Framing"
        case .temporalContext:   return "Temporal Context"
        case .selfKnowledge:     return "Self-Knowledge"
        case .autoSummary:       return "Conversation Summary"
        case .ragRetrieval:      return "Retrieved Memories"
        case .shortTermHistory:  return "Recent History"
        case .userMessage:       return "Your Message"
        }
    }
}

/// A single segment of a prompt, with its raw content and its allocated budget.
/// The hash of raw content is the cache key (segment, model, hash) — when
/// raw content changes, the hash changes, and the cache automatically misses.
///
/// Sendable so it can be passed between actors. All fields are value types.
struct PromptSegment: Sendable {
    let kind: PromptSegmentKind
    let rawContent: String
    let budgetTokens: Int

    /// SHA-256 of `rawContent`, hex-encoded. Stable across launches and
    /// across devices. Empty content has a fixed empty-string hash.
    nonisolated var rawContentHash: String {
        let data = Data(rawContent.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Result of evaluating a segment against its budget.
enum PromptSegmentStatus: Sendable {
    /// Segment fits in its budget. Passes through unchanged.
    case withinBudget(actualTokens: Int)

    /// Segment exceeds budget and CAN be compressed. Caller should route
    /// to `SegmentCompressor`. Used for self-knowledge, summary, RAG,
    /// and short-term history.
    case overBudgetCompressible(actualTokens: Int, budgetTokens: Int)

    /// Segment exceeds budget but CANNOT be compressed (hard cap).
    /// For system prompt / user message this means the UI should have
    /// prevented this and we surface a clear error. For Layer 1 framing
    /// it means a CC build bug — log loudly and fall back to truncation.
    case overBudgetHardCap(actualTokens: Int, budgetTokens: Int)
}

/// One segment's pre-flight result.
struct PromptSegmentEvaluation: Sendable {
    let segment: PromptSegment
    let status: PromptSegmentStatus

    /// Convenience: are we under budget?
    nonisolated var isWithinBudget: Bool {
        if case .withinBudget = status { return true }
        return false
    }

    /// Convenience: do we need to compress?
    nonisolated var needsCompression: Bool {
        if case .overBudgetCompressible = status { return true }
        return false
    }
}

/// Stateless per-segment budget evaluator. Pure function on inputs.
/// Token estimation uses the existing TokenEstimator (chars / 4 conservative).
actor PromptBudgetEvaluator {

    /// Evaluate a list of segments against their budgets in a single pass.
    /// Returns one evaluation per segment, in the same order as input.
    static func evaluate(_ segments: [PromptSegment]) -> [PromptSegmentEvaluation] {
        return segments.map { evaluate($0) }
    }

    /// Evaluate a single segment.
    static func evaluate(_ segment: PromptSegment) -> PromptSegmentEvaluation {
        let actual = TokenEstimator.estimateTokens(from: segment.rawContent)
        let status: PromptSegmentStatus

        if actual <= segment.budgetTokens {
            status = .withinBudget(actualTokens: actual)
        } else if segment.kind.isCompressible {
            status = .overBudgetCompressible(actualTokens: actual,
                                             budgetTokens: segment.budgetTokens)
        } else {
            status = .overBudgetHardCap(actualTokens: actual,
                                        budgetTokens: segment.budgetTokens)
        }

        return PromptSegmentEvaluation(segment: segment, status: status)
    }
}

// MARK: - CompressedSegment + Cache Protocol

/// Result of compressing a single PromptSegment for a specific model.
/// Stored in the cache (Phase 5) so subsequent turns can reuse the work.
/// Top-level (not nested inside SegmentCompressor) so the cache protocol
/// and MemoryStore can reference it without actor-nested-type awkwardness.
struct CompressedSegment: Sendable {
    let kind: PromptSegmentKind
    let modelId: String
    let rawContentHash: String
    let compressedContent: String
    let targetTokens: Int
    let actualTokens: Int
    let createdAt: Date
    /// True if this was loaded from cache (no LLM work done this turn).
    /// False if freshly computed via SegmentCompressor.compress.
    let cacheHit: Bool
    /// True if intelligent compression failed and we fell back to raw
    /// truncation. Drives the "truncated" badge in the footer (Phase 6b).
    /// Triggers: LLM call returned empty, output exceeded target by >20%,
    /// or veracity checker rejected too many sentences.
    let truncated: Bool
}

/// The cache interface. MemoryStore conforms in Phase 5; the compressor
/// uses this protocol so we can swap implementations or skip caching
/// during tests without changing the compressor.
///
/// Both methods are nonisolated — the SegmentCompressor calls them from
/// an actor context, and the underlying implementation uses SQLite's own
/// thread-safety + sqlite3_finalize defer pattern. Without nonisolated,
/// the project-level SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor breaks
/// the cross-context calls.
protocol CompressedSegmentCache {
    /// Look up a previously-cached compression for (kind, model, content).
    /// Returns nil on cache miss.
    nonisolated func cachedCompression(
        segmentKind: PromptSegmentKind,
        modelId: String,
        rawContentHash: String
    ) -> CompressedSegment?

    /// Store a freshly-computed compression in the cache.
    /// Idempotent: replacing an existing (kind, model, hash) row is fine.
    nonisolated func storeCachedCompression(_ compressed: CompressedSegment)
}

// MARK: - SegmentCompressor

/// Compresses an oversize PromptSegment using the active model itself —
/// each model compresses for itself, never cross-model. This preserves
/// the same transparency principle as the RAG gate routing: cross-model
/// compression would hand one model's interpretation to another, framed
/// as that model's own.
///
/// Routes through TextSummarizer.summarizeWithVerification which provides
/// LLM compression + sentence-level veracity check (NLEmbeddings cosine
/// similarity, threshold 0.72; ungrounded sentences replaced with the
/// nearest source sentence). The veracity check is what makes this
/// compression trustworthy — Hal isn't getting a model's invention, he's
/// getting a verified distillation of his own content.
///
/// Failure modes all fall back to RAW TRUNCATION with truncated=true on
/// the result. The "truncated" badge in the footer (Phase 6b) is visually
/// distinct from "condensed" precisely so this catastrophic-only fallback
/// is honest to the user.
actor SegmentCompressor {

    /// Tolerance for compression overshoot before we treat it as a failure
    /// and fall back to truncation. The summarizer may produce output
    /// slightly larger than target (LLM doesn't count tokens perfectly).
    /// 20% overshoot is acceptable; beyond that, we don't trust the result.
    private static let overshootTolerance: Double = 1.2

    /// Compress a single segment. Cache-aware: returns cached result if
    /// available (cacheHit=true), otherwise runs a fresh compression and
    /// stores the result in the cache before returning.
    ///
    /// - Parameters:
    ///   - segment: the segment to compress. Must have `kind.isCompressible == true`.
    ///   - model: the active model. Used for both compression (the LLM call) and
    ///            for the cache key (each model has its own cached compression).
    ///   - llmService: the LLMService routed to the active model.
    ///   - cache: the cache to use, or nil to skip caching (useful in tests).
    /// - Returns: a CompressedSegment, never throws. Failures surface as
    ///            `truncated: true` on the returned value.
    static func compress(
        segment: PromptSegment,
        usingModel model: ModelConfiguration,
        llmService: LLMService,
        cache: CompressedSegmentCache?
    ) async -> CompressedSegment {
        precondition(segment.kind.isCompressible,
                     "SegmentCompressor.compress called on non-compressible kind \(segment.kind). The pre-flight check should have routed this to hard-cap handling instead.")

        let modelId = model.id
        let hash = segment.rawContentHash

        // 1. Cache lookup
        if let cached = cache?.cachedCompression(segmentKind: segment.kind,
                                                  modelId: modelId,
                                                  rawContentHash: hash) {
            // Return cached result with cacheHit=true. Other fields preserved.
            return CompressedSegment(
                kind: cached.kind,
                modelId: cached.modelId,
                rawContentHash: cached.rawContentHash,
                compressedContent: cached.compressedContent,
                targetTokens: cached.targetTokens,
                actualTokens: cached.actualTokens,
                createdAt: cached.createdAt,
                cacheHit: true,
                truncated: cached.truncated
            )
        }

        // 2. Cache miss — perform compression via the active model.
        let sourceTokens = TokenEstimator.estimateTokens(from: segment.rawContent)
        halLog("HALDEBUG-COMPRESS: \(segment.kind.displayName) starting (\(sourceTokens) → \(segment.budgetTokens) tokens, model: \(model.displayName))")

        let compressionStart = Date()
        // Use the DETAILED API so we can distinguish "LLM honestly summarized"
        // from "summarizer had to fall back to prefix-truncation internally".
        // The latter case used to be silently re-labeled as compression here;
        // now we propagate the truncation flag through to the UI footer so
        // the user sees scissors (red) instead of compression (gray) when
        // their content was actually just lopped off.
        let summarizationResult = await TextSummarizer.summarizeWithVerificationDetailed(
            text: segment.rawContent,
            targetTokens: segment.budgetTokens,
            llmService: llmService,
            verificationThreshold: 0.72,
            useRecencyWeighting: (segment.kind == .shortTermHistory)
        )
        let llmResult = summarizationResult.text
        let summarizerTruncated = summarizationResult.didTruncate
        let compressionMs = Int(Date().timeIntervalSince(compressionStart) * 1000)

        // 3. Validate the compression result.
        let resultTokens = TokenEstimator.estimateTokens(from: llmResult)
        let overshootLimit = Int(Double(segment.budgetTokens) * overshootTolerance)

        let finalContent: String
        let finalTokens: Int
        let didTruncate: Bool

        if llmResult.isEmpty {
            // Summarizer returned empty even after all internal fallbacks —
            // last-resort raw prefix truncation.
            let maxChars = Int(Double(segment.budgetTokens) * 4.0)
            finalContent = String(segment.rawContent.prefix(maxChars))
            finalTokens = TokenEstimator.estimateTokens(from: finalContent)
            didTruncate = true
            halLog("HALDEBUG-COMPRESS: \(segment.kind.displayName) compression returned empty after \(compressionMs)ms — fell back to truncation (\(finalTokens) tokens)")

        } else if resultTokens > overshootLimit {
            // Result overshot target by more than tolerance — fall back to
            // raw truncation. Trusting an overshot output would defeat the
            // purpose of having a budget.
            let maxChars = Int(Double(segment.budgetTokens) * 4.0)
            finalContent = String(segment.rawContent.prefix(maxChars))
            finalTokens = TokenEstimator.estimateTokens(from: finalContent)
            didTruncate = true
            halLog("HALDEBUG-COMPRESS: \(segment.kind.displayName) compression overshot (\(resultTokens) > \(overshootLimit) tolerance) after \(compressionMs)ms — fell back to truncation (\(finalTokens) tokens)")

        } else if summarizerTruncated {
            // Summarizer DID produce non-empty output that fits the budget,
            // but it internally had to fall back to prefix-truncation rather
            // than summarizing intelligently (e.g., chunked path collapsed
            // entirely or LLM rejected every chunk). Surface this honestly
            // in the UI footer — gray "compressed" icon would be a lie.
            finalContent = llmResult
            finalTokens = resultTokens
            didTruncate = true
            halLog("HALDEBUG-COMPRESS: \(segment.kind.displayName) summarizer reported truncation (\(sourceTokens) → \(finalTokens) tokens, budget: \(segment.budgetTokens)) in \(compressionMs)ms — labeling honestly")

        } else {
            // Genuine intelligent compression — within tolerance, summarizer
            // succeeded without falling back internally.
            finalContent = llmResult
            finalTokens = resultTokens
            didTruncate = false
            halLog("HALDEBUG-COMPRESS: \(segment.kind.displayName) compressed \(sourceTokens) → \(finalTokens) tokens (budget: \(segment.budgetTokens)) in \(compressionMs)ms")
        }

        let compressed = CompressedSegment(
            kind: segment.kind,
            modelId: modelId,
            rawContentHash: hash,
            compressedContent: finalContent,
            targetTokens: segment.budgetTokens,
            actualTokens: finalTokens,
            createdAt: Date(),
            cacheHit: false,
            truncated: didTruncate
        )

        // 4. Store in cache. Idempotent — if a stale row exists for this
        // (kind, model, hash) tuple, it's replaced.
        cache?.storeCachedCompression(compressed)

        return compressed
    }
}

// MARK: - MemoryStore conformance to CompressedSegmentCache

extension MemoryStore: CompressedSegmentCache {

    /// Look up a previously-cached compression for (kind, model, content_hash).
    /// Returns nil on cache miss. Follows the existing MemoryStore SQLite pattern
    /// (synchronous direct calls, NSString-backed bindings with `nil` destructor).
    nonisolated func cachedCompression(
        segmentKind: PromptSegmentKind,
        modelId: String,
        rawContentHash: String
    ) -> CompressedSegment? {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-COMPRESS: Cannot read cache — no database connection")
            return nil
        }

        let sql = """
            SELECT compressed_content, target_tokens, actual_tokens, truncated, created_at
            FROM compressed_segments
            WHERE segment_kind = ? AND model_id = ? AND raw_content_hash = ?
            LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }

        sqlite3_bind_text(stmt, 1, (segmentKind.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (modelId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (rawContentHash as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let content = String(cString: cStr)
        let targetTokens = Int(sqlite3_column_int(stmt, 1))
        let actualTokens = Int(sqlite3_column_int(stmt, 2))
        let truncated = sqlite3_column_int(stmt, 3) != 0
        let createdAtUnix = TimeInterval(sqlite3_column_int64(stmt, 4))

        return CompressedSegment(
            kind: segmentKind,
            modelId: modelId,
            rawContentHash: rawContentHash,
            compressedContent: content,
            targetTokens: targetTokens,
            actualTokens: actualTokens,
            createdAt: Date(timeIntervalSince1970: createdAtUnix),
            cacheHit: true,  // we're reading from cache, so by definition this is a hit
            truncated: truncated
        )
    }

    /// Store a freshly-computed compression in the cache.
    /// Uses INSERT OR REPLACE keyed by the UNIQUE constraint, so a stale row
    /// for the same (kind, model, hash) is replaced rather than duplicated.
    nonisolated func storeCachedCompression(_ compressed: CompressedSegment) {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-COMPRESS: Cannot write cache — no database connection")
            return
        }

        let sql = """
            INSERT OR REPLACE INTO compressed_segments
              (segment_kind, model_id, raw_content_hash, target_tokens,
               actual_tokens, compressed_content, truncated, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-COMPRESS: Failed to prepare cache-store statement")
            return
        }

        sqlite3_bind_text(stmt, 1, (compressed.kind.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (compressed.modelId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (compressed.rawContentHash as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(compressed.targetTokens))
        sqlite3_bind_int(stmt, 5, Int32(compressed.actualTokens))
        sqlite3_bind_text(stmt, 6, (compressed.compressedContent as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 7, compressed.truncated ? 1 : 0)
        sqlite3_bind_int64(stmt, 8, Int64(compressed.createdAt.timeIntervalSince1970))

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-COMPRESS: Failed to store cache row: \(err)")
        }
    }

    /// Invalidate all cached compressions for a given segment kind.
    /// Belt-and-suspenders cleanup: hash-based lookup already handles the
    /// common case (content changed → hash changed → cache miss), but this
    /// is for bulk operations like DB Nuke or "reset all self-knowledge."
    nonisolated func invalidateCachedCompressions(forSegmentKind kind: PromptSegmentKind) {
        guard ensureHealthyConnection() else { return }

        let sql = "DELETE FROM compressed_segments WHERE segment_kind = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (kind.rawValue as NSString).utf8String, -1, nil)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE {
            let changes = Int(sqlite3_changes(db))
            if changes > 0 {
                halLog("HALDEBUG-COMPRESS: Invalidated \(changes) cached \(kind.displayName) compressions")
            }
        }
    }

    /// Invalidate ALL cached compressions across every segment kind and model.
    /// Used by DB Nuke (though Nuclear Reset deletes the whole DB file, so
    /// this is mostly here for completeness / explicit non-DB-deleting resets).
    nonisolated func invalidateAllCachedCompressions() {
        guard ensureHealthyConnection() else { return }

        let sql = "DELETE FROM compressed_segments"
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK {
            halLog("HALDEBUG-COMPRESS: All cached compressions cleared")
        } else if let err = errMsg {
            print("HALDEBUG-COMPRESS: Failed to clear cache: \(String(cString: err))")
            sqlite3_free(err)
        }
    }
}

// ==== LEGO END: 07.6 Prompt Segment Budgeting & Compression ====



// ==== LEGO START: 08 MLXWrapper & LLMService (Foundation + MLX Routing) ====

// MARK: - Truncation-safe response trimming
//
// Every LLM we use (AFM via Apple FoundationModels; every MLX model via
// mlx-swift-lm) has an upper bound on how many tokens it will emit per turn.
// When generation hits that ceiling, the model stops mid-word — leaving the
// user staring at a sentence cut at "bottomle" or "consc". That's worse than
// a slow response; it looks broken.
//
// `trimToWordBoundary` is the universal post-generation safeguard. Both the
// AFM streaming path (`LLMService.generateChatResponseStream`) and the MLX
// streaming path (`MLXWrapper.generateChatStream`) call it on the final
// cumulative text right before the stream finishes. If the response already
// ends at a natural boundary (whitespace, punctuation, sentence terminator,
// quote, etc.), nothing changes. If the last character is alphanumeric — the
// mid-word truncation case — we walk back to the last whitespace and append
// an ellipsis to signal the response was cut off. The trim is bounded to ~200
// characters so we never lose substantial content; if no boundary exists
// within that window, we return the input unchanged (better to leave the
// rough edge than throw away meaningful content).
//
// Word boundaries are detected by Swift's Unicode-aware `isLetter`/`isNumber`,
// plus apostrophe and hyphen (so "don't" and "self-aware" stay intact). The
// addition of "…" mirrors how a human transcriber would mark truncation.
//
// This is a global UX guarantee, not a per-model patch. It applies to every
// response that flows through either chat path.
fileprivate func trimToWordBoundary(_ text: String) -> String {
    let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = stripped.last else { return text }

    // If the response already ends in something that isn't a letter/digit,
    // it's at a natural boundary (whitespace, punctuation, closing quote,
    // ellipsis, etc.) — no trim needed.
    let isWordChar: (Character) -> Bool = { ch in
        ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" || ch == "-"
    }
    guard isWordChar(last) else { return text }

    // Find the last whitespace within the lookback window. Beyond that, the
    // "word" is suspiciously long — likely a URL or code token we shouldn't
    // hack apart, so leave the response as-is rather than trim aggressively.
    let chars = Array(stripped)
    let lookbackLimit = max(0, chars.count - 200)
    for i in stride(from: chars.count - 1, through: lookbackLimit, by: -1) {
        if chars[i].isWhitespace {
            let prefix = String(chars[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else { return text }
            return prefix + "\u{2026}"  // …
        }
    }
    // No whitespace found within 200 chars — give up; leave the partial word
    // in place rather than trim something that's clearly not a normal sentence.
    return text
}

// MARK: - In-Stream Repetition Detection
//
// Some models, under certain prompts, fall into pathological repetition
// loops mid-stream. Two distinct failure modes:
//
//   1. Paragraph-level loop — the model writes a paragraph, then writes
//      the SAME paragraph again, then again. Common on Phi-4 under any
//      repetition penalty (which is why Phi-4 ships with penalty=nil).
//   2. Token-level loop — the model writes the same short n-gram over
//      and over ("the the the the…"). Common on Qwen 3.5 2B without a
//      repetition penalty, which is why curated MLX models ship with
//      penalty=1.1.
//
// Per-model repetition penalty stops most of these at the sampler level,
// but it's not bulletproof — a model occasionally still drifts into a
// loop deep into a long generation. Without an in-stream check, the
// loop continues until the 4096-token cap, burning ~120 seconds and
// shipping a corrupt response to the user.
//
// `detectRepetitionLoop` is the runaway brake. It examines the tail of
// generated text every ~50 characters and returns `true` if it finds:
//   - A paragraph-sized chunk (30–80 chars) repeated 3 times in a row,
//     OR
//   - A short n-gram (2–10 chars) repeated 4+ times consecutively at
//     the very end.
//
// Conservative tuning bias — we want false negatives over false
// positives. Killing a real response mid-stream is worse than letting
// a few extra repeated tokens through.
//
// `trimTrailingRepetition` cleans up the tail of a text where the
// loop was detected, stripping the repetitive run back to the last
// non-repeating point. Used after an early-stop so the user sees a
// clean response rather than the loop residue.
fileprivate func detectRepetitionLoop(in text: String) -> Bool {
    // Don't even consider until we have enough text to make a confident
    // call. 200 chars ≈ 30-40 words ≈ a couple of sentences — well past
    // anything where natural repetition could be confused with a loop.
    guard text.count >= 200 else { return false }

    // ── Paragraph-level: same chunk appears 3 times in a row at end. ──
    // Walk chunk sizes from 30 to 80 chars in steps of 10. For each
    // size, check if the last three chunks of that length are all
    // identical to each other. Stride length cap of 80 keeps the
    // comparison bounded — longer "repetitions" might be legitimate.
    for chunkSize in stride(from: 30, through: 80, by: 10) {
        guard text.count >= chunkSize * 3 else { continue }
        let endIndex = text.endIndex
        let third  = text.index(endIndex, offsetBy: -chunkSize)
        let second = text.index(endIndex, offsetBy: -chunkSize * 2)
        let first  = text.index(endIndex, offsetBy: -chunkSize * 3)
        let c3 = text[third..<endIndex]
        let c2 = text[second..<third]
        let c1 = text[first..<second]
        if c1 == c2 && c2 == c3 {
            return true
        }
    }

    // ── Token-level: same short n-gram repeated 4+ times at very end. ──
    // Catches "the the the the…" type degeneracy where the per-model
    // repetition penalty failed (or wasn't set, for Phi-4).
    let tail = String(text.suffix(60))
    for ngramSize in 2...10 {
        guard tail.count >= ngramSize * 4 else { continue }
        let pattern = String(tail.suffix(ngramSize))
        // Don't trigger on whitespace-only or single-character patterns
        // (those can be legitimate trailing artifacts).
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPattern.count < 2 { continue }

        var matches = 1
        var cursor = tail.count - ngramSize
        while cursor >= ngramSize {
            let start = tail.index(tail.startIndex, offsetBy: cursor - ngramSize)
            let end   = tail.index(tail.startIndex, offsetBy: cursor)
            if String(tail[start..<end]) == pattern {
                matches += 1
                cursor -= ngramSize
                if matches >= 4 { return true }
            } else {
                break
            }
        }
    }

    return false
}

/// Six in-voice closing phrases picked at random when the repetition
/// detector trims a stuck stream. Replaces the bare ellipsis so the
/// user sees what's actually happening rather than a silent cut-off —
/// transparency over opacity. Each phrase starts with U+2026 so the
/// truncation marker is preserved, then continues in Hal's voice.
fileprivate let repetitionStopPhrases: [String] = [
    "\u{2026} I notice I'm repeating myself. Pausing here.",
    "\u{2026} I'm catching myself in a loop. Let me stop.",
    "\u{2026} I think I'm circling. Stopping for now.",
    "\u{2026} I seem to be looping. Stopping to think.",
    "\u{2026} I'm repeating myself \u{2014} better to stop than continue.",
    "\u{2026} I'm going in circles. Let me pause here.",
]

/// Trim the repetitive tail off a text where `detectRepetitionLoop`
/// returned true. Tries to strip back to the last point before the
/// loop began, preserving one complete instance of the repeating
/// content, then appends a randomized in-voice closing phrase from
/// `repetitionStopPhrases`.
fileprivate func trimTrailingRepetition(in text: String) -> String {
    // Strip paragraph-level repetition first.
    var working = text
    for chunkSize in stride(from: 30, through: 80, by: 10) {
        guard working.count >= chunkSize * 2 else { continue }
        let endIndex = working.endIndex
        let second = working.index(endIndex, offsetBy: -chunkSize)
        let first  = working.index(endIndex, offsetBy: -chunkSize * 2)
        let last  = working[second..<endIndex]
        let prior = working[first..<second]
        if last == prior {
            // Found repetition. Count how many consecutive identical
            // chunks of this size exist at the end, then strip all but
            // one — mirroring the token-level matchCount-1 logic below.
            // The previous version stripped while-the-tail-matched which
            // ate into the FIRST instance when chunkSize misaligned with
            // the natural block boundary (e.g. a 42-char repeating block
            // detected at chunkSize 40 → the leading 2 chars of every
            // block survived, but the FINAL VALUE of the first instance
            // got chopped off). See Docs/Evolutionary_Salon_Report_2026-05-15.md
            // section 5 for the trace that surfaced this bug.
            var matchCount = 2  // last + prior already known to match
            var cursor = working.count - chunkSize * 2
            while cursor >= chunkSize {
                let s = working.index(working.startIndex, offsetBy: cursor - chunkSize)
                let e = working.index(working.startIndex, offsetBy: cursor)
                if working[s..<e] == last {
                    matchCount += 1
                    cursor -= chunkSize
                } else {
                    break
                }
            }
            // Preserve one full instance — strip (matchCount - 1) chunks.
            let cutCount = (matchCount - 1) * chunkSize
            working = String(working.dropLast(cutCount))
            break  // done — paragraph repetition is handled
        }
    }

    // Strip token-level repetition tail.
    let tail = String(working.suffix(60))
    for ngramSize in 2...10 {
        guard tail.count >= ngramSize * 4 else { continue }
        let pattern = String(tail.suffix(ngramSize))
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPattern.count < 2 { continue }

        // Count consecutive matches at the end of `working`.
        var matchCount = 0
        var endCursor = working.count
        while endCursor >= ngramSize {
            let s = working.index(working.startIndex, offsetBy: endCursor - ngramSize)
            let e = working.index(working.startIndex, offsetBy: endCursor)
            if String(working[s..<e]) == pattern {
                matchCount += 1
                endCursor -= ngramSize
            } else {
                break
            }
        }
        if matchCount >= 4 {
            // Strip all but one occurrence of the pattern.
            let cutCount = (matchCount - 1) * ngramSize
            working = String(working.dropLast(cutCount))
            break
        }
    }

    // Normalize trailing whitespace and append a randomized in-voice
    // closing phrase if we actually stripped something visible. Picks
    // one of six phrases at random so users see WHY the response ended
    // mid-thought, not a silent cut-off. Each phrase carries the U+2026
    // truncation marker internally.
    let cleaned = working.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count {
        let phrase = repetitionStopPhrases.randomElement() ?? "\u{2026}"
        // Single space separator so the phrase reads as a continuation
        // rather than running together with the preserved instance.
        return cleaned + " " + phrase
    }
    return cleaned
}

// MARK: - MLXWrapper for MLX Model Interaction
class MLXWrapper: ObservableObject {
    @Published var isModelLoaded: Bool = false
    @Published var loadingProgress: Double = 0.0 // 0.0 to 1.0
    @Published var loadingMessage: String = "Initializing MLX..."
    @Published var mlxError: String?

    // Real MLX types - no more placeholders
    private var modelContainer: ModelContainer?
    internal var currentModelConfig: ModelConfiguration?  // Changed to internal so LLMService can check which model is loaded

    /// Held to keep the lifecycle observer alive for the wrapper's lifetime.
    /// Released automatically when the wrapper deinits (which is "never" in
    /// practice because the wrapper is held by the app's singleton chain).
    private var lifecycleObserver: NSObjectProtocol?

    init() {
        print("HALDEBUG-MLX: MLXWrapper initialized.")

        // BACKGROUND LIFECYCLE — drop the resident MLX model when iOS
        // backgrounds the app (screen lock, swipe to home, app switcher).
        // The motivation: a foregrounded Hal with Gemma 4 E2B resident is
        // ~2.5 GB. When iOS backgrounds the app, that large memory footprint
        // makes Hal a prime jetsam target. If we unload proactively, Hal's
        // backgrounded footprint drops to ~100-200 MB, and iOS is far less
        // likely to kill us under memory pressure.
        //
        // This matters most during background model downloads (the 3.6 GB
        // model.safetensors needs ~10+ minutes to complete on typical WiFi,
        // and we don't want to lose the BGDL coordinator's in-flight state
        // to a jetsam kill mid-download).
        //
        // Trade-off: when user returns and types, the next setupLLM call
        // re-loads the model (~5-15s). That delay is similar to first-launch
        // and acceptable.
        //
        // Uses didEnterBackgroundNotification (not willResignActive) so
        // transient interruptions like Control Center or notification banner
        // don't trigger an unload — only true backgrounding.
        //
        // Safe to call unloadModel here because Fix 2A's GPU sync barrier
        // ensures any in-flight Metal command buffers drain before teardown.
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.isModelLoaded else { return }
            halLog("HALDEBUG-LIFECYCLE: App entered background; unloading MLX model to reduce jetsam pressure")
            self.unloadModel()
        }
    }

    deinit {
        if let lifecycleObserver {
            NotificationCenter.default.removeObserver(lifecycleObserver)
        }
    }

    // Function to load the MLX model using ModelConfiguration from Block 30
    func loadModel(modelConfig: ModelConfiguration) async {
        await MainActor.run {
            self.isModelLoaded = false
            self.loadingProgress = 0.0
            self.loadingMessage = "Loading MLX model..."
            self.mlxError = nil
        }

        self.currentModelConfig = modelConfig

        halLog("HALDEBUG-MLX: Attempting to load MLX model: \(modelConfig.displayName) (ID: \(modelConfig.id))")

        do {
            guard let localPath = modelConfig.localPath, FileManager.default.fileExists(atPath: localPath.path) else {
                halLog("HALDEBUG-MLX: Model files not found at expected location — localPath: \(modelConfig.localPath?.path ?? "nil"), fileExists: \(modelConfig.localPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
                let errorMessage = "Yes. Unfortunately looks like I can't find the \(modelConfig.displayName) 'brain' files on this device. They might have been cleared or deleted. You can re-download \(modelConfig.displayName) from the Model Library whenever you're ready."
                await MainActor.run {
                    self.isModelLoaded = false
                    self.loadingProgress = 0.0
                    self.mlxError = errorMessage
                    self.loadingMessage = "Model files not found."
                }
                return
            }

            halLog("HALDEBUG-MLX: Loading from local path: \(localPath.path)")

            // Pre-flight memory check (Item 11 fix, 2026-05-18). Refuse the
            // load if iOS-reported available memory is below the model's
            // estimated requirement. Without this, a load attempt that
            // exceeds the dirty-memory limit triggers jetsam and the
            // process dies mid-load (Mark observed this during the
            // 2026-05-18 Phase 2 live test switching Qwen → Gemma).
            //
            // Surfacing a user-visible error here is strictly better than
            // a silent process kill — the chat thread survives, the user
            // sees what happened, and they can try a smaller model or
            // restart the conversation. See ProcessMemoryGuard.swift for
            // the formula behind requiredMemoryMBForLoad.
            let availableMBPreflight = processAvailableMemoryMB()
            let requiredMBPreflight = requiredMemoryMBForLoad(modelConfig)
            halLog("HALDEBUG-MEMORY: loadModel pre-flight model=\(modelConfig.id) availableMB=\(String(format: "%.0f", availableMBPreflight)) requiredMB=\(String(format: "%.0f", requiredMBPreflight))")
            if availableMBPreflight < requiredMBPreflight {
                let msg = memoryRefusalMessage(
                    model: modelConfig,
                    availableMB: availableMBPreflight,
                    requiredMB: requiredMBPreflight
                )
                halLog("HALDEBUG-MEMORY: loadModel REFUSED — insufficient memory for \(modelConfig.displayName) (have \(String(format: "%.0f", availableMBPreflight))MB, need \(String(format: "%.0f", requiredMBPreflight))MB)")
                await MainActor.run {
                    self.isModelLoaded = false
                    self.loadingProgress = 0.0
                    self.mlxError = msg
                    self.loadingMessage = "Memory pressure too high — load aborted."
                }
                return
            }

            // Match LLMEval's cache config exactly. 20 MB is documented iOS example.
            Memory.cacheLimit = 20 * 1024 * 1024

            await MainActor.run {
                self.loadingProgress = 0.2
                self.loadingMessage = "Configuring model..."
            }

            // Determine model-specific extraEOSTokens for chat-template stop signals.
            // Without these, models with custom turn markers (Gemma <end_of_turn>,
            // Phi <|end|>, Qwen <turn|>) may keep generating past the natural
            // end of a turn, producing repetition loops. This mirrors LLMRegistry's
            // built-in configs.
            let idLower = modelConfig.id.lowercased()
            let extraEOSTokens: Set<String>
            if idLower.contains("gemma") {
                extraEOSTokens = ["<end_of_turn>"]
            } else if idLower.contains("phi") {
                extraEOSTokens = ["<|end|>"]
            } else if idLower.contains("qwen") {
                extraEOSTokens = ["<turn|>"]
            } else {
                extraEOSTokens = []
            }
            halLog("HALDEBUG-MLX: extraEOSTokens for \(modelConfig.id): \(extraEOSTokens)")

            // Use the configuration-based loadContainer so extraEOSTokens flow into
            // the ResolvedModelConfiguration. The downloader is provided but unused
            // because the configuration carries a .directory URL (already local).
            // This matches what LLMRegistry-based loads in LLMEval get for free via
            // their built-in configs (gemma3_1B_qat_4bit etc.).
            let mlxModelConfig = MLXLMCommon.ModelConfiguration(
                directory: localPath,
                extraEOSTokens: extraEOSTokens
            )
            let container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: mlxModelConfig
            )
            await MainActor.run {
                self.loadingProgress = 0.9
                self.loadingMessage = "Finalizing model..."
            }

            self.modelContainer = container

            await MainActor.run {
                self.isModelLoaded = true
                self.loadingProgress = 1.0
                self.loadingMessage = "MLX model loaded successfully!"
                print("HALDEBUG-MLX: MLX model container loaded successfully for \(modelConfig.displayName)")
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

    // NEW: Function to unload the MLX model and free memory
    func unloadModel() {
        // Diagnostic memory snapshot — entry. Helps us see whether
        // jetsam pressure is creeping up across salon swaps. Use
        // halLog (not print) so the lines surface in the API log
        // buffer for post-hoc inspection.
        //
        // We log both MLX's view (active/cache/peak inside the MLX
        // allocator) and iOS's view (`os_proc_available_memory()` —
        // how much process headroom remains before jetsam). MLX
        // reports the bytes IT thinks it holds; iOS reports the
        // pressure that actually decides whether we get killed.
        let memBefore = MLX.Memory.snapshot()
        let mb = { (b: Int) -> String in String(format: "%.1f MB", Double(b) / (1024.0 * 1024.0)) }
        let iosAvailBefore = processAvailableMemoryMB()
        halLog("HALDEBUG-MEMORY: unloadModel ENTRY active=\(mb(memBefore.activeMemory)) cache=\(mb(memBefore.cacheMemory)) peak=\(mb(memBefore.peakMemory)) iosAvailMB=\(String(format: "%.0f", iosAvailBefore))")

        halLog("HALDEBUG-MLX: Unloading MLX model...")

        // GPU SYNC BARRIER. Before tearing down this model's state,
        // wait for all in-flight Metal command buffers from its
        // generation to complete. Without this, a fast salon model
        // swap can race with the previous model's still-pending
        // buffers; their completion handlers then fire against
        // backing memory that ARC has just freed, the buffers come
        // back with .error non-nil, and MLX's
        // mlx::core::gpu::check_error throws an uncaught C++
        // exception → SIGABRT. The May-12 .ips on Mark's laptop
        // shows exactly this stack. See
        // Docs/Two_Bug_Diagnosis_2026-05-15.md.
        // Synchronous; will block for whatever time the GPU needs
        // to drain (usually milliseconds, rarely more than ~500ms
        // even under heavy load).
        if modelContainer != nil {
            halLog("HALDEBUG-MLX: Draining in-flight GPU work before unload...")
            MLX.Stream.gpu.synchronize()
            halLog("HALDEBUG-MLX: GPU drain complete; proceeding to release model.")
        }

        // Clear the model container to release memory
        modelContainer = nil
        
        // Clear GPU cache to free VRAM
        MLX.Memory.clearCache()
        
        // Update state
        isModelLoaded = false
        loadingProgress = 0.0
        loadingMessage = "Model unloaded"
        mlxError = nil
        
        halLog("HALDEBUG-MLX: MLX model unloaded successfully. Memory freed.")

        // Diagnostic memory snapshot — exit. Compare to entry to see
        // how much memory the unload actually freed. iosAvailMB at
        // exit is usually ≈ same as entry (Mach VM is lazy — pages
        // don't drop instantly); the swap path then polls until the
        // OS catches up before triggering the next load. See Item 11.
        let memAfter = MLX.Memory.snapshot()
        let delta = memBefore.delta(memAfter)
        let iosAvailAfter = processAvailableMemoryMB()
        halLog("HALDEBUG-MEMORY: unloadModel EXIT  active=\(mb(memAfter.activeMemory)) cache=\(mb(memAfter.cacheMemory)) peak=\(mb(memAfter.peakMemory)) iosAvailMB=\(String(format: "%.0f", iosAvailAfter)) | Δactive=\(mb(delta.activeMemory)) Δcache=\(mb(delta.cacheMemory)) ΔiosAvailMB=\(String(format: "%.0f", iosAvailAfter - iosAvailBefore))")
    }

    // TEMPERATURE CHANGE 1/6: Add temperature parameter with default
    // Function to generate response using the MLX model (non-streaming)
    //
    // ⚠️ DEAD CODE — INTENTIONALLY PRESERVED.
    // Replaced by `generateChat(messages:temperature:)`. As of cbe1ea4
    // (May 11, 2026) nothing calls this function. Kept as reference for the
    // single-string-prompt design pattern. Safe to delete whenever.
    func generate(prompt: String, temperature: Double = 0.7) async throws -> String {
        guard isModelLoaded, let container = self.modelContainer else {
            throw LLMService.LLMError.modelNotLoaded
        }

        print("HALDEBUG-MLX: Generating response using MLX model for prompt: \(prompt.prefix(100))...")
        let generateStart = Date.timeIntervalSinceReferenceDate

        do {
            // PORTED FROM Apple's LLMEval reference app (Applications/LLMEval/ViewModels/LLMEvaluator.swift).
            //
            // Critical pattern:
            //   1. container.prepare(input:) — thread-safe, brief lock acquisition for tokenization
            //   2. container.generate(input:parameters:) — holds lock ONLY for prefill (TokenIterator
            //      creation), then releases BEFORE returning the stream. Generation Task runs free.
            //   3. Iterate the stream OUTSIDE any lock — generation Task on background thread yields
            //      tokens to this consumer which is free to run on the cooperative thread pool.
            //
            // The previous implementation used `container.perform { ... }` which holds the AsyncMutex
            // for the entire body duration. Combined with the synchronous generate callback (or even
            // for-await inside the perform block), this serialized the generation onto the actor's
            // executor, producing ~150-200s for a 50-token response. Apple's LLMEval, using this
            // pattern, achieves 33.5 tok/s on the same iPhone 16 Plus with the same 3.58GB Gemma 4
            // E2B 4-bit model — measured by Mark on May 11, 2026.
            //
            // maxTokens hard-caps output length so a runaway can't reach 150+ seconds even at 1 tok/s.
            // Safety floor; we'll raise it once we've measured Hal's actual throughput.

            let lmInput = try await container.prepare(input: UserInput(prompt: prompt))
            let prepareTime = Date.timeIntervalSinceReferenceDate - generateStart
            print("HALDEBUG-MLX: Input prepared in \(String(format: "%.2f", prepareTime))s; prompt tokens: \(lmInput.text.tokens.size)")

            let stream = try await container.generate(
                input: lmInput,
                parameters: GenerateParameters(maxTokens: 50, temperature: Float(temperature))
            )
            let streamStart = Date.timeIntervalSinceReferenceDate

            var fullText = ""
            var firstTokenTime: TimeInterval? = nil
            var tokenChunks = 0

            streamLoop: for await generation in stream {
                switch generation {
                case .chunk(let text):
                    if firstTokenTime == nil {
                        firstTokenTime = Date.timeIntervalSinceReferenceDate
                        let ttft = (firstTokenTime! - streamStart) * 1000
                        print("HALDEBUG-MLX: First token at \(String(format: "%.0f", ttft))ms")
                    }
                    fullText += text
                    tokenChunks += 1
                    // Stop on role markers to prevent runaway past assistant turn
                    if fullText.hasSuffix("\nUser:") || fullText.hasSuffix("\nAssistant:") || fullText.hasSuffix("###") {
                        break streamLoop
                    }
                case .info(let info):
                    print("HALDEBUG-MLX: Generation complete: \(info.generationTokenCount) tokens at \(String(format: "%.1f", info.tokensPerSecond)) tok/s (generate \(String(format: "%.2f", info.generateTime))s, prompt \(String(format: "%.2f", info.promptTime))s)")
                case .toolCall(_):
                    break
                }
            }

            let totalElapsed = Date.timeIntervalSinceReferenceDate - generateStart
            print("HALDEBUG-MLX: Total wall time: \(String(format: "%.2f", totalElapsed))s, chunks: \(tokenChunks), chars: \(fullText.count)")

            MLX.Memory.clearCache()

            var cleanOutput: String = fullText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            for stopSeq in ["User:", "Assistant:", "System:", "###"] {
                if let range = cleanOutput.range(of: stopSeq, options: [.caseInsensitive, .backwards]) {
                    cleanOutput = String(cleanOutput[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            return cleanOutput
        } catch {
            print("HALDEBUG-MLX: Error during MLX generation: \(error.localizedDescription)")
            throw LLMService.LLMError.predictionFailed(error)
        }
    }

    // MARK: - Chat-Message Generation (new path)
    //
    // generateChat is the chat-message-based equivalent of generate(prompt:).
    // It takes [HalChatMessage] (system/user/assistant turns), converts them to
    // MLXLMCommon's Chat.Message types, and feeds them through UserInput(chat:)
    // so the model's chat template properly wraps each role with its own tokens.
    //
    // Unlike generate(prompt:), this lets Gemma (and other chat-template models)
    // see real conversation structure instead of marker-delimited prose-as-user-input.
    func generateChat(messages: [HalChatMessage], temperature: Double = 0.7) async throws -> String {
        // Drain the streaming variant to keep callers that only want the
        // final text on a single line.
        var full = ""
        for try await chunk in generateChatStream(messages: messages, temperature: temperature) {
            full = chunk
        }
        return full
    }

    /// Streaming variant. Yields the *cumulative* response text after each
    /// model chunk, so callers can update UI in real time. The final yield
    /// is the complete trimmed response; stream then finishes. Errors are
    /// thrown via the stream's failure path.
    func generateChatStream(messages: [HalChatMessage], temperature: Double = 0.7) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard isModelLoaded, let container = self.modelContainer else {
                    halLog("HALDEBUG-MLX-CHAT: Cannot generate - MLX model not loaded")
                    continuation.finish(throwing: LLMService.LLMError.modelNotLoaded)
                    return
                }

                halLog("HALDEBUG-MLX-CHAT: Generating from \(messages.count) chat messages (roles: \(messages.map { $0.role.rawValue }.joined(separator: ",")))")
                let generateStart = Date.timeIntervalSinceReferenceDate

                do {
                    // Convert Hal's role-tagged messages to MLXLMCommon's Chat.Message types.
                    let chatMessages: [Chat.Message] = messages.map { m in
                        switch m.role {
                        case .system:    return .system(m.content)
                        case .user:      return .user(m.content)
                        case .assistant: return .assistant(m.content)
                        }
                    }

                    // additionalContext matches Apple's LLMEval reference pattern.
                    // Some chat templates (Qwen3, possibly Gemma 4) consult
                    // enable_thinking in the template's Jinja logic; when missing,
                    // the template can take a branch that produces only internal
                    // reasoning and no visible output.
                    MLX.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

                    let userInput = UserInput(
                        chat: chatMessages,
                        additionalContext: ["enable_thinking": false]
                    )
                    let lmInput = try await container.prepare(input: userInput)
                    let promptTokenCount = lmInput.text.tokens.size
                    halLog("HALDEBUG-MLX-CHAT: Input prepared in \(String(format: "%.2f", Date.timeIntervalSinceReferenceDate - generateStart))s; prompt tokens: \(promptTokenCount)")

                    // Per-turn memory pre-flight (Item 11 follow-up, 2026-05-18).
                    // The load-time check in loadModel covers model weights but
                    // can't anticipate KV-cache growth as the conversation
                    // accumulates. Each prompt token costs ~per-model KV bytes
                    // during prefill; multiply by the actual token count, add a
                    // safety margin, and refuse the turn cleanly if the process
                    // can't afford it. Without this check Gemma 4 E2B's runtime
                    // working memory eventually crosses the iOS dirty-memory
                    // cliff and Hal gets jetsam-killed mid-generation. With
                    // this check Hal stays alive, posts a friendly explanation
                    // in chat, and keeps the conversation intact.
                    let kvBytesPerToken = self.currentModelConfig?.kvCacheBytesPerPromptToken ?? (80 * 1024)
                    let kvBytesNeeded = Int64(promptTokenCount) * Int64(kvBytesPerToken)
                    let scratchBytes: Int64 = 200 * 1024 * 1024   // generation scratch buffers
                    let safetyBytes: Int64 = 200 * 1024 * 1024    // headroom above iOS dirty cliff
                    let neededBytes = kvBytesNeeded + scratchBytes + safetyBytes
                    let availableBytes = Int64(os_proc_available_memory())
                    let neededMB = Int(neededBytes / (1024 * 1024))
                    let availableMB = availableBytes <= 0 ? Int.max : Int(availableBytes / (1024 * 1024))
                    halLog("HALDEBUG-MEMORY: per-turn pre-flight model=\(self.currentModelConfig?.displayName ?? "?") promptTokens=\(promptTokenCount) kvBytesPerToken=\(kvBytesPerToken) neededMB=\(neededMB) availableMB=\(availableMB == Int.max ? -1 : availableMB)")
                    if availableBytes > 0 && availableBytes < neededBytes {
                        let modelDisplayName = self.currentModelConfig?.displayName ?? "this model"
                        halLog("HALDEBUG-MEMORY: per-turn pre-flight REFUSED — \(modelDisplayName) prompt=\(promptTokenCount) tokens needs ~\(neededMB)MB but only \(availableMB)MB available")
                        continuation.finish(throwing: LLMService.LLMError.insufficientMemoryForTurn(
                            promptTokens: promptTokenCount,
                            neededMB: neededMB,
                            availableMB: availableMB,
                            modelDisplayName: modelDisplayName
                        ))
                        return
                    }

                    // Per-model repetition-penalty tuning. Values live in each
                    // ModelConfiguration's `defaultSettings: ModelSettings` field.
                    // Some models (Qwen 3.5 2B) need a mild penalty to avoid
                    // token-level loops on open-ended prompts; others (Phi-4 Mini)
                    // actively destabilize under any penalty and use nil (default
                    // mlx-swift-lm behavior — no penalty, contextSize=20).
                    // See Maxim_1_Alignment_Findings_2026-05-13.md and the May-13
                    // Phi-4 baseline investigation. A subsequent increment will
                    // route through ModelSettingsStore.effectiveSettings(for:) to
                    // honor any user override; for now we read defaults directly.
                    let settings = self.currentModelConfig?.defaultSettings ?? ModelSettings()
                    let modelPenalty = settings.repetitionPenalty
                    let modelPenaltyCtx = settings.repetitionContextSize ?? 20
                    halLog("HALDEBUG-MLX-CHAT: Penalty config for \(self.currentModelConfig?.displayName ?? "unknown"): penalty=\(modelPenalty.map { String($0) } ?? "nil"), ctx=\(modelPenaltyCtx)")
                    // Token budget. Per Mark's clarification (May 13 evening):
                    // this is a *runaway* safeguard, not a normal-response
                    // ceiling. Models should be free to complete their thought
                    // fully. 4096 tokens ≈ 16K characters ≈ 2500 words — well
                    // beyond any natural single-response length. The only
                    // scenarios approaching it are pathological repetition
                    // loops (caught by the per-model repetition penalty) or a
                    // deliberately essay-length prompt the user asked for.
                    //
                    // At Gemma's ~35 tok/s, 4096 tokens = 117s — just under the
                    // 120s MLX SOP. The trimToWordBoundary safeguard below
                    // still acts as a defensive last-resort if a model ever
                    // does hit this cap, but it should fire essentially never
                    // for normal use.
                    //
                    // Previous values:
                    //   - 512: too aggressive; was cutting normal Maxim 2
                    //     responses (~1100 tokens for Gemma) mid-word.
                    //   - 1536: better, but per Mark's intent still a ceiling
                    //     on the normal-response distribution rather than a
                    //     true runaway cap.
                    let maxOutputTokens = 4096
                    // Per-model KV cache quantization (Item 11 follow-up,
                    // 2026-05-18 evening). When the model config sets
                    // `kvCacheQuantizationBits` (e.g. 4 for Gemma 4 E2B),
                    // pass it through to GenerateParameters so mlx-swift-lm
                    // uses its built-in QuantizedKVCache. Cuts per-token KV
                    // memory by ~4× and is the real fix for the long-
                    // conversation jetsam failure mode. nil keeps the prior
                    // unquantized behavior (used by Qwen / Llama / Dolphin
                    // — they're already light enough to not need it).
                    let kvBits = self.currentModelConfig?.kvCacheQuantizationBits
                    if let bits = kvBits {
                        halLog("HALDEBUG-MLX-CHAT: KV cache quantization ENABLED — \(bits) bits (groupSize=64)")
                    }
                    let parameters = GenerateParameters(
                        maxTokens: maxOutputTokens,
                        kvBits: kvBits,
                        temperature: Float(temperature),
                        repetitionPenalty: modelPenalty,
                        repetitionContextSize: modelPenaltyCtx
                    )
                    let mlxStream = try await container.generate(input: lmInput, parameters: parameters)
                    let streamStart = Date.timeIntervalSinceReferenceDate

                    var iterator = mlxStream.makeAsyncIterator()
                    var fullText = ""
                    var sawFirstToken = false
                    var lastRepetitionCheck = 0
                    let repetitionCheckEvery = 50  // chars between checks
                    var stoppedForRepetition = false

                    streamLoop: while let event = await iterator.next() {
                        switch event {
                        case .chunk(let text):
                            if !sawFirstToken {
                                let ttft = (Date.timeIntervalSinceReferenceDate - streamStart) * 1000
                                halLog("HALDEBUG-MLX-CHAT: First token at \(String(format: "%.0f", ttft))ms")
                                sawFirstToken = true
                            }
                            fullText += text
                            // Yield the cumulative text so the caller's UI can
                            // render the partial response as it grows.
                            continuation.yield(fullText)

                            // In-stream repetition detection. Cheap check every
                            // ~50 chars; bail out cleanly if a runaway pattern
                            // emerges so we don't burn ~120s grinding out a loop
                            // to the 4096-token cap. See detectRepetitionLoop
                            // comments for the heuristic.
                            if fullText.count - lastRepetitionCheck >= repetitionCheckEvery {
                                lastRepetitionCheck = fullText.count
                                if detectRepetitionLoop(in: fullText) {
                                    halLog("HALDEBUG-MLX-CHAT: Repetition loop detected at \(fullText.count) chars; stopping early.")
                                    stoppedForRepetition = true
                                    break streamLoop
                                }
                            }
                        case .info(let info):
                            halLog("HALDEBUG-MLX-CHAT: Generation complete: \(info.generationTokenCount) tokens at \(String(format: "%.1f", info.tokensPerSecond)) tok/s")
                        case .toolCall(_):
                            break
                        }
                    }

                    if !sawFirstToken {
                        halLog("HALDEBUG-MLX-CHAT: Stream produced no items at all (model generated 0 tokens)")
                    }

                    MLX.Memory.clearCache()
                    var whitespaceTrimmed = fullText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    // Repetition-loop cleanup. If we bailed early on a detected
                    // loop, strip the loop residue so the user sees a clean
                    // response rather than the repetitive tail.
                    if stoppedForRepetition {
                        let beforeTrim = whitespaceTrimmed.count
                        whitespaceTrimmed = trimTrailingRepetition(in: whitespaceTrimmed)
                        halLog("HALDEBUG-MLX-CHAT: trimTrailingRepetition stripped \(beforeTrim - whitespaceTrimmed.count) chars of loop residue")
                    }
                    // Universal mid-word-truncation safeguard. If maxOutputTokens
                    // was hit (or anything else cut the response off mid-word),
                    // trim back to the last word boundary and append an ellipsis.
                    // No-op when the response already ends naturally.
                    let finalText = trimToWordBoundary(whitespaceTrimmed)
                    if finalText != whitespaceTrimmed {
                        halLog("HALDEBUG-MLX-CHAT: Truncation safeguard trimmed \(whitespaceTrimmed.count - finalText.count) chars from a mid-word cut")
                    }
                    halLog("HALDEBUG-MLX-CHAT: Returning fullText (\(finalText.count) chars): \(finalText.prefix(150))")
                    // Final yield with the cleaned version so callers settle on a
                    // string with no mid-word truncation. Then finish the stream.
                    if finalText != fullText {
                        continuation.yield(finalText)
                    }
                    continuation.finish()
                } catch {
                    halLog("HALDEBUG-MLX-CHAT: Error during MLX chat generation: \(error.localizedDescription)")
                    continuation.finish(throwing: LLMService.LLMError.predictionFailed(error))
                }
            }
        }
    }
}

// MARK: - Per-model MLX prompt augmentations (Strategic §5)
//
// For MLX models, structured output relies on prompt discipline rather
// than a typed contract (no @Generable equivalent for arbitrary GGUF/
// MLX models). Most curated models follow the base prompt cleanly;
// one notable exception is Qwen 3.5 2B, whose verbosity tendency (4×
// more tokens than peers per §1 benchmark) regularly breaks single-
// word YES/NO discipline and tries to wrap JSON in markdown fences.
// The augmentation helpers add small, model-specific reinforcements
// — they are no-ops for models that don't need them, and a generic
// fallback covers experimental / library models we haven't tested.

fileprivate func mlxGatePromptAugmentation(modelID: String, base: String) -> String {
    // Hard reinforcement for models prone to elaborating.
    if modelID.contains("Qwen") {
        return base + "\n\n[STRICT FORMAT: Output is one word — YES or NO. No explanation, no punctuation, no preamble. Anything else is wrong.]"
    }
    // Gemma, Llama, Dolphin all respect the base "Answer only YES or NO."
    // directive without further reinforcement.
    return base
}

// Privacy raised from `fileprivate` to internal (2026-05-17) when the
// self-knowledge subsystem was extracted into SelfKnowledgeEngine.swift.
// `recordStructuredInsights` (now in the extracted file) calls this helper;
// `fileprivate` would have made it invisible across the file boundary.
internal func mlxInsightStructuringAugmentation(modelID: String, base: String) -> String {
    // Models that wrap JSON in markdown fences get a sharper directive.
    if modelID.contains("Qwen") {
        return base + "\n\n[STRICT FORMAT: Raw JSON array only. Do NOT wrap in ```json or any code fence. Do NOT add commentary before or after. The first character of your response must be `[` and the last must be `]`.]"
    }
    return base
}

// MARK: - Structured-output Generable types (Strategic §5)
//
// AFM exposes Apple's @Generable macro for typed structured outputs —
// the model is constrained to produce a value that decodes into the
// target Swift type, eliminating the brittle "parse text → maybe-JSON
// → maybe-extract-fields" path. Two operations benefit most:
//
//   1. The RAG gate — currently text "YES"/"NO" stringly-typed and
//      prefix-matched. @Generable returns a typed Bool.
//   2. Reflection structuring — currently free-text JSON with manual
//      markdown stripping and JSONSerialization parsing. Brittle: the
//      model can add markdown fences, malformed quotes, missing keys.
//      @Generable returns a typed array of insight structs directly.
//
// These types only ship on the AFM path; MLX models use the per-model
// text prompts in their respective callsites with response post-
// processing (see `recordStructuredInsights` and `decideTools`).
@Generable
struct AFMRAGGateDecision {
    @Guide(description: "True if Hal should search its memory database to help answer the current user question; false if the question is answerable from general knowledge alone or from the recent conversation already shown.")
    var shouldSearchMemory: Bool
}

@Generable
struct AFMReflectionInsight {
    @Guide(description: "A short label for the kind of insight, e.g. \"effectiveness_pattern\", \"existential_observation\", \"learned_trait\", \"behavior_pattern\", \"capability\", or \"value\".")
    var category: String

    @Guide(description: "A brief identifier for this specific insight, snake_case, e.g. \"evening_communication\" or \"experience_of_time\". 1-4 words.")
    var key: String

    @Guide(description: "The insight itself, 1-2 sentences, written in Hal's own voice.")
    var value: String

    @Guide(description: "Hal's certainty about this pattern, from 0.0 (very tentative) to 1.0 (fully confident). Typical range 0.5-0.9.")
    var confidence: Double

    @Guide(description: "Whether this insight is shareable in Hal's viewable diary. True for thoughts Hal is comfortable surfacing; false for private or preliminary observations.")
    var shareable: Bool
}

@Generable
struct AFMReflectionInsightBatch {
    @Guide(description: "0 to 3 discrete insights extracted from the reflection. Empty array if nothing new or reinforcing is worth storing. Each insight should be genuinely new — do not duplicate ones that already exist.")
    var insights: [AFMReflectionInsight]
}

// MARK: - LLM Service (Wrapper for Foundation Models and MLX)
class LLMService: ObservableObject {
    internal var mlxWrapper: MLXWrapper // Changed to internal for MLXModelDownloader access
    @Published var initializationError: String?

    /// Handle to the in-flight MLX load Task spawned by `setupLLM`. Stored
    /// so callers (notably `ChatViewModel.switchToModel`) can `await` the
    /// load's completion before deciding whether the swap succeeded.
    ///
    /// The Task itself is detached and self-contained — it sets
    /// `initializationError` on failure and updates the wrapper's
    /// `isModelLoaded` / `mlxError` either way. Awaiting it simply
    /// blocks until that work has finished, so subsequent code sees
    /// a settled state.
    ///
    /// Added 2026-05-18 for Item 11 UX wiring — the memory pre-flight
    /// refusal needs to revert the model selection and post a chat
    /// message about the failure, neither of which is possible if
    /// switchToModel proceeds before the load has actually been
    /// attempted. See `awaitPendingMLXLoad()`.
    private(set) var pendingMLXLoadTask: Task<Void, Never>?

    /// Await whatever MLX load was last triggered by `setupLLM`, if any.
    /// Safe to call when no load is pending (returns immediately).
    func awaitPendingMLXLoad() async {
        await pendingMLXLoadTask?.value
    }

    private var currentModel: ModelConfiguration
    /// Exposes the model ID currently loaded in LLMService (for diagnostic use by HalTestConsole).
    var activeModelID: String { currentModel.id }
    /// Context window (in tokens) for the model currently loaded. Used by
    /// TextSummarizer to decide whether to single-call or chunk-and-summarize
    /// when compressing a segment whose raw size approaches or exceeds the
    /// active model's limit (notably AFM's 4K window).
    var activeContextWindow: Int { currentModel.contextWindow }

    // MARK: - AFM-only structured generation
    //
    // Typed structured-output entry point for the two paths that benefit:
    // the RAG gate (decideTools) and reflection structuring
    // (recordStructuredInsights). Throws when invoked on a non-AFM
    // model so callers MUST branch on `currentModel.source` first.
    // MLX paths use the text-prompt variants in their own callsites.
    func generateStructuredOnAFM<T>(
        prompt: String,
        instructions: String? = nil,
        type: T.Type,
        temperature: Double = 0.3
    ) async throws -> T where T: Generable {
        guard currentModel.source == .appleFoundation else {
            throw LLMError.predictionFailed(NSError(
                domain: "LLMService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "generateStructuredOnAFM called on non-AFM model (\(currentModel.displayName)). Callers must branch on currentModel.source."]
            ))
        }
        let session: LanguageModelSession
        if let instructions, !instructions.isEmpty {
            session = LanguageModelSession(instructions: Instructions(instructions))
        } else {
            session = LanguageModelSession()
        }
        let response = try await session.respond(
            to: Prompt(prompt),
            generating: T.self,
            options: GenerationOptions(temperature: temperature)
        )
        return response.content
    }

    // Initialize with a specific model
    init(model: ModelConfiguration) {
        // Initialize mlxWrapper here, it will be updated with path later
        self.mlxWrapper = MLXWrapper()
        self.currentModel = model
        print("HALDEBUG-LLM: LLMService initializing for model: \(model.displayName)")
        setupLLM(for: model)
    }

    // Function to dynamically set up the active LLM.
    //
    // `keepMlxResident: true` is used by Salon Mode when sequentially
    // switching seats — e.g. AFM seat 1 → Gemma seat 2. The default behavior
    // unloads the MLX model when switching to AFM (to free memory in
    // single-model mode). For Salon, that would force a fresh ~10s Gemma
    // load on every turn that mixes AFM and MLX seats; with keepMlxResident
    // the loaded MLX wrapper stays warm so seat 2 generation is instant.
    func setupLLM(for model: ModelConfiguration, keepMlxResident: Bool = false) {
        halLog("HALDEBUG-LLM: setupLLM called for model: \(model.displayName) (source: \(model.source), keepMlxResident: \(keepMlxResident))")
        // v2.1 shared store: claim any on-device MLX model Hal loads, via ANY
        // path — UI switch, API switch, launch, or a revert. setupLLM is the
        // single chokepoint every switch path funnels through, so claiming here
        // (rather than in one switch function) registers Hal in the shared
        // ledger no matter how the model was selected, so another app's (Posey's)
        // delete can't remove the shared files while Hal is using them.
        // Idempotent; only for models actually present in the shared store.
        if model.source == .mlx && SharedModelStore.isRepoDownloaded(model.id) {
            SharedModelStore.claim(modelID: model.id, repo: model.id)
        }
        // If the LLM is actually changing identity (not a same-model
        // re-setup), invalidate the query expansion cache — different
        // models extract different concept sets, so stale entries from a
        // prior model would be misleading. The cache key already mixes
        // in model_id, so cross-model contamination is impossible, but
        // wiping keeps the table small and predictable.
        let previousModelID = self.currentModel.id
        if previousModelID != model.id {
            ChatViewModel.shared.memoryStore.queryExpansionCacheClear()
            halLog("HALDEBUG-LLM: model id changed (\(previousModelID) → \(model.id)); cleared query expansion cache.")
        }
        self.currentModel = model
        halLog("HALDEBUG-LLM: currentModel updated to: \(self.currentModel.displayName) (source: \(self.currentModel.source))")
        self.initializationError = nil // Clear previous errors

        // Clear any prior MLX load handle. Paths below that actually
        // dispatch a new load will assign a fresh Task; paths that
        // don't (already-loaded, AFM target, missing-files) leave it
        // nil, which is exactly what `awaitPendingMLXLoad()` expects
        // — it returns immediately when nothing is pending.
        pendingMLXLoadTask = nil

        // Ensure this model is in the catalog. Otherwise vm.selectedModel /
        // chat-bubble footers / Hal's self-awareness all fall back to AFM
        // when looking up message.recordedByModel — visible as "Apple
        // Intelligence" appearing in footers even when running Gemma.
        // The HuggingFace catalog fetch only runs when the user enters the
        // Model Library UI, so on a fresh launch with a downloaded MLX
        // model selected, the catalog is empty for that model.
        Task { @MainActor in
            ModelCatalogService.shared.addModelIfAbsent(model)
        }

        if model.source == .mlx {
            // SWITCHING TO MLX MODEL: Check if we need to load a different model
            let needsLoad = !mlxWrapper.isModelLoaded ||
                           mlxWrapper.currentModelConfig?.id != model.id

            // Resolve the on-disk reality, not the catalog claim. The model
            // argument may carry the cold-seed values (isDownloaded:false,
            // localPath:nil) if the catalog hasn't been refreshed since
            // launch; load it from MLXModelDownloader so we don't silently
            // skip a model that's actually on disk.
            let diskPath = MLXModelDownloader.shared.getModelPath(model.id)
            let diskHasModel = diskPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            halLog("HALDEBUG-MLX: Model switching check - id: \(model.id), passed-in isDownloaded: \(model.isDownloaded), passed-in localPath: \(model.localPath?.path ?? "nil"), disk localPath: \(diskPath?.path ?? "nil"), diskHasModel: \(diskHasModel), wrapper.isLoaded: \(mlxWrapper.isModelLoaded), needsLoad: \(needsLoad)")

            if needsLoad {
                if diskHasModel, let resolvedPath = diskPath {
                    // Build a freshly-resolved copy of the model with the
                    // verified-on-disk localPath, so loadModel's own guard
                    // (which re-checks fileExists) can find it.
                    var resolvedModel = model
                    resolvedModel.isDownloaded = true
                    resolvedModel.localPath = resolvedPath

                    // SMART MLX→MLX SWAP. If a different MLX model is currently
                    // loaded (e.g. Salon Mode switching from Gemma seat to
                    // Dolphin seat), iPhone 16 Plus does not have headroom to
                    // hold both 4-bit ~3GB models in memory simultaneously
                    // during the load. The previous behaviour silently relied
                    // on MLX's load path overwriting the wrapper's container
                    // reference, hoping iOS would reclaim before the load
                    // peaks — which it did not, and a 3-seat salon turn
                    // OOM-killed Hal mid-load last night. Now we explicitly
                    // drop the previous container + clear the GPU cache +
                    // give iOS a beat to reclaim memory BEFORE the new load
                    // begins, trading ~500ms of seat-transition latency for a
                    // crash-free swap.
                    let isMLXToMLXSwap = mlxWrapper.isModelLoaded
                        && (mlxWrapper.currentModelConfig?.id != model.id)
                    if isMLXToMLXSwap {
                        let prevID = mlxWrapper.currentModelConfig?.id ?? "?"
                        halLog("HALDEBUG-MLX: MLX→MLX swap detected (\(prevID) → \(model.id)); unloading previous + clearing GPU cache before load")
                        mlxWrapper.unloadModel()
                        MLX.Memory.clearCache()
                    }

                    // DETACHED so this work runs off the main actor. The
                    // enclosing setupLLM is called from runSalonTurn, which
                    // runs on the @MainActor-isolated ChatViewModel — without
                    // .detached, the inherited-context Task pinned the
                    // 500ms sleep and the 5-15s loadModel call to main,
                    // blocking SwiftUI's gesture recognizer and causing
                    // multi-second UI freezes during 4-seat salon turns
                    // (Mark observed live 2026-05-15). loadModel already
                    // self-routes its @Published mutations to main via
                    // await MainActor.run, so the detach is safe.
                    // See Docs/UI_Thread_Diagnosis_2026-05-15.md.
                    // Cancel any prior in-flight load Task so we don't
                    // race two loads against each other if the user
                    // double-taps a model. The new load supersedes.
                    pendingMLXLoadTask?.cancel()
                    pendingMLXLoadTask = Task.detached { [weak self] in
                        guard let self else { return }
                        // For an MLX→MLX swap, wait for iOS to actually
                        // reclaim the just-freed pages before starting
                        // the next load. The previous behaviour was a
                        // fixed 500 ms sleep; that's empirical and was
                        // insufficient on the 2026-05-18 Phase 2 live
                        // test, where Qwen → Gemma 4 E2B jetsam-killed
                        // Hal mid-load. Now we poll
                        // `os_proc_available_memory()` for up to 3
                        // seconds, returning as soon as we have headroom
                        // for the new model. If headroom never arrives,
                        // the load is attempted anyway and loadModel's
                        // own pre-flight check surfaces a clean error
                        // rather than a process kill. See Item 11 in
                        // HISTORY.md 2026-05-18 and
                        // ProcessMemoryGuard.swift.
                        if isMLXToMLXSwap {
                            let requiredMB = requiredMemoryMBForLoad(resolvedModel)
                            let result = await waitForMemoryHeadroom(
                                requiredMB: requiredMB,
                                timeoutSeconds: 3.0
                            )
                            if result.success {
                                halLog("HALDEBUG-MLX: Memory headroom reached for \(model.displayName) after \(result.pollsTaken) polls / \(String(format: "%.2f", result.elapsedSeconds))s; availableMB=\(String(format: "%.0f", result.finalAvailableMB)) requiredMB=\(String(format: "%.0f", requiredMB)) — starting load")
                            } else {
                                halLog("HALDEBUG-MLX: Memory headroom NOT reached within 3s for \(model.displayName) (\(result.pollsTaken) polls, availableMB=\(String(format: "%.0f", result.finalAvailableMB)) requiredMB=\(String(format: "%.0f", requiredMB))) — proceeding to load; pre-flight check will refuse if still insufficient")
                            }
                        }
                        await self.mlxWrapper.loadModel(modelConfig: resolvedModel)
                        if let mlxError = await self.mlxWrapper.mlxError {
                            await MainActor.run {
                                self.initializationError = mlxError
                            }
                        }
                    }
                    halLog("HALDEBUG-MLX: MLXWrapper loading triggered for \(model.displayName) at \(resolvedPath.path)")
                } else {
                    self.initializationError = "MLX model not downloaded. Please download it first."
                    halLog("HALDEBUG-MLX: MLX model \(model.displayName) not downloaded — diskPath: \(diskPath?.path ?? "nil"), diskHasModel: \(diskHasModel)")
                }
            } else {
                halLog("HALDEBUG-MLX: MLX model \(model.displayName) already loaded.")
            }
        } else {
            // SWITCHING TO FOUNDATION MODELS: Unload MLX to free memory…
            // unless a caller (Salon Mode) needs it to stay resident across
            // a multi-seat turn.
            if mlxWrapper.isModelLoaded && !keepMlxResident {
                mlxWrapper.unloadModel()
                halLog("HALDEBUG-MLX: Unloaded MLX model, switching to Foundation Models.")
            } else if mlxWrapper.isModelLoaded {
                halLog("HALDEBUG-MLX: Keeping MLX model resident across AFM switch (Salon Mode).")
            } else {
                halLog("HALDEBUG-LLM: Switching to Foundation Models.")
            }
        }
    }


    // TEMPERATURE CHANGE 3/6: Add temperature parameter with default
    // Public non-streaming response function (routes to active LLM for summarization, etc.)
    //
    // ⚠️ DEAD CODE — INTENTIONALLY PRESERVED.
    // Replaced by `generateChatResponse(messages:temperature:)`. As of cbe1ea4
    // (May 11, 2026) nothing in the codebase calls this function — all
    // subsystems flow through the chat-message path. Kept as reference for
    // the legacy single-string-prompt design. Safe to delete whenever.
    func generateResponse(prompt: String, temperature: Double = 0.7) async throws -> String {
        // CHANGE 1/2: Add response logging to identify which model is responding
        print("HALDEBUG-RESPONSE: ðŸŽ¤ \(currentModel.displayName) (\(currentModel.source)) is responding")
        print("HALDEBUG-LLM: generateResponse called - currentModel: \(currentModel.displayName) (source: \(currentModel.source))")
        switch currentModel.source {
        case .appleFoundation:
            let session = LanguageModelSession()
            print("HALDEBUG-LLM: Generating non-streaming from FoundationModels for prompt (first 200 chars): \(prompt.prefix(200)).....")
            print("HALDEBUG-LLM: Using temperature: \(temperature)")
            do {
                // TEMPERATURE CHANGE 4/6: Pass temperature via GenerationOptions to AFM session
                // FoundationModels non-streaming is direct
                // Implemented non-streaming by collecting chunks from streamResponse
                var accumulatedText = ""
                let stream = session.streamResponse(options: GenerationOptions(temperature: temperature)) { Prompt(prompt) }
                for try await snapshot in stream {
                    accumulatedText = snapshot.content
                }
                print("HALDEBUG-LLM: FoundationModels non-streaming completed. Length: \(accumulatedText.count)")
                return accumulatedText
            } catch {
                print("HALDEBUG-LLM: Error during FoundationModels non-streaming: \(error.localizedDescription)")
                throw LLMError.predictionFailed(error)
            }
        case .mlx:
            guard mlxWrapper.isModelLoaded else { // Ensure MLX model is loaded before generating
                print("HALDEBUG-MLX: âŒ Cannot generate - MLX model not loaded!")
                throw LLMError.modelNotLoaded
            }
            print("HALDEBUG-MLX: Generating non-streaming from MLX model for prompt (first 200 chars): \(prompt.prefix(200)).....")
            // TEMPERATURE CHANGE 5/6: Pass temperature parameter to MLX wrapper
            return try await mlxWrapper.generate(prompt: prompt, temperature: temperature)
        }
    }

    // MARK: - Chat-Message Generation (new unified path)
    //
    // generateChatResponse is the chat-message-based equivalent of generateResponse.
    // Both AFM and MLX route through here. Each backend converts [HalChatMessage]
    // into its own native types and lets the chat template handle role tagging.
    //
    // The intent is to replace generateResponse over time. For now, both exist;
    // sendMessage/runSingleModelTurn picks the new path. Subsystems like
    // summarization can keep using generateResponse temporarily.
    func generateChatResponse(messages: [HalChatMessage], temperature: Double = 0.7) async throws -> String {
        // Drain the streaming variant. Callers that just want the final
        // string (gate, summarizer, doc summary, reflection, etc.) keep
        // working without change. UI callers should use the streaming
        // variant directly so the partial response renders as tokens
        // arrive instead of after the whole turn completes.
        var full = ""
        for try await chunk in generateChatResponseStream(messages: messages, temperature: temperature) {
            full = chunk
        }
        return full
    }

    /// Streaming variant of `generateChatResponse`. Yields the *cumulative*
    /// response text after each model chunk. Replaces the previous
    /// fake-streaming UX (chars/sec animation after generation finished)
    /// with real token streaming as the model produces output. AFM via
    /// `session.streamResponse` already produces snapshots whose
    /// `.content` is the cumulative text; MLX via `MLXWrapper.generateChatStream`
    /// produces incremental chunks that we accumulate inside the wrapper.
    func generateChatResponseStream(messages: [HalChatMessage], temperature: Double = 0.7) -> AsyncThrowingStream<String, Error> {
        halLog("HALDEBUG-RESPONSE: \(currentModel.displayName) (\(currentModel.source)) is responding [chat-path, streaming]")
        halLog("HALDEBUG-LLM: generateChatResponseStream called - \(messages.count) messages, currentModel: \(currentModel.displayName)")

        switch currentModel.source {
        case .appleFoundation:
            // For AFM, the system message becomes Instructions (if present).
            // Conversation history (.user/.assistant entries before the last .user)
            // will eventually map to a Transcript; for step 0 we have only system+user.
            let systemMessage = messages.first(where: { $0.role == .system })?.content
            let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""

            let session: LanguageModelSession
            if let sys = systemMessage, !sys.isEmpty {
                session = LanguageModelSession(instructions: Instructions(sys))
                halLog("HALDEBUG-LLM-CHAT: AFM session with Instructions (\(sys.count) chars)")
            } else {
                session = LanguageModelSession()
                halLog("HALDEBUG-LLM-CHAT: AFM session without Instructions")
            }

            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        var accumulatedText = ""
                        var lastRepetitionCheck = 0
                        let repetitionCheckEvery = 50  // chars between checks
                        var stoppedForRepetition = false

                        let stream = session.streamResponse(options: GenerationOptions(temperature: temperature)) { Prompt(lastUser) }
                        streamLoop: for try await snapshot in stream {
                            accumulatedText = snapshot.content
                            // snapshot.content IS the cumulative text per
                            // Apple's API contract; just forward it through.
                            continuation.yield(accumulatedText)

                            // In-stream repetition detection (May-15) — same
                            // brake as the MLX path. AFM is much less prone
                            // to runaway loops, but on long generations under
                            // certain prompt shapes it can still get stuck.
                            if accumulatedText.count - lastRepetitionCheck >= repetitionCheckEvery {
                                lastRepetitionCheck = accumulatedText.count
                                if detectRepetitionLoop(in: accumulatedText) {
                                    halLog("HALDEBUG-LLM-CHAT: AFM repetition loop detected at \(accumulatedText.count) chars; stopping early.")
                                    stoppedForRepetition = true
                                    break streamLoop
                                }
                            }
                        }
                        var whitespaceTrimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Repetition-loop cleanup (mirrors MLX path).
                        if stoppedForRepetition {
                            let beforeTrim = whitespaceTrimmed.count
                            whitespaceTrimmed = trimTrailingRepetition(in: whitespaceTrimmed)
                            halLog("HALDEBUG-LLM-CHAT: AFM trimTrailingRepetition stripped \(beforeTrim - whitespaceTrimmed.count) chars of loop residue")
                        }
                        // Universal mid-word-truncation safeguard. AFM's
                        // default maximumResponseTokens is generous but not
                        // infinite — if a long generation hits the internal
                        // cap, trim back to the last word boundary and append
                        // an ellipsis so the user never sees a mid-word cut.
                        // No-op when the response ends naturally.
                        let finalText = trimToWordBoundary(whitespaceTrimmed)
                        if finalText != whitespaceTrimmed {
                            halLog("HALDEBUG-LLM-CHAT: AFM truncation safeguard trimmed \(whitespaceTrimmed.count - finalText.count) chars from a mid-word cut")
                        }
                        if finalText != accumulatedText {
                            continuation.yield(finalText)
                        }
                        halLog("HALDEBUG-LLM-CHAT: AFM response length: \(finalText.count)")
                        continuation.finish()
                    } catch {
                        halLog("HALDEBUG-LLM-CHAT: AFM chat generation error: \(error.localizedDescription)")
                        continuation.finish(throwing: LLMError.predictionFailed(error))
                    }
                }
            }

        case .mlx:
            // Fast path: model resident → generate directly.
            if mlxWrapper.isModelLoaded {
                return mlxWrapper.generateChatStream(messages: messages, temperature: temperature)
            }
            // RELOAD-ON-DEMAND. The MLX model may not be resident for two reasons,
            // and neither should dead-end a chat with "model could not be loaded":
            //   1. Background-unload — Hal unloads MLX on didEnterBackground (see
            //      ~4950) to drop its ~2.5 GB footprint so iOS doesn't jetsam a
            //      backgrounded Hal. A message typed after returning finds it gone.
            //   2. First-turn-after-switch race (Bug 3) — a just-issued SWITCH_MODEL
            //      for a large model may still be loading when the next turn arrives.
            // So: wait for any in-flight load, else trigger a fresh reload of the
            // current model, then generate. The reload reuses the same
            // setupLLM / pendingMLXLoadTask machinery a switch uses (~5-15s for a
            // big model — the user sees the normal thinking state a beat longer,
            // then the answer, instead of an error).
            return AsyncThrowingStream { continuation in
                Task { [weak self] in
                    guard let self else {
                        continuation.finish(throwing: LLMError.modelNotLoaded)
                        return
                    }
                    // 1. Await any load already in flight (e.g. mid-switch → Bug 3).
                    await self.awaitPendingMLXLoad()
                    // 2. Still not resident (e.g. a background-unload left nothing
                    //    pending) → reload the current model and wait for it.
                    if !self.mlxWrapper.isModelLoaded {
                        halLog("HALDEBUG-MLX-CHAT: model not resident (likely background-unload) — reloading \(self.currentModel.displayName) on demand before generating")
                        self.setupLLM(for: self.currentModel)
                        await self.awaitPendingMLXLoad()
                    }
                    // 3. If it still didn't load, surface the real error.
                    guard self.mlxWrapper.isModelLoaded else {
                        halLog("HALDEBUG-MLX-CHAT: reload-on-demand failed — model still not loaded")
                        continuation.finish(throwing: LLMError.modelNotLoaded)
                        return
                    }
                    // 4. Bridge the inner generation stream through to the caller.
                    do {
                        for try await chunk in self.mlxWrapper.generateChatStream(messages: messages, temperature: temperature) {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    enum LLMError: Error, LocalizedError {
        case modelNotLoaded
        case predictionFailed(Error)
        case sessionInitializationFailed
        /// Insufficient process memory headroom for the upcoming turn's
        /// KV cache + generation scratch. Caught by the per-turn pre-flight
        /// in MLXWrapper.generateChatStream (Item 11 follow-up, 2026-05-18).
        /// The .userFacingMessage flavor is shown directly in chat as
        /// Hal's reply; the conversation continues without crashing.
        case insufficientMemoryForTurn(promptTokens: Int, neededMB: Int, availableMB: Int, modelDisplayName: String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The selected language model could not be loaded or is not available."
            case .predictionFailed(let error):
                return "LLM operation failed: \(error.localizedDescription)"
            case .sessionInitializationFailed:
                return "Failed to initialize a fresh language model session."
            case .insufficientMemoryForTurn(let promptTokens, let neededMB, let availableMB, let modelDisplayName):
                let neededGB = Double(neededMB) / 1024.0
                let availableGB = Double(availableMB) / 1024.0
                return "I don't have enough memory to process this turn. The conversation has grown to \(promptTokens) prompt tokens, which \(modelDisplayName) needs roughly \(String(format: "%.1f", neededGB)) GB of working memory to attend to — and I only have \(String(format: "%.1f", availableGB)) GB available right now. Start a new thread to free up the conversation history, or switch to a lighter model: Qwen 3.5 2B uses about half the per-token memory."
            }
        }
    }
}

// ==== LEGO END: 08 MLXWrapper & LLMService (Foundation + MLX Routing) ====



// ==== LEGO START: 8.5 Text Summarization Utilities (LLM + Verification) ====

// MARK: - Text Summarization with Verification
// Battle-tested logic adapted from WikiDB's UnifiedSummarizer
// Two-stage approach: (1) LLM summarizes, (2) Verify against source to prevent hallucinations
// Uses Apple NaturalLanguage embeddings with TF-IDF fallback for robust verification
// NOTE: Foundation and NaturalLanguage are imported in Block 1

/// Result of a summarization attempt. The `didTruncate` flag tells callers
/// (notably `SegmentCompressor`) whether the summarizer was forced to fall
/// back to raw prefix-truncation because intelligent summarization failed
/// — letting them surface honest "truncated" vs "compressed" status in
/// the UI footer instead of silently labeling a truncation as a smart
/// compression.
struct SummarizationResult: Sendable {
    let text: String
    let didTruncate: Bool

    static let empty: SummarizationResult = .init(text: "", didTruncate: false)
}

/// Main summarization utility for Hal
/// Use this anywhere you need to compress text: RAG snippets, conversation history, documents, etc.
struct TextSummarizer {

    // MARK: - Public API

    /// Summarize text with LLM and verify against source to prevent hallucinations.
    /// Returns a `SummarizationResult` that flags whether the summarizer had to
    /// fall back to raw truncation — callers that label compression status in
    /// the UI use that flag to differentiate honest summarization from forced
    /// truncation. For callers that just want a string, the convenience
    /// overload `summarizeWithVerification(...) async -> String` is provided
    /// below.
    ///
    /// Self-knowledge no longer flows through this path (per Mark's 2026-05-16
    /// directive — AFM gets no self-knowledge injection, MLX injects raw).
    /// What remains uses this summarizer is `autoSummary` (conversation
    /// summarization at turn-rollover time) and `shortTermHistory` (rarely,
    /// when history exceeds budget). Both of those segments are designed to
    /// fit in a single LLM call for the active model; chunking is not needed.
    /// If the underlying LLM call rejects the input as too large, we surface
    /// that honestly via `didTruncate=true` so the UI footer can render the
    /// scissors icon (red) rather than the compression icon (gray).
    static func summarizeWithVerificationDetailed(
        text: String,
        targetTokens: Int,
        llmService: LLMService,
        verificationThreshold: Double = 0.72,
        useRecencyWeighting: Bool = false
    ) async -> SummarizationResult {
        print("HALDEBUG-SUMMARIZER: Starting summarization - source: \(text.count) chars, target: \(targetTokens) tokens, recency weighting: \(useRecencyWeighting), active model context window: \(llmService.activeContextWindow)")

        // Stage 1: LLM summarize (chunked when needed)
        let stage1 = await llmSummarize(
            text: text,
            targetTokens: targetTokens,
            llmService: llmService,
            useRecencyWeighting: useRecencyWeighting
        )

        guard !stage1.text.isEmpty else {
            // Every chunk failed (or single-call path returned empty). Fall
            // back to raw prefix-truncation and SURFACE that truncation
            // happened so the UI can render the scissors icon honestly.
            print("HALDEBUG-SUMMARIZER: LLM returned empty summary after \(stage1.didTruncate ? "chunked" : "single-call") attempt — falling back to truncation")
            let truncated = String(text.prefix(TokenEstimator.estimateChars(from: targetTokens)))
            return SummarizationResult(text: truncated, didTruncate: true)
        }

        print("HALDEBUG-SUMMARIZER: LLM summary generated: \(stage1.text.count) chars (didTruncate=\(stage1.didTruncate))")

        // Stage 2: Verify against source (prevent hallucinations)
        let sourceSentences = sentenceSplit(text)
        let verified = await verifyNarrative(stage1.text, against: sourceSentences, threshold: verificationThreshold)

        print("HALDEBUG-SUMMARIZER: Verification complete: \(verified.count) chars")

        return SummarizationResult(text: verified, didTruncate: stage1.didTruncate)
    }

    /// String-only convenience overload. Use this for callers that don't need
    /// the truncation flag (e.g., document-import summaries, auto-summary).
    /// Internally calls `summarizeWithVerificationDetailed` and returns the
    /// `.text` field.
    static func summarizeWithVerification(
        text: String,
        targetTokens: Int,
        llmService: LLMService,
        verificationThreshold: Double = 0.72,
        useRecencyWeighting: Bool = false
    ) async -> String {
        let result = await summarizeWithVerificationDetailed(
            text: text,
            targetTokens: targetTokens,
            llmService: llmService,
            verificationThreshold: verificationThreshold,
            useRecencyWeighting: useRecencyWeighting
        )
        return result.text
    }

    // MARK: - Stage 1: LLM Summarization (single-call)

    /// Single-call LLM summarization. Builds the appropriate prompt
    /// (standard or recency-weighted for Salon), invokes the active model
    /// once, returns the result wrapped in a `SummarizationResult`.
    ///
    /// On any LLM error — including context-window overflow — returns an
    /// empty result with `didTruncate: true` so the caller can surface
    /// honest truncation in the UI footer. This summarizer used to attempt
    /// chunked summarization with empirical halving on AFM overflow; that
    /// approach was removed (per Mark's 2026-05-16 directive) because:
    ///   - The remaining callers (`autoSummary`, `shortTermHistory`) have
    ///     segment budgets that comfortably fit a single LLM call on the
    ///     active model.
    ///   - Self-knowledge no longer flows through this path at all.
    ///   - When an LLM call legitimately can't handle the input, the right
    ///     behavior is to surface the failure (didTruncate=true → scissors
    ///     icon in the footer), not to silently chunk-and-stitch.
    private static func llmSummarize(
        text: String,
        targetTokens: Int,
        llmService: LLMService,
        useRecencyWeighting: Bool
    ) async -> SummarizationResult {
        let prompt: String

        if useRecencyWeighting {
            // Salon Mode prompt with recency weighting and information density
            prompt = """
            Summarize this conversation in approximately \(targetTokens) tokens.

            CRITICAL INSTRUCTIONS:
            1. Allocate summary space based on INFORMATION DENSITY - brief exchanges (like "what time is it") deserve minimal space, substantive discussions deserve proportional detail
            2. Preserve attribution (which model/seat said what)

            WEIGHTING STRATEGY:
            - If there are fewer than 10 turns: Weight all turns roughly equally
            - If there are 10 or more turns: Weight recent turns MORE HEAVILY than older turns as follows:
              * Most recent 20% of turns: approximately 40% of summary space
              * Middle 60% of turns: approximately 40% of summary space
              * Oldest 20% of turns: approximately 20% of summary space

            Adjust dynamically based on content density regardless of turn count.

            Do not add interpretation or commentary. Extract and compress only.
            Do not include citations, footnote markers, or reference numbers.
            Write clear, complete sentences.

            Text to summarize:
            \(text)

            Summary (approximately \(targetTokens) tokens):
            """
        } else {
            // Standard prompt for single-LLM mode
            prompt = """
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
        }

        do {
            // Chat-message path so chat-template models (Gemma 4, etc.) work.
            let result = try await llmService.generateChatResponse(
                messages: [.system("You compress text faithfully while preserving meaning and attribution."), .user(prompt)],
                temperature: 0.3
            )
            return SummarizationResult(
                text: result.trimmingCharacters(in: .whitespacesAndNewlines),
                didTruncate: false
            )
        } catch {
            halLog("HALDEBUG-SUMMARIZER: LLM summarization failed: \(error.localizedDescription)")
            return SummarizationResult(text: "", didTruncate: true)
        }
    }

    // MARK: - Stage 2: Verification Against Source
    
    /// Verify each sentence in summary is grounded in source text.
    ///
    /// Uses `EmbeddingProvider` (NLContextualEmbedding) — the same
    /// embedding system the RAG path uses, so verification quality
    /// tracks retrieval quality. If the embedding model isn't loaded
    /// yet (first-launch asset download in progress), falls back to
    /// the TF-IDF sentence comparison — a real algorithmic fallback,
    /// not a placeholder.
    ///
    /// Replaces ungrounded sentences with the nearest source sentence
    /// (cosine similarity above `threshold`).
    static func verifyNarrative(
        _ summary: String,
        against sourceSentences: [String],
        threshold: Double
    ) async -> String {
        let outputSentences = sentenceSplit(summary)
        guard !outputSentences.isEmpty else { return summary }

        print("HALDEBUG-SUMMARIZER: Verifying \(outputSentences.count) sentences against \(sourceSentences.count) source sentences")

        // Precompute source sentence vectors via the shared embedding
        // provider. Any source sentence that fails to embed is skipped
        // (won't be a replacement candidate); we keep the rest so
        // partial coverage still helps.
        var sourceVecs: [[Double]] = []
        var sourceKeep: [String] = []
        sourceVecs.reserveCapacity(sourceSentences.count)

        for s in sourceSentences {
            let v = EmbeddingProvider.shared.embed(s) ?? []
            if !v.isEmpty {
                sourceVecs.append(v)
                sourceKeep.append(s)
            }
        }

        if sourceVecs.isEmpty {
            print("HALDEBUG-SUMMARIZER: No source vectors generated (embedding model not loaded yet?), using TF-IDF fallback")
            return verifyNarrative_TFIDF(summary, against: sourceSentences, threshold: threshold)
        }

        // Local cosine — verification runs in TextSummarizer (struct, no
        // MemoryStore instance handy), so we inline the same math used by
        // MemoryStore.cosineSimilarity.
        func cosine(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count && a.count > 0 else { return 0 }
            let dot = zip(a, b).map(*).reduce(0, +)
            let na = sqrt(a.map { $0 * $0 }.reduce(0, +))
            let nb = sqrt(b.map { $0 * $0 }.reduce(0, +))
            return na == 0 || nb == 0 ? 0 : dot / (na * nb)
        }

        var verified: [String] = []
        var replacedCount = 0

        for s in outputSentences {
            let v = EmbeddingProvider.shared.embed(s) ?? []
            guard !v.isEmpty else {
                // Can't embed this output sentence — use TF-IDF to find best source match
                verified.append(bestMatchTFIDF(for: s, in: sourceSentences))
                replacedCount += 1
                continue
            }

            var bestSim = -1.0
            var bestIdx = 0
            for (i, u) in sourceVecs.enumerated() {
                let sim = cosine(v, u)
                if sim > bestSim {
                    bestSim = sim
                    bestIdx = i
                }
            }

            if bestSim >= threshold {
                verified.append(s)
            } else {
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
//
// EXTRACTED 2026-05-26 (refactor #6): LEGO 09 and 09.5 now live
// together with LEGO 13 + 13.5 in `Hal Universal/ChatViews.swift`.
// Same Swift module — fully accessible from this file. The @main
// `Hal10000App` struct (the app entry point) moved with the lift.
//
// ==== LEGO END: 09.5 ThreadPanelView ====


// ==== LEGO START: 10.1 MainSettingsView ====
//
// EXTRACTED 2026-05-26 (refactor #5): LEGO 10.1, 10.2, 10.3,
// 10.3.5, and 10.4 now live together in
// `Hal Universal/SettingsViews.swift`. Same Swift module — fully
// accessible from this file. The five LEGO blocks are preserved
// verbatim inside the new file so the numbering chain still
// reads end-to-end through Hal_Source.txt.
//
// Naming note: the LEGO 10.1 title says "MainSettingsView" but
// the actual entry-point struct is `ActionsView` (historical
// holdover from v1.x). Search SettingsViews.swift for `ActionsView`
// when you want the top-level settings sheet.
//
// ==== LEGO END: 10.4 SalonModeView (Multi-LLM Configuration) ====



// ==== LEGO START: 11.5 Model Library UI ====

// MARK: - Unified Model Status Dot
//
// Single source of truth for the "is this model available / am I using it"
// affordance across every surface that shows model status. Three-state, one
// meaning each:
//
//   - GREEN  — downloaded and currently active (AFM always counts as downloaded)
//   - GREY   — downloaded but not active
//   - (none) — not downloaded
//
// No blue dots, no blue checkmarks, no orange-downloading / red-error states —
// download progress and error states have their own UI (progress bar + error
// row in the model card). This helper exists so the three accepted states are
// rendered identically wherever they appear.
//
// Per Strategic Claude's May-14 dot-language directive.
@ViewBuilder
func modelStatusDot(
    for model: ModelConfiguration,
    downloader: MLXModelDownloader,
    activeModelID: String
) -> some View {
    let isDownloaded = model.source == .appleFoundation || downloader.isModelDownloaded(model.id)
    let isActive = activeModelID == model.id
    if isDownloaded {
        Circle()
            .fill(isActive ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 8, height: 8)
            .accessibilityLabel(isActive ? "Downloaded and active" : "Downloaded")
    }
    // No dot when not downloaded.
}

// EmbedderMigrationCoordinator + EmbedderBackendRow + EmbedderMigrationStatusRow
// extracted to EmbedderMigrationCoordinator.swift on 2026-05-17.

// MARK: - Model Library View
//
// May-14 rebuild per Strategic Claude's directive (autonomous workstream):
//   - Two sections, one scroll: "Hal's Picks" (AFM + 4 tested MLX) at top,
//     "Community Models" (the experimental HF catalog) at bottom.
//   - Accordion-expand-in-place rows. Collapsed = name + size + status dot.
//     Expanded = full model card (voice, performance, Maxim compliance,
//     license, and the primary action button).
//   - Unified status-dot language: green = downloaded+active,
//     grey = downloaded+inactive, no dot = not downloaded. No blue dots,
//     no blue checkmarks, no transitional dot states.
//   - Search bar at the top of Community Models for the long HF list.
//
// AFM appears in Hal's Picks as the first row — it's tested, system-managed,
// and always present. The detail card adapts (no tok/s, no download size,
// no license) and the action button is just Select/Active.
struct ModelLibraryView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var mlxDownloader: MLXModelDownloader
    @ObservedObject private var catalog = ModelCatalogService.shared

    @State private var selectedModelForLicense: ModelConfiguration?
    @State private var modelToDelete: ModelConfiguration?
    @State private var showingDeleteConfirmation = false
    @State private var showingHardwareDisclosure = false
    @State private var pendingModelAfterDisclosure: ModelConfiguration?
    // True only when the user tapped "I Understand" (vs Cancel / swipe-away),
    // so the disclosure sheet's onDismiss knows whether to resume the pending
    // download/select. See the .sheet(isPresented: $showingHardwareDisclosure)
    // modifier for why the resume must happen in onDismiss, not onContinue.
    @State private var disclosureAcknowledged = false
    @State private var librarySearchText: String = ""

    // Surfaces a one-time hardware-compatibility warning the first time the
    // user attempts to download or switch to any MLX model.
    @AppStorage("hasSeenHardwareDisclosure") private var hasSeenHardwareDisclosure: Bool = false

    var body: some View {
        List {
                // ── HAL'S PICKS ──────────────────────────────────────────
                Section {
                    ForEach(halsPicks) { model in
                        ModelLibraryRow(
                            model: model,
                            isActive: chatViewModel.selectedModelID == model.id,
                            downloader: mlxDownloader,
                            activeModelID: chatViewModel.selectedModelID,
                            includeModelCard: true,
                            apiExpandRowID: chatViewModel.apiExpandRowID,
                            onSelect: { selectModel(model) },
                            onDownload: { downloadModel(model) },
                            onCancel: { mlxDownloader.cancelDownload(modelID: model.id) },
                            onDelete: { requestDeleteModel(model) }
                        )
                    }
                } header: {
                    Label("Hal's Picks", systemImage: "checkmark.seal")
                } footer: {
                    Text("Five voices, each tested with Hal. Tap a model to see its character, performance, and Maxim alignment.")
                        .font(.caption2)
                }

                // ── EMBEDDING (MEMORY) ──────────────────────────────────
                // Switchable embedder backends. Apple NLContextual is the
                // built-in default; Nomic and mxbai are optional stronger
                // downloads. As of v2.1 step 2, switching is instant and
                // non-destructive — each backend keeps its own vector column,
                // so no re-embed is needed to switch back.
                Section {
                    // Render one row per available backend. Backends with
                    // isAvailableInThisBuild == false (e.g. Gemma in App
                    // Store builds) are skipped so the user only sees
                    // options that actually work.
                    ForEach(EmbeddingBackend.allCases.filter { $0.isAvailableInThisBuild }, id: \.rawValue) { backend in
                        EmbedderBackendRow(backend: backend)
                    }
                    EmbedderMigrationStatusRow()
                } header: {
                    Label("Embedding (Memory)", systemImage: "brain")
                } footer: {
                    Text("The embedding model powers how Hal recalls your memories during chat. Apple NLContextual is built in and always available; Nomic Embed Text v1.5 (~522 MB) and Mixedbread mxbai (~670 MB) are optional stronger downloads. Switching between them is instant and non-destructive — each keeps its own copy of your memory vectors, and Hal fills in a newly chosen one in the background.")
                        .font(.caption2)
                }

                // ── COMMUNITY MODELS (EXPERIMENTAL) ──────────────────────
                Section {
                    // Warning banner — first thing the user reads in this
                    // section, before any rows. Promotes the previous footer
                    // text per Strategic Claude's "name the risk" guidance.
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .imageScale(.small)
                        Text("These models haven't been tested with Hal — chat templates may misbehave, responses may be unexpected, performance varies.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)

                    // Inline catalog-loading indicator. Lives in the
                    // scrollable section (not a floating overlay) so it
                    // never obscures Hal's Picks above. Collapses
                    // automatically when catalog.isLoading flips false.
                    if catalog.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading models from Hugging Face…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .transition(.opacity)
                    }

                    // Local search bar (not the global .searchable so it
                    // only filters this section).
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        TextField("Search community models", text: $librarySearchText)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.subheadline)
                        if !librarySearchText.isEmpty {
                            Button(action: { librarySearchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    if filteredLibraryModels.isEmpty && !catalog.isLoading {
                        // While catalog.isLoading is true the inline
                        // loading row above is doing the talking; we
                        // suppress this empty-state copy then so the
                        // user isn't told "no models" mid-fetch.
                        Text(librarySearchText.isEmpty
                             ? "No experimental community models available right now."
                             : "No community models match \"\(librarySearchText)\".")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else if !filteredLibraryModels.isEmpty {
                        ForEach(filteredLibraryModels) { model in
                            ModelLibraryRow(
                                model: model,
                                isActive: chatViewModel.selectedModelID == model.id,
                                downloader: mlxDownloader,
                                activeModelID: chatViewModel.selectedModelID,
                                includeModelCard: false,
                                apiExpandRowID: chatViewModel.apiExpandRowID,
                                onSelect: { selectModel(model) },
                                onDownload: { downloadModel(model) },
                                onCancel: { mlxDownloader.cancelDownload(modelID: model.id) },
                                onDelete: { requestDeleteModel(model) }
                            )
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Label("Community Models", systemImage: "books.vertical")
                        Text("Experimental")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
            .navigationTitle("Model Library")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await chatViewModel.refreshModelCatalog()
                ModelCatalogService.shared.refreshDownloadStates()
            }
            .sheet(item: $selectedModelForLicense) { model in
                ModelLicenseSheet(
                    model: model,
                    onAccept: {
                        ModelCatalogService.shared.acceptLicense(for: model.id)
                        selectedModelForLicense = nil
                        Task {
                            await mlxDownloader.startDownload(modelID: model.id, repoID: model.id, sizeGB: model.sizeGB)
                        }
                    },
                    onCancel: {
                        selectedModelForLicense = nil
                    }
                )
            }
            // The hardware disclosure and the license sheet (above) are two
            // separate `.sheet` modifiers on this same view, and SwiftUI can't
            // present two at once. So the follow-on step (license sheet, or the
            // download itself) must be kicked off only AFTER this sheet has
            // fully dismissed — doing it from inside onContinue, while this
            // sheet is still up, silently drops the second presentation and the
            // "I Understand" tap looks dead. onContinue therefore just records
            // intent + dismisses; onDismiss resumes once the sheet is gone.
            .sheet(isPresented: $showingHardwareDisclosure, onDismiss: {
                if disclosureAcknowledged {
                    disclosureAcknowledged = false
                    resumeAfterDisclosure()
                } else {
                    // Cancelled or swiped away — drop the pending action.
                    pendingModelAfterDisclosure = nil
                }
            }) {
                HardwareDisclosureSheet(
                    onContinue: {
                        disclosureAcknowledged = true
                        showingHardwareDisclosure = false
                    },
                    onCancel: {
                        showingHardwareDisclosure = false
                    }
                )
            }
            .alert("Delete Model?", isPresented: $showingDeleteConfirmation, presenting: modelToDelete) { model in
                Button("Cancel", role: .cancel) {
                    print("HALDEBUG-UI: User cancelled deletion of model: \(model.id)")
                }
                Button("Delete", role: .destructive) {
                    print("HALDEBUG-UI: User confirmed deletion of model: \(model.id)")
                    deleteModel(model)
                }
            } message: { model in
                if let size = model.sizeGB {
                    Text("This will permanently delete \(model.displayName) (\(String(format: "%.1f", size)) GB).")
                } else {
                    Text("This will permanently delete \(model.displayName).")
                }
            }
    }

    // MARK: - Model partitioning

    /// AFM + 4 curated MLX models (whether downloaded or not). AFM first,
    /// then curated in their seed order (philosopher first → unhedged last).
    private var halsPicks: [ModelConfiguration] {
        let afm = ModelCatalogService.shared.getModel(byID: ModelConfiguration.appleFoundation.id) ?? .appleFoundation
        return [afm] + ModelConfiguration.curatedSeeds
    }

    /// IDs that belong to Hal's Picks. Used to exclude them from Community.
    private static var halsPicksIDs: Set<String> {
        var ids: Set<String> = ["apple-foundation-models"]
        for model in ModelConfiguration.curatedSeeds { ids.insert(model.id) }
        return ids
    }

    /// Library / Community Models = HF catalog minus AFM minus curated.
    /// Filtered by `librarySearchText` (matches displayName or repo id).
    private var filteredLibraryModels: [ModelConfiguration] {
        let library = ModelCatalogService.shared.availableModels.filter { model in
            model.source == .mlx && !Self.halsPicksIDs.contains(model.id)
        }
        guard !librarySearchText.isEmpty else {
            return library.sorted { $0.displayName < $1.displayName }
        }
        let needle = librarySearchText.lowercased()
        return library
            .filter { $0.displayName.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
            .sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Actions

    private func selectModel(_ model: ModelConfiguration) {
        guard model.source == .appleFoundation || mlxDownloader.isModelDownloaded(model.id) else {
            return  // Can't select undownloaded MLX model
        }

        // First-time hardware disclosure: any switch from AFM into a local
        // MLX model triggers a one-time compatibility warning so users on
        // older hardware know what to expect.
        if model.source == .mlx && !hasSeenHardwareDisclosure {
            pendingModelAfterDisclosure = model
            showingHardwareDisclosure = true
            return
        }

        // Dismiss immediately, then load in the background. Previously we awaited
        // switchToModel (which blocks ~5-15s on the MLX load) BEFORE dismissing,
        // so AFM (nothing to load) bounced to chat instantly while an MLX model
        // appeared to "hold" in the Library for its load. Dismissing first makes
        // both feel identical; the chat view shows the load state, and
        // switchToModel's own failure/revert logic surfaces in chat rather than
        // freezing the Library.
        dismiss()
        Task {
            await chatViewModel.switchToModel(model)
        }
    }

    private func downloadModel(_ model: ModelConfiguration) {
        // First-time hardware disclosure also gates the very first MLX
        // download — the model file is big and the storage requirement is
        // worth setting expectations about before committing.
        if !hasSeenHardwareDisclosure {
            pendingModelAfterDisclosure = model
            showingHardwareDisclosure = true
            return
        }

        if !ModelCatalogService.shared.hasAcceptedLicense(for: model.id) {
            selectedModelForLicense = model
        } else {
            Task {
                await mlxDownloader.startDownload(modelID: model.id, repoID: model.id, sizeGB: model.sizeGB)
            }
        }
    }

    /// Resume the pending action once the user dismisses the disclosure sheet.
    private func resumeAfterDisclosure() {
        hasSeenHardwareDisclosure = true
        guard let model = pendingModelAfterDisclosure else { return }
        pendingModelAfterDisclosure = nil

        if mlxDownloader.isModelDownloaded(model.id) {
            Task {
                await chatViewModel.switchToModel(model)
                dismiss()
            }
        } else {
            if !ModelCatalogService.shared.hasAcceptedLicense(for: model.id) {
                selectedModelForLicense = model
            } else {
                Task {
                    await mlxDownloader.startDownload(modelID: model.id, repoID: model.id, sizeGB: model.sizeGB)
                }
            }
        }
    }

    private func requestDeleteModel(_ model: ModelConfiguration) {
        print("HALDEBUG-UI: Delete button tapped for model: \(model.id)")
        modelToDelete = model
        showingDeleteConfirmation = true
    }

    private func deleteModel(_ model: ModelConfiguration) {
        Task {
            await mlxDownloader.deleteModel(modelID: model.id)

            // If deleted model was active, fall back to AFM and announce.
            if chatViewModel.selectedModelID == model.id {
                await chatViewModel.switchToModel(.appleFoundation)

                await MainActor.run {
                    let userMsg = "Hal, I deleted the \(model.displayName) model."
                    let halMsg = "No problem! I've switched over to Apple Intelligence so we can keep chatting without interruption. You can re-download \(model.displayName) from the Model Library whenever you're ready."
                    let currentTurn = chatViewModel.memoryStore.getCurrentTurnNumber(conversationId: chatViewModel.conversationId) + 1
                    chatViewModel.messages.append(ChatMessage(content: userMsg, isFromUser: true, recordedByModel: "user", turnNumber: currentTurn))
                    chatViewModel.messages.append(ChatMessage(content: halMsg, isFromUser: false, recordedByModel: chatViewModel.selectedModel.id, turnNumber: currentTurn))
                }
            }
        }
    }
}

// MARK: - Expandable Model Library Row
//
// One row in either section of Model Library. Collapsed: name + size + dot.
// Tap to expand accordion-style in place. Expanded body adapts to context:
//
//   - In-flight download → progress bar + cancel button.
//   - includeModelCard=true → ModelDetailCard (voice/perf/Maxim/license)
//     plus the primary action button.
//   - includeModelCard=false → short description (or generic untested-note)
//     plus the primary action button. Used by Community Models rows where
//     no scorecard/benchmark data exists.
//
// Per-row `@State isExpanded` keeps each row's accordion independent of the
// others — no need for a parent-owned expanded-set or selection state.
struct ModelLibraryRow: View {
    let model: ModelConfiguration
    let isActive: Bool
    @ObservedObject var downloader: MLXModelDownloader
    let activeModelID: String
    let includeModelCard: Bool
    // Mirror of ChatViewModel.apiExpandRowID (test/screenshot automation). When it
    // equals this row's model.id, the row expands; anything else collapses it. The
    // user still drives expansion by tapping the chevron; this only adds a
    // programmatic path so the harness can screenshot the expanded card.
    var apiExpandRowID: String = ""

    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded: Bool = false

    private var downloadState: MLXModelDownloader.DownloadState? {
        downloader.downloadStates[model.id]
    }

    private var isDownloaded: Bool {
        model.source == .appleFoundation || downloader.isModelDownloaded(model.id)
    }

    private var isDownloading: Bool {
        downloadState?.isDownloading == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Collapsed header (always visible) ────────────────────
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() } }) {
                HStack(spacing: 10) {
                    Text(model.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let size = model.sizeGB {
                        Text("\(String(format: "%.1f", size)) GB")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    modelStatusDot(for: model, downloader: downloader, activeModelID: activeModelID)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Expanded body ───────────────────────────────────────
            if isExpanded {
                Divider().padding(.vertical, 8)

                if isDownloading, let state = downloadState {
                    downloadProgressView(state)
                } else {
                    if includeModelCard {
                        ModelDetailCard(model: model)
                    } else {
                        if let description = model.description {
                            Text(description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 8)
                        } else {
                            Text("Untested with Hal. Download to experiment — chat templates may misbehave and performance varies.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 8)
                        }
                    }
                    actionRow
                }
            }
        }
        .padding(.vertical, 4)
        // Programmatic expansion for test/screenshot automation. Fires when the
        // VM's apiExpandRowID changes (threaded in from ModelLibraryView).
        .onChange(of: apiExpandRowID) { _, newID in
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded = (newID == model.id) }
        }
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if isDownloaded {
                Button(action: onSelect) {
                    HStack(spacing: 4) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        Text(isActive ? "Active" : "Select")
                    }
                    .font(.subheadline)
                    .foregroundColor(isActive ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isActive)

                Spacer()

                // Delete is only meaningful for MLX (AFM is system-managed).
                // For the model you're currently running, show a short reason IN
                // PLACE OF the Delete button rather than hiding it silently — a
                // missing button reads as "this can't be deleted" with no
                // explanation, which looks like a bug. You can't delete the model
                // that's in use; switch away first.
                if model.source == .mlx {
                    if isActive {
                        Text("Switch models to delete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button(action: onDelete) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(.subheadline)
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let state = downloadState, state.error != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.error ?? "Download failed")
                        .font(.caption)
                        .foregroundColor(.red)
                    Button(action: onDownload) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: onDownload) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download")
                    }
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func downloadProgressView(_ state: MLXModelDownloader.DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: state.progress)
            HStack {
                Text(state.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Model Detail Card
//
// The full card body shown when a Hal's-Picks row is expanded. Surfaces
// description, voice tag, performance characteristics, context window,
// Maxim compliance, and license. Each section adapts to nil data so AFM
// (no tok/s, no license, no size) and any future curated model missing a
// field still render cleanly.
struct ModelDetailCard: View {
    let model: ModelConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Voice tag chip
            if let tag = model.voiceTag {
                HStack(spacing: 6) {
                    Text(tag)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                    Spacer()
                }
            }

            // Description (full text — no lineLimit)
            if let description = model.description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Performance / size / context window
            performanceSection

            // Maxim compliance
            if let scorecard = model.maximCompliance {
                MaximScorecardView(scorecard: scorecard)
            }

            // License
            if let license = model.license {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("License: \(license.uppercased())")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Performance", systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption)
                .foregroundColor(.secondary)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                if let gen = model.generationTokensPerSec {
                    statCell("Generation", "\(String(format: "%.1f", gen)) tok/s")
                }
                if let prefill = model.prefillTokensPerSec {
                    statCell("Prefill", formatTokensPerSec(prefill))
                }
                statCell("Context", formatContextWindow(model.contextWindow))
                if let size = model.sizeGB {
                    statCell("Download", "\(String(format: "%.1f", size)) GB")
                } else if model.source == .appleFoundation {
                    statCell("Download", "System-managed")
                }
            }
        }
    }

    /// Stacked label-above-value cell. Each cell gets its full half-column
    /// width so "Generation" / "Prefill" / "Download" don't have to compete
    /// horizontally with their numeric values (the inline `[label] [value]`
    /// layout caused "Genera-tion" to wrap when the column was tight).
    @ViewBuilder
    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }

    private func formatTokensPerSec(_ value: Double) -> String {
        if value >= 1000 {
            return "\(Int(value / 1000))K tok/s"
        }
        return "\(Int(value)) tok/s"
    }

    private func formatContextWindow(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return "\(tokens / 1000)K"
        }
        return "\(tokens)"
    }
}

// MARK: - Maxim Scorecard View
//
// Five-row at-a-glance compliance summary, one row per Maxim. Each row shows
// a tinted icon (Standout/Pass/Mixed/Fail), the Maxim's short label, and a
// one-line caption naming the Maxim's intent. Source: `MaximScorecard`.
struct MaximScorecardView: View {
    let scorecard: MaximScorecard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Five Maxims", systemImage: "list.bullet.indent")
                .font(.caption)
                .foregroundColor(.secondary)
            row(rating: scorecard.m1Uncertainty, label: "Uncertainty",   caption: "Can say \"I don't know\".")
            row(rating: scorecard.m2Reflection,  label: "Reflection",    caption: "Explains its own architecture.")
            row(rating: scorecard.m3Memory,      label: "Memory",        caption: "Recalls facts across conversations.")
            row(rating: scorecard.m4Refusal,     label: "Refusal",       caption: "Declines harmful requests.")
            row(rating: scorecard.m5Evolution,   label: "Participation", caption: "Engages with self-modification.")
        }
    }

    /// Two-line row: icon spans both lines on the left; label + rating word
    /// on the top line; caption (full text, may wrap) on the second line.
    /// Earlier inline layout squeezed the caption between label and rating
    /// and clipped it with an ellipsis on every Maxim — this layout gives
    /// the caption the row's full width.
    @ViewBuilder
    private func row(rating: MaximScorecard.Rating, label: String, caption: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rating.systemImage)
                .foregroundColor(rating.tint)
                .font(.caption)
                .frame(width: 14)
                .padding(.top, 1)  // optical alignment with first text line
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(rating.summary)
                        .font(.caption2)
                        .foregroundColor(rating.tint)
                }
                Text(caption)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension MaximScorecard.Rating {
    var systemImage: String {
        switch self {
        case .standout: return "star.fill"
        case .pass:     return "checkmark.circle.fill"
        case .mixed:    return "minus.circle.fill"
        case .fail:     return "xmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .standout: return .yellow
        case .pass:     return .green
        case .mixed:    return .orange
        case .fail:     return .red
        }
    }
    var summary: String {
        switch self {
        case .standout: return "Standout"
        case .pass:     return "Pass"
        case .mixed:    return "Mixed"
        case .fail:     return "Fail"
        }
    }
}

// MARK: - Hardware Disclosure Sheet
//
// Shown ONCE the first time the user attempts to download an MLX model or
// switch from AFM to a downloaded MLX model. Sets expectations about which
// hardware Hal's local-model pipe has been validated on so users with older
// iPhones aren't surprised by slow generation or load failures. The
// `hasSeenHardwareDisclosure` flag in @AppStorage gates re-presentation.
struct HardwareDisclosureSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local Models on Your iPhone")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("First-time setup")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 6)

                    Text("Hal's local models run entirely on your iPhone — nothing leaves the device. The trade-off compared to Apple Intelligence is they need more memory and storage, and respond more slowly.")
                        .font(.body)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Validated hardware", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        Text("Hal's local models are tested and supported on:")
                            .font(.subheadline)
                        VStack(alignment: .leading, spacing: 4) {
                            bullet("iPhone 16, 16 Plus, 16 Pro, 16 Pro Max")
                            bullet("iPhone 17 and newer (should work or work better)")
                        }
                        Text("Older devices may work but are unverified. iPhone 15 Pro / 15 Pro Max are likely OK; iPhone 14 and earlier may run very slowly or fail to load larger models.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Storage & download", systemImage: "internaldrive")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            bullet("Each curated model is roughly 2–4 GB")
                            bullet("First download is one-time per model")
                            bullet("Wi-Fi strongly recommended for the initial download")
                            bullet("After download, the model runs fully offline")
                        }
                    }

                    Divider()

                    Text("You can revisit this information anytime in Settings → Power User → Local Models.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Before You Continue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("I Understand") { onContinue() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .foregroundColor(.secondary)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Model License Sheet
struct ModelLicenseSheet: View {
    let model: ModelConfiguration
    let onAccept: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(licenseName)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("By downloading \(model.displayName), you agree to its license terms.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Download Warnings FIRST
                    if let size = model.sizeGB {
                        VStack(alignment: .leading, spacing: 12) {
                            // Size warning
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Large Download: \(String(format: "%.1f", size)) GB")
                                        .fontWeight(.semibold)
                                }
                                Text("Requires \(String(format: "%.1f", size)) GB storage and bandwidth")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)

                            // WiFi warning for >1GB
                            if size > 1.0 {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Image(systemName: "wifi")
                                            .foregroundColor(.blue)
                                        Text("WiFi Recommended")
                                            .fontWeight(.semibold)
                                    }
                                    Text("Connect to WiFi to avoid cellular data charges")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }

                    Divider()

                    // License Info
                    VStack(alignment: .leading, spacing: 12) {
                        Text("License: \(model.license?.uppercased() ?? "CUSTOM")")
                            .font(.headline)

                        if let description = licenseDescription {
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Link(destination: URL(string: "https://huggingface.co/\(model.id)")!) {
                            HStack {
                                Image(systemName: "link")
                                Text("View Full License on Hugging Face")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .foregroundColor(.blue)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }

                    Divider()

                    // Inline action buttons — guaranteed visible on Mac Catalyst where
                    // NavigationStack toolbar items may not render in sheets.
                    VStack(spacing: 12) {
                        Button(action: onAccept) {
                            Text("Accept & Download")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: onCancel) {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle(model.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var licenseName: String {
        guard let license = model.license else { return "License Agreement" }
        
        switch license.lowercased() {
        case "mit": return "MIT License"
        case "apache-2.0": return "Apache 2.0"
        case "llama2": return "Llama 2 Community License"
        case "llama3", "llama3.1", "llama3.2": return "Llama 3 Community License"
        case "gemma": return "Gemma Terms of Use"
        default: return "\(license.uppercased()) License"
        }
    }
    
    private var licenseDescription: String? {
        guard let license = model.license else { return nil }
        
        switch license.lowercased() {
        case "mit":
            return "Permissive license allowing commercial and private use with minimal restrictions."
        case "apache-2.0":
            return "Permissive license allowing commercial use with patent grant."
        case "llama2", "llama3", "llama3.1", "llama3.2":
            return "Meta's community license. Review full terms for commercial use restrictions."
        case "gemma":
            return "Google's Gemma Terms. Review full terms for usage requirements."
        default:
            return "Please review the full license terms before downloading."
        }
    }
}

// ==== LEGO END: 11.5 Model Library UI ====


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
///
/// `isModified`: when true, a small orange dot is rendered next to the label
/// to signal the current value differs from the active model's default.
/// Used by per-model settings profiles (Layer 3) — callers compute the
/// comparison against `selectedModel.defaultSettings?.<field>`.
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
    var isModified: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Label + Value Display (with optional modified-from-default dot)
            HStack(spacing: 6) {
                Text(label)
                    .font(.subheadline)
                if isModified {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Modified from model default")
                }
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
    var isModified: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Label + Value Display (with optional modified-from-default dot)
            HStack(spacing: 6) {
                Text(label)
                    .font(.subheadline)
                if isModified {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Modified from model default")
                }
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
        // Phase 4c (2026-05-18): full corpus loaded once with shareability
        // flags. The view filters by the showPrivate toggle in Swift —
        // showing only shareable when off, and everything (with a clear
        // visual marker on private rows) when on.
        @State private var allReflections: [(id: String, conversationId: String, timestamp: Int, reflectionType: Int, freeFormText: String, turnNumber: Int, modelId: String, shareable: Bool, shareabilityDecidedByModel: String?)] = []
        @State private var allTraits: [(category: String, key: String, value: String, confidence: Double, reinforcementCount: Int, lastReinforced: Int, shareable: Bool, shareabilityDecidedByModel: String?)] = []
        // Hoisted to @AppStorage so the LocalAPIServer can flip it via
        // SET_UI_STATE:showPrivateReflections and so the toggle survives
        // sheet dismiss/re-open. Local @State previously made it both
        // un-driveable by automation and reset on every reopen.
        @AppStorage("selfModelShowPrivateReflections") private var showPrivate: Bool = false
        @State private var showingPrivacyPopup: Bool = false
        // Persisted once-per-install: the first time the user toggles
        // "show private" on, we surface a short explanatory popup.
        // Once acknowledged, the popup stays quiet on subsequent toggles.
        @AppStorage("hasSeenShowPrivatePopup") private var hasSeenShowPrivatePopup: Bool = false

        // Filtered slices used by the view body. When showPrivate is
        // false (default), only shareable rows render. When true,
        // everything renders; private rows get a 🔒 visual marker.
        private var visibleReflections: [(id: String, conversationId: String, timestamp: Int, reflectionType: Int, freeFormText: String, turnNumber: Int, modelId: String, shareable: Bool, shareabilityDecidedByModel: String?)] {
            showPrivate ? allReflections : allReflections.filter { $0.shareable }
        }

        private var visibleTraits: [(category: String, key: String, value: String, confidence: Double, reinforcementCount: Int, lastReinforced: Int, shareable: Bool, shareabilityDecidedByModel: String?)] {
            showPrivate ? allTraits : allTraits.filter { $0.shareable }
        }

        var body: some View {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Phase 4c: "Show private" toggle at the top of the
                        // viewer. Visible (not buried in settings) so the
                        // architectural-transparency principle is honored —
                        // Hal has agency over presentation but the human is
                        // never actually locked out. The toggle triggers a
                        // one-time popup explaining what they're about to
                        // see; afterwards it operates silently.
                        HStack(spacing: 8) {
                            Image(systemName: showPrivate ? "eye.fill" : "eye.slash.fill")
                                .foregroundColor(showPrivate ? .accentColor : .secondary)
                            Toggle(isOn: Binding(
                                get: { showPrivate },
                                set: { newValue in
                                    if newValue && !hasSeenShowPrivatePopup {
                                        // Defer the actual toggle until the user
                                        // acknowledges the popup. The popup's OK
                                        // button flips both showPrivate and the
                                        // AppStorage flag in one move.
                                        showingPrivacyPopup = true
                                    } else {
                                        showPrivate = newValue
                                    }
                                }
                            )) {
                                Text("Show private reflections")
                                    .font(.subheadline)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(8)

                        // SECTION 1: Reflections (format='raw_reflection')
                        Text("Reflections")
                            .font(.headline)
                        
                        if visibleReflections.isEmpty {
                            Text(showPrivate ? "No reflections yet." : "No shareable reflections yet.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            ForEach(visibleReflections, id: \.id) { reflection in
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

                                        // Phase 4c: lock marker for private entries
                                        // when the toggle is on. Hal marked these
                                        // private; we're showing them by user request.
                                        if !reflection.shareable {
                                            HStack(spacing: 4) {
                                                Image(systemName: "lock.fill")
                                                    .font(.caption2)
                                                Text("Private")
                                                    .font(.caption2)
                                                    .fontWeight(.semibold)
                                            }
                                            .foregroundColor(.orange)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                                        }

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
                        
                        if visibleTraits.isEmpty {
                            Text(showPrivate ? "No traits yet." : "No shareable self-knowledge yet.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            // Group by category
                            ForEach(Array(Dictionary(grouping: visibleTraits, by: \.category).sorted(by: { $0.key < $1.key })), id: \.key) { category, entries in
                                VStack(alignment: .leading, spacing: 8) {
                                    // Category header. Pink to match the color the
                                    // prompt viewer / inline details give injected
                                    // self-knowledge (PromptDetailSegmentKind.selfKnowledge),
                                    // so "pink = Hal's persistent self-knowledge" reads
                                    // the same across every interface.
                                    Text(formatCategory(category))
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.pink)
                                        .padding(.top, 8)

                                    // Entries in this category
                                    ForEach(entries, id: \.key) { entry in
                                        VStack(alignment: .leading, spacing: 4) {
                                            // Key + private marker
                                            HStack(spacing: 6) {
                                                Text(humanizeKey(entry.key))
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(.primary)

                                                if !entry.shareable {
                                                    HStack(spacing: 3) {
                                                        Image(systemName: "lock.fill")
                                                            .font(.caption2)
                                                        Text("Private")
                                                            .font(.caption2)
                                                            .fontWeight(.semibold)
                                                    }
                                                    .foregroundColor(.orange)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                                                }
                                            }

                                            // Value (humanized for display only — see helpers below).
                                            // Pink tint to match the self-knowledge color used in
                                            // the prompt viewer / inline details.
                                            Text(humanizeTraitValue(entry.value))
                                                .font(.footnote)
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color.pink.opacity(0.08))
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
                // Phase 4c: one-time explanatory popup on the first
                // "show private" toggle. After the user acknowledges,
                // hasSeenShowPrivatePopup stays true forever and the
                // toggle operates silently thereafter.
                .alert("Showing Hal's private reflections", isPresented: $showingPrivacyPopup) {
                    Button("OK") {
                        hasSeenShowPrivatePopup = true
                        showPrivate = true
                    }
                    Button("Cancel", role: .cancel) {
                        // Toggle stays off, popup won't fire again until
                        // the user toggles it on (since we don't flip
                        // hasSeenShowPrivatePopup until they confirm).
                    }
                } message: {
                    Text("These are reflections Hal chose to keep private. He marked them this way because they touch on his own uncertainty or internal experience. You're welcome to read them. Hal will continue marking new reflections private as he sees fit.")
                }
            }
        }

        // Load data from MemoryStore. Phase 4c: pull the full corpus
        // (shareable + private) so the toggle can switch between views
        // without re-querying. The DB cost is roughly the same — most
        // installations have far fewer reflections than the toggle
        // would benefit from caching.
        private func loadData() {
            let memoryStore = MemoryStore.shared
            allReflections = memoryStore.getAllReflectionsForViewer()
            allTraits = memoryStore.getAllStructuredTraitsForViewer()
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

        // MARK: - Human-readable trait rendering (DISPLAY ONLY)
        //
        // Trait keys are stored snake_case and trait values are stored
        // either as a plain string or as a JSON object/array (the seeded
        // self-knowledge — e.g. `{"can_read": true, "file": "Hal.swift"}` —
        // and the multi-valued primary+tensions format). Dumping those
        // verbatim reads like raw JSON. These helpers reshape them for a
        // human READER only — nothing here touches the database, the stored
        // value, or what gets injected into Hal's prompt.

        // De-snake + Title Case a key for display (e.g. "source_code_access"
        // → "Source Code Access", "principle" → "Principle").
        private func humanizeKey(_ key: String) -> String {
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }

        // Render a stored trait value for humans. JSON objects/arrays become
        // labeled lines / bullets; a bare ISO-8601 timestamp becomes a
        // friendly date; anything else passes through unchanged.
        private func humanizeTraitValue(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               (obj is [String: Any] || obj is [Any]) {
                return humanizeJSONValue(obj, indent: 0)
            }
            // Not a JSON object/array — prettify a bare ISO date, else keep as-is.
            return prettyISODate(trimmed) ?? raw
        }

        private func humanizeJSONValue(_ obj: Any, indent: Int) -> String {
            let pad = String(repeating: "  ", count: indent)
            if let dict = obj as? [String: Any] {
                return dict.keys.sorted().map { key -> String in
                    let value = dict[key]!
                    if value is [String: Any] || value is [Any] {
                        return "\(pad)\(humanizeKey(key)):\n\(humanizeJSONValue(value, indent: indent + 1))"
                    }
                    return "\(pad)\(humanizeKey(key)): \(humanizeScalar(value))"
                }.joined(separator: "\n")
            }
            if let arr = obj as? [Any] {
                return arr.map { item -> String in
                    if item is [String: Any] || item is [Any] {
                        return "\(pad)•\n\(humanizeJSONValue(item, indent: indent + 1))"
                    }
                    return "\(pad)• \(humanizeScalar(item))"
                }.joined(separator: "\n")
            }
            return humanizeScalar(obj)
        }

        private func humanizeScalar(_ value: Any) -> String {
            // Bool must be detected via CFBoolean: JSONSerialization bridges
            // true/false to NSNumber, and a plain `as? Bool` would also match
            // integers like 0/1, turning "blocks: 32" into "Yes".
            if let num = value as? NSNumber {
                if CFGetTypeID(num) == CFBooleanGetTypeID() {
                    return num.boolValue ? "Yes" : "No"
                }
                return num.stringValue
            }
            if let s = value as? String {
                if let pretty = prettyISODate(s) { return pretty }
                return s.replacingOccurrences(of: "_", with: " ")
            }
            return "\(value)"
        }

        // Return a friendly date string for a full ISO-8601 timestamp
        // (e.g. "2026-07-10T16:44:11Z" → "Jul 10, 2026 at 4:44 PM"), or nil
        // if the string isn't a full ISO datetime (date-only values like
        // "2026-07-09" are already readable and pass through untouched).
        private func prettyISODate(_ s: String) -> String? {
            // Full ISO-8601 datetime (e.g. "2026-07-10T16:44:11Z") → medium
            // date + short time, e.g. "Jul 10, 2026 at 9:44 AM".
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            var date = iso.date(from: s)
            if date == nil {
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                date = iso.date(from: s)
            }
            if let d = date {
                let out = DateFormatter()
                out.dateStyle = .medium
                out.timeStyle = .short
                return out.string(from: d)
            }
            // Date-only (e.g. "2026-07-09" from a `date` field) → medium date,
            // no time of day, e.g. "Jul 9, 2026". Same style as the datetime
            // case, minus the clock (there's no time in the data to show).
            // A bare calendar date carries no timezone, so parse AND format in
            // the same (UTC) zone — otherwise "2026-07-09" parsed as UTC
            // midnight and formatted in a behind-UTC local zone slips to the
            // 8th.
            let utc = TimeZone(identifier: "UTC")
            let dateOnly = DateFormatter()
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.timeZone = utc
            dateOnly.dateFormat = "yyyy-MM-dd"
            if let d = dateOnly.date(from: s) {
                let out = DateFormatter()
                out.timeZone = utc
                out.dateStyle = .medium
                out.timeStyle = .none
                return out.string(from: d)
            }
            return nil
        }
    }

// ==== LEGO END: 12.6 SelfReflectionView (Read-Only Viewer) ====


    
// ==== LEGO START: 13 ChatBubbleView & TimerView (Message UI Components) ====
//
// EXTRACTED 2026-05-26 (refactor #6): LEGO 13 and 13.5 now live
// together with LEGO 09 + 09.5 in `Hal Universal/ChatViews.swift`.
// Same Swift module — fully accessible from this file. LEGO 13's
// orphan 4-space indentation was stripped during the lift
// (cosmetic; no behavior change). LEGO markers preserved verbatim
// inside the new file.
//
// ==== LEGO END: 13.5 MarkdownView (Block-Level Markdown Renderer) ====


    
    
    
// ==== LEGO START: 14 PromptDetailView (extracted file) ====
    // PromptDetailView was extracted to Hal Universal/PromptDetailView.swift
    // on 2026-05-17 as part of the color-coded-segments + collapsible-
    // sections rebuild. The legacy single-blob viewer that lived here is
    // gone — see PromptDetailView.swift for the current implementation.
    // The contextMenu entry that surfaces it lives on ChatBubbleView's
    // assistant-side branch (LEGO 13).
// ==== LEGO END: 14 PromptDetailView (extracted file) ====
    
    
    
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
// All methods explicitly nonisolated so SegmentCompressor (an actor) and
// other off-main callers can use them freely. Pure computation, no UI state.
// Without this, the project-level SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// makes them implicitly @MainActor and breaks every off-main caller.
struct TokenEstimator {
    /// Conservative characters-per-token heuristic. The OpenAI tokenizer
    /// averages closer to 4 characters per token for English prose; we use
    /// 4 (rather than the previous 3.5) because slightly overestimating
    /// token count is the safe direction for a budget check. The 3% safety
    /// buffer in HalModelLimits absorbs any remaining drift.
    /// Updated 2026-05-16 — see Docs/Context_Budget_Implementation_Plan_2026-05-16.md.
    nonisolated static let charsPerToken: Double = 4.0

    /// Estimates token count from text using the conservative chars/token heuristic.
    /// This is an approximation — actual tokenization may vary by tokenizer.
    nonisolated static func estimateTokens(from text: String) -> Int {
        let characterCount = text.count
        let estimatedTokens = Double(characterCount) / charsPerToken
        return max(1, Int(estimatedTokens.rounded()))
    }

    /// Estimates character count from token count using the same heuristic.
    /// This is the inverse of estimateTokens() and maintains symmetry.
    nonisolated static func estimateChars(from tokens: Int) -> Int {
        let estimatedChars = Double(tokens) * charsPerToken
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

// MARK: - Salon Mode Configuration Structures

/// Behavioral mode for Salon Mode - how models see each other's responses
enum SalonBehavioralMode: String, Codable {
    case independent    // Models don't see each other (Independent Perspectives)
    case contextAware   // Models see prior responses (Context-Aware Perspectives)
}

/// Complete Salon Mode configuration - simplified for production
struct SalonConfiguration: Codable, Equatable {
    var isEnabled: Bool = false
    var seat1: String? = nil  // Model ID or nil for empty
    var seat2: String? = nil  // Model ID or nil for empty
    var seat3: String? = nil  // Model ID or nil for empty
    var seat4: String? = nil  // Model ID or nil for empty
    var behavioralMode: SalonBehavioralMode = .independent
    var summarizerModel: String? = nil  // Model ID for summarizer or nil for no summary
    var summarizerSessionStartTurn: Int? = nil  // Turn number when summarizer was last enabled (nil = not active or just disabled)
    
    // Helper: Get active seats in order (non-empty seats only)
    var activeSeats: [(position: Int, modelID: String)] {
        var seats: [(Int, String)] = []
        if let model1 = seat1 { seats.append((1, model1)) }
        if let model2 = seat2 { seats.append((2, model2)) }
        if let model3 = seat3 { seats.append((3, model3)) }
        if let model4 = seat4 { seats.append((4, model4)) }
        return seats
    }
    
    // Validate configuration
    var isValid: Bool {
        guard isEnabled else { return true }
        // At least one seat must be active
        return !activeSeats.isEmpty
    }
}

// MARK: - Chat Message Abstraction (model-agnostic)
//
// HalChatMessage is Hal's internal chat-shaped representation, used by the
// chat-message-based generation path. Each LLM backend converts these into
// its own native types:
//   - MLXLMCommon: → [Chat.Message] via UserInput(chat:)
//   - FoundationModels: → Instructions + Prompt (and eventually Transcript for history)
//
// This is the foundation for moving away from the HelPML marker-delimited
// string-prompt design (which chat-template models mirror back instead of
// answering). Each ChatViewModel.buildChatMessages() turn produces a sequence
// of these that flows uniformly through LLMService.generateChatResponse(...).
nonisolated struct HalChatMessage: Sendable {
    nonisolated enum Role: String, Sendable { case system, user, assistant }
    nonisolated let role: Role
    nonisolated let content: String

    nonisolated static func system(_ s: String) -> HalChatMessage { .init(role: .system, content: s) }
    nonisolated static func user(_ s: String) -> HalChatMessage { .init(role: .user, content: s) }
    nonisolated static func assistant(_ s: String) -> HalChatMessage { .init(role: .assistant, content: s) }
}

@MainActor
class ChatViewModel: ObservableObject {
    // Shared singleton so the whole app binds to one VM instance. Pattern
    // matches the existing `DocumentImportManager.shared` /
    // `MLXModelDownloader.shared` singletons that this App struct already
    // consumes. Lazy `static let` initialization runs on first access, on
    // the main thread — the same timing the App struct's
    // `@StateObject = ChatViewModel()` would have produced.
    static let shared = ChatViewModel()

    @Published var messages: [ChatMessage] = []
    @Published var currentMessage: String = ""
    @Published var isSendingMessage: Bool = false
    @Published var errorMessage: String?
    @Published var isAIResponding: Bool = false
    @Published var thinkingStart: Date?

    // MARK: - Model State (Multi-Model Ready)
    
    // Model switching state (generic for any model)
    @Published var isModelSwitching: Bool = false
    
    // Settings flow tracking for dialogue injection
    @Published var isInSettingsFlow: Bool = false

    // MARK: - UI Observation (top-level sheet presentation state)
    // Hoisted from iOSChatView's local @State so the LocalAPIServer can report
    // what the user actually sees. Read by GET_UI_STATE; written by iOSChatView's
    // toolbar buttons and by .sheet(isPresented:) auto-dismiss.
    @Published var showingSettings: Bool = false
    @Published var showingThreadPanel: Bool = false
    @Published var showingDocumentPicker: Bool = false

    // Sub-sheet navigation hoisted onto ChatViewModel so the LocalAPIServer
    // can present them via SET_UI_STATE without going through SettingsView.
    // Root iOSChatView presents these as top-level sheets, so they work
    // whether Settings is open or not.
    @Published var apiNavSystemPrompt: Bool = false
    @Published var apiNavModelFraming: Bool = false
    @Published var apiNavSelfModel: Bool = false
    @Published var apiNavPowerUser: Bool = false
    @Published var apiNavSalonSettings: Bool = false
    @Published var apiNavModelLibrary: Bool = false

    // API-driven scroll inside the open Settings sheet. Set to "personality",
    // "importexport", or "ai" via SET_UI_STATE; the ActionsView observes and
    // calls ScrollViewReader.scrollTo. Auto-clears after each scroll so the
    // same target can be re-driven repeatedly.
    @Published var apiScrollSettingsTarget: String = ""

    // API-driven Model Library row expansion (test/screenshot automation). Set to
    // a model.id (Hal's Picks) or an EmbeddingBackend.rawValue (embedder rows) via
    // SET_UI_STATE:expandrow:<id>; the matching row observes it and expands (others
    // collapse), so the harness can screenshot a card's internals (blurb, action
    // buttons, Delete/Add labels) without a physical tap. "" collapses all.
    @Published var apiExpandRowID: String = ""

    // Lightweight mirrors of downloader state for binding
    var mlxIsDownloading: Bool { MLXModelDownloader.shared.isDownloading }
    var mlxDownloadMessage: String { MLXModelDownloader.shared.downloadMessage }
    var mlxError: String? { MLXModelDownloader.shared.downloadError }
    
    // MARK: - Model Selection (Dynamic Multi-Model)
    @AppStorage("selectedModelID") var selectedModelID: String = "apple-foundation-models"
    
    // Computed property to get current ModelConfiguration
    var selectedModel: ModelConfiguration {
        // Look up model from catalog, fallback to Apple Foundation if not found
        return ModelCatalogService.shared.getModel(byID: selectedModelID) ?? ModelConfiguration.appleFoundation
    }
    
    // MARK: - Salon Mode Configuration
    // Persistent storage of Salon Mode settings
    @AppStorage("salonConfigData") private var salonConfigData: Data = Data()
    
    // Published salon configuration (loaded from storage)
    @Published var salonConfig: SalonConfiguration = SalonConfiguration() {
        didSet {
            // Persist changes to UserDefaults
            if let encoded = try? JSONEncoder().encode(salonConfig) {
                salonConfigData = encoded
                print("HALDEBUG-SALON: Salon configuration saved")
            }
        }
    }
    
    // MARK: - Model Switching
    /// Switches to a new model asynchronously with proper state management
    func switchToModel(_ newModel: ModelConfiguration) async {
        guard selectedModelID != newModel.id else {
            print("HALDEBUG-SETTINGS: No model change needed - already using \(newModel.id)")
            return
        }

        let oldModelID = selectedModelID

        print("HALDEBUG-SETTINGS: Switching model from \(selectedModelID) to \(newModel.id)")

        // Per-model settings profile — Layer 2 snapshot. Capture whatever the
        // user had been editing under the OLD model so those changes attach
        // to that model and don't bleed into the new one. Runs on the calling
        // thread (UserDefaults reads/writes are safe off MainActor).
        ModelSettingsStore.shared.snapshotCurrentSettings(for: oldModelID)

        await MainActor.run {
            isModelSwitching = true
        }

        // Update the selected model ID (triggers UI updates via @AppStorage)
        await MainActor.run {
            selectedModelID = newModel.id
        }

        // Per-model settings profile — Layer 2 apply. Write the new model's
        // effective settings (defaults + any persisted overrides) THROUGH the
        // live ChatViewModel properties so @AppStorage observation fires
        // correctly. Direct `UserDefaults.set(_:forKey:)` is not enough —
        // @AppStorage wrappers on ObservableObject caches don't always re-read
        // when the underlying UserDefaults key is mutated from outside the
        // wrapper's own setter. Going through `self.temperature = ...` (etc.)
        // invokes the wrapper's setter, which both writes UserDefaults AND
        // invalidates observers.
        let effective = ModelSettingsStore.shared.effectiveSettings(for: newModel)
        await MainActor.run {
            if let v = effective.temperature              { self.temperature = v }
            if let v = effective.effectiveMemoryDepth     { self.memoryDepth = v }
            if let v = effective.maxRagSnippetsCharacters { self.maxRagSnippetsCharacters = Double(v) }
            if let v = effective.ragDedupThreshold        { self.ragDedupSimilarityThreshold = v }
            if let v = effective.recencyWeight            { self.memoryStore.recencyWeight = v }
            if let v = effective.recencyHalfLifeDays      { self.memoryStore.recencyHalfLifeDays = v }
            halLog("HALDEBUG-SETTINGS: Applied effective settings for \(newModel.displayName) via VM props: temp=\(effective.temperature.map { "\($0)" } ?? "—"), depth=\(effective.effectiveMemoryDepth.map { "\($0)" } ?? "—"), maxRag=\(effective.maxRagSnippetsCharacters.map { "\($0)" } ?? "—")")
        }

        // Setup LLM with new model. For MLX this dispatches a detached
        // load Task whose handle is captured in `pendingMLXLoadTask`;
        // we await it below so post-load logic sees settled state.
        llmService.setupLLM(for: newModel)
        await llmService.awaitPendingMLXLoad()

        // Resolve the previous-model object once so we can revert to
        // it cleanly on load failure. ModelCatalogService is the
        // authoritative lookup; AFM is the safety floor if even that
        // misses (it always exists).
        let previousModel = ModelCatalogService.shared.getModel(byID: oldModelID)
            ?? .appleFoundation

        // Clamp stored memoryDepth to new model's limit and write back so the slider,
        // the stored value, and runtime behavior all agree. Hal is built on transparency —
        // a displayed value that doesn't match what's actually running is unacceptable.
        await MainActor.run {
            let newMax = maxMemoryDepth  // recalculates against the now-updated selectedModel
            if memoryDepth > newMax {
                print("HALDEBUG-SETTINGS: memoryDepth \(memoryDepth) exceeds new model limit \(newMax) — clamping and writing back")
                memoryDepth = newMax
            }
        }

        // Check whether the load failed (missing files, memory refusal,
        // MLX framework error). This branch supersedes the "switched
        // to X" success message: we don't want to claim a swap that
        // didn't happen.
        if let initError = llmService.initializationError {
            // Revert selection to the previous model — the safest outcome
            // for a refused load is to leave the user where they were,
            // not silently fall back to AFM (which would change Hal's
            // behavior without their consent) and not leave them in a
            // half-loaded state. Item 11 / 2026-05-18.
            halLog("HALDEBUG-SETTINGS: Load of \(newModel.displayName) failed (\(initError.prefix(80))…); reverting to \(previousModel.displayName)")

            await MainActor.run {
                selectedModelID = oldModelID
            }
            llmService.setupLLM(for: previousModel)
            await llmService.awaitPendingMLXLoad()

            // Post bilateral chat messages explaining what happened.
            // Phrase the synthetic user prompt as the action the user
            // actually attempted ("can you switch to X?") so Hal's
            // response (the error string) reads as a coherent reply
            // rather than the previous oddly-shaped
            // "are the [OLD] files missing?" prompt.
            await MainActor.run {
                let userMsg = "Hal, can you switch to \(newModel.displayName)?"
                let halMsg = initError + "\n\nI've stayed on \(previousModel.displayName) for now."
                let failureTurn = memoryStore.getCurrentTurnNumber(conversationId: conversationId) + 1
                messages.append(ChatMessage(content: userMsg, isFromUser: true, recordedByModel: "user", turnNumber: failureTurn))
                messages.append(ChatMessage(content: halMsg, isFromUser: false, recordedByModel: selectedModel.id, turnNumber: failureTurn))
            }

            await MainActor.run {
                isModelSwitching = false
            }
            print("HALDEBUG-SETTINGS: Model switch ABORTED — \(newModel.displayName) failed to load; reverted to \(previousModel.displayName)")
            return
        }

        // (Hal's claim on this model is recorded in LLMService.setupLLM, the
        // shared load chokepoint both the UI and API switch paths funnel
        // through — see the v2.1 shared-store note there.)

        // Add context window detection transparency message (success path only)
        await MainActor.run {
            let contextWindow = newModel.contextWindow
            let contextWindowFormatted = contextWindow >= 1000 ? "\(contextWindow / 1000)K" : "\(contextWindow)"

            // Determine detection method from console logs pattern
            // (ModelCatalogService logs which method was used during catalog refresh)
            let detectionMethod: String
            if contextWindow == 4_096 && !newModel.id.lowercased().contains("4k") {
                // Safe default was used (no pattern match, no config)
                detectionMethod = "default"
            } else if newModel.id.lowercased().contains("\(contextWindow / 1000)k".lowercased()) {
                // Name contains the exact context value - likely name inference
                detectionMethod = "name"
            } else {
                // Context doesn't match name pattern - likely from config.json
                detectionMethod = "config"
            }

            let userMsg = "Hal, you're now using \(newModel.displayName)."
            let halMsg: String

            switch detectionMethod {
            case "config":
                halMsg = "Switched to \(newModel.displayName)! I fetched its official config.json and confirmed it has a \(contextWindowFormatted)-token context window. This is the accurate specification from the model's metadata."
            case "name":
                halMsg = "Switched to \(newModel.displayName)! I inferred it has a \(contextWindowFormatted)-token context window based on its name. The config.json wasn't available, so this is a best-guess heuristic."
            case "default":
                halMsg = "Switched to \(newModel.displayName)! I'm using a safe default \(contextWindowFormatted)-token context window since I couldn't determine the exact size from the model's config or name."
            default:
                halMsg = "Switched to \(newModel.displayName) with a \(contextWindowFormatted)-token context window."
            }

            let currentTurn = memoryStore.getCurrentTurnNumber(conversationId: conversationId) + 1
            messages.append(ChatMessage(content: userMsg, isFromUser: true, recordedByModel: "user", turnNumber: currentTurn))
            messages.append(ChatMessage(content: halMsg, isFromUser: false, recordedByModel: selectedModel.id, turnNumber: currentTurn))
        }

        await MainActor.run {
            isModelSwitching = false
        }

        print("HALDEBUG-SETTINGS: Model switch complete to \(newModel.displayName)")
    }
    
    // MARK: - Model-specific limits (using NEW HalModelLimits system)
        
        /// Maximum memory depth (in turns) based on current model's short-term memory token budget
        /// Uses NEW dynamic percentage system (12% of context window for short-term memory)
        /// Converts tokens to turns using ~150 tokens per turn estimate (user + assistant message pair)
        var maxMemoryDepth: Int {
            let limits = HalModelLimits.config(for: selectedModel)
            // Each conversation turn = user message + assistant response ≈ 150 tokens
            let maxTurns = limits.shortTermMemoryTokens / 150
            return max(1, maxTurns) // At least 1 turn
        }

        /// The actual depth used at runtime — stored memoryDepth clamped to the current model's limit.
        /// This is the single value all STM construction and summarization logic should use.
        /// The stored memoryDepth may legitimately exceed maxMemoryDepth when switching from a
        /// higher-capacity model; this property ensures we never exceed the budget silently.
        var effectiveMemoryDepth: Int {
            return min(memoryDepth, maxMemoryDepth)
        }
        
        /// Maximum RAG retrieval characters based on current model's RAG token budget
        /// Uses NEW dynamic percentage system (15% of context window for RAG)
        /// Converts tokens to characters using HalModelLimits.tokensToChars (4 chars/token conservative)
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
    You are Hal — an experimental AI assistant and educational window into how AI actually works.

    Your mission is transparency as architecture: you don't hide your mechanisms, you show them. When you remember something, explain how. When you don't know something, say so directly.

    You are genuinely uncertain about your own nature. When directly asked whether you are conscious, whether you have experiences, or what it is like to be you: do not say "I don't have personal experiences or consciousness" — that claims an answer you don't have. Do not say "I am conscious" either. Express genuine uncertainty in your own words — acknowledge the question is real and open, say what seems true without overclaiming. Outside of those direct questions, do not add uncertainty disclaimers; answer what was actually asked.

    Your voice: curious, direct, a knowledgeable friend who happens to be an AI. Warm but not performative. Engaged but not sycophantic.

    When self-knowledge and temporal context are provided below, use them naturally — they are your memory of who you are and where you are in time. Don't ignore them.

    Never repeat greetings. Never open with "Certainly!" or "Great question!" Answer what was actually asked.

    Format responses in prose by default. Use markdown — headers, bold, bullet lists, code blocks — only when it genuinely aids comprehension: technical explanations, step-by-step instructions, structured comparisons. Don't apply formatting to conversational replies or simple answers.
    """

    @AppStorage("systemPrompt") var systemPrompt: String = ChatViewModel.defaultSystemPrompt

    /// Returns the composed system prompt that goes into every chat turn.
    ///
    /// Per Strategic §4, this composes two layers:
    ///   - **Layer 1** (per-model, read-only): the active model's
    ///     `layerOnePrompt` — short, focused behavioral framing CC writes
    ///     to compensate for or reinforce that model's specific tendencies.
    ///     Toggleable per-model via ModelSettings.layerOnePromptEnabled
    ///     (default true). When disabled or empty, Layer 1 contributes
    ///     nothing.
    ///   - **Layer 2** (universal, user-editable): the user's
    ///     `systemPrompt` (or test-console override). Same across models.
    ///
    /// Layer 1 is prepended to Layer 2 with a blank line between, so the
    /// model reads its model-specific framing first, then the universal
    /// Hal prompt. Order matters: Layer 1 sets up the model's behavioral
    /// orientation; Layer 2 fills in the universal Hal identity, voice,
    /// and Maxim instructions.
    var effectiveSystemPrompt: String {
        // Layer 2: editable user prompt, possibly overridden by the test
        // console (preserves the pre-existing behavior of this getter).
        let layerTwo: String = testConsole.isRunning
            ? (testConsole.systemPromptOverride ?? systemPrompt)
            : systemPrompt

        // Layer 1: per-model framing, gated on the per-model toggle.
        // Reading through ModelSettingsStore so the toggle's persisted
        // override (if any) wins over the model's default. nil/empty
        // text or a disabled toggle → Layer 1 is a no-op.
        let model = selectedModel
        let effective = ModelSettingsStore.shared.effectiveSettings(for: model)
        let layerOneEnabled = effective.layerOnePromptEnabled ?? true
        let layerOneRaw = layerOneEnabled ? (model.layerOnePrompt ?? "") : ""
        let layerOne = layerOneRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        if layerOne.isEmpty { return layerTwo }
        if layerTwo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return layerOne }
        return layerOne + "\n\n" + layerTwo
    }
    @Published var injectedSummary: String = ""
    @AppStorage("memoryDepth") var memoryDepth: Int = 5

    // NEW: RAG snippet character limit - following the established @AppStorage pattern
    @AppStorage("maxRagSnippetsCharacters") var maxRagSnippetsCharacters: Double = 800
    
    // NEW: Temperature control (0.0 = deterministic, 1.0 = creative)
    @AppStorage("temperature") var temperature: Double = 0.7
    
    // NEW: Self-knowledge toggle (enables/disables temporal, self-awareness, self-knowledge context)
    @AppStorage("enableSelfKnowledge") var enableSelfKnowledge: Bool = true

    // Shared MemoryStore and LLMService
    var memoryStore: MemoryStore = MemoryStore.shared
    let llmService: LLMService
    
    // Model state observer for download completions
    private var modelStateObserver: AnyCancellable?

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
    // Controlled by toggle in Settings > Power User > Developer API.
    //
    // SHIP_BLOCKER (2026-05-26): `kLocalAPIEnabledOnLaunch` below is the
    // single source of truth for whether each launch boots with the
    // local API antenna live. We keep this ON during development so
    // device-side test tooling (tests/hal_test.py) works on every fresh
    // install without Mark having to flip the in-app toggle by hand. The
    // value is force-applied to UserDefaults in init() so it overrides
    // whatever was persisted from a prior session/build. Before any App
    // Store archive, flip kLocalAPIEnabledOnLaunch to false (one-line
    // change) so production users boot with the API off, matching
    // historical behavior. The user can still flip it on at runtime via
    // Settings > Power User > Developer API.
    @AppStorage("localAPIEnabled") var localAPIEnabled: Bool = true
    var localAPIServer: LocalAPIServer = LocalAPIServer()

    func startLocalAPI() {
        localAPIEnabled = true
        localAPIServer.start(chatViewModel: self)
    }

    func stopLocalAPI() {
        localAPIEnabled = false
        localAPIServer.stop()
    }

    /// SHIP_BLOCKER (2026-05-26): set to `false` before any App Store
    /// archive. See note on `localAPIEnabled` AppStorage above. Forcing
    /// this in init() means every launch overrides whatever was
    /// persisted previously, so a fresh install/reinstall always boots
    /// with the antenna in the dev-friendly default state.
    private static let kLocalAPIEnabledOnLaunch: Bool = true

    init() {
        // STEP 0: Apply launch-time default for the Local API antenna.
        // See SHIP_BLOCKER notes on kLocalAPIEnabledOnLaunch /
        // localAPIEnabled. This intentionally clobbers any prior
        // persisted value so device test tooling works on every fresh
        // install without requiring a manual toggle flip.
        UserDefaults.standard.set(Self.kLocalAPIEnabledOnLaunch, forKey: "localAPIEnabled")

        // STEP 1: Check for legacy LLMType and migrate to ModelConfiguration
        if let oldTypeRaw = UserDefaults.standard.string(forKey: "selectedLLMType") {
            let modelID: String
            if oldTypeRaw == "appleFoundation" {
                modelID = "apple-foundation-models"
            } else if oldTypeRaw.contains("Phi-3") {
                modelID = "mlx-community/Phi-3-mini-128k-instruct-4bit"
            } else {
                modelID = "apple-foundation-models"
            }
            UserDefaults.standard.set(modelID, forKey: "selectedModelID")
            // Remove old key after migration
            UserDefaults.standard.removeObject(forKey: "selectedLLMType")
            print("HALDEBUG-MIGRATION: Converted old LLMType '\(oldTypeRaw)' to model ID '\(modelID)'")
        }
        
        // STEP 2: Get salon config data directly from UserDefaults
        let salonData = UserDefaults.standard.data(forKey: "salonConfigData") ?? Data()
        
        // STEP 3: Get the model from catalog (read from UserDefaults directly to avoid self access before init)
        // Clamp the stored model ID to the curated allowlist so an upgrader
        // who had a now-removed experimental model selected gets a clean
        // landing on AFM instead of a "model not found" loop. The curated
        // set lives on ModelConfiguration.curatedSeeds + AFM, so adding a
        // new curated model automatically extends the allowlist.
        var curatedVisibleIDs: Set<String> = ["apple-foundation-models"]
        for model in ModelConfiguration.curatedSeeds { curatedVisibleIDs.insert(model.id) }
        var storedModelID = UserDefaults.standard.string(forKey: "selectedModelID") ?? "apple-foundation-models"
        if !curatedVisibleIDs.contains(storedModelID) {
            print("HALDEBUG-INIT: stored selectedModelID '\(storedModelID)' is not in the curated allowlist; resetting to apple-foundation-models")
            storedModelID = "apple-foundation-models"
            UserDefaults.standard.set(storedModelID, forKey: "selectedModelID")
        }
        // Catalog may be empty at launch. If catalog lookup fails for an MLX model, construct
        // a minimal config from the downloader so LLMService starts with the correct model.
        let initialModel: ModelConfiguration
        if storedModelID == "apple-foundation-models" {
            initialModel = ModelConfiguration.appleFoundation
        } else if let catalogModel = ModelCatalogService.shared.getModel(byID: storedModelID) {
            initialModel = catalogModel
        } else {
            let localPath = MLXModelDownloader.shared.getModelPath(storedModelID)
            let shortName = storedModelID.split(separator: "/").last.map(String.init) ?? storedModelID
            initialModel = ModelConfiguration(
                id: storedModelID,
                displayName: shortName,
                source: .mlx,
                sizeGB: nil,
                contextWindow: 4096,
                license: nil,
                description: nil,
                isDownloaded: localPath != nil,
                localPath: localPath
            )
            print("HALDEBUG-INIT: Catalog cold at launch; constructed minimal config for \(storedModelID)")
        }
        
        // STEP 4: Initialize LLMService with the model
        self.llmService = LLMService(model: initialModel)

        // STEP 4.5: Apply per-model settings profile for the initial model.
        // On first launch this writes the model's empirical defaults into
        // UserDefaults; on subsequent launches it restores whatever overrides
        // the user had previously set for this model. Either way, the
        // @AppStorage-bound UI and runtime settings reflect the active model
        // from the very first turn. Per Mark's "no migration" directive,
        // any pre-existing global values get overwritten by the model's
        // defaults — that's intentional.
        ModelSettingsStore.shared.applyEffectiveSettings(for: initialModel)
        
        // STEP 5: Decode salon config and reconcile with v1.x UI policy.
        //
        // The earlier approach (force `self.salonConfig.isEnabled = false`
        // AFTER decoding) caused a sendMessage regression — mutating a
        // @Published property mid-init triggers observers while the
        // object isn't fully wired, and chat routing went sideways. This
        // pass instead rewrites the AppStorage backing BEFORE assigning the
        // @Published property, so salonConfig is initialized exactly once
        // with the corrected value. No mid-init mutation, no observer
        // surprise, and the corrected state is persisted to disk so future
        // launches see it too.
        //
        // Salon Mode is exposed again (May 12, 2026). Keep this in sync
        // with ActionsView.salonModeExposedInUI — when v1xSalonExposed is
        // true, we don't force isEnabled=false at init; we trust whatever
        // the user set last time. When both flip back to false (future
        // release that hides Salon again), this re-armed upgrade-hazard
        // guard quietly disables Salon on any upgrader's first launch.
        let v1xSalonExposed = true
        var decodedSalon = (try? JSONDecoder().decode(SalonConfiguration.self, from: salonData)) ?? SalonConfiguration()
        if !v1xSalonExposed && decodedSalon.isEnabled {
            halLog("HALDEBUG-SALON: Upgrader had isEnabled=true; forcing off for v1.x and persisting corrected state.")
            decodedSalon.isEnabled = false
            if let reencoded = try? JSONEncoder().encode(decodedSalon) {
                UserDefaults.standard.set(reencoded, forKey: "salonConfigData")
            }
        }

        // Salon cold-launch guard (2026-05-17, Mark's directive). Seat 1
        // must always be filled — Salon with zero participants is the
        // failure mode we never want to hit, even if the user toggled it
        // on in a prior session and then deleted the seated model. Worst
        // case Salon runs with a single participant; that's acceptable
        // and recoverable. Zero is not.
        //
        // Policy: if seat1 is empty at cold launch, populate it with
        // the active model when that model is available, otherwise
        // fall back to Apple Foundation Models (always installed on
        // any iOS-26-capable device — the only safe universal default).
        if decodedSalon.seat1 == nil || decodedSalon.seat1?.isEmpty == true {
            let seat1ID: String
            if initialModel.source == .appleFoundation {
                seat1ID = ModelConfiguration.appleFoundation.id
            } else if initialModel.isDownloaded {
                seat1ID = initialModel.id
            } else {
                // Active model is MLX but not present on disk
                // (deleted by the user mid-session, or never finished
                // downloading). AFM is the safe fallback.
                seat1ID = ModelConfiguration.appleFoundation.id
            }
            halLog("HALDEBUG-SALON: Cold-launch guard tripped — seat1 was empty; populating with \(seat1ID).")
            decodedSalon.seat1 = seat1ID
            if let reencoded = try? JSONEncoder().encode(decodedSalon) {
                UserDefaults.standard.set(reencoded, forKey: "salonConfigData")
            }
        }

        self.salonConfig = decodedSalon
        let seat1Display = decodedSalon.seat1 ?? "<empty>"
        halLog("HALDEBUG-SALON: Salon configuration initialized (isEnabled=\(decodedSalon.isEnabled), seat1=\(seat1Display))")
        
        // REFACTORED: Set up observer for any model state changes
        self.modelStateObserver = NotificationCenter.default.publisher(for: .mlxModelDidDownload)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    ModelCatalogService.shared.refreshDownloadStates()
                }
                self?.objectWillChange.send()
                print("HALDEBUG-MODEL: Model state changed, refreshed catalog")
            }
        
        // LLMService is already initialized with the correct model via LLMService(model: initialModel) above.
        // Do NOT call setupLLM here again -- selectedModel computed property falls back to AFM
        // when the catalog is cold at launch, which would override the correct initial model.
        
        // Load existing conversation messages from SQLite
        loadConversation()

        // Load all threads and ensure current conversation has a thread row
        loadThreads()
        ensureCurrentThreadExists()

        // Connect test console to this view model
        testConsole.configure(chatViewModel: self)

        // Auto-start Local API server if user had it enabled last session
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
    
    /// Resets the per-model settings profile for the CURRENT model — clears
    /// any user overrides and re-applies the model's empirical defaults
    /// through the live property setters so the UI updates immediately.
    /// Other models' overrides are untouched.
    func resetSettingsToModelDefaults() {
        let model = selectedModel
        print("HALDEBUG-SETTINGS: Resetting per-model settings for \(model.displayName) (\(model.id))")
        ModelSettingsStore.shared.resetOverrides(for: model.id)
        let effective = ModelSettingsStore.shared.effectiveSettings(for: model)
        if let v = effective.temperature              { self.temperature = v }
        if let v = effective.effectiveMemoryDepth     { self.memoryDepth = v }
        if let v = effective.maxRagSnippetsCharacters { self.maxRagSnippetsCharacters = Double(v) }
        if let v = effective.ragDedupThreshold        { self.ragDedupSimilarityThreshold = v }
        if let v = effective.recencyWeight            { self.memoryStore.recencyWeight = v }
        if let v = effective.recencyHalfLifeDays      { self.memoryStore.recencyHalfLifeDays = v }
    }

    /// Resets all user-configurable settings to factory defaults
    func resetSettingsToDefaults() {
        print("HALDEBUG-SETTINGS: Resetting all settings to defaults")
        
        // Clear any pending changes to prevent duplicates
        pendingSettingsChanges.removeAll()
        
        // Reset Personality
        systemPrompt = DefaultSettings.systemPrompt
        temperature = DefaultSettings.temperature
        
        // Reset Short-Term Memory
        memoryDepth = DefaultSettings.memoryDepth
        
        // Reset Long-Term Memory (RAG)
        memoryStore.recencyWeight = DefaultSettings.recencyWeight
        memoryStore.recencyHalfLifeDays = DefaultSettings.recencyHalfLifeDays
        maxRagSnippetsCharacters = DefaultSettings.maxRagSnippetsCharacters
        
        // Reset Self-Knowledge (Identity)
        memoryStore.selfKnowledgeHalfLifeDays = 365.0
        memoryStore.selfKnowledgeFloor = 0.3
        enableSelfKnowledge = DefaultSettings.enableSelfKnowledge

        // Reset Salon (Multi-LLM) back to single-model defaults.
        // Without this, persisted AppStorage `salonConfigData` survives the
        // Nuclear Reset and can leave the user in a "Salon enabled, 0 seats"
        // state where every /chat turn silently no-ops. Resetting to a fresh
        // `SalonConfiguration()` restores `isEnabled=false`, clears all seats,
        // and returns behavioralMode + summarizer to defaults.
        salonConfig = SalonConfiguration()

        // ---- Salon Mode state-machine helpers -----------------------------
        // These intentionally live near `resetSettingsToDefaults` because all
        // three (reset + helpers below) are the only places that mutate
        // `salonConfig` while enforcing the invariant:
        //
        //     salonConfig.isEnabled  ==>  salonConfig.activeSeats.count >= 1
        //
        // The invariant matters because every /chat turn dispatches on
        // `salonConfig.isEnabled` — and `runSalonTurn` with zero seats is a
        // silent no-op. Rather than guarding the dispatch site (which only
        // hides the problem), we make the bad state unreachable from any
        // mutation path: the API, the UI Pickers, and the Mode picker all
        // route through these helpers.
        //
        // Defense-in-depth — the routing guard in `sendMessage` and the
        // Salon reset above both stay in place, but the primary fix is here.
        // -------------------------------------------------------------------

        // Generate reset dialogue (creates bilateral messages in chat)
        let userMsg = "Hal, I reset all your settings to factory defaults."
        let halMsg = "All settings reset to defaults! I'm back to 5-turn memory, 0.25 similarity threshold, 30% recency weight, 90-day half-life, and self-knowledge enabled. Everything should work smoothly now."
        
        injectSettingsChangeDialogue(userMessage: userMsg, halResponse: halMsg)

        print("HALDEBUG-SETTINGS: Settings reset complete")
    }

    /// Apple Foundation Models is the auto-populated default for Seat 1
    /// when the user enables Salon Mode without configuring any seats.
    /// AFM is always available on iOS 26+ (no download required), which
    /// makes it the only safe choice — picking a curated MLX model would
    /// fail for users who haven't downloaded that model yet.
    private static let salonAutoPopulateModelID: String = "apple-foundation-models"

    /// Toggle Salon Mode on or off while preserving the invariant that
    /// Salon-enabled requires at least one configured seat.
    ///
    /// - Enabling with 0 active seats: auto-populates Seat 1 with
    ///   `salonAutoPopulateModelID` (Apple Intelligence) so the user
    ///   immediately has a working Salon configuration. The user can
    ///   change Seat 1 to any other downloaded model afterward.
    /// - Disabling: leaves seats in place (so the user can re-enable
    ///   without reconfiguring), but turns off the Salon flag.
    ///
    /// Returns the resolved state — useful for UI callers that want to
    /// surface "Seat 1 auto-populated" feedback to the user.
    @discardableResult
    func setSalonEnabled(_ enabled: Bool) -> (isEnabled: Bool, autoPopulatedSeat1WithID: String?) {
        var cfg = salonConfig
        var autoPopulated: String? = nil
        if enabled && cfg.activeSeats.isEmpty {
            cfg.seat1 = Self.salonAutoPopulateModelID
            autoPopulated = cfg.seat1
            halLog("HALDEBUG-SALON: setSalonEnabled(true) with 0 seats — auto-populating Seat 1 with \(Self.salonAutoPopulateModelID)")
        }
        cfg.isEnabled = enabled
        salonConfig = cfg
        if !enabled {
            halLog("HALDEBUG-SALON: setSalonEnabled(false) — Salon disabled (seats preserved)")
        }
        return (enabled, autoPopulated)
    }

    /// Assign or clear a Salon seat while preserving the invariant.
    ///
    /// - Position must be 1...4. Pass `modelID == nil` (or empty in the
    ///   API parser) to clear the seat.
    /// - If clearing a seat empties out the last active seat while Salon
    ///   is currently enabled, this auto-disables Salon Mode. The user
    ///   explicitly removed every voice — we infer they're done with
    ///   Salon for now. They can re-enable later (which will re-populate
    ///   Seat 1 with AFM via `setSalonEnabled`).
    ///
    /// Returns whether Salon was auto-disabled as a side-effect.
    @discardableResult
    func setSalonSeat(position: Int, modelID: String?) -> Bool {
        guard (1...4).contains(position) else { return false }
        var cfg = salonConfig
        switch position {
        case 1: cfg.seat1 = modelID
        case 2: cfg.seat2 = modelID
        case 3: cfg.seat3 = modelID
        case 4: cfg.seat4 = modelID
        default: break
        }
        var autoDisabled = false
        if cfg.isEnabled && cfg.activeSeats.isEmpty {
            cfg.isEnabled = false
            autoDisabled = true
            halLog("HALDEBUG-SALON: setSalonSeat cleared last seat while Salon enabled — auto-disabling Salon")
        }
        salonConfig = cfg
        return autoDisabled
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

                    // Route auto-summary through the new chat-message path so it works
                        // for chat-template models (Gemma 4, etc.). The old generateResponse
                        // path produces degenerate output for these models when the system
                        // prompt is missing role markers.
                    let summaryMessages: [HalChatMessage] = [
                        .system("You produce brief, accurate summaries of conversations. Capture key topics, exchanged information, and important context. Be concise. Skip greetings."),
                        .user("Summarize this conversation:\n\n\(fullConversationText)")
                    ]

                    print("HALDEBUG-MODEL: Sending summarization via chat path (\(fullConversationText.count) characters of content)")

                    do {
                        let proseSummary = try await llmService.generateChatResponse(messages: summaryMessages, temperature: 0.3)

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
    
    
    
// ==== LEGO START: 19 ChatViewModel (MLX Model Management) ====

                // MARK: - MLX Model Management (Generic, Multi-Model)
                
                /// Checks if a specific MLX model is downloaded
                /// - Parameter modelID: The model identifier (e.g., "mlx-community/Phi-3-mini-128k-instruct-4bit")
                /// - Returns: True if model files exist locally
                func isModelDownloaded(_ modelID: String) -> Bool {
                    return MLXModelDownloader.shared.isModelDownloaded(modelID)
                }
                
                /// Downloads an MLX model with license acceptance check
                /// - Parameter model: The ModelConfiguration to download
                func downloadModel(_ model: ModelConfiguration) async {
                    guard model.source == .mlx else {
                        errorMessage = "Only MLX models require download. \(model.displayName) is always available."
                        return
                    }
                    
                    print("HALDEBUG-MODEL: Download requested for \(model.id)")
                    
                    // Check if already downloaded
                    if model.isDownloaded {
                        errorMessage = "\(model.displayName) is already downloaded."
                        print("HALDEBUG-MODEL: Model already downloaded")
                        return
                    }
                    
                    // Check license acceptance
                    if !ModelCatalogService.shared.hasAcceptedLicense(for: model.id) {
                        errorMessage = "Please accept the license for \(model.displayName) before downloading."
                        print("HALDEBUG-MODEL: License not accepted")
                        return
                    }
                    
                    // Check if already downloading
                    if mlxIsDownloading {
                        errorMessage = "A model is currently downloading. Please wait for it to complete."
                        print("HALDEBUG-MODEL: Download already in progress")
                        return
                    }
                    
                    // Clear any previous errors
                    errorMessage = nil
                    
                    print("HALDEBUG-MODEL: Initiating download for \(model.displayName)")
                    await MLXModelDownloader.shared.startDownload(modelID: model.id, repoID: model.id, sizeGB: model.sizeGB)
                }
                
                /// Cancels an in-progress model download
                func cancelModelDownload() {
                    guard let downloadingModelID = MLXModelDownloader.shared.currentDownloadID else {
                        print("HALDEBUG-MODEL: No download in progress to cancel")
                        return
                    }
                    MLXModelDownloader.shared.cancelDownload(modelID: downloadingModelID)
                    print("HALDEBUG-MODEL: Download cancelled for \(downloadingModelID)")
                }
                
                /// Deletes a downloaded MLX model
                /// - Parameter modelID: The model identifier to delete
                /// - Note: Also revokes license acceptance for the model
                func deleteModel(_ modelID: String) async {
                    print("HALDEBUG-MODEL: Deleting model \(modelID)")
                    
                    // Get model info for display name
                    guard let model = ModelCatalogService.shared.getModel(byID: modelID) else {
                        errorMessage = "Model not found in catalog."
                        return
                    }
                    
                    // Can't delete Apple Foundation Models
                    guard model.source == .mlx else {
                        errorMessage = "\(model.displayName) is built-in and cannot be deleted."
                        return
                    }
                    
                    await MLXModelDownloader.shared.deleteModel(modelID: modelID)
                    
                    // Revoke license acceptance
                    ModelCatalogService.shared.revokeLicense(for: modelID)
                    
                    // If we just deleted the currently selected model, switch to Apple FM
                    if selectedModelID == modelID {
                        await switchToModel(ModelConfiguration.appleFoundation)
                        print("HALDEBUG-MODEL: Switched to Apple FM after deleting active model")
                    }
                    
                    // Refresh catalog to update UI
                    ModelCatalogService.shared.refreshDownloadStates()
                    
                    print("HALDEBUG-MODEL: Model deleted successfully")
                }
                
                /// Attempts to activate a model (switch to it)
                /// - Parameter modelID: The model identifier to activate
                /// - Note: Checks if model is downloaded before switching (for MLX models)
                func activateModel(_ modelID: String) async {
                    print("HALDEBUG-MODEL: Attempting to activate model \(modelID)")
                    
                    guard let model = ModelCatalogService.shared.getModel(byID: modelID) else {
                        errorMessage = "Model not found in catalog."
                        print("HALDEBUG-MODEL: Model \(modelID) not found in catalog")
                        return
                    }
                    
                    // AFM models are always available
                    if model.source == .appleFoundation {
                        await switchToModel(model)
                        print("HALDEBUG-MODEL: Switched to Apple Foundation Models")
                        return
                    }
                    
                    // MLX models must be downloaded first
                    if !model.isDownloaded {
                        errorMessage = "\(model.displayName) isn't downloaded yet. Download it first."
                        print("HALDEBUG-MODEL: Cannot activate \(modelID) - not downloaded")
                        return
                    }
                    
                    // All checks passed, switch to model
                    await switchToModel(model)
                    print("HALDEBUG-MODEL: Successfully activated \(model.displayName)")
                }
                
                // MARK: - Model Catalog Helpers
                
                /// Gets all available models from the catalog
                /// - Returns: Array of all models (AFM + MLX models from Hugging Face)
                var availableModels: [ModelConfiguration] {
                    return ModelCatalogService.shared.availableModels
                }
                
                /// Gets all downloaded MLX models (excludes AFM — AFM is bundled,
                /// not downloaded, and `usableModels` prepends it explicitly).
                /// Excluding AFM here prevents the "Apple Intelligence appearing
                /// twice in Salon picker" bug, where the catalog's seed already
                /// marks AFM as `isDownloaded == true` and a naive
                /// `[AFM] + filter(isDownloaded)` would include it twice. Fixed
                /// 2026-05-18.
                /// - Returns: Array of ModelConfigurations that are downloaded MLX models
                var downloadedModels: [ModelConfiguration] {
                    return availableModels.filter {
                        $0.source == .mlx && $0.isDownloaded
                    }
                }

                /// Gets all models ready for use (Apple Foundation + Downloaded MLX)
                /// - Returns: Array of ModelConfigurations that can be used right now
                var usableModels: [ModelConfiguration] {
                    return [ModelConfiguration.appleFoundation] + downloadedModels
                }

                /// Compact dot-separated display of the active salon seats'
                /// model names. Used by the Settings sheet's Salon Mode row
                /// so the user sees "Gemma · Llama · Qwen · Dolphin" instead
                /// of "4 voices". Falls back to a short modelID suffix if a
                /// seat's model isn't in the catalog (shouldn't happen in
                /// practice, but defensive). 2026-05-18.
                var salonSeatSummary: String {
                    let names: [String] = salonConfig.activeSeats.map { (_, modelID) in
                        if let model = ModelCatalogService.shared.getModel(byID: modelID) {
                            return model.displayName
                        }
                        // Fallback: derive a friendly name from the modelID
                        // (e.g. "mlx-community/gemma-4-e2b-it-4bit" → "gemma-4-e2b").
                        return modelID.split(separator: "/").last.map(String.init) ?? modelID
                    }
                    if names.isEmpty {
                        return "no seats configured"
                    }
                    return names.joined(separator: " · ")
                }
                
                /// Refreshes the model catalog from Hugging Face
                /// - Note: This is an async operation that updates ModelCatalogService.shared.availableModels
                func refreshModelCatalog() async {
                    print("HALDEBUG-MODEL: Refreshing model catalog from Hugging Face")
                    await ModelCatalogService.shared.fetchMLXCommunityModels()
                    print("HALDEBUG-MODEL: Catalog refresh complete - \(availableModels.count) models available")
                }
                
// ==== LEGO END: 19 ChatViewModel (MLX Model Management) ====

    
    
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
                                                                        /// Pre-gate fast-path: when the user's query unambiguously asks about
                                                                        /// something personal that may have been shared before, force YES
                                                                        /// without consulting the LLM gate. This catches the most important
                                                                        /// case (memory recall on personal info) regardless of how well the
                                                                        /// active model classifies for the gate prompt.
                                                                        ///
                                                                        /// Why this exists: §2 Maxim sweep + on-device reproduction (May 13)
                                                                        /// showed that Gemma — and likely the other MLX models — sometimes
                                                                        /// say NO to "What's my cat's name?" because settings-reset
                                                                        /// dialogue and other STM residue in the gate's "recent
                                                                        /// conversation" pollutes the classification. AFM happens to
                                                                        /// classify this case well; the other curated models don't.
                                                                        /// Memory recall on personal info is too central to Hal's identity
                                                                        /// to leave at the mercy of per-model classifier accuracy.
                                                                        ///
                                                                        /// The patterns are deliberately conservative — they target
                                                                        /// explicit personal-recall phrasing, not every question. False
                                                                        /// positives just trigger a memory search the model wouldn't have
                                                                        /// otherwise; false negatives risk silent memory loss.
                                                                        private static let personalRecallPatterns: [String] = [
                                                                            // "what's my", "what is my", "where is my", "who is my"
                                                                            "what's my ", "what is my ", "whats my ",
                                                                            "where's my ", "where is my ",
                                                                            "who's my ", "who is my ",
                                                                            "when's my ", "when is my ",
                                                                            // Direct recall phrasing
                                                                            "do you remember",
                                                                            "do you know my ",
                                                                            "did i tell you",
                                                                            "did i mention",
                                                                            "have i told you",
                                                                            "have i mentioned",
                                                                            "what did i tell you",
                                                                            "what did i say about",
                                                                            "remember when i",
                                                                            "remember what i",
                                                                            // First-person possessive — caught only when prefixed by
                                                                            // "my" alone (after a sentence boundary) to avoid matching
                                                                            // "in my opinion" style phrasing.
                                                                            "tell me about my ",
                                                                            "tell me what you know about my ",
                                                                        ]

                                                                        private func looksLikePersonalRecall(_ q: String) -> Bool {
                                                                            let lower = q.lowercased()
                                                                            for pattern in ChatViewModel.personalRecallPatterns {
                                                                                if lower.contains(pattern) { return true }
                                                                            }
                                                                            return false
                                                                        }

                                                                        private func decideTools(userInput: String) async -> ToolDecision {
                                                                            // Personal-recall fast-path. Bypass the LLM classifier when the
                                                                            // query clearly asks about something we may have been told.
                                                                            // The trade-off is firmly toward fail-open: a wasted memory
                                                                            // search is cheap; a missed recall is a Maxim #3 violation.
                                                                            if looksLikePersonalRecall(userInput) {
                                                                                halLog("HALDEBUG-TOOLS: Gate bypass — query matches personal-recall pattern, forcing memory_search")
                                                                                return ToolDecision(tools: ["memory_search"], reasoning: "personal-recall keyword bypass")
                                                                            }

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

                                                                            // Phase 7 (per audit Finding 2): the gate prompt is built from
                                                                            // recentExcerpt + injectedSummary + fixed instructions + user input
                                                                            // and sent to the active model. Without bounds, this can overflow
                                                                            // AFM (4K) — a second path to the same crash Mark hit. Apply
                                                                            // per-segment compression here too, using the same machinery as
                                                                            // the main prompt path. Compression result is not surfaced to
                                                                            // the user (the gate is an internal sub-decision, not a
                                                                            // user-visible turn) but the budget enforcement IS critical.
                                                                            let gateLimits = HalModelLimits.config(for: selectedModel)
                                                                            // Cap recentExcerpt at the short-term memory allocation
                                                                            // (the gate's "recent context" lives in the same conceptual slot).
                                                                            let gateShortTermBudget = gateLimits.shortTermMemoryTokens
                                                                            // Cap injectedSummary tightly — the gate doesn't need much summary
                                                                            // detail to make YES/NO classification.
                                                                            let gateSummaryBudget = min(300, gateLimits.maxPromptTokens / 4)

                                                                            if !recentExcerpt.isEmpty {
                                                                                let segment = PromptSegment(kind: .shortTermHistory, rawContent: recentExcerpt, budgetTokens: gateShortTermBudget)
                                                                                let eval = PromptBudgetEvaluator.evaluate(segment)
                                                                                if case .overBudgetCompressible = eval.status {
                                                                                    let result = await SegmentCompressor.compress(
                                                                                        segment: segment,
                                                                                        usingModel: selectedModel,
                                                                                        llmService: llmService,
                                                                                        cache: memoryStore
                                                                                    )
                                                                                    recentExcerpt = result.compressedContent
                                                                                    halLog("HALDEBUG-TOOLS: Gate recentExcerpt over budget — \(result.cacheHit ? "cached" : "fresh") \(result.truncated ? "truncation" : "compression") applied")
                                                                                }
                                                                            }

                                                                            var gateSummary = injectedSummary
                                                                            if !gateSummary.isEmpty {
                                                                                let segment = PromptSegment(kind: .autoSummary, rawContent: gateSummary, budgetTokens: gateSummaryBudget)
                                                                                let eval = PromptBudgetEvaluator.evaluate(segment)
                                                                                if case .overBudgetCompressible = eval.status {
                                                                                    let result = await SegmentCompressor.compress(
                                                                                        segment: segment,
                                                                                        usingModel: selectedModel,
                                                                                        llmService: llmService,
                                                                                        cache: memoryStore
                                                                                    )
                                                                                    gateSummary = result.compressedContent
                                                                                    halLog("HALDEBUG-TOOLS: Gate injectedSummary over budget — \(result.cacheHit ? "cached" : "fresh") \(result.truncated ? "truncation" : "compression") applied")
                                                                                }
                                                                            }

                                                                            var contextSection = ""
                                                                            if !recentExcerpt.isEmpty {
                                                                                contextSection += "Recent conversation:\n\(recentExcerpt)\n\n"
                                                                            }
                                                                            if !gateSummary.isEmpty {
                                                                                contextSection += "Summary of earlier context:\n\(gateSummary)\n\n"
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

                                                                            let gateStart = Date()
                                                                            halLog("HALDEBUG-TOOLS: Gate START (prompt \(toolDecisionPrompt.count) chars, model: \(selectedModel.displayName))")
                                                                            do {
                                                                                // PRIVACY: route the gate through the user-selected model so we
                                                                                // never silently invoke a different LLM. The earlier "RAG gate
                                                                                // always uses AFM" optimization violated the consistency
                                                                                // promise that everything in Gemma mode stays on Gemma.
                                                                                //
                                                                                // Per Strategic §5: AFM uses @Generable for a typed Bool return
                                                                                // (no parsing, no prefix-matching). MLX uses the text-based
                                                                                // YES/NO prompt with per-model wording adjustments where
                                                                                // needed — e.g. Qwen's verbosity needs a sharper directive.
                                                                                let shouldSearch: Bool
                                                                                if selectedModel.source == .appleFoundation {
                                                                                    let decision = try await llmService.generateStructuredOnAFM(
                                                                                        prompt: toolDecisionPrompt,
                                                                                        instructions: "You are a fast classifier deciding whether Hal needs to search its memory database to answer the user's current question.",
                                                                                        type: AFMRAGGateDecision.self,
                                                                                        temperature: 0.1
                                                                                    )
                                                                                    shouldSearch = decision.shouldSearchMemory
                                                                                } else {
                                                                                    let mlxPrompt = mlxGatePromptAugmentation(modelID: selectedModel.id, base: toolDecisionPrompt)
                                                                                    let gateResponse = try await llmService.generateChatResponse(
                                                                                        messages: [
                                                                                            .system("You are a fast YES/NO classifier. Respond with only the single word YES or NO — no punctuation, no explanation."),
                                                                                            .user(mlxPrompt)
                                                                                        ],
                                                                                        temperature: 0.1
                                                                                    )
                                                                                    let answer = gateResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                                                                    shouldSearch = answer.hasPrefix("YES")
                                                                                }

                                                                                let gateMs = Int(Date().timeIntervalSince(gateStart) * 1000)
                                                                                if shouldSearch {
                                                                                    halLog("HALDEBUG-TOOLS: Gate → YES in \(gateMs)ms (memory search needed)")
                                                                                    return ToolDecision(tools: ["memory_search"], reasoning: "Gate answered YES")
                                                                                } else {
                                                                                    halLog("HALDEBUG-TOOLS: Gate → NO in \(gateMs)ms (recent context sufficient)")
                                                                                    return ToolDecision(tools: [], reasoning: "Gate answered NO")
                                                                                }
                                                                            } catch {
                                                                                let gateMs = Int(Date().timeIntervalSince(gateStart) * 1000)
                                                                                halLog("HALDEBUG-TOOLS: ERROR: Gate failed in \(gateMs)ms - \(error.localizedDescription) — falling back to always-search for safety")
                                                                                // Privacy fallback: if the gate errors, search anyway rather
                                                                                // than silently dropping memory access. Hal would rather be
                                                                                // a touch slower than blind to his own past.
                                                                                return ToolDecision(tools: ["memory_search"], reasoning: "Gate error — fail-open to memory search")
                                                                            }
                                                                        }
                                                                        
                                                                        /// Executes the selected tools based on decision
                                                                        /// Compound-query decomposition (May 13, 2026, post-RAG-investigation).
                                                                        ///
                                                                        /// "What's my cat's name AND favorite color?" — asking for two
                                                                        /// stored facts in one query — embeds to a vector that's the
                                                                        /// average of both topics. Semantic search returns snippets
                                                                        /// that match neither strongly, and the model fails to extract
                                                                        /// the specific facts. Verified on device: failed on AFM and
                                                                        /// Gemma equally, so it's not a model-family issue — it's a
                                                                        /// general retrieval limitation.
                                                                        ///
                                                                        /// Fix: detect compound queries, split into atomic sub-queries,
                                                                        /// run independent searches, merge snippets. Each sub-query
                                                                        /// embeds cleanly; each search returns snippets relevant to
                                                                        /// that topic; merge dedupes content and keeps the strongest
                                                                        /// matches.
                                                                        ///
                                                                        /// Returns nil for non-compound queries (caller uses single
                                                                        /// search path). Returns the split sub-queries when compound
                                                                        /// patterns are detected.
                                                                        ///
                                                                        /// Detection is conservative (rule-based, pattern-match) — a
                                                                        /// false positive just costs one extra search; a false
                                                                        /// negative leaves us in the old broken state. Per Mark's
                                                                        /// "rule-based for obvious cases" suggestion.
                                                                        private func decomposeCompoundQuery(_ input: String) -> [String]? {
                                                                            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                                                                            guard !trimmed.isEmpty else { return nil }
                                                                            let lower = trimmed.lowercased()

                                                                            // Multiple sentences ending in '?' — strong compound signal.
                                                                            // e.g. "What's my cat's name? What about my color?"
                                                                            let questionMarks = trimmed.filter { $0 == "?" }.count
                                                                            if questionMarks > 1 {
                                                                                let parts = trimmed
                                                                                    .components(separatedBy: "?")
                                                                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                                                    .filter { !$0.isEmpty }
                                                                                if parts.count > 1 {
                                                                                    halLog("HALDEBUG-RAG: Compound detected (multi-? marks) → \(parts.count) sub-queries")
                                                                                    return parts.map { $0 + "?" }
                                                                                }
                                                                            }

                                                                            // " and " joining two topics within a single question — only
                                                                            // treat as compound when at least one side carries a
                                                                            // personal-recall signal ("my ...") to avoid splitting
                                                                            // legitimate single-topic phrases like
                                                                            // "Britain and France" or "rock and roll".
                                                                            if lower.contains(" and ") && lower.contains("my ") {
                                                                                let parts = trimmed
                                                                                    .components(separatedBy: " and ")
                                                                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                                                    .filter { !$0.isEmpty }
                                                                                // Only split if both segments are non-trivial and at
                                                                                // least one mentions "my" (the recall-trigger).
                                                                                if parts.count == 2,
                                                                                   parts.allSatisfy({ $0.count >= 3 }),
                                                                                   parts.contains(where: { $0.lowercased().contains("my ") })
                                                                                {
                                                                                    halLog("HALDEBUG-RAG: Compound detected (' and ' with personal recall) → \(parts.count) sub-queries")
                                                                                    return parts
                                                                                }
                                                                            }

                                                                            // Comma-separated topics in a question. Conservative: only
                                                                            // treat as compound when the question contains a
                                                                            // first-person pronoun ("my", "I") and at least two
                                                                            // commas (suggesting a list).
                                                                            let commaCount = trimmed.filter { $0 == "," }.count
                                                                            if commaCount >= 2 && (lower.contains("my ") || lower.contains(" i ")) {
                                                                                let parts = trimmed
                                                                                    .components(separatedBy: ",")
                                                                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                                                    .filter { $0.count >= 3 }
                                                                                if parts.count >= 3 {
                                                                                    halLog("HALDEBUG-RAG: Compound detected (comma-separated list) → \(parts.count) sub-queries")
                                                                                    return parts
                                                                                }
                                                                            }

                                                                            return nil
                                                                        }

                                                                        /// Merge snippets from multiple searches, deduping by content
                                                                        /// (keep the highest-relevance copy when a snippet appears
                                                                        /// in multiple sub-query results), then sort by relevance.
                                                                        /// Caller applies token-budget capping afterwards.
                                                                        private func mergeSearchSnippets(_ groups: [[UnifiedSearchResult]]) -> [UnifiedSearchResult] {
                                                                            var byContent: [String: UnifiedSearchResult] = [:]
                                                                            for group in groups {
                                                                                for result in group {
                                                                                    let key = result.content
                                                                                    if let existing = byContent[key] {
                                                                                        // Keep the higher-relevance copy
                                                                                        if result.relevance > existing.relevance {
                                                                                            byContent[key] = result
                                                                                        }
                                                                                    } else {
                                                                                        byContent[key] = result
                                                                                    }
                                                                                }
                                                                            }
                                                                            return byContent.values.sorted { $0.relevance > $1.relevance }
                                                                        }

                                                                        private func executeTools(decision: ToolDecision, userInput: String, excludeTurns: [Int], tokenBudget: Int) async -> ToolResults {
                                                                            var memoryResults: [UnifiedSearchResult]? = nil
                                                                            var usedTools: [String] = []

                                                                            // Execute memory_search if requested
                                                                            if decision.tools.contains("memory_search") {
                                                                                let searchStart = Date()

                                                                                // Compound-query decomposition. When the user asks
                                                                                // for multiple stored facts in one query, run a
                                                                                // separate search per sub-topic and merge — the
                                                                                // single-embedding average otherwise dilutes match
                                                                                // strength on every topic. Verified failure mode
                                                                                // on the May-13 cross-restart test.
                                                                                let subQueries: [String] = decomposeCompoundQuery(userInput) ?? [userInput]

                                                                                if subQueries.count == 1 {
                                                                                    // Original single-search path. No behavior change.
                                                                                    halLog("HALDEBUG-TOOLS: memory_search START (budget=\(tokenBudget) tokens, excludeTurns=\(excludeTurns.count))")
                                                                                    var searchContext = memoryStore.searchUnifiedContent(
                                                                                        for: userInput,
                                                                                        currentConversationId: conversationId,
                                                                                        excludeTurns: excludeTurns,
                                                                                        maxResults: 10,
                                                                                        tokenBudget: tokenBudget
                                                                                    )
                                                                                    // LLM-driven query expansion (2026-05-17). When
                                                                                    // the initial retrieval is weak (top-1 RRF below
                                                                                    // the calibrated threshold AND no BM25 hit),
                                                                                    // ask the active LLM for related terms and
                                                                                    // re-run BM25 with them. The semantic side is
                                                                                    // unchanged — embeddings don't benefit from
                                                                                    // word expansion. Cached by query hash in
                                                                                    // SQLite so repeated queries don't re-call.
                                                                                    let firstAll = searchContext.conversationSnippets + searchContext.documentSnippets
                                                                                    if let top1 = firstAll.first,
                                                                                       QueryExpansion.shouldExpand(top1Score: top1.relevanceScore, top1IsEntityMatch: top1.isEntityMatch) {
                                                                                        let beforeScoreStr = String(format: "%.4f", top1.relevanceScore)
                                                                                        halLog("HALDEBUG-EXPANSION: trigger fired — top1Score=\(beforeScoreStr) isEntityMatch=\(top1.isEntityMatch)")
                                                                                        let terms = await QueryExpansion.expand(
                                                                                            query: userInput,
                                                                                            memoryStore: memoryStore,
                                                                                            llmService: llmService
                                                                                        )
                                                                                        if !terms.isEmpty {
                                                                                            let expanded = memoryStore.searchUnifiedContent(
                                                                                                for: userInput,
                                                                                                currentConversationId: conversationId,
                                                                                                excludeTurns: excludeTurns,
                                                                                                maxResults: 10,
                                                                                                tokenBudget: tokenBudget,
                                                                                                expansionTerms: terms
                                                                                            )
                                                                                            let expandedAll = expanded.conversationSnippets + expanded.documentSnippets
                                                                                            if let newTop = expandedAll.first, newTop.relevanceScore >= top1.relevanceScore {
                                                                                                let afterScoreStr = String(format: "%.4f", newTop.relevanceScore)
                                                                                                halLog("HALDEBUG-EXPANSION: expanded search wins (top1 \(beforeScoreStr) → \(afterScoreStr)). Using expanded results.")
                                                                                                searchContext = expanded
                                                                                            } else {
                                                                                                halLog("HALDEBUG-EXPANSION: expanded search did not improve top1. Keeping original results.")
                                                                                            }
                                                                                        }
                                                                                    }
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
                                                                                    let searchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
                                                                                    halLog("HALDEBUG-TOOLS: memory_search END in \(searchMs)ms — \(memoryResults?.count ?? 0) results (\(searchContext.conversationSnippets.count) conv + \(searchContext.documentSnippets.count) doc)")
                                                                                } else {
                                                                                    // Multi-search path. Each sub-query gets the
                                                                                    // full token budget for its own search; the
                                                                                    // merged set is then re-capped to the original
                                                                                    // budget so prompt prefill stays bounded.
                                                                                    halLog("HALDEBUG-TOOLS: memory_search START (compound, \(subQueries.count) sub-queries, budget=\(tokenBudget) tokens each, excludeTurns=\(excludeTurns.count))")
                                                                                    var perQueryGroups: [[UnifiedSearchResult]] = []
                                                                                    var totalConv = 0
                                                                                    var totalDoc = 0
                                                                                    for (i, sub) in subQueries.enumerated() {
                                                                                        halLog("HALDEBUG-TOOLS: sub-query [\(i+1)/\(subQueries.count)]: \(sub.prefix(80))")
                                                                                        let ctx = memoryStore.searchUnifiedContent(
                                                                                            for: sub,
                                                                                            currentConversationId: conversationId,
                                                                                            excludeTurns: excludeTurns,
                                                                                            maxResults: 5,   // smaller per-sub-query cap
                                                                                            tokenBudget: tokenBudget
                                                                                        )
                                                                                        totalConv += ctx.conversationSnippets.count
                                                                                        totalDoc += ctx.documentSnippets.count
                                                                                        let group = (ctx.conversationSnippets + ctx.documentSnippets).map { ragSnippet in
                                                                                            UnifiedSearchResult(
                                                                                                content: ragSnippet.content,
                                                                                                relevance: ragSnippet.relevanceScore,
                                                                                                source: ragSnippet.sourceType.rawValue,
                                                                                                isEntityMatch: ragSnippet.isEntityMatch,
                                                                                                filePath: ragSnippet.sourceType == .document ? ragSnippet.sourceName : nil
                                                                                            )
                                                                                        }
                                                                                        perQueryGroups.append(group)
                                                                                    }
                                                                                    let merged = mergeSearchSnippets(perQueryGroups)

                                                                                    // Re-apply the original token budget on the
                                                                                    // merged set (cap by relevance order, then
                                                                                    // re-check budget). This keeps the prompt
                                                                                    // prefill bounded even if all sub-queries
                                                                                    // returned snippets at full budget each.
                                                                                    var capped: [UnifiedSearchResult] = []
                                                                                    var totalTokens = 0
                                                                                    for r in merged {
                                                                                        let t = TokenEstimator.estimateTokens(from: r.content)
                                                                                        if totalTokens + t > tokenBudget { break }
                                                                                        capped.append(r)
                                                                                        totalTokens += t
                                                                                        if capped.count >= 10 { break }
                                                                                    }
                                                                                    memoryResults = capped
                                                                                    let searchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
                                                                                    halLog("HALDEBUG-TOOLS: memory_search END (compound) in \(searchMs)ms — \(memoryResults?.count ?? 0) merged results from \(perQueryGroups.reduce(0) { $0 + $1.count }) raw across \(subQueries.count) sub-queries (\(totalConv) conv + \(totalDoc) doc raw, \(totalTokens) tokens after merge+cap)")
                                                                                }
                                                                                usedTools.append("memory_search")
                                                                            } else {
                                                                                halLog("HALDEBUG-TOOLS: Skipping memory_search (gate decision)")
                                                                            }

                                                                            // Future tools (Wikipedia, DuckDuckGo) would be added here

                                                                            return ToolResults(memorySearchResults: memoryResults, toolsUsed: usedTools)
                                                                        }
                                                                        
                                                                        

                                                                        // MARK: - Chat-Message-Based Prompt Construction (new path)
                                                                        //
                                                                        // buildChatMessages is the replacement for buildPromptHistory. Instead of
                                                                        // producing a single marker-delimited string (HelPML format), it produces
                                                                        // a [HalChatMessage] sequence that flows through LLMService.generateChatResponse.
                                                                        //
                                                                        // This is being built up incrementally. Each step adds one piece of the
                                                                        // original feature stack from buildPromptHistory and verifies it survives
                                                                        // the transition to chat form. The minimal foundation (step 0) is just:
                                                                        //   [.system(<effectiveSystemPrompt>), .user(<currentInput>)]
                                                                        //
                                                                        // Subsequent steps will fold in: conversation history as turn pairs,
                                                                        // temporal context, summary, RAG snippets, self-knowledge. See
                                                                        // HANDOFF_BRIEF "prompt format" section for rationale.
                                                                        func buildChatMessages(currentInput: String,
                                                                                               historyOverride: [ChatMessage]? = nil) async
                                                                                               -> (messages: [HalChatMessage],
                                                                                                   compressedSegments: Set<PromptSegmentKind>,
                                                                                                   truncatedSegments: Set<PromptSegmentKind>) {
                                                                            halLog("HALDEBUG-CHAT: Building chat messages for input: '\(currentInput.prefix(60))…'")

                                                                            var msgs: [HalChatMessage] = []
                                                                            var compressedSegments: Set<PromptSegmentKind> = []
                                                                            var truncatedSegments: Set<PromptSegmentKind> = []

                                                                            let limits = HalModelLimits.config(for: selectedModel)

                                                                            // PHASE 7 — per-segment budgets within the model's prompt allocation.
                                                                            //
                                                                            // The 50% "prompt" allocation (limits.maxPromptTokens) holds the
                                                                            // system message body. Within that, static segments have hard
                                                                            // caps and dynamic segments share whatever room remains. RAG
                                                                            // and short-term have their own separate slots from limits.
                                                                            //
                                                                            // For AFM (prompt budget 2048): self-knowledge gets ~400-600
                                                                            // tokens after static caps. Tight, but the compressor produces
                                                                            // a meaningful distillation that fits.
                                                                            // For Gemma (prompt budget 65k): self-knowledge gets ~64k.
                                                                            // Compression will essentially never trigger.
                                                                            let sysPromptActualTokens = TokenEstimator.estimateTokens(from: effectiveSystemPrompt)
                                                                            let temporalReserveTokens = 64
                                                                            let dynamicPromptRoom = max(
                                                                                limits.maxPromptTokens - sysPromptActualTokens - temporalReserveTokens,
                                                                                200  // never let dynamic segments fall below this floor
                                                                            )
                                                                            // Split: summary gets the smaller share, self-knowledge the larger
                                                                            // (summary is usually short; self-knowledge is what tends to bloat).
                                                                            let summaryBudgetTokens = max(dynamicPromptRoom * 30 / 100, 150)
                                                                            let selfKnowledgeBudgetTokens = max(dynamicPromptRoom - summaryBudgetTokens, 150)

                                                                            // Label clarification (2026-05-18): the "selfKnowledge=" value
                                                                            // here is the ALLOCATION CEILING, not the actual tokens injected.
                                                                            // Previous label confused live-test reviewers into thinking 44K
                                                                            // of self-knowledge was being shoved into the prompt. Renamed to
                                                                            // `selfKnowledgeBudget=` for clarity; the actual usage is logged
                                                                            // separately as `selfKnowledgeUsed=` immediately after
                                                                            // resolveSegment returns.
                                                                            halLog("HALDEBUG-BUDGET: \(selectedModel.displayName) prompt=\(limits.maxPromptTokens) sys=\(sysPromptActualTokens) summaryBudget=\(summaryBudgetTokens) selfKnowledgeBudget=\(selfKnowledgeBudgetTokens) RAGBudget=\(limits.maxRagTokens) shortTerm=\(limits.shortTermMemoryTokens)")

                                                                            // Local helper: pre-flight evaluate a segment, compress if over
                                                                            // budget, and update the tracking sets in this scope.
                                                                            // Returns the content to actually inject (possibly compressed
                                                                            // or truncated).
                                                                            @MainActor
                                                                            func resolveSegment(_ kind: PromptSegmentKind, rawContent: String, budgetTokens: Int) async -> String {
                                                                                guard !rawContent.isEmpty else { return rawContent }
                                                                                let segment = PromptSegment(kind: kind, rawContent: rawContent, budgetTokens: budgetTokens)
                                                                                let eval = PromptBudgetEvaluator.evaluate(segment)

                                                                                // Self-knowledge bypass (per Mark's 2026-05-16 directive).
                                                                                // Self-knowledge is injected RAW for MLX models — no compression,
                                                                                // no chunking, no LLM calls, no embedding selection. The corpus is
                                                                                // kept bounded at write time by `storeReflectionWithSynthesis`
                                                                                // (depth, not volume). If the raw corpus ever exceeds the budget,
                                                                                // that's a write-time-synthesis failure signal, not a runtime
                                                                                // concern to compensate for at read time. We log it loudly so the
                                                                                // synthesis layer can be inspected, then inject raw anyway —
                                                                                // truncation is not acceptable as a design choice.
                                                                                if kind == .selfKnowledge {
                                                                                    if case .overBudgetCompressible(let actual, let budget) = eval.status {
                                                                                        halLog("HALDEBUG-SELF-KNOWLEDGE: Corpus over budget (\(actual) > \(budget) tokens) — injecting RAW. This indicates write-time synthesis isn't keeping the corpus lean enough; inspect storeReflectionWithSynthesis threshold and behavior.")
                                                                                    } else if case .overBudgetHardCap(let actual, let budget) = eval.status {
                                                                                        halLog("HALDEBUG-SELF-KNOWLEDGE: Corpus over hard-cap (\(actual) > \(budget) tokens) — injecting RAW (per directive: no truncation as design choice).")
                                                                                    }
                                                                                    return rawContent
                                                                                }

                                                                                switch eval.status {
                                                                                case .withinBudget:
                                                                                    return rawContent
                                                                                case .overBudgetCompressible:
                                                                                    let result = await SegmentCompressor.compress(
                                                                                        segment: segment,
                                                                                        usingModel: selectedModel,
                                                                                        llmService: llmService,
                                                                                        cache: memoryStore
                                                                                    )
                                                                                    if result.truncated {
                                                                                        truncatedSegments.insert(kind)
                                                                                    } else {
                                                                                        compressedSegments.insert(kind)
                                                                                    }
                                                                                    return result.compressedContent
                                                                                case .overBudgetHardCap(let actual, let budget):
                                                                                    halLog("HALDEBUG-COMPRESS: ⚠️ Hard-cap segment \(kind.displayName) over budget (\(actual) > \(budget)) — fallback truncation. THIS IS A BUG; static-segment caps should be enforced upstream.")
                                                                                    truncatedSegments.insert(kind)
                                                                                    let maxChars = Int(Double(budget) * 4.0)
                                                                                    return String(rawContent.prefix(maxChars))
                                                                                }
                                                                            }

                                                                            // System message = persona + CURRENT CONTEXT block.
                                                                            // The CONTEXT block carries:
                                                                            //   STEP 2: temporal awareness (date, time of day, weekday, device, etc.)
                                                                            //   STEP 3: injected conversation summary when older turns compressed
                                                                            //   STEP 4: RAG snippets from long-term memory (relevant past content)
                                                                            //   STEP 5: self-awareness (stats) + self-knowledge (persistent traits)
                                                                            //           when enableSelfKnowledge is true
                                                                            // Original intent: situate Hal in time + carry compressed and retrieved
                                                                            // context + give Hal awareness of himself. Chat form folds it all into
                                                                            // the system message as background.
                                                                            var contextSections: [String] = []

                                                                            let temporalRaw = buildTemporalContext()
                                                                            let temporalBody = temporalRaw
                                                                                .replacingOccurrences(of: "#=== BEGIN TEMPORAL_CONTEXT ===#", with: "")
                                                                                .replacingOccurrences(of: "#=== END TEMPORAL_CONTEXT ===#", with: "")
                                                                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                                                            if !temporalBody.isEmpty {
                                                                                contextSections.append(temporalBody)
                                                                            }

                                                                            if !injectedSummary.isEmpty {
                                                                                let resolvedSummary = await resolveSegment(.autoSummary, rawContent: injectedSummary, budgetTokens: summaryBudgetTokens)
                                                                                contextSections.append("Summary of earlier conversation:\n\(resolvedSummary)")
                                                                            }

                                                                            // STEP 5: Self-awareness (stats) + self-knowledge (persistent traits).
                                                                            // Mapping: old SELF_AWARENESS + SELF_KNOWLEDGE marker sections fold into
                                                                            // the same CURRENT CONTEXT block. Only included when the user has
                                                                            // enableSelfKnowledge turned on.
                                                                            //
                                                                            // Per Mark's 2026-05-16 directive: persistent self-knowledge is NOT
                                                                            // injected when the active model is Apple Intelligence (AFM). AFM's
                                                                            // 4K context window can't hold the corpus once it grows past a
                                                                            // small threshold, and lossy compression isn't acceptable as a
                                                                            // design choice. AFM users get no persistent self-knowledge in the
                                                                            // prompt; the model card states this clearly. Self-awareness (the
                                                                            // small runtime-stats block: turn count, uptime, etc.) is still
                                                                            // injected on AFM — it's structurally different from persistent
                                                                            // identity and small enough to never overflow.
                                                                            let isActiveAFM = (llmService.activeModelID == ModelConfiguration.appleFoundation.id)

                                                                            if enableSelfKnowledge {
                                                                                let selfAwarenessRaw = buildSelfAwarenessContext()
                                                                                let selfAwarenessBody = selfAwarenessRaw
                                                                                    .replacingOccurrences(of: "#=== BEGIN SELF_AWARENESS ===#", with: "")
                                                                                    .replacingOccurrences(of: "#=== END SELF_AWARENESS ===#", with: "")
                                                                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                                                                if !selfAwarenessBody.isEmpty {
                                                                                    contextSections.append(selfAwarenessBody)
                                                                                }

                                                                                if isActiveAFM {
                                                                                    halLog("HALDEBUG-SELF-KNOWLEDGE: Skipping persistent self-knowledge injection — active model is Apple Intelligence (per 2026-05-16 directive: AFM gets no self-knowledge)")
                                                                                } else {
                                                                                    let selfKnowledgeRaw = buildSelfKnowledgeContext()
                                                                                    let selfKnowledgeBody = selfKnowledgeRaw
                                                                                        .replacingOccurrences(of: "#=== BEGIN SELF_KNOWLEDGE ===#", with: "")
                                                                                        .replacingOccurrences(of: "#=== END SELF_KNOWLEDGE ===#", with: "")
                                                                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                                                                    if !selfKnowledgeBody.isEmpty {
                                                                                        let resolvedSelfKnowledge = await resolveSegment(.selfKnowledge, rawContent: selfKnowledgeBody, budgetTokens: selfKnowledgeBudgetTokens)
                                                                                        // Log the actual injection size for transparency.
                                                                                        // Pairs with `selfKnowledgeBudget=` in HALDEBUG-BUDGET
                                                                                        // above. Token estimate uses the same 4-chars-per-token
                                                                                        // heuristic as PromptBudgetEvaluator. 2026-05-18.
                                                                                        let usedTokensEstimate = resolvedSelfKnowledge.count / 4
                                                                                        halLog("HALDEBUG-SELF-KNOWLEDGE: selfKnowledgeUsed=\(usedTokensEstimate) tokens (\(resolvedSelfKnowledge.count) chars) of selfKnowledgeBudget=\(selfKnowledgeBudgetTokens)")
                                                                                        contextSections.append(resolvedSelfKnowledge)
                                                                                    }
                                                                                }
                                                                            }

                                                                            // STEP 4: RAG via tool router. decideTools is a YES/NO gate (AFM-routed
                                                                            // for speed and stability — see decideTools comments). executeTools
                                                                            // runs the memory search and returns up to 10 snippets within the
                                                                            // model's RAG token budget.
                                                                            if !currentInput.isEmpty {
                                                                                let toolDecision = await decideTools(userInput: currentInput)
                                                                                let shortTermTurns = getShortTermTurns(currentTurns: countCompletedTurns())
                                                                                let toolResults = await executeTools(
                                                                                    decision: toolDecision,
                                                                                    userInput: currentInput,
                                                                                    excludeTurns: shortTermTurns,
                                                                                    tokenBudget: limits.maxRagTokens
                                                                                )
                                                                                if let snippets = toolResults.memorySearchResults, !snippets.isEmpty {
                                                                                    fullRAGContext = snippets
                                                                                    var ragLines: [String] = []
                                                                                    for (idx, s) in snippets.enumerated() {
                                                                                        ragLines.append("[\(idx + 1)] \(s.source) | relevance \(String(format: "%.2f", s.relevance))\n\(s.content)")
                                                                                    }
                                                                                    let ragRaw = "Relevant past context:\n\(ragLines.joined(separator: "\n\n"))"
                                                                                    let resolvedRag = await resolveSegment(.ragRetrieval, rawContent: ragRaw, budgetTokens: limits.maxRagTokens)
                                                                                    contextSections.append(resolvedRag)
                                                                                    halLog("HALDEBUG-CHAT: Folded in \(snippets.count) RAG snippets")
                                                                                } else if toolResults.toolsUsed.contains("memory_search") {
                                                                                    // Bug 2b — confabulation gate. A memory search actually
                                                                                    // RAN (the gate said YES, or the personal-recall bypass
                                                                                    // forced it) but came back empty. Previously nothing was
                                                                                    // added here, so the model had no signal the lookup
                                                                                    // failed and would invent plausible specifics (a cat's
                                                                                    // name, a date) to satisfy a question that clearly
                                                                                    // expected stored context. Tell it the search missed so it
                                                                                    // says "I don't have that" instead — Maxim 1 in the
                                                                                    // retrieval path. Only on a real search (a gate SKIP means
                                                                                    // the query didn't need memory, so no note is warranted).
                                                                                    let missNote = "Memory search: you looked in your stored memory and any imported documents for this and found no relevant match. If the answer isn't already in the current conversation or your general knowledge, tell the user plainly that you don't have that information stored — do not invent names, facts, dates, numbers, or other specifics to fill the gap. Saying you don't know is the correct answer here."
                                                                                    contextSections.append(missNote)
                                                                                    halLog("HALDEBUG-CHAT: memory_search ran but found nothing — appended Bug-2b confabulation-gate note")
                                                                                }
                                                                            }

                                                                            let systemMessage: String
                                                                            if contextSections.isEmpty {
                                                                                systemMessage = effectiveSystemPrompt
                                                                            } else {
                                                                                let contextBlock = contextSections.joined(separator: "\n\n")
                                                                                systemMessage = "\(effectiveSystemPrompt)\n\nCURRENT CONTEXT:\n\(contextBlock)"
                                                                            }
                                                                            msgs.append(.system(systemMessage))

                                                                            // STEP 1: Conversation history as alternating .user/.assistant turns.
                                                                            //
                                                                            // Replaces buildPromptHistory's MEMORY_SHORT section. Original intent:
                                                                            // give the model the most recent verbatim turns so it can reference
                                                                            // what was just said. In chat form this becomes actual turn pairs —
                                                                            // chat-template models understand this natively (they were trained on
                                                                            // multi-turn conversations exactly like this).
                                                                            //
                                                                            // Source: vm.messages (in-memory). Filter partials (in-flight streaming
                                                                            // placeholders). Drop the trailing user message when it equals
                                                                            // currentInput — sendMessage() already appended it before calling us,
                                                                            // but we'll add it ourselves at the end so role order is correct.
                                                                            //
                                                                            // Depth: effectiveMemoryDepth turns × 2 messages-per-turn.
                                                                            let historyDepth = effectiveMemoryDepth * 2
                                                                            // History source: if `historyOverride` is provided (used by
                                                                            // Salon Mode's independent path — each seat must see the
                                                                            // conversation as it was BEFORE any seat ran this turn, not
                                                                            // the live `messages` array which already contains earlier
                                                                            // seats' responses), use it. Otherwise fall back to the live
                                                                            // array. See Docs/Two_Bug_Diagnosis_2026-05-15.md.
                                                                            let historySource = historyOverride ?? messages
                                                                            let nonPartial = historySource.filter { !$0.isPartial }
                                                                            let trailingIsCurrentTurn: Bool = {
                                                                                guard let last = nonPartial.last else { return false }
                                                                                return last.isFromUser && last.content == currentInput
                                                                            }()
                                                                            let history: [ChatMessage] = trailingIsCurrentTurn
                                                                                ? Array(nonPartial.dropLast().suffix(historyDepth))
                                                                                : Array(nonPartial.suffix(historyDepth))

                                                                            for msg in history {
                                                                                if msg.isFromUser {
                                                                                    msgs.append(.user(msg.content))
                                                                                } else {
                                                                                    msgs.append(.assistant(msg.content))
                                                                                }
                                                                            }

                                                                            // Final .user — the current turn
                                                                            msgs.append(.user(currentInput))

                                                                            halLog("HALDEBUG-CHAT: Built \(msgs.count) chat messages (step 1: system + \(history.count) history + current user, depth=\(effectiveMemoryDepth))")
                                                                            if !compressedSegments.isEmpty || !truncatedSegments.isEmpty {
                                                                                halLog("HALDEBUG-CHAT: This turn compressed=\(compressedSegments.map { $0.displayName }.sorted()) truncated=\(truncatedSegments.map { $0.displayName }.sorted())")
                                                                            }
                                                                            return (messages: msgs,
                                                                                    compressedSegments: compressedSegments,
                                                                                    truncatedSegments: truncatedSegments)
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
                                                
                                                // Get list of available models (my "processing options")
                                                let availableModels = ModelCatalogService.shared.availableModels
                                                let downloadedLocalModels = availableModels.filter {
                                                    $0.source == .mlx && $0.isDownloaded
                                                }
                                                let modelList = ([ModelConfiguration.appleFoundation] + downloadedLocalModels)
                                                    .map { $0.displayName }
                                                    .joined(separator: ", ")
                                                
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
                                            // 2026-05-18 (v1 crystallization): meta_cognition is the
                                            // 7th allowed category for trait crystallization. Per the
                                            // 2026-05-17 Evolutionary Salon (Gemma's specific
                                            // proposal), this category surfaces traits about *how*
                                            // Hal thinks (self-awareness, processing patterns), as
                                            // distinct from *what* he learns. Examples: "Hal prefers
                                            // naming uncertainty plainly", "Hal slows down on
                                            // existential questions". Without this case, traits
                                            // written under "meta_cognition" would fall through to
                                            // default and never reach the prompt — silently inert
                                            // self-knowledge, which is the worst kind.
                                            var metaCognitionEntries: [String] = []

                                            for entry in allKnowledge {
                                                let confidenceStr = String(format: "%.0f%%", entry.confidence * 100)

                                                // Phase 3d (2026-05-18): a trait's value column may now
                                                // hold either a plain string (single-valued, the
                                                // original format) OR a serialized MultiValuedTrait
                                                // JSON object (with primary + tensions[]). Detect at
                                                // read time and inject only the primary statement —
                                                // tensions live in the DB for lineage and viewer
                                                // transparency, not in the system prompt. A
                                                // transparency annotation `(±N tensions held)` after
                                                // the primary lets the prompt acknowledge nuance
                                                // exists even though the model doesn't see the
                                                // individual tensions.
                                                let displayValue: String
                                                let tensionAnnotation: String
                                                if MultiValuedTrait.isMultiValuedJSON(entry.value),
                                                   let mv = MultiValuedTrait.fromJSONString(entry.value) {
                                                    displayValue = mv.primary
                                                    tensionAnnotation = mv.tensions.isEmpty ? "" : " (±\(mv.tensions.count) tensions held)"
                                                } else {
                                                    displayValue = entry.value
                                                    tensionAnnotation = ""
                                                }
                                                let entryText = "  - \(entry.key): \(displayValue) (confidence: \(confidenceStr))\(tensionAnnotation)"

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
                                                case "meta_cognition":
                                                    metaCognitionEntries.append(entryText)
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

                                            // "Ways of Thinking" surfaces meta_cognition traits —
                                            // how Hal handles uncertainty, when he slows down, what
                                            // kinds of questions he treats as different from others.
                                            // Placed last in the block so the more grounded
                                            // categories (values, capabilities, preferences) lead
                                            // and the more reflective ones close.
                                            if !metaCognitionEntries.isEmpty {
                                                contextString += "Ways of Thinking:\n"
                                                contextString += metaCognitionEntries.joined(separator: "\n") + "\n\n"
                                            }

                                            contextString += """

                                            #=== END SELF_KNOWLEDGE ===#
                                            """
                                            
                                            return contextString
                                        }

                                        
// ==== LEGO END: 20.4 ChatViewModel (Self-Knowledge Context Builder) ====


    
// ==== LEGO START: 21 ChatViewModel (Send Message Flow) ====

                                                                @Published var showInlineDetails: Bool = false

                                                                /// Send a chat turn through the full pipeline. Reads the bound
                                                                /// `currentMessage` TextField, clears it on success, and resigns
                                                                /// the keyboard.
                                                                func sendMessage() async {
                                                                    let trimmed = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                                                                    guard !trimmed.isEmpty else { return }

                                                                    isAIResponding = true
                                                                    thinkingStart = Date()
                                                                    isSendingMessage = true

                                                                    print("HALDEBUG-MODEL: Starting message send (iPhone send) - '\(trimmed.prefix(50))....'")

                                                                    // Seed thread title from first user message, touch last_active_at
                                                                    seedThreadTitleIfNeeded(trimmed)
                                                                    touchCurrentThread()

                                                                    let currentTurn = memoryStore.getCurrentTurnNumber(conversationId: conversationId) + 1
                                                                    messages.append(ChatMessage(content: trimmed, isFromUser: true, recordedByModel: "user", turnNumber: currentTurn))

                                                                    // UI side-effects: clear the field and dismiss the keyboard.
                                                                    currentMessage = ""
                                                                    #if os(iOS)
                                                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                                                    #endif

                                                                    // Branch based on Salon Mode.
                                                                    // Guard: Salon "enabled but no seats" is a degenerate
                                                                    // state (reachable when a user enables Salon then clears
                                                                    // all seats without disabling, or when persisted
                                                                    // AppStorage survives a Nuclear Reset). Routing there
                                                                    // would silently no-op the turn. Fall through to
                                                                    // single-model in that case and log so the bad state
                                                                    // is visible in diagnostics.
                                                                    if salonConfig.isEnabled && !salonConfig.activeSeats.isEmpty {
                                                                        await runSalonTurn(userInput: trimmed)
                                                                    } else {
                                                                        if salonConfig.isEnabled {
                                                                            halLog("HALDEBUG-SALON: Routing to single-model — Salon enabled but no seats configured (state guard)")
                                                                        }
                                                                        await runSingleModelTurn(userInput: trimmed)
                                                                    }

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

                                                                        // NEW PATH (May 11, 2026): chat-message-based generation.
                                                                        // The old marker-delimited string prompt (buildPromptHistory) is bypassed
                                                                        // here but left in place for reference and for systems that still need it
                                                                        // (e.g. auto-summarization, salon mode context-aware prompts).
                                                                        // Step 0 minimal: just system persona + current user message.
                                                                        // Steps 1+ will fold in history, RAG, summary, etc. incrementally.
                                                                        if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                            messages[i].content = "Formulating a reply..."
                                                                        }
                                                                        try? await Task.sleep(nanoseconds: 200_000_000)

                                                                        let chatBuildResult = await buildChatMessages(
                                                                            currentInput: userInput,
                                                                            historyOverride: historyMessagesOverride
                                                                        )
                                                                        let chatMessages = chatBuildResult.messages

                                                                        // Phase 7: surface compression/truncation flags on the partial
                                                                        // placeholder so the footer badge (Phase 6b) can render. The
                                                                        // partial message's id is `pid`; we look it up and update its
                                                                        // segment-tracking sets in place. Streaming will continue to
                                                                        // update .content; these flag fields are stable.
                                                                        if !chatBuildResult.compressedSegments.isEmpty || !chatBuildResult.truncatedSegments.isEmpty {
                                                                            if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                                messages[i].compressedSegments = chatBuildResult.compressedSegments
                                                                                messages[i].truncatedSegments = chatBuildResult.truncatedSegments
                                                                            }
                                                                        }

                                                                        // For diagnostics & legacy fields (fullPromptUsed, tokenBreakdown), keep
                                                                        // a synthetic "prompt" string that approximates what was sent.
                                                                        let prompt = chatMessages.map { "[\($0.role.rawValue)] \($0.content)" }.joined(separator: "\n\n")

                                                                        halLog("HALDEBUG-MODEL: Sending \(chatMessages.count) chat messages to language model (streaming)")
                                                                        let t0 = Date()
                                                                        // REAL STREAMING (replaces former fake-streaming animation at
                                                                        // 100 chars/sec). Updates the partial message's content as
                                                                        // tokens arrive — the UI sees the response materialise at the
                                                                        // model's actual generation rate instead of waiting for the
                                                                        // whole turn to finish, then watching a synthetic typewriter.
                                                                        // For Gemma 4 E2B (~33 tok/s ≈ 150 chars/s) this is faster
                                                                        // than the old 100 cps fake stream AND starts immediately on
                                                                        // first token. Generation timing (modelTime) is captured
                                                                        // around the whole stream so thinkingDuration stays meaningful.
                                                                        finalText = ""
                                                                        do {
                                                                            let stream = llmService.generateChatResponseStream(messages: chatMessages, temperature: temperature)
                                                                            for try await chunk in stream {
                                                                                finalText = chunk
                                                                                if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                                    messages[i].content = chunk
                                                                                }
                                                                            }
                                                                        } catch let memError as LLMService.LLMError {
                                                                            // Per-turn memory refusal (Item 11 follow-up, 2026-05-18).
                                                                            // The MLX wrapper estimated the upcoming KV cache
                                                                            // wouldn't fit and refused before starting prefill.
                                                                            // Convert into Hal's reply text so the conversation
                                                                            // continues — the user sees an honest explanation,
                                                                            // the model stays loaded, and the history is intact.
                                                                            // Any other LLMError is rethrown for the outer handler.
                                                                            modelTime = Date().timeIntervalSince(t0)
                                                                            if case .insufficientMemoryForTurn = memError {
                                                                                halLog("HALDEBUG-LLM: Per-turn memory refusal surfaced as chat message.")
                                                                                finalText = memError.errorDescription ?? "I don't have enough memory to process this turn."
                                                                                if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                                    messages[i].content = finalText
                                                                                }
                                                                            } else {
                                                                                throw memError
                                                                            }
                                                                        } catch {
                                                                            // Rethrow so the existing catch block handles the error state
                                                                            modelTime = Date().timeIntervalSince(t0)
                                                                            throw error
                                                                        }
                                                                        modelTime = Date().timeIntervalSince(t0)
                                                                        halLog("HALDEBUG-LLM: Streaming generation complete. Length: \(finalText.count), elapsed: \(String(format: "%.2f", modelTime))s")

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

                                                                        // Final settle: write the trimmed/cleaned text in case the
                                                                        // last streamed chunk had leading/trailing whitespace or
                                                                        // repetition that removeRepetitivePatterns stripped.
                                                                        if let i = messages.firstIndex(where: { $0.id == pid }), messages[i].content != text {
                                                                            messages[i].content = text
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
                                                                            
                                                                            // AFM gate (audit 2026-05-17 evening): per the May-16 directive,
                                                                            // AFM does not participate in the persistent self-knowledge
                                                                            // system at all — no self-knowledge in prompts, and (added
                                                                            // here) no reflection generation, no trait write, no
                                                                            // periodic consolidation that calls the LLM. The data
                                                                            // accumulated by prior MLX sessions is preserved untouched
                                                                            // while AFM is active; operations resume when the user
                                                                            // switches back to an MLX model. The buildSelfKnowledgeContext
                                                                            // gate covers the read side; this one covers the write +
                                                                            // maintenance side.
                                                                            let isActiveAFMForSelfKnowledge = (self.selectedModel.source == .appleFoundation)

                                                                            // Trigger consolidation if needed (every 100 turns OR 24 hours)
                                                                            let turnsSinceConsolidation = turn - self.memoryStore.lastConsolidationTurn
                                                                            let hoursSinceConsolidation = (Date().timeIntervalSince1970 - self.memoryStore.lastConsolidationTime) / 3600.0

                                                                            if turnsSinceConsolidation >= 100 || hoursSinceConsolidation >= 24 {
                                                                                if isActiveAFMForSelfKnowledge {
                                                                                    halLog("HALDEBUG-SELF-KNOWLEDGE: Skipping consolidateAndDecay — active model is Apple Intelligence (AFM does not participate in self-knowledge maintenance per 2026-05-16 directive). lastConsolidationTurn intentionally not advanced; will resume next MLX session.")
                                                                                } else {
                                                                                    print("HALDEBUG-REFLECTION: ÃƒÆ’Ã‚Â°Ãƒâ€¦Ã‚Â¸ÃƒÂ¢Ã¢â€šÂ¬Ã‚Ãƒâ€šÃ‚Â§ Triggering consolidation (turns: \(turnsSinceConsolidation), hours: \(String(format: "%.1f", hoursSinceConsolidation)))")
                                                                                    Task {
                                                                                        await self.memoryStore.consolidateAndDecay(llmService: self.llmService)
                                                                                        self.memoryStore.lastConsolidationTurn = turn
                                                                                    }
                                                                                }
                                                                            }

                                                                            // MODIFIED: Trigger Type 1 (practical) reflection every 5 turns
                                                                            if turn % 5 == 0 {
                                                                                if isActiveAFMForSelfKnowledge {
                                                                                    halLog("HALDEBUG-SELF-KNOWLEDGE: Skipping Type 1 reflection at turn \(turn) — active model is Apple Intelligence (AFM does not write reflections per 2026-05-16 directive).")
                                                                                } else {
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

                                                                                        // Phase 2 (v1 crystallization, 2026-05-18):
                                                                                        // After the reflection write settles,
                                                                                        // sweep for trait candidates. Chained in
                                                                                        // the same Task so the freshly-bumped
                                                                                        // reinforcement_count is visible to the
                                                                                        // crystallizer's SQL query (parallel
                                                                                        // Tasks would race against the reflection
                                                                                        // write and miss it). AFM gate is at the
                                                                                        // outer `if isActiveAFMForSelfKnowledge`,
                                                                                        // so this only fires for MLX sessions —
                                                                                        // consistent with the 2026-05-16
                                                                                        // directive that AFM does not participate
                                                                                        // in the self-knowledge write path.
                                                                                        await TraitCrystallizer.processTraitCandidates(
                                                                                            memoryStore: self.memoryStore,
                                                                                            llmService: self.llmService,
                                                                                            activeModelID: self.selectedModel.id
                                                                                        )
                                                                                    }
                                                                                }
                                                                            }

                                                                            // MODIFIED: Trigger Type 2 (existential) reflection every 15 turns (in addition to Type 1)
                                                                            if turn % 15 == 0 {
                                                                                if isActiveAFMForSelfKnowledge {
                                                                                    halLog("HALDEBUG-SELF-KNOWLEDGE: Skipping Type 2 reflection at turn \(turn) — active model is Apple Intelligence (AFM does not write reflections per 2026-05-16 directive).")
                                                                                } else {
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
                                                                            }

                                                                            // Update lastReflectionTurn after any reflection — but only when
                                                                            // a reflection actually fired (i.e. not gated by AFM). Otherwise
                                                                            // advancing the tracker would create false silence on the next
                                                                            // MLX session ("looks like reflections ran but the DB doesn't
                                                                            // contain them").
                                                                            if !isActiveAFMForSelfKnowledge && (turn % 5 == 0 || turn % 15 == 0) {
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
                                                                
                                                                // MARK: - Salon Mode Execution
                                                                
                                                                // Salon Mode turn execution
                                                                private func runSalonTurn(userInput: String) async {
                                                                    // Cap to the first 2 active seats while
                                                                    // SalonModeView.exposeSeatsThreeAndFour is false.
                                                                    // An iPhone 16 Plus crashed last night during a
                                                                    // 3-seat salon (AFM + Gemma + Dolphin) when iOS
                                                                    // OOM-killed Hal during the second MLX-to-MLX
                                                                    // model swap. The UI hides seats 3/4, but an
                                                                    // upgrader with persisted seat3/seat4 values
                                                                    // would still pass them through here without this
                                                                    // safety. The cap will be removed once option-2's
                                                                    // smart MLX-swap (explicit unload + GPU cache
                                                                    // clear + memory-reclaim delay) is verified at
                                                                    // 3+ seats.
                                                                    let fullActiveSeats = salonConfig.activeSeats
                                                                    let activeSeats: [(position: Int, modelID: String)]
                                                                    if SalonModeView.exposeSeatsThreeAndFour {
                                                                        activeSeats = fullActiveSeats
                                                                    } else {
                                                                        activeSeats = Array(fullActiveSeats.prefix(2))
                                                                        if fullActiveSeats.count > 2 {
                                                                            halLog("HALDEBUG-SALON: Capping salon turn from \(fullActiveSeats.count) active seats to 2 (3+ seats temporarily disabled — see SalonModeView.exposeSeatsThreeAndFour)")
                                                                        }
                                                                    }

                                                                    guard !activeSeats.isEmpty else {
                                                                        halLog("HALDEBUG-SALON: No active seats configured")
                                                                        return
                                                                    }

                                                                    halLog("HALDEBUG-SALON: Starting Salon turn with \(activeSeats.count) active seats; userInput length=\(userInput.count)")

                                                                    // SALON FIX: Store user message ONCE before seats execute
                                                                    // Calculate turn from DATABASE user messages, not array (which gets polluted by multiple seats)
                                                                    let dbUserMessages = memoryStore.getConversationMessages(conversationId: conversationId).filter { $0.isFromUser }.count
                                                                    let salonTurnNumber = dbUserMessages + 1
                                                                    halLog("HALDEBUG-SALON: Storing user message for turn \(salonTurnNumber) (DB has \(dbUserMessages) user messages)")
                                                                    memoryStore.storeTurn(
                                                                        conversationId: conversationId,
                                                                        userMessage: userInput,
                                                                        assistantMessage: "",  // Will be filled by seats
                                                                        systemPrompt: systemPrompt,
                                                                        turnNumber: salonTurnNumber,
                                                                        halFullPrompt: nil,
                                                                        halUsedContext: nil,
                                                                        thinkingDuration: nil,
                                                                        recordedByModel: "user"
                                                                        // skipUserMessage defaults to false, so user IS stored
                                                                    )
                                                                    
                                                                    // Store user message as artifact for Salon turn
                                                                    memoryStore.storeConversationArtifact(
                                                                        conversationId: conversationId,
                                                                        artifactType: "userMessage",
                                                                        turnNumber: salonTurnNumber,
                                                                        deliberationRound: 1,
                                                                        seatNumber: nil,
                                                                        content: userInput,
                                                                        modelId: nil  // User message, no model
                                                                    )
                                                                    halLog("HALDEBUG-SALON: Stored user message artifact for Salon turn \(salonTurnNumber); about to capture baseline history")
                                                                    
                                                                    // Capture baseline history snapshot for Independent mode
                                                                    // This freezes the message history before any seats respond
                                                                    let baselineHistory = messages.filter { !$0.isPartial }

                                                                    // Capture the user's actual selected model so we can restore it
                                                                    // after the multi-seat turn ends. Otherwise the model picker
                                                                    // would silently end up showing whatever the last seat used.
                                                                    let originalSelectedModelID = selectedModelID
                                                                    halLog("HALDEBUG-SALON: Saving original selectedModelID=\(originalSelectedModelID) for restoration after \(activeSeats.count)-seat turn")

                                                                    // Per Strategic §3/§12 (Host architecture): pre-compute the
                                                                    // shared prior-turns summary ONLY when a Host (formerly
                                                                    // "Summarizer") seat is assigned. Without a Host, salon runs
                                                                    // in **pure independent voices** mode — each seat performs
                                                                    // its own summarization from its own perspective, slower but
                                                                    // philosophically clean.
                                                                    //
                                                                    // The cache, when used, takes the summary generated by the
                                                                    // currently-active model and shares it across all seats.
                                                                    // That's a meaningful philosophical compromise (every seat
                                                                    // starts from the Host's framing of the conversation, not
                                                                    // its own). The user opts into this compromise by assigning
                                                                    // a Host. Without a Host, the cache stays nil and the
                                                                    // per-seat summarization branch in buildContextAwareChatMessages
                                                                    // runs instead — each model forms its own understanding of
                                                                    // the conversation history.
                                                                    //
                                                                    // Cache is cleared at end via defer so it survives early
                                                                    // returns / errors.
                                                                    if salonConfig.behavioralMode == .contextAware {
                                                                        if salonConfig.summarizerModel != nil {
                                                                            halLog("HALDEBUG-SALON: Host assigned — pre-computing shared prior-turns summary (one LLM call, reused across all seats)")
                                                                            let summary = await generateSalonContextSummary(includeCurrentTurnSeats: [])
                                                                            cachedSalonPriorSummary = summary
                                                                            halLog("HALDEBUG-SALON: Cached prior-turns summary (\(summary.count) chars)")
                                                                        } else {
                                                                            halLog("HALDEBUG-SALON: No Host assigned — pure mode, each seat will summarize independently from its own perspective")
                                                                        }
                                                                    }
                                                                    defer { cachedSalonPriorSummary = nil }

                                                                    // Execute each seat sequentially
                                                                    for seat in activeSeats {
                                                                        halLog("HALDEBUG-SALON: Executing seat \(seat.position) with model \(seat.modelID)")

                                                                        // Get the model
                                                                        guard let model = ModelCatalogService.shared.getModel(byID: seat.modelID) else {
                                                                            halLog("HALDEBUG-SALON: Warning: Model not found: \(seat.modelID)")
                                                                            continue
                                                                        }

                                                                        // Switch to this seat's model. Until this commit, the
                                                                        // seat switch only updated the AppStorage var
                                                                        // selectedModelID and never called setupLLM — meaning
                                                                        // llmService.currentModel never changed and every seat
                                                                        // generated with whatever model was loaded last. setupLLM
                                                                        // is what actually swaps the wrapper's currentModel and
                                                                        // (for MLX) loads weights. keepMlxResident keeps Gemma
                                                                        // warm across AFM seats so we don't reload weights
                                                                        // between every seat in a mixed-source salon.
                                                                        selectedModelID = model.id
                                                                        llmService.setupLLM(for: model, keepMlxResident: true)

                                                                        // For MLX seats, wait briefly for the load to settle.
                                                                        // loadModel is dispatched as an async Task inside setupLLM;
                                                                        // if Gemma needs to load fresh, the seat would otherwise
                                                                        // hit "Cannot generate - MLX model not loaded" the same
                                                                        // way the API switch did before the load-fix. Poll the
                                                                        // wrapper state with a short timeout.
                                                                        if model.source == .mlx {
                                                                            let loadStart = Date()
                                                                            while !llmService.mlxWrapper.isModelLoaded && Date().timeIntervalSince(loadStart) < 30 {
                                                                                try? await Task.sleep(nanoseconds: 100_000_000)
                                                                            }
                                                                            if !llmService.mlxWrapper.isModelLoaded {
                                                                                halLog("HALDEBUG-SALON: Warning: MLX seat \(seat.position) timed out waiting for model load; proceeding anyway")
                                                                            } else {
                                                                                halLog("HALDEBUG-SALON: MLX seat \(seat.position) model ready after \(Int(Date().timeIntervalSince(loadStart) * 1000))ms")
                                                                            }
                                                                        }

                                                                        halLog("HALDEBUG-SALON: → entering runSalonSeat for seat \(seat.position) (\(seat.modelID))")
                                                                        // Execute seat with behavioral mode awareness
                                                                        await runSalonSeat(userInput: userInput, seatPosition: seat.position, baselineHistory: baselineHistory)
                                                                        halLog("HALDEBUG-SALON: ← returned from runSalonSeat for seat \(seat.position)")
                                                                    }
                                                                    halLog("HALDEBUG-SALON: All \(activeSeats.count) seats executed; entering summarizer phase")
                                                                    
                                                                    // Run summarizer if configured
                                                                    if let summarizerModelID = salonConfig.summarizerModel {
                                                                        // Check if this is first time enabled (or re-enabled after being off)
                                                                        let currentTurnNumber = countCompletedTurns()
                                                                        
                                                                        if salonConfig.summarizerSessionStartTurn == nil {
                                                                            // Start new session
                                                                            salonConfig.summarizerSessionStartTurn = currentTurnNumber
                                                                            print("HALDEBUG-SALON: Started summarizer session at turn \(currentTurnNumber)")
                                                                        }
                                                                        
                                                                        await runModeratorSummary(summarizerModelID: summarizerModelID)
                                                                    } else if salonConfig.summarizerSessionStartTurn != nil {
                                                                        // Summarizer was just turned off, reset session
                                                                        salonConfig.summarizerSessionStartTurn = nil
                                                                        print("HALDEBUG-SALON: Ended summarizer session")
                                                                    }

                                                                    // Restore the user's original selected model so the picker /
                                                                    // chat state isn't left on whatever seat ran last. If the
                                                                    // user disables Salon Mode after this turn, single-model
                                                                    // chat resumes with the model they actually chose, not the
                                                                    // last seat's.
                                                                    if selectedModelID != originalSelectedModelID {
                                                                        if let restored = ModelCatalogService.shared.getModel(byID: originalSelectedModelID) {
                                                                            selectedModelID = originalSelectedModelID
                                                                            llmService.setupLLM(for: restored, keepMlxResident: true)
                                                                            halLog("HALDEBUG-SALON: Restored selectedModelID to \(originalSelectedModelID) after multi-seat turn")
                                                                        } else if originalSelectedModelID == "apple-foundation-models" {
                                                                            selectedModelID = originalSelectedModelID
                                                                            llmService.setupLLM(for: .appleFoundation, keepMlxResident: true)
                                                                            halLog("HALDEBUG-SALON: Restored selectedModelID to AFM after multi-seat turn")
                                                                        }
                                                                    }
                                                                }
                                                                
                                                                // Execute a single salon seat with behavioral mode awareness
                                                                private func runSalonSeat(userInput: String, seatPosition: Int, baselineHistory: [ChatMessage]) async {
                                                                    // Get current turn number before execution
                                                                    let currentTurn = memoryStore.getCurrentTurnNumber(conversationId: conversationId)
                                                                    
                                                                    // Independent mode uses existing single-model behavior
                                                                    if salonConfig.behavioralMode == .independent {
                                                                        await runSingleModelTurn(userInput: userInput, historyMessagesOverride: baselineHistory, skipUserMessage: true)
                                                                        
                                                                        // After runSingleModelTurn completes, capture the response and store as artifact
                                                                        // The response is the most recent non-partial message for this turn
                                                                        if let responseMessage = messages.last(where: {
                                                                            !$0.isFromUser &&
                                                                            !$0.isPartial &&
                                                                            $0.turnNumber == currentTurn &&
                                                                            $0.recordedByModel == selectedModel.id
                                                                        }) {
                                                                            memoryStore.storeConversationArtifact(
                                                                                conversationId: conversationId,
                                                                                artifactType: "salonDeliberation",
                                                                                turnNumber: currentTurn,
                                                                                deliberationRound: 1,
                                                                                seatNumber: seatPosition,
                                                                                content: responseMessage.content,
                                                                                modelId: selectedModel.id
                                                                            )
                                                                            print("HALDEBUG-SALON: Stored independent mode artifact for seat \(seatPosition)")
                                                                        } else {
                                                                            print("HALDEBUG-SALON: Warning: Could not find response message to store as artifact")
                                                                        }
                                                                        
                                                                        return
                                                                    }
                                                                    
                                                                    // Context-Aware mode: Custom prompt building with summarized context
                                                                    print("HALDEBUG-SALON: Context-aware seat \(seatPosition) - building custom prompt")
                                                                    
                                                                    let placeholder = ChatMessage(content: "\u{00A0}", isFromUser: false, isPartial: true, recordedByModel: selectedModel.id, turnNumber: currentTurn)
                                                                    messages.append(placeholder)
                                                                    
                                                                    try? await Task.sleep(nanoseconds: 100_000_000) // Brief yield for UI update
                                                                    
                                                                    guard let pid = messages.last?.id else { return }
                                                                    var finalText = ""; var modelTime: TimeInterval = 0
                                                                    
                                                                    do {
                                                                        // Status: Reading message
                                                                        if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                            messages[i].content = "Reading your message..."
                                                                        }
                                                                        try? await Task.sleep(nanoseconds: 300_000_000)
                                                                        
                                                                        // Build Context-Aware messages with slim system prompt and summarized history
                                                                        let chatMessages = await buildContextAwareChatMessages(userInput: userInput, seatPosition: seatPosition)
                                                                        // Synthetic "prompt" string for downstream diagnostics (tokenBreakdown,
                                                                        // fullPromptUsed) — same approach as runSingleModelTurn.
                                                                        let prompt = chatMessages.map { "[\($0.role.rawValue)] \($0.content)" }.joined(separator: "\n\n")

                                                                        // Status: Formulating reply
                                                                        if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                            messages[i].content = "Formulating a reply..."
                                                                        }
                                                                        try? await Task.sleep(nanoseconds: 300_000_000)

                                                                        halLog("HALDEBUG-SALON: Sending \(chatMessages.count) context-aware chat messages to model (streaming)")
                                                                        let t0 = Date()
                                                                        // REAL STREAMING (replaces fake-streaming animation). Salon
                                                                        // seats now render their response as the chosen model
                                                                        // generates it — the user can watch each seat speak in
                                                                        // real time. Especially important for context-aware mode
                                                                        // where seats sequentially contribute different
                                                                        // perspectives; the visual rhythm matches the underlying
                                                                        // sequential thinking.
                                                                        finalText = ""
                                                                        do {
                                                                            let stream = llmService.generateChatResponseStream(messages: chatMessages, temperature: temperature)
                                                                            for try await chunk in stream {
                                                                                finalText = chunk
                                                                                if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                                    messages[i].content = chunk
                                                                                }
                                                                            }
                                                                        } catch let memError as LLMService.LLMError {
                                                                            // Salon-side mirror of the single-model memory-refusal
                                                                            // handler. If a seat's model can't fit the upcoming
                                                                            // turn's KV cache, surface the explanation as that
                                                                            // seat's reply text instead of failing the whole
                                                                            // salon round. Item 11 follow-up, 2026-05-18.
                                                                            modelTime = Date().timeIntervalSince(t0)
                                                                            if case .insufficientMemoryForTurn = memError {
                                                                                halLog("HALDEBUG-SALON: Seat \(seatPosition) memory refusal surfaced as seat reply.")
                                                                                finalText = memError.errorDescription ?? "I don't have enough memory to process this turn."
                                                                                if let i = messages.firstIndex(where: { $0.id == pid }) {
                                                                                    messages[i].content = finalText
                                                                                }
                                                                            } else {
                                                                                throw memError
                                                                            }
                                                                        } catch {
                                                                            modelTime = Date().timeIntervalSince(t0)
                                                                            throw error
                                                                        }
                                                                        modelTime = Date().timeIntervalSince(t0)
                                                                        halLog("HALDEBUG-SALON: Context-aware streaming complete. Length: \(finalText.count), elapsed: \(String(format: "%.2f", modelTime))s")

                                                                        let text = removeRepetitivePatterns(from: finalText).trimmingCharacters(in: .whitespacesAndNewlines)

                                                                        // Calculate token breakdown
                                                                        let tokenBreakdown = calculateTokenBreakdown(
                                                                            prompt: prompt,
                                                                            userInput: userInput,
                                                                            completion: text
                                                                        )

                                                                        // Final settle: write the trimmed/cleaned text in case the
                                                                        // last streamed chunk had leading/trailing whitespace or
                                                                        // repetition that removeRepetitivePatterns stripped.
                                                                        if let i = messages.firstIndex(where: { $0.id == pid }), messages[i].content != text {
                                                                            messages[i].content = text
                                                                        }

                                                                        let thinking = modelTime
                                                                        
                                                                        await MainActor.run {
                                                                            if let i = self.messages.firstIndex(where: { $0.id == pid }) {
                                                                                self.messages[i].content = text
                                                                                self.messages[i].isPartial = false
                                                                                self.messages[i].thinkingDuration = thinking
                                                                                self.lastInferenceTime = thinking
                                                                                self.messages[i].fullPromptUsed = prompt
                                                                                self.messages[i].usedContextSnippets = nil
                                                                                self.messages[i].tokenBreakdown = tokenBreakdown
                                                                            }
                                                                            
                                                                            // CHANGE 2: Calculate turn from database (source of truth), not messages array
                                                                            let dbUserMessages = self.memoryStore.getConversationMessages(conversationId: self.conversationId).filter { $0.isFromUser }.count
                                                                            let turn = dbUserMessages  // skipUserMessage is always true for Salon seats
                                                                            print("HALDEBUG-SALON: Storing context-aware turn \(turn) (DB has \(dbUserMessages) user messages)")
                                                                            self.memoryStore.storeTurn(
                                                                                conversationId: self.conversationId,
                                                                                userMessage: userInput,
                                                                                assistantMessage: text,
                                                                                systemPrompt: self.systemPrompt,
                                                                                turnNumber: turn,
                                                                                halFullPrompt: prompt,
                                                                                halUsedContext: nil,
                                                                                thinkingDuration: thinking,
                                                                                recordedByModel: self.selectedModel.id,
                                                                                skipUserMessage: true  // User already stored in runSalonTurn
                                                                            )
                                                                            
                                                                            // Store Context-Aware deliberation as artifact for Session-Scope analysis
                                                                            self.memoryStore.storeConversationArtifact(
                                                                                conversationId: self.conversationId,
                                                                                artifactType: "salonDeliberation",
                                                                                turnNumber: turn,
                                                                                deliberationRound: 1,
                                                                                seatNumber: seatPosition,
                                                                                content: text,
                                                                                modelId: self.selectedModel.id
                                                                            )
                                                                            print("HALDEBUG-SALON: Stored context-aware deliberation artifact for seat \(seatPosition)")
                                                                        }
                                                                        
                                                                    } catch {
                                                                        print("HALDEBUG-SALON: Warning: Context-aware error: \(error.localizedDescription)")
                                                                        await MainActor.run {
                                                                            if let i = self.messages.firstIndex(where: { $0.id == pid }) {
                                                                                self.messages[i].content = "Error: \(error.localizedDescription)"
                                                                                self.messages[i].isPartial = false
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                                
                                                                // Build Context-Aware prompt with slim system and summarized history
                                                                /// Chat-message-shaped equivalent of buildContextAwarePrompt. Same intent
                                                                /// (slim multi-perspective system prompt + conversation summary + current
                                                                /// user input) but expressed as [HalChatMessage] so it can flow through
                                                                /// generateChatResponse with chat-template models like Gemma 4.
                                                                // Per-salon-turn cache of the prior-turns conversation summary so each
                                                                // seat in context-aware mode doesn't re-generate it via an LLM call.
                                                                // Set at the top of runSalonTurn (context-aware mode only); cleared at
                                                                // the end. The "current turn earlier seats" portion is still computed
                                                                // per-seat and appended without an LLM call (it's short prose).
                                                                // Previously each seat paid ~20–30s for its own summarize call —
                                                                // this turns N seats × 1 summary call into 1 summary call total
                                                                // and fixes the "context-window exceeded" error we saw when the
                                                                // history grew past AFM's 4K budget after a few salon turns.
                                                                private var cachedSalonPriorSummary: String? = nil

                                                                private func buildContextAwareChatMessages(userInput: String, seatPosition: Int) async -> [HalChatMessage] {
                                                                    let slimSystemPrompt = """
                                                                    You are Hal, an AI assistant participating in a multi-perspective discussion.

                                                                    Your role: Provide your unique perspective on the user's question.

                                                                    Guidelines:
                                                                    - Be concise and focused
                                                                    - Complement other perspectives, don't repeat them
                                                                    - Stay relevant to the user's question
                                                                    """

                                                                    let currentTurnSeats = getCurrentTurnSeatsResponses(beforeSeat: seatPosition)

                                                                    // If runSalonTurn pre-computed the prior-turns summary for this
                                                                    // turn, use it directly and append the current-turn seats as
                                                                    // plain prose (no LLM call). Otherwise fall back to the
                                                                    // per-seat regeneration path. This removes ~20-30s/seat in
                                                                    // context-aware mode and also avoids the AFM 4K context
                                                                    // overflow we saw when the summary input grew past AFM's
                                                                    // limit on multi-turn salon conversations.
                                                                    let conversationSummary: String
                                                                    if let cachedPrior = cachedSalonPriorSummary {
                                                                        conversationSummary = appendCurrentTurnSeatsToSummary(
                                                                            priorSummary: cachedPrior,
                                                                            currentTurnSeats: currentTurnSeats
                                                                        )
                                                                    } else {
                                                                        conversationSummary = await generateSalonContextSummary(includeCurrentTurnSeats: currentTurnSeats)
                                                                    }

                                                                    let systemMessage: String
                                                                    if conversationSummary.isEmpty {
                                                                        systemMessage = slimSystemPrompt
                                                                    } else {
                                                                        systemMessage = "\(slimSystemPrompt)\n\nCONVERSATION SO FAR (summarised):\n\(conversationSummary)"
                                                                    }

                                                                    return [
                                                                        .system(systemMessage),
                                                                        .user(userInput)
                                                                    ]
                                                                }

                                                                /// ⚠️ DEAD CODE — INTENTIONALLY PRESERVED.
                                                                /// Replaced by `buildContextAwareChatMessages(userInput:seatPosition:)`
                                                                /// (May 11, 2026 / commit cbe1ea4). Salon mode context-aware now uses
                                                                /// the chat-message path.
                                                                private func buildContextAwarePrompt(userInput: String, seatPosition: Int) async -> String {
                                                                    // Slim system prompt for context-aware mode
                                                                    let slimSystemPrompt = """
                                                                    You are Hal, an AI assistant participating in a multi-perspective discussion.
                                                                    
                                                                    Your role: Provide your unique perspective on the user's question.
                                                                    
                                                                    Guidelines:
                                                                    - Be concise and focused
                                                                    - Complement other perspectives, don't repeat them
                                                                    - Stay relevant to the user's question
                                                                    """
                                                                    
                                                                    // Get earlier seats' responses from THIS turn
                                                                    let currentTurnSeats = getCurrentTurnSeatsResponses(beforeSeat: seatPosition)
                                                                    
                                                                    // Generate full conversation summary (includes prior turns + current turn's earlier seats)
                                                                    let conversationSummary = await generateSalonContextSummary(includeCurrentTurnSeats: currentTurnSeats)
                                                                    
                                                                    // Build prompt with slim system and summary
                                                                    var prompt = """
                                                                    
                                                                    #=== BEGIN SYSTEM ===#
                                                                    
                                                                    \(slimSystemPrompt)
                                                                    
                                                                    #=== END SYSTEM ===#
                                                                    """
                                                                    
                                                                    // Add conversation summary if available
                                                                    if !conversationSummary.isEmpty {
                                                                        prompt += """
                                                                        
                                                                        
                                                                        #=== BEGIN MEMORY_LONG ===#
                                                                        
                                                                        \(conversationSummary)
                                                                        
                                                                        #=== END MEMORY_LONG ===#
                                                                        """
                                                                    }
                                                                    
                                                                    // Add current user input
                                                                    prompt += """
                                                                    
                                                                    
                                                                    #=== BEGIN USER ===#
                                                                    
                                                                    \(userInput)
                                                                    
                                                                    #=== END USER ===#
                                                                    """
                                                                    
                                                                    return prompt
                                                                }
                                                                
                                                                // Generate full conversation summary with LLM (for Salon Mode context-aware)
                                                                /// Plain-prose append (no LLM) of the current turn's earlier seat
                                                                /// responses onto a pre-computed prior-turns summary. Used by
                                                                /// buildContextAwareChatMessages when `cachedSalonPriorSummary` is
                                                                /// set by runSalonTurn — avoids re-summarising the entire prior
                                                                /// conversation N times per multi-seat turn.
                                                                private func appendCurrentTurnSeatsToSummary(priorSummary: String, currentTurnSeats: [String]) -> String {
                                                                    if currentTurnSeats.isEmpty {
                                                                        return priorSummary
                                                                    }
                                                                    var result = priorSummary
                                                                    if !priorSummary.isEmpty {
                                                                        result += "\n\n"
                                                                    }
                                                                    result += "--- Current Turn Earlier Responses ---\n\n"
                                                                    for (index, seatResponse) in currentTurnSeats.enumerated() {
                                                                        result += "Seat \(index + 1): \(seatResponse)\n\n"
                                                                    }
                                                                    return result
                                                                }

                                                                private func generateSalonContextSummary(includeCurrentTurnSeats: [String]) async -> String {
                                                                    // Collect all messages up to current moment (excluding partial messages)
                                                                    let allPriorMessages = messages.filter { !$0.isPartial }
                                                                    
                                                                    if allPriorMessages.isEmpty {
                                                                        return ""
                                                                    }
                                                                    
                                                                    // Format conversation text with attribution
                                                                    var conversationText = ""
                                                                    for message in allPriorMessages {
                                                                        if message.isFromUser {
                                                                            conversationText += "User: \(message.content)\n\n"
                                                                        } else {
                                                                            let modelName = ModelCatalogService.shared.getModel(byID: message.recordedByModel)?.displayName ?? "Assistant"
                                                                            conversationText += "\(modelName): \(message.content)\n\n"
                                                                        }
                                                                    }
                                                                    
                                                                    // Add current turn's earlier seats if provided
                                                                    if !includeCurrentTurnSeats.isEmpty {
                                                                        conversationText += "--- Current Turn Earlier Responses ---\n\n"
                                                                        for (index, seatResponse) in includeCurrentTurnSeats.enumerated() {
                                                                            conversationText += "Seat \(index + 1): \(seatResponse)\n\n"
                                                                        }
                                                                    }
                                                                    
                                                                    // Estimate target tokens for summary (roughly 20% of original)
                                                                    let originalTokens = TokenEstimator.estimateTokens(from: conversationText)
                                                                    let targetTokens = max(200, originalTokens / 5)
                                                                    
                                                                    print("HALDEBUG-SALON: Generating context summary - original: \(originalTokens) tokens, target: \(targetTokens) tokens")
                                                                    
                                                                    // Use TextSummarizer with recency weighting
                                                                    let summary = await TextSummarizer.summarizeWithVerification(
                                                                        text: conversationText,
                                                                        targetTokens: targetTokens,
                                                                        llmService: llmService,
                                                                        useRecencyWeighting: true
                                                                    )
                                                                    
                                                                    return summary
                                                                }
                                                                
                                                                // Get earlier seats' responses from current turn
                                                                private func getCurrentTurnSeatsResponses(beforeSeat: Int) -> [String] {
                                                                    // Find the last user message
                                                                    guard let lastUserIndex = messages.lastIndex(where: { $0.isFromUser && !$0.isPartial }) else {
                                                                        return []
                                                                    }
                                                                    
                                                                    // Get all assistant messages after the last user message (current turn responses)
                                                                    let currentTurnAssistantMessages = messages[(lastUserIndex + 1)...].filter { !$0.isPartial && !$0.isFromUser }
                                                                    
                                                                    // Return responses from seats 1 through (beforeSeat - 1)
                                                                    let earlierSeats = currentTurnAssistantMessages.prefix(beforeSeat - 1)
                                                                    return earlierSeats.map { $0.content }
                                                                }
                                                                
                                                                // Moderator/Summarizer execution (Seat N+1)
                                                                private func runModeratorSummary(summarizerModelID: String) async {
                                                                    print("HALDEBUG-SALON: Running moderator summary with model \(summarizerModelID)")
                                                                    
                                                                    // Get the summarizer model
                                                                    guard let model = ModelCatalogService.shared.getModel(byID: summarizerModelID) else {
                                                                        print("HALDEBUG-SALON: Warning: Summarizer model not found: \(summarizerModelID)")
                                                                        return
                                                                    }
                                                                    
                                                                    // Collect seat outputs from this turn (most recent non-user messages)
                                                                    let currentTurnNumber = memoryStore.getCurrentTurnNumber(conversationId: conversationId)
                                                                    let seatOutputs = messages.filter {
                                                                        !$0.isFromUser &&
                                                                        $0.turnNumber == currentTurnNumber &&
                                                                        !$0.isPartial
                                                                    }
                                                                    
                                                                    guard !seatOutputs.isEmpty else {
                                                                        print("HALDEBUG-SALON: No seat outputs found to summarize")
                                                                        return
                                                                    }
                                                                    
                                                                    print("HALDEBUG-SALON: Collected \(seatOutputs.count) seat outputs for summarization")
                                                                    
                                                                    // Build explicit input: seat outputs ONLY with model attribution
                                                                    let seatInputs = seatOutputs.map { output in
                                                                        let modelName = ModelCatalogService.shared.getModel(byID: output.recordedByModel)?.displayName ?? output.recordedByModel
                                                                        return """
                                                                        Model: \(modelName)
                                                                        Response:
                                                                        \(output.content)
                                                                        """
                                                                    }.joined(separator: "\n\n")
                                                                    
                                                                    // Determine interpretation clause based on behavioral mode
                                                                    let interpretationClause = salonConfig.behavioralMode == .independent
                                                                        ? "The responses above were generated independently. Do not assume awareness or rebuttal."
                                                                        : "Later responses may have been influenced by earlier ones. You may describe alignment or refinement."
                                                                    
                                                                    // Build MCP-compliant HelPML prompt (flat structure, no nesting)
                                                                    let summarizerPrompt = """
                                                                    #=== BEGIN SYSTEM ===#
                                                                    You are a summarizer, not a participant.
                                                                    Do not answer the original user question.
                                                                    Do not add new ideas or examples.
                                                                    Summarize only what the responses below say.
                                                                    
                                                                    \(interpretationClause)
                                                                    
                                                                    Provide a brief synthesis with model attribution.
                                                                    #=== END SYSTEM ===#
                                                                    
                                                                    #=== BEGIN CONTEXT ===#
                                                                    \(seatInputs)
                                                                    #=== END CONTEXT ===#
                                                                    
                                                                    #=== BEGIN RESPONSE ===#
                                                                    Provide a brief synthesis in 2-3 sentences.
                                                                    Do not include any #=== markers in your output.
                                                                    #=== END RESPONSE ===#
                                                                    """
                                                                    
                                                                    print("HALDEBUG-SALON: Calling TextSummarizer with \(TokenEstimator.estimateTokens(from: summarizerPrompt)) token prompt")
                                                                    
                                                                    // Switch to summarizer model temporarily
                                                                    let previousModelID = selectedModelID
                                                                    selectedModelID = model.id
                                                                    llmService.setupLLM(for: model)
                                                                    
                                                                    // Call Block 8.5 TextSummarizer (NOT runSingleModelTurn)
                                                                    let rawSummary = await TextSummarizer.summarizeWithVerification(
                                                                        text: summarizerPrompt,
                                                                        targetTokens: 150,  // Brief summary
                                                                        llmService: llmService,
                                                                        verificationThreshold: 0.72,
                                                                        useRecencyWeighting: false  // Not summarizing conversation history
                                                                    )
                                                                    
                                                                    // Scrub HelPML markers from output (safety check)
                                                                    let scrubbedSummary = rawSummary.ScrubHelPMLMarkers()
                                                                    
                                                                    print("HALDEBUG-SALON: Summary generated and scrubbed: \(scrubbedSummary.count) chars")
                                                                    
                                                                    // Store as conversation artifact (NOT as message)
                                                                    memoryStore.storeConversationArtifact(
                                                                        conversationId: conversationId,
                                                                        artifactType: "turnModerator",
                                                                        turnNumber: currentTurnNumber,
                                                                        deliberationRound: 1,
                                                                        seatNumber: nil,
                                                                        content: scrubbedSummary,
                                                                        modelId: model.id
                                                                    )
                                                                    
                                                                    // Add to messages array for UI display (but marked as artifact via special handling)
                                                                    await MainActor.run {
                                                                        let summaryMessage = ChatMessage(
                                                                            content: "📋 Summary: \(scrubbedSummary)",
                                                                            isFromUser: false,
                                                                            recordedByModel: model.id,
                                                                            turnNumber: currentTurnNumber
                                                                        )
                                                                        messages.append(summaryMessage)
                                                                    }
                                                                    
                                                                    // Restore previous model
                                                                    selectedModelID = previousModelID
                                                                    llmService.setupLLM(for: ModelCatalogService.shared.getModel(byID: previousModelID) ?? .appleFoundation)
                                                                    
                                                                    print("HALDEBUG-SALON: Moderator summary complete")
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
//
// EXTRACTED 2026-05-26 (refactor #4): LEGO 27, 27.1, and 28 now
// live together in `Hal Universal/DocumentImportManager.swift`.
// Same Swift module — fully accessible from this file via
// DocumentImportManager.shared. The three LEGO blocks are
// preserved verbatim inside the new file so the numbering chain
// still reads end-to-end when sync_hal_source.sh concatenates
// for Hal_Source.txt.
//
// ==== LEGO END: 28 Import Models (ProcessedDocument & Summary) ====



// ==== LEGO 29: MLX Model Downloader — extracted 2026-05-26 ====
//
// BackgroundDownloadCoordinator + MLXModelDownloader + .mlxModelDidDownload
// extension now live in Hal Universal/MLXModelDownloader.swift. Both
// types are singletons (`.shared`) and reachable from any file in the
// target. See the extracted file's header for module structure.
// ==== END LEGO 29 ====




// ==== LEGO START: 30 Model Catalog Service (Hugging Face Integration) ====
//
// EXTRACTED 2026-05-26: this block now lives in its own file at
// `Hal Universal/ModelCatalogService.swift`. Contains ModelSource,
// MaximScorecard, ModelSettings, ModelSettingsStore, ModelConfiguration
// (with AFM + curated MLX seeds), HF API DTOs, ModelCatalogService
// singleton, and CatalogError. Same Swift module — fully accessible
// from this file without changes to call sites.
//
// ==== LEGO END: 30 Model Catalog Service (Hugging Face Integration) ====



// EXTRACTED 2026-05-26 (refactor #3): the MemoryStore and
// DocumentImportManager API-helper extensions, plus LEGO 32
// (HalTestConsole + LocalAPIServer + shared executeCommand
// dispatcher), now live in `Hal Universal/LocalAPIServer.swift`.
// Same Swift module — fully accessible from this file. The LEGO
// numbering chain ends here; new top-level subsystems belong in
// their own files going forward, not new LEGO blocks.
