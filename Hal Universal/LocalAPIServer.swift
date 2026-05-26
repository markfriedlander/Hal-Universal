// LocalAPIServer.swift
// Hal Universal
//
// Extracted from Hal.swift on 2026-05-26 as part of the refactor-as-you-go
// directive. The "Developer API" subsystem — every path by which an
// external process can drive Hal without going through the SwiftUI shell.
//
// Five cooperating pieces in one file, all sharing one dispatcher:
//
//   extension MemoryStore { listDocuments / deleteDocument }
//       — Document API helpers the HTTP layer calls to surface LIST_DOCS
//         / DELETE_DOC results. Direct sqlite3_* access, defined here
//         because the columns + base64-metadata-decode are
//         API-presentation concerns, not core MemoryStore semantics.
//
//   extension DocumentImportManager { importFromPath }
//       — Path-based variant of the document importer used by the
//         IMPORT_DOC command. Bypasses UIKit security-scope plumbing
//         since API callers can place a file in the app sandbox before
//         calling.
//
//   class HalTestConsole
//       — The file-channel half. Watches ~/Documents/hal_test/input.txt
//         + commands.txt via DispatchSourceFileSystemObject; injects
//         user turns; writes diagnostics to output_latest.json. macOS-
//         friendly when running under simulator/Catalyst, but also
//         active on device when the toggle is on. Owns the shared
//         executeCommand(_:vm:) function that both channels call.
//
//   class LocalAPIServer
//       — The HTTP half. NWListener on port 8766 (per-app port family;
//         Posey is 8765, Hal is 8766). Bearer-token auth via Keychain.
//         Routes POST /chat, POST /command, GET /state, etc. Calls into
//         HalTestConsole.executeCommand for everything except /chat.
//
// Why one file: the two channels (HTTP + file watcher) are conceptually
// twins — same authorization model, same response envelope, same
// dispatcher. Splitting them would push the seam through executeCommand
// (which would then need a separate home) and create a synthetic three-
// file unit that doesn't reflect any real layering. The two API-helper
// extensions live with them because they exist solely to back specific
// command verbs in the dispatcher.
//
// External dependencies (all in the Hal Universal target):
//   - halLog                        — global logging function (Hal.swift)
//   - ChatViewModel                 — the dispatcher's vm: argument
//   - MemoryStore, DocumentImportManager — types we extend
//   - ModelCatalogService.shared    — sibling extracted module
//   - MLXModelDownloader.shared     — sibling extracted module
//   - HuggingFace / MLX / Apple Foundation Models — only via vm.* calls,
//     never directly here
//
// Pre-extraction this was the unmarked MemoryStore/DocumentImportManager
// extension block (Hal.swift ~16292-16389) plus LEGO block 32 (~16391-
// 18252). The LEGO 32 markers are removed here; Hal.swift retains a
// pointer comment at the old slot so the LEGO numbering still reads.

import Foundation
import SwiftUI
import Combine
import Network
import Security
import SQLite3
import WatchConnectivity

// MARK: - MemoryStore Document API helpers (used by LocalAPIServer)
extension MemoryStore {

    struct DocumentRecord {
        let sourceID: String
        let displayName: String  // filename extracted from metadata, or source_id prefix
        let chunks: Int
        let createdAt: Int       // Unix timestamp
    }

    func listDocuments() -> [DocumentRecord] {
        guard let db else { return [] }
        var records: [DocumentRecord] = []
        let sql = """
            SELECT source_id, COUNT(*) as chunks, MIN(timestamp) as created_at,
                   MIN(metadata_json) as meta
            FROM unified_content
            WHERE source_type = 'document'
            GROUP BY source_id
            ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sourceID = String(cString: sqlite3_column_text(stmt, 0))
            let chunks   = Int(sqlite3_column_int(stmt, 1))
            let created  = Int(sqlite3_column_int64(stmt, 2))
            let metaB64  = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            // Decode base64 JSON -> {"filePath": "..."} to extract filename
            var displayName = String(sourceID.prefix(8))
            if let data = Data(base64Encoded: metaB64),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let path = json["filePath"] as? String {
                displayName = URL(fileURLWithPath: path).lastPathComponent
            }
            records.append(DocumentRecord(sourceID: sourceID, displayName: displayName, chunks: chunks, createdAt: created))
        }
        return records
    }

    @discardableResult
    func deleteDocument(sourceID: String) -> Int {
        guard let db else { return 0 }
        let sql = "DELETE FROM unified_content WHERE source_type = 'document' AND source_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sourceID as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        let deleted = Int(sqlite3_changes(db))
        totalDocuments = max(0, totalDocuments - 1)
        print("HALDEBUG-API: Deleted \(deleted) chunks for document \(sourceID.prefix(8))")
        return deleted
    }
}

// MARK: - DocumentImportManager API helper (path-based, no UIKit security scoping)
extension DocumentImportManager {

    /// Import a document from a plain file-system path. Safe on Mac Catalyst;
    /// on iOS the file must already be inside the app sandbox.
    func importFromPath(_ path: String, chatViewModel: ChatViewModel) async -> (success: Bool, message: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, "File not found: \(path)")
        }
        // Special-case .doc (legacy binary Word format pre-2007). There is
        // no reliable iOS-native parser; rather than swallow it as a
        // generic "Could not process" we surface the actionable hint:
        // open in any modern editor and save as .docx. Done here (not in
        // processDocumentImmediatelyWithEntities) so the friendly message
        // round-trips back via the API return tuple instead of getting
        // collapsed into a skipped-files list.
        if url.pathExtension.lowercased() == "doc" {
            print("HALDEBUG-IMPORT: .doc legacy binary format rejected: \(url.lastPathComponent)")
            return (false, DocumentImportManager.DocumentProcessingError.legacyDocFormat(url.lastPathComponent).errorDescription ?? "Legacy .doc format not supported on iOS")
        }
        // On macOS startAccessingSecurityScopedResource always returns true for plain paths.
        // On iOS the file must be in an accessible location (e.g. the app's Documents dir).
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let (processed, skipped) = await processURLImmediatelyWithEntities(url)
        if processed.isEmpty {
            return (false, "Could not process file (skipped: \(skipped))")
        }
        await storeDocumentsInMemoryWithEntities(processed)
        await generateImportMessages(
            documentSummaries: processed.map { $0.filename },
            totalProcessed: processed.count,
            totalEntities: processed.reduce(0) { $0 + $1.entities.count },
            chatViewModel: chatViewModel
        )
        return (true, "Imported \(processed.count) document(s): \(processed.map(\.filename).joined(separator: ", "))")
    }
}


// ==== LEGO START: 32 HalTestConsole (macOS Test Harness) ====
//
// SELF-AWARENESS NOTE (for Hal reading this code):
// This is a development tool that lets Claude Code converse with your pipeline directly,
// bypassing the UI entirely. It works through two channels:
//
// 1. FILE CHANNEL: Write a message to ~/Documents/hal_test/input.txt
//    HalTestConsole detects the write via DispatchSource and injects into the pipeline.
//    Write commands to ~/Documents/hal_test/commands.txt.
//    Full response + diagnostics written to output_latest.json.
//
// 2. HTTP CHANNEL (LocalAPIServer): POST /chat, POST /command, GET /state
//    Bearer token auth. Enable in Settings > Power User > Developer API.
//    Both channels share the same executeCommand() dispatch function.
//
// Enable via Power User settings. Runs until stopped or app quits.

@MainActor
class HalTestConsole: ObservableObject {

    @Published var isRunning: Bool = false
    @Published var turnCount: Int = 0
    @Published var statusMessage: String = "Stopped"

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
        if autoStart {
            Task { @MainActor in self.start() }
        }
    }

    func start() {
        guard !isRunning else { return }
        autoStart = true

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: inputFile.path) {
            FileManager.default.createFile(atPath: inputFile.path, contents: Data())
        }
        if !FileManager.default.fileExists(atPath: commandsFile.path) {
            FileManager.default.createFile(atPath: commandsFile.path, contents: Data())
        }

        let ready = """
        {
          "status": "ready",
          "inputFile": "\(inputFile.path)",
          "commandsFile": "\(commandsFile.path)",
          "stateFile": "\(stateFile.path)",
          "outputFile": "\(outputLatestFile.path)"
        }
        """
        try? ready.write(to: outputLatestFile, atomically: true, encoding: .utf8)

        startCommandsWatcher()

        let fd = open(inputFile.path, O_EVTONLY)
        guard fd != -1 else {
            statusMessage = "Error: could not open input file for watching"
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
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self.handleInputFileChange()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.watchedFD != -1 { close(self.watchedFD); self.watchedFD = -1 }
        }
        fileWatcher = source
        source.resume()

        isRunning = true
        statusMessage = "Watching \(inputFile.lastPathComponent)"
        print("HALDEBUG-TESTCONSOLE: Started. Input: \(inputFile.path)")
    }

    func stop() {
        fileWatcher?.cancel()
        fileWatcher = nil
        commandsWatcher?.cancel()
        commandsWatcher = nil
        isRunning = false
        autoStart = false
        statusMessage = "Stopped"
        lastProcessedContent = ""
        lastProcessedCommand = ""
        systemPromptOverride = nil
        print("HALDEBUG-TESTCONSOLE: Stopped.")
    }

    // MARK: - Commands Channel

    private func startCommandsWatcher() {
        let fd = open(commandsFile.path, O_EVTONLY)
        guard fd != -1 else { return }
        commandsWatchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self.handleCommandFileChange()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.commandsWatchedFD != -1 { close(self.commandsWatchedFD); self.commandsWatchedFD = -1 }
        }
        commandsWatcher = source
        source.resume()
    }

    private func handleCommandFileChange() async {
        guard let content = try? String(contentsOf: commandsFile, encoding: .utf8) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastProcessedCommand else { return }
        lastProcessedCommand = trimmed
        guard let vm = chatViewModel else { return }
        print("HALDEBUG-TESTCONSOLE: Command received: \(trimmed.prefix(80))")
        statusMessage = "CMD: \(trimmed.prefix(40))"
        let result = await executeCommand(trimmed, vm: vm)
        // Write result to state file so file-mode callers can read it
        if let data = result.data(using: .utf8) {
            try? data.write(to: stateFile)
        }
        statusMessage = "CMD done: \(trimmed.prefix(30))"
    }

    // MARK: - Shared Command Dispatch
    // Used by both the file watcher and LocalAPIServer. Returns JSON result string.

    @discardableResult
    func executeCommand(_ cmd: String, vm: ChatViewModel) async -> String {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("SET_MODEL:") || trimmed.hasPrefix("SWITCH_MODEL:") {
            let prefix = trimmed.hasPrefix("SET_MODEL:") ? "SET_MODEL:" : "SWITCH_MODEL:"
            let modelID = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            await switchToModel(modelID, vm: vm)
            writeStateJSON(vm: vm)
            return "{\"status\":\"ok\",\"command\":\"SWITCH_MODEL\",\"modelID\":\"\(modelID)\"}"

        } else if trimmed == "CURRENT_MODEL" {
            let liveID = vm.llmService.activeModelID
            let displayName = vm.selectedModel.displayName
            return "{\"status\":\"ok\",\"modelID\":\"\(liveID)\",\"displayName\":\"\(jsonStringEscape(displayName))\"}"

        } else if trimmed == "MLX_STATE" {
            // Diagnostic snapshot of the MLX runtime + catalog state for the
            // currently selected model. Used to diagnose load failures
            // without needing device-console access.
            let selectedID = vm.selectedModelID
            let wrapper = vm.llmService.mlxWrapper
            let wrapperLoaded = wrapper.isModelLoaded
            let wrapperConfigID = wrapper.currentModelConfig?.id ?? ""
            let wrapperConfigPath = wrapper.currentModelConfig?.localPath?.path ?? ""
            let wrapperError = wrapper.mlxError ?? ""
            let wrapperLoadingMessage = wrapper.loadingMessage
            let wrapperLoadingProgress = wrapper.loadingProgress
            let catalogModel = ModelCatalogService.shared.getModel(byID: selectedID)
            let catalogIsDownloaded = catalogModel?.isDownloaded ?? false
            let catalogLocalPath = catalogModel?.localPath?.path ?? ""
            let diskPath = MLXModelDownloader.shared.getModelPath(selectedID)
            let diskPathStr = diskPath?.path ?? ""
            let diskHasModel = diskPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return """
            {"status":"ok","selectedModelID":"\(jsonStringEscape(selectedID))","wrapper":{"isModelLoaded":\(wrapperLoaded),"currentModelConfigID":"\(jsonStringEscape(wrapperConfigID))","currentModelConfigLocalPath":"\(jsonStringEscape(wrapperConfigPath))","mlxError":"\(jsonStringEscape(wrapperError))","loadingMessage":"\(jsonStringEscape(wrapperLoadingMessage))","loadingProgress":\(wrapperLoadingProgress)},"catalog":{"hasEntry":\(catalogModel != nil),"isDownloaded":\(catalogIsDownloaded),"localPath":"\(jsonStringEscape(catalogLocalPath))"},"disk":{"resolvedPath":"\(jsonStringEscape(diskPathStr))","fileExists":\(diskHasModel)}}
            """

        } else if trimmed == "LIST_MODELS" {
            return buildModelListJSON(vm: vm)

        } else if trimmed.hasPrefix("DOWNLOAD_MODEL:") {
            let modelID = String(trimmed.dropFirst("DOWNLOAD_MODEL:".count)).trimmingCharacters(in: .whitespaces)
            return await startModelDownload(modelID, vm: vm)

        } else if trimmed.hasPrefix("MODEL_STATUS:") {
            let modelID = String(trimmed.dropFirst("MODEL_STATUS:".count)).trimmingCharacters(in: .whitespaces)
            return buildModelStatusJSON(modelID)

        } else if trimmed.hasPrefix("DELETE_MODEL:") {
            let modelID = String(trimmed.dropFirst("DELETE_MODEL:".count)).trimmingCharacters(in: .whitespaces)
            return await deleteModel(modelID)

        } else if trimmed.hasPrefix("SIMULATE_WATCH_MESSAGE:") {
            // Drive the Watch round-trip locally without paired hardware.
            // Routes through the exact same ChatViewModel entrypoint
            // (`processWatchIncomingMessage`) that HalWatchBridge uses for
            // real WCSession deliveries. The reply is pushed to the Watch
            // (a no-op if no Watch is reachable, with a HALDEBUG-WATCH log
            // line) AND returned to the API caller in the response body so
            // tests can verify the round-trip without a real Watch.
            //
            // Strategic Claude's May-14 directive: "This should behave
            // exactly as if the Watch sent that text via WCSession — the
            // iPhone receives it, routes it through ChatViewModel, generates
            // a response, and sends the reply back through the WCSession path."
            let payload = String(trimmed.dropFirst("SIMULATE_WATCH_MESSAGE:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else {
                return "{\"status\":\"error\",\"command\":\"SIMULATE_WATCH_MESSAGE\",\"error\":\"empty payload\"}"
            }
            let reply = await vm.processWatchIncomingMessage(payload)
            let watchReachable = WCSession.default.isReachable
            let replyEscaped = jsonStringEscape(reply ?? "")
            let payloadEscaped = jsonStringEscape(payload)
            return "{\"status\":\"ok\",\"command\":\"SIMULATE_WATCH_MESSAGE\",\"sent\":\"\(payloadEscaped)\",\"reply\":\"\(replyEscaped)\",\"watchReachable\":\(watchReachable)}"

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
            return "{\"status\":\"ok\",\"command\":\"SET_SYSTEM_PROMPT\"}"

        } else if trimmed == "CLEAR_SYSTEM_PROMPT" {
            systemPromptOverride = nil
            return "{\"status\":\"ok\",\"command\":\"CLEAR_SYSTEM_PROMPT\"}"

        } else if trimmed.hasPrefix("SET_SYSTEM_PROMPT_STORED:") {
            let promptText = String(trimmed.dropFirst("SET_SYSTEM_PROMPT_STORED:".count)).trimmingCharacters(in: .whitespaces)
            vm.systemPrompt = promptText
            writeStateJSON(vm: vm)
            return "{\"status\":\"ok\",\"command\":\"SET_SYSTEM_PROMPT_STORED\"}"

        } else if trimmed == "RESET_MODEL_SETTINGS" {
            // Per-model settings reset (Layer 3 of per-model profiles).
            // Clears the ACTIVE model's user overrides and re-applies its
            // empirical defaults through the live VM properties so the
            // @AppStorage-bound state reflects the change immediately.
            // Other models' overrides are untouched.
            await MainActor.run {
                vm.resetSettingsToModelDefaults()
            }
            writeStateJSON(vm: vm)
            return "{\"status\":\"ok\",\"command\":\"RESET_MODEL_SETTINGS\",\"modelID\":\"\(jsonStringEscape(vm.selectedModelID))\"}"

        } else if trimmed.hasPrefix("SET_MEMORY_DEPTH:") {
            let depthStr = String(trimmed.dropFirst("SET_MEMORY_DEPTH:".count)).trimmingCharacters(in: .whitespaces)
            if let depth = Int(depthStr), depth >= 1 {
                let clamped = min(depth, vm.maxMemoryDepth)
                vm.memoryDepth = clamped
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"memoryDepth\":\(clamped)}"
            }
            return "{\"status\":\"error\",\"message\":\"SET_MEMORY_DEPTH: must be integer >= 1\"}"

        } else if trimmed.hasPrefix("SET_TEMPERATURE:") {
            let valStr = String(trimmed.dropFirst("SET_TEMPERATURE:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.0, val <= 1.0 {
                vm.temperature = val
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"temperature\":\(val)}"
            }
            return "{\"status\":\"error\",\"message\":\"SET_TEMPERATURE: must be 0.0–1.0\"}"

        } else if trimmed.hasPrefix("SET_SELF_KNOWLEDGE:") {
            let valStr = String(trimmed.dropFirst("SET_SELF_KNOWLEDGE:".count)).trimmingCharacters(in: .whitespaces).lowercased()
            if valStr == "true" || valStr == "false" {
                vm.enableSelfKnowledge = (valStr == "true")
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"enableSelfKnowledge\":\(vm.enableSelfKnowledge)}"
            }
            return "{\"status\":\"error\",\"message\":\"SET_SELF_KNOWLEDGE: must be true or false\"}"

        } else if trimmed.hasPrefix("SET_MAX_RAG_CHARS:") {
            let valStr = String(trimmed.dropFirst("SET_MAX_RAG_CHARS:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 200 {
                vm.maxRagSnippetsCharacters = val
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"maxRagSnippetsCharacters\":\(Int(val))}"
            }
            return "{\"status\":\"error\",\"message\":\"SET_MAX_RAG_CHARS: must be >= 200\"}"

        } else if trimmed.hasPrefix("SET_RAG_DEDUP:") {
            let valStr = String(trimmed.dropFirst("SET_RAG_DEDUP:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.0, val <= 1.0 {
                vm.ragDedupSimilarityThreshold = val
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"ragDedupThreshold\":\(val)}"
            }
            return "{\"status\":\"error\",\"message\":\"SET_RAG_DEDUP: must be 0.0–1.0\"}"

        } else if trimmed.hasPrefix("SET_RECENCY_WEIGHT:") {
            let valStr = String(trimmed.dropFirst("SET_RECENCY_WEIGHT:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 0.0, val <= 1.0 {
                vm.memoryStore.recencyWeight = val
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"recencyWeight\":\(val)}"
            }
            return "{\"status\":\"error\",\"message\":\"SET_RECENCY_WEIGHT: must be 0.0–1.0\"}"

        } else if trimmed.hasPrefix("SET_RECENCY_HALFLIFE:") {
            let valStr = String(trimmed.dropFirst("SET_RECENCY_HALFLIFE:".count)).trimmingCharacters(in: .whitespaces)
            if let val = Double(valStr), val >= 1.0 {
                vm.memoryStore.recencyHalfLifeDays = val
                writeStateJSON(vm: vm)
                return "{\"status\":\"ok\",\"recencyHalfLifeDays\":\(val)}"
            }
            return "{\"status\":\"error\",\"message\":\"SET_RECENCY_HALFLIFE: must be >= 1.0 (days)\"}"

        } else if trimmed == "GET_THREADS" {
            let threads = vm.threads
            let activeID = vm.conversationId
            let entries = threads.map { t -> String in
                let active = t.id == activeID
                let title = jsonStringEscape(t.title)
                return "{\"id\":\"\(t.id)\",\"title\":\"\(title)\",\"active\":\(active),\"createdAt\":\(t.createdAt),\"lastActiveAt\":\(t.lastActiveAt)}"
            }.joined(separator: ",")
            return "{\"status\":\"ok\",\"threads\":[\(entries)]}"

        } else if trimmed.hasPrefix("SWITCH_THREAD:") {
            let threadID = String(trimmed.dropFirst("SWITCH_THREAD:".count)).trimmingCharacters(in: .whitespaces)
            let known = vm.threads.first { $0.id == threadID }
            guard known != nil else {
                return "{\"status\":\"error\",\"message\":\"Thread not found: \(jsonStringEscape(threadID))\"}"
            }
            vm.messages.removeAll()
            vm.injectedSummary = ""
            vm.pendingAutoInject = false
            vm.lastSummarizedTurnCount = 0
            vm.conversationId = threadID
            vm.loadConversation()
            vm.loadThreads()
            print("HALDEBUG-TESTCONSOLE: Switched to thread \(threadID.prefix(8))")
            writeStateJSON(vm: vm)
            return "{\"status\":\"ok\",\"command\":\"SWITCH_THREAD\",\"conversationId\":\"\(threadID)\",\"messageCount\":\(vm.messages.count)}"

        } else if trimmed == "GET_MESSAGES" {
            let msgs = vm.messages.filter { !$0.isPartial }
            let entries = msgs.map { m -> String in
                let role = m.isFromUser ? "user" : "assistant"
                let content = jsonStringEscape(String(m.content.prefix(500)))
                let ts = Int(m.timestamp.timeIntervalSince1970)
                return "{\"role\":\"\(role)\",\"timestamp\":\(ts),\"content\":\"\(content)\",\"truncated\":\(m.content.count > 500)}"
            }.joined(separator: ",")
            return "{\"status\":\"ok\",\"conversationId\":\"\(vm.conversationId)\",\"messageCount\":\(msgs.count),\"messages\":[\(entries)]}"

        } else if trimmed == "GET_MEMORY_STATS" {
            let ms = vm.memoryStore
            return "{\"status\":\"ok\",\"totalConversations\":\(ms.totalConversations),\"totalTurns\":\(ms.totalTurns),\"totalDocuments\":\(ms.totalDocuments),\"totalDocumentChunks\":\(ms.totalDocumentChunks),\"activeThreadMessages\":\(vm.messages.filter{!$0.isPartial}.count)}"

        } else if trimmed == "GET_UI_STATE" {
            return buildUIStateJSON(vm: vm)

        } else if trimmed.hasPrefix("SET_UI_STATE:") {
            // SET_UI_STATE:<settings|threadPanel|none>:<true|false>
            //
            // Programmatic toggle of the chat-view sheet state so test
            // and screenshot automation can navigate without relying on
            // the iOS simulator's tap-into-toolbar path (which has been
            // flaky on iOS 26.5 sim for our app). Production users
            // continue to drive these via the toolbar buttons.
            let body = String(trimmed.dropFirst("SET_UI_STATE:".count))
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                return "{\"status\":\"error\",\"message\":\"Expected SET_UI_STATE:<settings|threadPanel|none>:<true|false>\"}"
            }
            let target = parts[0].lowercased()
            let value = (parts[1].lowercased() == "true" || parts[1] == "1")
            switch target {
            case "settings":
                vm.showingSettings = value
                if value { vm.showingThreadPanel = false }
            case "threadpanel":
                vm.showingThreadPanel = value
                if value { vm.showingSettings = false }
            case "systemprompt":
                // Sub-sheets can't co-exist with the Settings sheet —
                // SwiftUI only presents one .sheet at a time from a given
                // view. When activating a sub-sheet, dismiss Settings
                // first; reverse on deactivation isn't needed because
                // the sub-sheet dismissal just leaves the underlying
                // chat view visible.
                if value { vm.showingSettings = false }
                vm.apiNavSystemPrompt = value
            case "modelframing":
                if value { vm.showingSettings = false }
                vm.apiNavModelFraming = value
            case "selfmodel":
                if value { vm.showingSettings = false }
                vm.apiNavSelfModel = value
            case "poweruser":
                if value { vm.showingSettings = false }
                vm.apiNavPowerUser = value
            case "salonsettings":
                if value { vm.showingSettings = false }
                vm.apiNavSalonSettings = value
            case "modellibrary":
                if value { vm.showingSettings = false }
                vm.apiNavModelLibrary = value
            case "selfmodelshowprivate":
                // Mirror the @AppStorage key flipped by the SelfReflectionView
                // toggle. Driving it via UserDefaults lets the API set it
                // without the view being on-screen, and on-screen views
                // observe the change because @AppStorage is KVO-backed.
                UserDefaults.standard.set(value, forKey: "selfModelShowPrivateReflections")
            case "scrollsettings":
                // Scroll the open Settings sheet to a section. `value` is
                // unused; the section name comes from parts[1] (already
                // lowercased). Valid: "personality", "importexport", "ai",
                // "poweruser". Settings sheet observes apiScrollSettingsTarget
                // and uses ScrollViewReader.scrollTo on change.
                vm.apiScrollSettingsTarget = parts[1].lowercased()
            case "none":
                vm.showingSettings = false
                vm.showingThreadPanel = false
                vm.apiNavSystemPrompt = false
                vm.apiNavModelFraming = false
                vm.apiNavSelfModel = false
                vm.apiNavPowerUser = false
                vm.apiNavSalonSettings = false
                vm.apiNavModelLibrary = false
            default:
                return "{\"status\":\"error\",\"message\":\"Unknown target '\(target)' (use settings|threadPanel|systemPrompt|modelFraming|selfModel|none)\"}"
            }
            return "{\"status\":\"ok\",\"command\":\"SET_UI_STATE\",\"target\":\"\(target)\",\"value\":\(value)}"

        } else if trimmed == "EXPORT_THREAD" {
            // Returns the same text that the UI's "Export Thread" button
            // hands to UIActivityViewController. Lets CC verify export
            // content correctness without having to capture the system
            // share sheet (which renders identically on sim and device
            // anyway, so pixels add nothing).
            let text = vm.exportChatHistory()
            return "{\"status\":\"ok\",\"command\":\"EXPORT_THREAD\",\"length\":\(text.count),\"text\":\"\(jsonStringEscape(text))\"}"

        } else if trimmed == "SCREENSHOT" {
            // Capture the current key window as a PNG and write to the app's
            // Documents directory. Returns the on-device path. The Python
            // test runner pulls it back via `devicectl device file pull` on
            // device, or reads the sim path directly. Added so CC can do
            // visual-correctness verification on the physical device, where
            // simulator MCP tooling doesn't apply.
            return await captureScreenshotJSON()

        } else if trimmed == "GET_RENDERED_MESSAGES" {
            return buildRenderedMessagesJSON(vm: vm)

        } else if trimmed == "GET_RENDERED_MESSAGES_FULL" {
            // Untruncated variant for transcript capture (salon conversations,
            // report writing, etc.). The default GET_RENDERED_MESSAGES caps
            // each content field at 500 chars to keep the API response cheap
            // for UI observability; this command returns the full content.
            // Used by the salon conductor script — model responses routinely
            // exceed 500 chars and we need them whole for the transcript.
            return buildRenderedMessagesJSON(vm: vm, truncateChars: nil)

        } else if trimmed == "GET_LOGS" {
            return buildLogsJSON(limit: 200)

        } else if trimmed.hasPrefix("GET_LOGS:") {
            let n = Int(trimmed.dropFirst("GET_LOGS:".count).trimmingCharacters(in: .whitespaces)) ?? 200
            return buildLogsJSON(limit: max(1, min(1000, n)))

        } else if trimmed == "CLEAR_LOGS" {
            RuntimeLog.shared.clear()
            return "{\"status\":\"ok\",\"command\":\"CLEAR_LOGS\"}"

        } else if trimmed.hasPrefix("CANCEL_DOWNLOAD:") {
            let modelID = String(trimmed.dropFirst("CANCEL_DOWNLOAD:".count)).trimmingCharacters(in: .whitespaces)
            MLXModelDownloader.shared.cancelDownload(modelID: modelID)
            print("HALDEBUG-TESTCONSOLE: Cancelled download for \(modelID)")
            return "{\"status\":\"ok\",\"command\":\"CANCEL_DOWNLOAD\",\"modelID\":\"\(jsonStringEscape(modelID))\"}"

        } else if trimmed.hasPrefix("IMPORT_DOCUMENT:") {
            let path = String(trimmed.dropFirst("IMPORT_DOCUMENT:".count)).trimmingCharacters(in: .whitespaces)
            let (ok, msg) = await DocumentImportManager.shared.importFromPath(path, chatViewModel: vm)
            let status = ok ? "ok" : "error"
            return "{\"status\":\"\(status)\",\"message\":\"\(jsonStringEscape(msg))\"}"

        } else if trimmed == "LIST_DOCUMENTS" {
            let docs = vm.memoryStore.listDocuments()
            let entries = docs.map { d -> String in
                "{\"sourceID\":\"\(d.sourceID)\",\"name\":\"\(jsonStringEscape(d.displayName))\",\"chunks\":\(d.chunks),\"createdAt\":\(d.createdAt)}"
            }.joined(separator: ",")
            return "{\"status\":\"ok\",\"count\":\(docs.count),\"documents\":[\(entries)]}"

        } else if trimmed.hasPrefix("DELETE_DOCUMENT:") {
            let sourceID = String(trimmed.dropFirst("DELETE_DOCUMENT:".count)).trimmingCharacters(in: .whitespaces)
            let deleted = vm.memoryStore.deleteDocument(sourceID: sourceID)
            return "{\"status\":\"ok\",\"command\":\"DELETE_DOCUMENT\",\"sourceID\":\"\(jsonStringEscape(sourceID))\",\"chunksDeleted\":\(deleted)}"

        } else if trimmed == "GET_REFLECTIONS" {
            let reflections = vm.memoryStore.getShareableReflections()
            let entries = reflections.prefix(20).map { r -> String in
                let text = jsonStringEscape(String(r.freeFormText.prefix(300)))
                return "{\"id\":\"\(r.id)\",\"type\":\(r.reflectionType),\"turn\":\(r.turnNumber),\"timestamp\":\(r.timestamp),\"text\":\"\(text)\"}"
            }.joined(separator: ",")
            return "{\"status\":\"ok\",\"count\":\(reflections.count),\"reflections\":[\(entries)]}"

        } else if trimmed == "RESET_SETTINGS" {
            vm.resetSettingsToDefaults()
            writeStateJSON(vm: vm)
            return "{\"status\":\"ok\",\"command\":\"RESET_SETTINGS\"}"

        } else if trimmed == "RESET_HARDWARE_DISCLOSURE" {
            // Debug-only: clears the one-time hardware-disclosure flag so the
            // popup fires again on the next MLX download or model switch.
            // Used to validate the popup UX without uninstalling Hal (which
            // would also wipe the multi-gigabyte downloaded models).
            UserDefaults.standard.removeObject(forKey: "hasSeenHardwareDisclosure")
            halLog("HALDEBUG-TESTCONSOLE: Reset hasSeenHardwareDisclosure flag (popup will re-fire on next MLX action)")
            return "{\"status\":\"ok\",\"command\":\"RESET_HARDWARE_DISCLOSURE\",\"note\":\"flag cleared; next MLX action will re-show the popup\"}"

        } else if trimmed == "SALON_GET_STATE" {
            let cfg = vm.salonConfig
            let seat1 = cfg.seat1 ?? ""
            let seat2 = cfg.seat2 ?? ""
            let seat3 = cfg.seat3 ?? ""
            let seat4 = cfg.seat4 ?? ""
            let summarizer = cfg.summarizerModel ?? ""
            return "{\"status\":\"ok\",\"isEnabled\":\(cfg.isEnabled),\"seat1\":\"\(jsonStringEscape(seat1))\",\"seat2\":\"\(jsonStringEscape(seat2))\",\"seat3\":\"\(jsonStringEscape(seat3))\",\"seat4\":\"\(jsonStringEscape(seat4))\",\"behavioralMode\":\"\(cfg.behavioralMode.rawValue)\",\"summarizerModel\":\"\(jsonStringEscape(summarizer))\",\"activeSeatCount\":\(cfg.activeSeats.count)}"

        } else if trimmed.hasPrefix("SALON_SET_ENABLED:") {
            // Routes through `setSalonEnabled` so the state-machine invariant
            // is enforced — enabling with 0 seats auto-populates Seat 1 with
            // AFM rather than leaving Salon in a degenerate state.
            let raw = String(trimmed.dropFirst("SALON_SET_ENABLED:".count)).trimmingCharacters(in: .whitespaces).lowercased()
            let on = (raw == "true" || raw == "1" || raw == "yes")
            let result = vm.setSalonEnabled(on)
            let autoStr = result.autoPopulatedSeat1WithID.map { jsonStringEscape($0) } ?? ""
            return "{\"status\":\"ok\",\"command\":\"SALON_SET_ENABLED\",\"isEnabled\":\(result.isEnabled),\"autoPopulatedSeat1WithID\":\"\(autoStr)\"}"

        } else if trimmed.hasPrefix("SALON_SET_SEAT:") {
            // Format: SALON_SET_SEAT:<position>:<modelID>  (modelID may be empty to clear the seat)
            // Routes through `setSalonSeat` so clearing the last seat while
            // Salon is enabled auto-disables Salon (preserving the invariant).
            let body = String(trimmed.dropFirst("SALON_SET_SEAT:".count))
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let position = Int(parts[0].trimmingCharacters(in: .whitespaces)), (1...4).contains(position) else {
                return "{\"status\":\"error\",\"message\":\"Expected SALON_SET_SEAT:<1-4>:<modelID-or-empty>\"}"
            }
            let modelID = parts[1].trimmingCharacters(in: .whitespaces)
            let assigned: String? = modelID.isEmpty ? nil : modelID
            let autoDisabled = vm.setSalonSeat(position: position, modelID: assigned)
            return "{\"status\":\"ok\",\"command\":\"SALON_SET_SEAT\",\"position\":\(position),\"modelID\":\"\(jsonStringEscape(assigned ?? ""))\",\"autoDisabledSalon\":\(autoDisabled)}"

        } else if trimmed.hasPrefix("SALON_SET_MODE:") {
            let raw = String(trimmed.dropFirst("SALON_SET_MODE:".count)).trimmingCharacters(in: .whitespaces)
            guard let mode = SalonBehavioralMode(rawValue: raw) else {
                return "{\"status\":\"error\",\"message\":\"Expected independent or contextAware\"}"
            }
            var cfg = vm.salonConfig
            cfg.behavioralMode = mode
            vm.salonConfig = cfg
            return "{\"status\":\"ok\",\"command\":\"SALON_SET_MODE\",\"behavioralMode\":\"\(mode.rawValue)\"}"

        } else if trimmed.hasPrefix("SALON_SET_SUMMARIZER:") {
            let raw = String(trimmed.dropFirst("SALON_SET_SUMMARIZER:".count)).trimmingCharacters(in: .whitespaces)
            var cfg = vm.salonConfig
            cfg.summarizerModel = raw.isEmpty ? nil : raw
            vm.salonConfig = cfg
            return "{\"status\":\"ok\",\"command\":\"SALON_SET_SUMMARIZER\",\"summarizerModel\":\"\(jsonStringEscape(raw))\"}"

        } else if trimmed == "NUCLEAR_RESET" {
            let (threads, facts, messages) = vm.memoryStore.clearAllConversationData()
            vm.resetSettingsToDefaults()
            vm.startNewConversation()
            print("HALDEBUG-TESTCONSOLE: NUCLEAR_RESET — \(threads) threads, \(messages) messages deleted")
            return "{\"status\":\"ok\",\"command\":\"NUCLEAR_RESET\",\"threadsDeleted\":\(threads),\"factsDeleted\":\(facts),\"messagesDeleted\":\(messages),\"newConversationId\":\"\(vm.conversationId)\"}"

        } else if trimmed == "RESET_SELF_KNOWLEDGE" {
            // Targeted reset: wipes every self_knowledge row (reflections
            // + structured traits) without touching conversations, threads,
            // or unified_content / RAG memory. Used to clear testing-
            // artifact data before a clean restart of the self-knowledge
            // accumulation cycle. Per Mark's May-15 directive before the
            // salon conversation: "the current entries are testing
            // artifacts — repetitive, shallow, generated under broken
            // conditions. They're junk data and they'll pollute everything
            // that follows. Start clean."
            let deleted = vm.memoryStore.resetSelfKnowledgeAndReflections()
            print("HALDEBUG-TESTCONSOLE: RESET_SELF_KNOWLEDGE — \(deleted) rows deleted (reflections + traits)")
            return "{\"status\":\"ok\",\"command\":\"RESET_SELF_KNOWLEDGE\",\"rowsDeleted\":\(deleted)}"

        } else if trimmed == "GET_STATE" {
            writeStateJSON(vm: vm)
            if let data = try? Data(contentsOf: stateFile),
               let json = String(data: data, encoding: .utf8) { return json }
            return "{\"status\":\"error\",\"message\":\"Could not read state\"}"

        } else if trimmed == "CLEAR_TEST_DATA" {
            let (threads, facts, messages) = vm.memoryStore.clearAllConversationData()
            vm.startNewConversation()
            return "{\"status\":\"ok\",\"command\":\"CLEAR_TEST_DATA\",\"threadsDeleted\":\(threads),\"factsDeleted\":\(facts),\"messagesDeleted\":\(messages),\"newConversationId\":\"\(vm.conversationId)\"}"

        } else if trimmed.hasPrefix("EMBED_SIM_BATCH:") {
            // EMBED_SIM_BATCH:<t1a>|||<t2a>~~~<t1b>|||<t2b>~~~...
            //
            // Like EMBED_SIM but takes many pairs in one round trip, to
            // avoid iOS suspending the app between probe calls. Pairs
            // separated by `~~~`, texts within a pair separated by `|||`.
            // Returns one JSON array of {sim, dim} entries in input order.
            //
            // Added 2026-05-18 for batch Nomic threshold calibration.
            let payload = String(trimmed.dropFirst("EMBED_SIM_BATCH:".count))
            let pairs = payload.components(separatedBy: "~~~")
            var results: [String] = []
            for pair in pairs {
                let halves = pair.components(separatedBy: "|||")
                if halves.count != 2 {
                    results.append("{\"sim\":null,\"error\":\"bad pair\"}")
                    continue
                }
                guard let v1 = EmbeddingProvider.shared.embed(halves[0], as: .document),
                      let v2 = EmbeddingProvider.shared.embed(halves[1], as: .document),
                      v1.count == v2.count, !v1.isEmpty else {
                    results.append("{\"sim\":null,\"error\":\"embed failed\"}")
                    continue
                }
                var dot = 0.0, n1 = 0.0, n2 = 0.0
                for i in 0..<v1.count {
                    dot += v1[i] * v2[i]
                    n1 += v1[i] * v1[i]
                    n2 += v2[i] * v2[i]
                }
                let denom = (n1.squareRoot() * n2.squareRoot())
                let sim = denom > 0 ? dot / denom : 0
                results.append("{\"sim\":\(sim),\"dim\":\(v1.count)}")
            }
            let backend = EmbeddingProvider.shared.activeBackend.rawValue
            return "{\"status\":\"ok\",\"backend\":\"\(backend)\",\"count\":\(results.count),\"results\":[\(results.joined(separator: ","))]}"

        } else if trimmed.hasPrefix("EMBED_SIM:") {
            // EMBED_SIM:<text1>|||<text2>
            //
            // Diagnostic: returns cosine similarity between embeddings of
            // two texts under the active backend. Used for threshold
            // calibration probes (see EmbeddingBackend.recommendedSynthesisThreshold).
            // Both texts embedded with `.document` purpose to match
            // reflection-storage semantics.
            //
            // Added 2026-05-18 for Nomic synthesis threshold calibration.
            let payload = String(trimmed.dropFirst("EMBED_SIM:".count))
            let parts = payload.components(separatedBy: "|||")
            guard parts.count == 2 else {
                return "{\"status\":\"error\",\"message\":\"EMBED_SIM: payload must be <text1>|||<text2>\"}"
            }
            let t1 = parts[0]
            let t2 = parts[1]
            guard let v1 = EmbeddingProvider.shared.embed(t1, as: .document),
                  let v2 = EmbeddingProvider.shared.embed(t2, as: .document),
                  v1.count == v2.count, !v1.isEmpty else {
                return "{\"status\":\"error\",\"message\":\"EMBED_SIM: embed failed or dim mismatch\"}"
            }
            var dot = 0.0, n1 = 0.0, n2 = 0.0
            for i in 0..<v1.count {
                dot += v1[i] * v2[i]
                n1 += v1[i] * v1[i]
                n2 += v2[i] * v2[i]
            }
            let denom = (n1.squareRoot() * n2.squareRoot())
            let sim = denom > 0 ? dot / denom : 0
            let backend = EmbeddingProvider.shared.activeBackend.rawValue
            return "{\"status\":\"ok\",\"backend\":\"\(backend)\",\"dim\":\(v1.count),\"sim\":\(sim),\"t1Len\":\(t1.count),\"t2Len\":\(t2.count)}"

        } else if trimmed == "EMBEDDING_STATUS" {
            // Read-only diagnostic for the active embedding backend.
            // Reports backend name and whether it's loaded yet. Only
            // performs an actual embed (which can block for many seconds
            // on Gemma first-call, or fail with no model loaded) when
            // isLoaded is true — so this command returns promptly during
            // first-launch download.
            let backend = EmbeddingProvider.shared.activeBackend
            let isLoaded = EmbeddingProvider.shared.isLoaded
            var dim = 0
            if isLoaded {
                if let testVec = EmbeddingProvider.shared.embed("test") {
                    dim = testVec.count
                }
            }
            return "{\"status\":\"ok\",\"backend\":\"\(backend.rawValue)\",\"isLoaded\":\(isLoaded),\"sampleVectorDim\":\(dim),\"expectedDim\":\(backend.dimension)}"

        } else if trimmed.hasPrefix("SET_EMBEDDING_BACKEND:") {
            // SET_EMBEDDING_BACKEND:<nlcontextual|embeddinggemma>
            //
            // Switches the active embedding backend. Persists to
            // UserDefaults("embeddingBackend"). Immediately wipes all
            // stored embeddings so rows re-embed via the new backend.
            // New rows re-embed lazily on next write; existing rows are
            // backfilled by the separate MIGRATE_EMBEDDINGS_REEMBED command.
            //
            // Note: this command does NOT run the migration synchronously,
            // because EmbeddingGemma may not be downloaded yet (or may
            // still be loading its weights). The catalog-driven UI is
            // responsible for ordering: download → switch → migrate.
            //
            // Added 2026-05-17 for Proposal A.
            let raw = String(trimmed.dropFirst("SET_EMBEDDING_BACKEND:".count))
                .trimmingCharacters(in: .whitespaces)
            // Hard-reject the removed "embeddinggemma" backend with a clean
            // error (per Mark's direction 2026-05-20). EmbeddingBackend.init
            // would already fail with "unknown backend" since the case is
            // commented out, but the dedicated message saves anyone running
            // an old test script some confusion.
            if raw == "embeddinggemma" {
                return "{\"status\":\"error\",\"message\":\"embeddinggemma backend is not available in this build\"}"
            }
            guard let newBackend = EmbeddingBackend(rawValue: raw) else {
                let valid = "nlcontextual, nomicswift"
                return "{\"status\":\"error\",\"message\":\"unknown backend '\(raw)'; valid: \(valid)\"}"
            }
            UserDefaults.standard.set(newBackend.rawValue, forKey: EmbeddingBackend.defaultsKey)
            // Drop the stored systemVersion so wipeStaleEmbeddingsIfNeeded
            // triggers on next call. Then call it explicitly so the wipe
            // happens before any further writes.
            UserDefaults.standard.removeObject(forKey: "embeddingSystemVersion")
            vm.memoryStore.wipeStaleEmbeddingsIfNeeded()
            // Kick off async warm-up of the new backend so the load
            // starts immediately rather than blocking the next embed() call.
            EmbeddingProvider.shared.warmUp()
            return "{\"status\":\"ok\",\"command\":\"SET_EMBEDDING_BACKEND\",\"backend\":\"\(newBackend.rawValue)\",\"expectedDim\":\(newBackend.dimension),\"note\":\"existing embeddings wiped; warm-up triggered; new rows re-embed on next write; call MIGRATE_EMBEDDINGS_REEMBED to backfill existing rows\"}"

        } else if trimmed == "MIGRATE_EMBEDDINGS_REEMBED" {
            // Re-embed every unified_content row with NULL embedding using
            // the currently-active backend. Use this after SET_EMBEDDING_BACKEND
            // (or whenever rows with missing embeddings need to be backfilled).
            //
            // Runs synchronously on the API thread — the caller controls
            // pacing. For large corpora the call may block for tens of
            // seconds; the UI flow surfaces progress via background polling
            // of the same `reEmbedAllNullRows` log line.
            //
            // No-op if the active backend isn't loaded — failures are counted
            // but the rows stay NULL for a future retry.
            let backend = EmbeddingProvider.shared.activeBackend
            let loaded = EmbeddingProvider.shared.isLoaded
            if !loaded {
                return "{\"status\":\"error\",\"message\":\"active backend '\(backend.rawValue)' is not loaded; cannot re-embed. For EmbeddingGemma, ensure the model is downloaded.\"}"
            }
            let result = vm.memoryStore.reEmbedAllNullRows()
            return "{\"status\":\"ok\",\"command\":\"MIGRATE_EMBEDDINGS_REEMBED\",\"backend\":\"\(backend.rawValue)\",\"updated\":\(result.updated),\"skipped\":\(result.skipped),\"failed\":\(result.failed)}"

        } else if trimmed == "DOWNLOAD_EMBEDDING_MODEL" || trimmed.hasPrefix("DOWNLOAD_EMBEDDING_MODEL:") {
            // DOWNLOAD_EMBEDDING_MODEL[:<backend>]
            //
            // Trigger download for the named embedding backend's model via
            // the existing MLXModelDownloader / BackgroundDownloadCoordinator
            // pipeline (same one that powers LLM downloads). Without the
            // backend suffix, defaults to "nomicswift" since that's the
            // primary downloadable embedder available today.
            //
            // Returns immediately; poll EMBEDDING_DOWNLOAD_STATUS:<backend>
            // for progress. Files end up at:
            //   .cachesDirectory/huggingface/models/<repoID>/
            // which is exactly the path each backend's ensure*Loaded path
            // looks at. Idempotent — if already downloaded, returns ok
            // with alreadyDownloaded=true.
            let raw: String
            if trimmed.hasPrefix("DOWNLOAD_EMBEDDING_MODEL:") {
                raw = String(trimmed.dropFirst("DOWNLOAD_EMBEDDING_MODEL:".count)).trimmingCharacters(in: .whitespaces)
            } else {
                raw = EmbeddingBackend.nomicSwift.rawValue
            }
            guard let backend = EmbeddingBackend(rawValue: raw) else {
                return "{\"status\":\"error\",\"message\":\"unknown backend '\(raw)'\"}"
            }
            guard backend.isAvailableInThisBuild else {
                return "{\"status\":\"error\",\"message\":\"backend '\(backend.rawValue)' is not enabled in this build\"}"
            }
            guard let modelID = backend.modelID else {
                return "{\"status\":\"error\",\"message\":\"backend '\(backend.rawValue)' has no downloadable model (built-in)\"}"
            }
            if MLXModelDownloader.shared.isModelDownloaded(modelID) {
                return "{\"status\":\"ok\",\"command\":\"DOWNLOAD_EMBEDDING_MODEL\",\"backend\":\"\(backend.rawValue)\",\"modelID\":\"\(modelID)\",\"alreadyDownloaded\":true}"
            }
            // Size estimate — approximate, used for pre-flight disk space check.
            let sizeGB: Double
            switch backend {
            // REMOVED 2026-05-20: case .embeddingGemma: sizeGB = 0.21
            case .nomicSwift: sizeGB = 0.55
            case .nlContextual: sizeGB = 0  // unreachable; built-in
            }
            Task { await MLXModelDownloader.shared.startDownload(modelID: modelID, repoID: modelID, sizeGB: sizeGB) }
            return "{\"status\":\"ok\",\"command\":\"DOWNLOAD_EMBEDDING_MODEL\",\"backend\":\"\(backend.rawValue)\",\"modelID\":\"\(modelID)\",\"started\":true,\"note\":\"download running in background; poll EMBEDDING_DOWNLOAD_STATUS:\(backend.rawValue)\"}"

        } else if trimmed == "FTS_DIAG" {
            // Read-only diagnostic for the FTS5 unified_content_fts index.
            // Counts rows in unified_content vs the FTS shadow table; runs
            // a literal `subaru` MATCH to verify the index contains injected
            // content; reports the FTS5 schema (columns + tokenizer).
            // Added 2026-05-17 afternoon to diagnose "BM25 returns 0 candidates"
            // regression.
            let counts = vm.memoryStore.debugFTSDiagnostic()
            return counts

        } else if trimmed == "SELF_KNOWLEDGE_AUDIT" || trimmed.hasPrefix("SELF_KNOWLEDGE_AUDIT:") {
            // Read-only audit of the self_knowledge corpus. Returns row
            // counts by format / category / shareable, reinforcement-count
            // distribution (for Phase 2 promotion-eligibility sanity), and
            // a sample of recent entries with the lineage fields. Useful
            // any time we need to understand what's actually in the
            // self-knowledge layer, especially before changes that depend
            // on it (Phase 3 trait-evolution work, the 2026-05-18 corpus
            // audit before deciding whether to nuke and rebuild, etc).
            //
            // Example: SELF_KNOWLEDGE_AUDIT or SELF_KNOWLEDGE_AUDIT:50
            let raw = trimmed.hasPrefix("SELF_KNOWLEDGE_AUDIT:")
                ? String(trimmed.dropFirst("SELF_KNOWLEDGE_AUDIT:".count)).trimmingCharacters(in: .whitespaces)
                : ""
            let limit = max(0, min(200, Int(raw) ?? 20))
            return vm.memoryStore.debugSelfKnowledgeAudit(sampleLimit: limit)

        } else if trimmed.hasPrefix("DB_SCHEMA:") {
            // Read-only schema-inspection diagnostic. Returns a JSON list of
            // {name, type, notnull, dflt_value, pk} for every column in the
            // named table via SQLite's PRAGMA table_info(). Useful for
            // verifying schema migrations landed (e.g. after adding
            // promoted_to_trait_id + shareability_decided_by_model in v1
            // crystallization, 2026-05-18).
            //
            // Example: DB_SCHEMA:self_knowledge
            let table = String(trimmed.dropFirst("DB_SCHEMA:".count)).trimmingCharacters(in: .whitespaces)
            return vm.memoryStore.debugSchemaForTable(table)

        } else if trimmed == "EMBEDDING_DOWNLOAD_STATUS" || trimmed.hasPrefix("EMBEDDING_DOWNLOAD_STATUS:") {
            // EMBEDDING_DOWNLOAD_STATUS[:<backend>]
            //
            // Read-only progress report for the named backend's download.
            // Without a backend suffix, defaults to "nomicswift".
            let raw: String
            if trimmed.hasPrefix("EMBEDDING_DOWNLOAD_STATUS:") {
                raw = String(trimmed.dropFirst("EMBEDDING_DOWNLOAD_STATUS:".count)).trimmingCharacters(in: .whitespaces)
            } else {
                raw = EmbeddingBackend.nomicSwift.rawValue
            }
            guard let backend = EmbeddingBackend(rawValue: raw) else {
                return "{\"status\":\"error\",\"message\":\"unknown backend '\(raw)'\"}"
            }
            guard let modelID = backend.modelID else {
                return "{\"status\":\"ok\",\"backend\":\"\(backend.rawValue)\",\"modelID\":\"\",\"isDownloaded\":true,\"isDownloading\":false,\"progress\":1.0,\"message\":\"built-in, no download required\",\"error\":\"\"}"
            }
            let isDownloaded = MLXModelDownloader.shared.isModelDownloaded(modelID)
            let state = MLXModelDownloader.shared.downloadStates[modelID]
            let isDownloading = state?.isDownloading ?? false
            let progress = state?.progress ?? (isDownloaded ? 1.0 : 0.0)
            let message = (state?.message ?? "").replacingOccurrences(of: "\"", with: "\\\"")
            let err = (state?.error ?? "").replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"status\":\"ok\",\"backend\":\"\(backend.rawValue)\",\"modelID\":\"\(modelID)\",\"isDownloaded\":\(isDownloaded),\"isDownloading\":\(isDownloading),\"progress\":\(progress),\"message\":\"\(message)\",\"error\":\"\(err)\"}"

        } else if trimmed == "INJECT_REALISTIC_TEST_CORPUS" {
            // Inject ~70 rows of realistic conversational content into
            // unified_content for RAG threshold evaluation. Used by the
            // 2026-05-17 threshold-tuning eval (build out a populated DB
            // so the threshold isn't tuned against a 6-row trivial case).
            let count = vm.memoryStore.injectRealisticTestCorpus()
            return "{\"status\":\"ok\",\"command\":\"INJECT_REALISTIC_TEST_CORPUS\",\"rowsInjected\":\(count)}"

        } else if trimmed.hasPrefix("MEMORY_DUMP:") {
            // MEMORY_DUMP:<limit>
            //
            // Read-only diagnostic for inspecting the most recent rows in
            // unified_content. Returns each row's id prefix, source_type,
            // source_id prefix, position, turn_number, is_from_user,
            // recorded_by_model, embedding doubles count, content length,
            // and a 200-char content preview. Used to verify write-side
            // behavior (planted turns get stored, embeddings get attached).
            // Added 2026-05-16 night for the RAG planted-fact-recall
            // regression investigation.
            let limitStr = String(trimmed.dropFirst("MEMORY_DUMP:".count)).trimmingCharacters(in: .whitespaces)
            let limit = Int(limitStr) ?? 20
            return vm.memoryStore.debugDumpRecentUnifiedContent(limit: limit)

        } else if trimmed.hasPrefix("MEMORY_SIMILARITY_DEBUG:") {
            // MEMORY_SIMILARITY_DEBUG:<query>
            //
            // Read-only diagnostic that scores the query against EVERY row
            // in unified_content via cosineSimilarity, without applying any
            // threshold or recency boost. Returns sorted by score desc.
            // Used to diagnose the semantic-search failure mode where rows
            // that should be high-confidence (e.g., query "Pepper" against
            // stored "Pepper is my dog.") fail the production threshold.
            // Added 2026-05-16 night for RAG regression diagnosis.
            let query = String(trimmed.dropFirst("MEMORY_SIMILARITY_DEBUG:".count))
            return vm.memoryStore.debugSemanticSimilarity(query: query)

        } else if trimmed.hasPrefix("MEMORY_SEARCH_EXPANDED:") {
            // MEMORY_SEARCH_EXPANDED:<query>
            //
            // Like MEMORY_SEARCH_DEBUG but runs the full two-pass
            // search-with-expansion flow the chat tool uses (first pass
            // without expansion, trigger check on top-1, second pass with
            // LLM-supplied expansion terms if tripped). Returns the same
            // shape plus an `expansion` object with triggered/terms/improved.
            // Used by the eval harness to measure expansion's recall lift.
            // Added 2026-05-17.
            let query = String(trimmed.dropFirst("MEMORY_SEARCH_EXPANDED:".count))
            return await vm.memoryStore.debugSearchUnifiedContentWithExpansion(
                query: query,
                currentConversationId: vm.conversationId,
                llmService: vm.llmService
            )

        } else if trimmed.hasPrefix("SET_FORCE_EXPANSION:") {
            // SET_FORCE_EXPANSION:<true|false>
            //
            // Diagnostic: force LLM query expansion to fire on every
            // query regardless of the normal trigger predicate. Used by
            // the eval harness to measure expansion's impact under the
            // Nomic pipeline (the original trigger was calibrated against
            // NLContextual). Production should leave this off.
            let raw = String(trimmed.dropFirst("SET_FORCE_EXPANSION:".count))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = (raw == "true" || raw == "1" || raw == "yes")
            UserDefaults.standard.set(value, forKey: "forceQueryExpansion")
            return "{\"status\":\"ok\",\"command\":\"SET_FORCE_EXPANSION\",\"value\":\(value)}"

        } else if trimmed == "CLEAR_QUERY_EXPANSION_CACHE" {
            // Clear all cached LLM expansion results. Called by the API
            // for diagnostics and (internally) when the active LLM
            // changes, since different models extract different concept
            // sets. Returns the number of rows deleted.
            let deleted = vm.memoryStore.queryExpansionCacheClear()
            return "{\"status\":\"ok\",\"command\":\"CLEAR_QUERY_EXPANSION_CACHE\",\"deleted\":\(deleted)}"

        } else if trimmed == "QUERY_EXPANSION_CACHE_STATUS" {
            // Read-only count of cached expansions. Useful for verifying
            // the cache is actually being populated/hit.
            let count = vm.memoryStore.queryExpansionCacheCount()
            return "{\"status\":\"ok\",\"command\":\"QUERY_EXPANSION_CACHE_STATUS\",\"cachedEntries\":\(count)}"

        } else if trimmed.hasPrefix("MEMORY_SEARCH_DEBUG:") {
            // MEMORY_SEARCH_DEBUG:<query>
            //
            // Read-only diagnostic that runs the SAME semantic + entity
            // search the chat pipeline uses (searchUnifiedContent) and
            // returns the resulting snippets with similarity scores plus a
            // 200-char content preview. Defaults to maxResults=20 and
            // tokenBudget=4000 (generous, so we see what the real ranking
            // looks like without budget-trimming hiding low-ranked hits).
            // Use to verify retrieval finds the planted fact for a
            // paraphrased query and at what score. Added 2026-05-16 night
            // for the RAG planted-fact-recall regression investigation.
            let query = String(trimmed.dropFirst("MEMORY_SEARCH_DEBUG:".count))
            return vm.memoryStore.debugSearchUnifiedContent(query: query, currentConversationId: vm.conversationId)

        } else if trimmed.hasPrefix("MEMORY_INJECT_TEST:") {
            // MEMORY_INJECT_TEST:<count>:<tokens_each>[:<category>]
            //
            // Inserts N synthetic self-knowledge entries of approximately
            // <tokens_each> tokens each, into the self_knowledge table. Dual
            // purpose per the implementation plan:
            //
            //   1. Context-budget testing: deterministically reproduce AFM
            //      context overflow without waiting for organic accumulation.
            //      Phase 8 validation uses this to verify compression triggers
            //      correctly when self-knowledge exceeds AFM's prompt budget.
            //
            //   2. Evolutionary Salon threshold testing: verify the salon
            //      Easter-egg trigger threshold (THRESHOLD ~50) without waiting
            //      weeks for organic accumulation.
            //
            // Same injection primitive, two consumer use cases.
            //
            // Each synthetic entry uses category=<provided> (default "test_synthetic"),
            // key=`synthetic_<index>`, value=padded-Lorem-Ipsum to ~tokens_each
            // tokens. Confidence is 0.95 so entries land at typical injection
            // strength. Use RESET_SELF_KNOWLEDGE to clear them when done testing.
            let payload = String(trimmed.dropFirst("MEMORY_INJECT_TEST:".count))
            let parts = payload.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2,
                  let count = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let tokensEach = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  count > 0, count <= 500,
                  tokensEach > 0, tokensEach <= 2000 else {
                return "{\"status\":\"error\",\"message\":\"MEMORY_INJECT_TEST requires <count>:<tokens_each>[:<category>]; count 1-500, tokens 1-2000\"}"
            }
            let category = parts.count >= 3 ? parts[2].trimmingCharacters(in: .whitespaces) : "test_synthetic"
            // Compose a value of approximately tokensEach tokens. We use
            // TokenEstimator's chars/4 heuristic in reverse so the generated
            // synthetic content gets estimated at close to tokensEach tokens.
            let charsPerValue = tokensEach * 4
            let pad = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. "
            var paddedValue = ""
            while paddedValue.count < charsPerValue {
                paddedValue += pad
            }
            paddedValue = String(paddedValue.prefix(charsPerValue))

            for i in 1...count {
                vm.memoryStore.storeSelfKnowledge(
                    modelId: nil,
                    category: category,
                    key: "synthetic_\(i)",
                    value: "Entry \(i): \(paddedValue)",
                    confidence: 0.95,
                    source: "MEMORY_INJECT_TEST",
                    shareable: false,
                    format: "structured_trait"
                )
            }
            // Invalidate any cached self-knowledge compressions so the next
            // turn sees the inflated raw state.
            vm.memoryStore.invalidateCachedCompressions(forSegmentKind: .selfKnowledge)
            print("HALDEBUG-TESTCONSOLE: MEMORY_INJECT_TEST — injected \(count) synthetic entries of ~\(tokensEach) tokens each (category: \(category))")
            return "{\"status\":\"ok\",\"command\":\"MEMORY_INJECT_TEST\",\"injected\":\(count),\"tokensEach\":\(tokensEach),\"category\":\"\(category)\"}"

        } else {
            print("HALDEBUG-TESTCONSOLE: Unknown command: \(trimmed.prefix(60))")
            return "{\"status\":\"error\",\"message\":\"Unknown command: \(jsonStringEscape(String(trimmed.prefix(60))))\"}"
        }
    }

    // MARK: - Model Management Helpers

    private func switchToModel(_ modelID: String, vm: ChatViewModel) async {
        // Per-model settings profile — Layer 2: snapshot the OUTGOING model's
        // settings before changing, then apply the INCOMING model's effective
        // settings after. Mirrors the equivalent hooks in
        // ChatViewModel.switchToModel(_:) so the API path and the UI path
        // produce identical per-model behavior. Without this, switching
        // models via the API would leave the previous model's settings in
        // place and the per-model profiles would silently break.
        let oldModelID = vm.selectedModelID
        ModelSettingsStore.shared.snapshotCurrentSettings(for: oldModelID)

        let newModel: ModelConfiguration
        if modelID == "apple-foundation-models" {
            newModel = .appleFoundation
            vm.selectedModelID = modelID
            vm.llmService.setupLLM(for: newModel)
            print("HALDEBUG-TESTCONSOLE: Switched to Apple Foundation Models")
        } else if let model = ModelCatalogService.shared.getModel(byID: modelID) {
            newModel = model
            vm.selectedModelID = modelID
            vm.llmService.setupLLM(for: model)
            print("HALDEBUG-TESTCONSOLE: Switched to \(model.displayName)")
        } else {
            let localPath = MLXModelDownloader.shared.getModelPath(modelID)
            let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
            newModel = ModelConfiguration(
                id: modelID, displayName: shortName, source: .mlx,
                sizeGB: nil, contextWindow: 4096, license: nil, description: nil,
                isDownloaded: localPath != nil, localPath: localPath
            )
            // Register the minimal config in the catalog so vm.selectedModel's
            // getModel(byID:) lookup succeeds and stops falling back to AFM.
            // Otherwise Hal would report itself as "Apple Intelligence" in
            // SELF_AWARENESS even while actually running on this MLX model.
            ModelCatalogService.shared.addModelIfAbsent(newModel)
            vm.selectedModelID = modelID
            vm.llmService.setupLLM(for: newModel)
            print("HALDEBUG-TESTCONSOLE: Switched to \(shortName) (minimal config, registered in catalog)")
        }

        // Apply the new model's effective settings THROUGH the live VM
        // properties so @AppStorage observation fires correctly. (Direct
        // UserDefaults writes don't reliably invalidate @AppStorage caches
        // on ObservableObject instances — see comment in ChatViewModel
        // switchToModel.)
        let effective = ModelSettingsStore.shared.effectiveSettings(for: newModel)
        await MainActor.run {
            if let v = effective.temperature              { vm.temperature = v }
            // Clamp memoryDepth to the new model's max so the API path
            // matches the UI switchToModel path. Without this, a per-
            // model default that exceeds its own runtime limit (e.g. the
            // pre-fix AFM default of 4 with max 3) would leave the
            // Settings slider showing one value with the thumb at
            // another. Memory Depth display mismatch, 2026-05-18.
            if let v = effective.effectiveMemoryDepth     { vm.memoryDepth = min(v, vm.maxMemoryDepth) }
            if let v = effective.maxRagSnippetsCharacters { vm.maxRagSnippetsCharacters = Double(v) }
            if let v = effective.ragDedupThreshold        { vm.ragDedupSimilarityThreshold = v }
            if let v = effective.recencyWeight            { vm.memoryStore.recencyWeight = v }
            if let v = effective.recencyHalfLifeDays      { vm.memoryStore.recencyHalfLifeDays = v }
            // Defense in depth: even if effective.effectiveMemoryDepth
            // was nil (leaving memoryDepth untouched from the previous
            // model's value), the previous value may exceed the new
            // model's max. Clamp unconditionally.
            if vm.memoryDepth > vm.maxMemoryDepth {
                halLog("HALDEBUG-SETTINGS: API path clamping memoryDepth \(vm.memoryDepth) → \(vm.maxMemoryDepth) (new model: \(newModel.displayName))")
                vm.memoryDepth = vm.maxMemoryDepth
            }
            halLog("HALDEBUG-SETTINGS: Applied effective settings for \(newModel.displayName) via VM props: temp=\(effective.temperature.map { "\($0)" } ?? "—"), depth=\(vm.memoryDepth), maxRag=\(effective.maxRagSnippetsCharacters.map { "\($0)" } ?? "—")")
        }

        // BUG 3 fix (2026-05-19): wait for the MLX load to actually
        // complete before returning. setupLLM(for:) kicks the load off
        // on a background Task captured in
        // `LLMService.pendingMLXLoadTask`; without awaiting it, the API
        // returns SWITCH_MODEL ok before the model is loaded, and the
        // user's immediate next /chat call hits the not-loaded gate
        // and returns "Error: The selected language model could not be
        // loaded or is not available." For ~3 GB MLX models like Gemma
        // 4 E2B and Dolphin 3.0 this fails reliably; smaller MLX
        // models win the race by accident. AFM has no load step so
        // awaiting is a no-op for it.
        await vm.llmService.awaitPendingMLXLoad()
    }

    private func buildModelListJSON(vm: ChatViewModel) -> String {
        // Refresh download states so the list is accurate
        ModelCatalogService.shared.refreshDownloadStates()
        let activeID = vm.llmService.activeModelID
        var entries: [String] = []

        // Iterate the catalog only. Previously this function also
        // hardcoded an AFM entry (displayName: "Apple Foundation Models")
        // on top of the catalog's seeded AFM (displayName: "Apple
        // Intelligence"), which produced two AFM rows in LIST_MODELS with
        // different display names. The seeded catalog entry is the single
        // source of truth.
        let catalog = ModelCatalogService.shared.availableModels
        for model in catalog {
            let isActive = model.id == activeID
            let sizeStr = model.sizeGB.map { String(format: "%.1f", $0) } ?? "null"
            let sizeVal = model.sizeGB != nil ? sizeStr : "null"
            entries.append("{\"id\":\"\(jsonStringEscape(model.id))\",\"displayName\":\"\(jsonStringEscape(model.displayName))\",\"downloaded\":\(model.isDownloaded),\"active\":\(isActive),\"sizeGB\":\(sizeVal)}")
        }

        return "{\"status\":\"ok\",\"models\":[\(entries.joined(separator: ","))]}"
    }

    private func startModelDownload(_ modelID: String, vm: ChatViewModel) async -> String {
        if MLXModelDownloader.shared.isModelDownloaded(modelID) {
            return "{\"status\":\"ok\",\"modelID\":\"\(jsonStringEscape(modelID))\",\"note\":\"already downloaded\"}"
        }
        // Build config for downloader
        let model: ModelConfiguration
        if let catalogModel = ModelCatalogService.shared.getModel(byID: modelID) {
            model = catalogModel
        } else {
            let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
            model = ModelConfiguration(
                id: modelID, displayName: shortName, source: .mlx,
                sizeGB: nil, contextWindow: 4096, license: nil, description: nil,
                isDownloaded: false, localPath: nil
            )
        }
        // Start download on a background task — startDownload is async and long-running
        Task { await MLXModelDownloader.shared.startDownload(modelID: model.id, repoID: model.id, sizeGB: model.sizeGB) }
        print("HALDEBUG-TESTCONSOLE: Download started for \(modelID)")
        return "{\"status\":\"ok\",\"command\":\"DOWNLOAD_MODEL\",\"modelID\":\"\(jsonStringEscape(modelID))\",\"note\":\"download started\"}"
    }

    private func buildModelStatusJSON(_ modelID: String) -> String {
        let downloader = MLXModelDownloader.shared
        let isDownloaded = downloader.isModelDownloaded(modelID)
        let isDownloading = downloader.isDownloading && downloader.currentDownloadID == modelID
        let prog = isDownloading ? String(format: "%.3f", downloader.progress) : (isDownloaded ? "1.0" : "0.0")
        // Surface error directly from downloadStates[modelID].error — this
        // covers refused downloads (insufficient disk space, etc.) which
        // set state.error WITHOUT setting currentDownloadID, since they
        // never actually started downloading. Previous logic only surfaced
        // errors for in-flight downloads, hiding refusal messages from API
        // consumers. UI was unaffected (ModelLibraryRow reads state.error
        // directly), but tests + automation now see the same view.
        let stateError = downloader.downloadStates[modelID]?.error
        let errorStr = stateError.map { "\"\(jsonStringEscape($0))\"" } ?? "null"
        return "{\"status\":\"ok\",\"modelID\":\"\(jsonStringEscape(modelID))\",\"isDownloaded\":\(isDownloaded),\"isDownloading\":\(isDownloading),\"progress\":\(prog),\"error\":\(errorStr)}"
    }

    private func deleteModel(_ modelID: String) async -> String {
        await MLXModelDownloader.shared.deleteModel(modelID: modelID)
        print("HALDEBUG-TESTCONSOLE: Model deleted: \(modelID)")
        return "{\"status\":\"ok\",\"command\":\"DELETE_MODEL\",\"modelID\":\"\(jsonStringEscape(modelID))\"}"
    }

    // MARK: - State JSON

    func buildStateJSON(vm: ChatViewModel) -> String {
        let promptText = vm.effectiveSystemPrompt
        let fingerprint = String(promptText.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let hasOverride = systemPromptOverride != nil
        let liveID = vm.llmService.activeModelID
        let hasSummary = !vm.injectedSummary.isEmpty
        let ms = vm.memoryStore
        return """
        {
          "modelID": "\(liveID)",
          "conversationId": "\(vm.conversationId)",
          "activeThreadMessages": \(vm.messages.filter { !$0.isPartial }.count),
          "turnCount": \(turnCount),
          "memoryDepth": \(vm.memoryDepth),
          "maxMemoryDepth": \(vm.maxMemoryDepth),
          "temperature": \(String(format: "%.2f", vm.temperature)),
          "selfKnowledgeEnabled": \(vm.enableSelfKnowledge),
          "recencyWeight": \(String(format: "%.2f", ms.recencyWeight)),
          "recencyHalfLifeDays": \(String(format: "%.1f", ms.recencyHalfLifeDays)),
          "maxRagSnippetsCharacters": \(Int(vm.maxRagSnippetsCharacters)),
          "ragDedupThreshold": \(String(format: "%.2f", vm.ragDedupSimilarityThreshold)),
          "lastSummarizedTurnCount": \(vm.lastSummarizedTurnCount),
          "injectedSummaryActive": \(hasSummary),
          "injectedSummaryLength": \(vm.injectedSummary.count),
          "totalConversations": \(ms.totalConversations),
          "totalTurns": \(ms.totalTurns),
          "totalDocuments": \(ms.totalDocuments),
          "systemPromptOverrideActive": \(hasOverride),
          "systemPromptFingerprint": "\(fingerprint)..."
        }
        """
    }

    func writeStateJSON(vm: ChatViewModel) {
        let state = buildStateJSON(vm: vm)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? state.write(to: stateFile, atomically: true, encoding: .utf8)
    }

    // MARK: - UI Observation JSON
    //
    // GET_UI_STATE and GET_RENDERED_MESSAGES expose what the user actually sees,
    // not just what's in the database. The distinction matters when:
    //   - A sheet/modal is presented over the chat view
    //   - vm.messages (rendered) drifts from memoryStore (persisted) — e.g. partial
    //     streaming messages that exist in memory but haven't been saved
    //   - Error banners are visible
    //   - The user has typed but not sent text in the input field
    //
    // These exist so a remote API caller (CC, hal_test.py, future tools) never needs
    // to ask a human "what do you see on screen?" — the answer is always queryable.

    func buildUIStateJSON(vm: ChatViewModel) -> String {
        // Top-most presented view, in z-order. documentPicker is presented from
        // ActionsView (settings) so it's above settings; settings is above chat.
        let currentView: String
        if vm.showingDocumentPicker        { currentView = "documentPicker" }
        else if vm.showingSettings         { currentView = "settings" }
        else if vm.showingThreadPanel      { currentView = "threadPanel" }
        else                                { currentView = "chat" }

        let renderedMessages = vm.messages
        let partialMessages = renderedMessages.filter { $0.isPartial }
        let lastPartial = partialMessages.last
        let partialContent = lastPartial.map { jsonStringEscape(String($0.content.prefix(500))) }

        let thinkingDuration: String
        if let start = vm.thinkingStart {
            thinkingDuration = String(format: "%.2f", Date().timeIntervalSince(start))
        } else {
            thinkingDuration = "null"
        }

        let liveModelID = vm.llmService.activeModelID
        let selectedModelDisplayName = jsonStringEscape(vm.selectedModel.displayName)
        let errorMsg = vm.errorMessage.map { jsonStringEscape(String($0.prefix(500))) }
        let inputFieldText = jsonStringEscape(String(vm.currentMessage.prefix(2000)))

        let mlxLoading = vm.llmService.mlxWrapper.loadingProgress
        let mlxLoadingMessage = jsonStringEscape(vm.llmService.mlxWrapper.loadingMessage)
        let mlxIsLoaded = vm.llmService.mlxWrapper.isModelLoaded

        return """
        {
          "status": "ok",
          "currentView": "\(currentView)",
          "visibleThreadID": "\(vm.conversationId)",
          "renderedMessageCount": \(renderedMessages.count),
          "renderedPartialCount": \(partialMessages.count),
          "isAIResponding": \(vm.isAIResponding),
          "thinkingDurationSec": \(thinkingDuration),
          "aiPartialContent": \(partialContent.map { "\"\($0)\"" } ?? "null"),
          "inputFieldText": "\(inputFieldText)",
          "isSendingMessage": \(vm.isSendingMessage),
          "isModelSwitching": \(vm.isModelSwitching),
          "errorMessage": \(errorMsg.map { "\"\($0)\"" } ?? "null"),
          "showingSettings": \(vm.showingSettings),
          "showingThreadPanel": \(vm.showingThreadPanel),
          "showingDocumentPicker": \(vm.showingDocumentPicker),
          "selectedModelID": "\(jsonStringEscape(vm.selectedModelID))",
          "selectedModelDisplayName": "\(selectedModelDisplayName)",
          "activeModelID": "\(jsonStringEscape(liveModelID))",
          "mlxModelLoaded": \(mlxIsLoaded),
          "mlxLoadingProgress": \(String(format: "%.2f", mlxLoading)),
          "mlxLoadingMessage": "\(mlxLoadingMessage)"
        }
        """
    }

    // Capture the current key window as a PNG, write to Documents/api_screenshots/,
    // and return the on-device path. CC test tooling pulls the file back via
    // `devicectl device file pull` (device) or reads it directly (simulator —
    // sim sandbox is reachable from the Mac).
    //
    // Runs on the main actor since UIKit's snapshotting requires it.
    @MainActor
    func captureScreenshotJSON() async -> String {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let keyWindow = scenes
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first else {
            return "{\"status\":\"error\",\"message\":\"SCREENSHOT: no key window\"}"
        }
        let bounds = keyWindow.bounds
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = keyWindow.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { ctx in
            keyWindow.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let png = image.pngData() else {
            return "{\"status\":\"error\",\"message\":\"SCREENSHOT: pngData failed\"}"
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("api_screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let file = dir.appendingPathComponent("sc_\(ts).png")
        do {
            try png.write(to: file)
        } catch {
            return "{\"status\":\"error\",\"message\":\"SCREENSHOT: write failed: \(jsonStringEscape(error.localizedDescription))\"}"
        }
        let w = Int(bounds.width), h = Int(bounds.height)
        return "{\"status\":\"ok\",\"command\":\"SCREENSHOT\",\"path\":\"\(jsonStringEscape(file.path))\",\"width\":\(w),\"height\":\(h),\"bytes\":\(png.count)}"
    }

    // Returns the most recent log entries captured by RuntimeLog. Useful for
    // diagnosing MLX/AFM generation behaviour without device-console access.
    func buildLogsJSON(limit: Int) -> String {
        let entries = RuntimeLog.shared.snapshot(limit: limit)
        let json = entries.map { "\"\(jsonStringEscape($0))\"" }.joined(separator: ",")
        return "{\"status\":\"ok\",\"count\":\(entries.count),\"logs\":[\(json)]}"
    }

    func buildRenderedMessagesJSON(vm: ChatViewModel, truncateChars: Int? = 500) -> String {
        // vm.messages is the in-memory array bound to the chat view's ForEach.
        // This is precisely what the user sees in the chat scroll. Differs from
        // GET_MESSAGES (which reads from memoryStore / SQLite) in that it:
        //   - Includes isPartial messages currently streaming
        //   - Reflects in-flight ordering before persistence
        //   - Includes per-message metadata (id, isPartial, recordedByModel, turnNumber)
        //
        // `truncateChars` caps each content field at the given length for
        // cheap observability (default 500). Pass nil to get full content
        // (used by GET_RENDERED_MESSAGES_FULL for transcript capture).
        let entries = vm.messages.map { m -> String in
            let role = m.isFromUser ? "user" : "assistant"
            let rawContent: String
            let truncated: Bool
            if let cap = truncateChars {
                rawContent = String(m.content.prefix(cap))
                truncated = m.content.count > cap
            } else {
                rawContent = m.content
                truncated = false
            }
            let content = jsonStringEscape(rawContent)
            let ts = Int(m.timestamp.timeIntervalSince1970)
            let recBy = jsonStringEscape(m.recordedByModel)
            return """
            {"id":"\(m.id.uuidString)","role":"\(role)","content":"\(content)","truncated":\(truncated),"timestamp":\(ts),"isPartial":\(m.isPartial),"recordedByModel":"\(recBy)","turnNumber":\(m.turnNumber)}
            """
        }.joined(separator: ",")
        return """
        {"status":"ok","conversationId":"\(vm.conversationId)","renderedMessageCount":\(vm.messages.count),"messages":[\(entries)]}
        """
    }

    // MARK: - Input File Channel

    private func handleInputFileChange() async {
        guard let content = try? String(contentsOf: inputFile, encoding: .utf8) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastProcessedContent else { return }
        lastProcessedContent = trimmed

        guard let vm = chatViewModel else {
            statusMessage = "Error: ChatViewModel unavailable"
            return
        }

        // Wait for any in-flight turn to complete (up to 120s)
        if vm.isAIResponding {
            var waited = 0
            while vm.isAIResponding && waited < 120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
            }
            if vm.isAIResponding {
                statusMessage = "Error: previous turn timed out"
                return
            }
        }

        turnCount += 1
        let turnNum = turnCount
        statusMessage = "Turn \(turnNum): processing…"
        print("HALDEBUG-TESTCONSOLE: Turn \(turnNum) — \"\(trimmed.prefix(60))\"")

        let startTime = Date()
        vm.currentMessage = trimmed
        await vm.sendMessage()
        let elapsed = Date().timeIntervalSince(startTime)

        let aiMessages = vm.messages.filter { !$0.isFromUser && !$0.isPartial }
        guard let lastAI = aiMessages.last else {
            statusMessage = "Turn \(turnNum): no AI response found"
            return
        }

        let json = buildOutputJSON(turn: turnNum, userMessage: trimmed, aiMessage: lastAI, elapsed: elapsed, vm: vm)
        let numberedOutput = baseDir.appendingPathComponent(String(format: "output_%04d.json", turnNum))
        try? json.write(to: outputLatestFile, atomically: true, encoding: .utf8)
        try? json.write(to: numberedOutput, atomically: true, encoding: .utf8)

        statusMessage = "Turn \(turnNum): done (\(String(format: "%.1f", elapsed))s)"
        print("HALDEBUG-TESTCONSOLE: Turn \(turnNum) complete in \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Output JSON Builder

    func buildOutputJSON(turn: Int, userMessage: String, aiMessage: ChatMessage, elapsed: TimeInterval, vm: ChatViewModel) -> String {
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

        let toolsJSON: String
        if let tools = aiMessage.toolsUsed, !tools.isEmpty {
            toolsJSON = "[" + tools.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        } else {
            toolsJSON = "[]"
        }

        let prompt = aiMessage.fullPromptUsed ?? ""
        let sections = [
            prompt.contains("#=== BEGIN SYSTEM ===#")           ? "\"system\""            : nil,
            prompt.contains("#=== BEGIN MEMORY_SHORT ===#")    ? "\"short_term_memory\""  : nil,
            prompt.contains("#=== BEGIN SUMMARY ===#")          ? "\"summary\""            : nil,
            prompt.contains("#=== BEGIN TEMPORAL_CONTEXT ===#") ? "\"temporal_context\""  : nil,
            prompt.contains("#=== BEGIN MEMORY_LONG ===#")     ? "\"rag\""                : nil,
            prompt.contains("#=== BEGIN SELF_AWARENESS ===#")  ? "\"self_awareness\""     : nil,
            prompt.contains("#=== BEGIN SELF_KNOWLEDGE ===#")  ? "\"self_knowledge\""     : nil,
        ].compactMap { $0 }.joined(separator: ", ")

        let promptContent = prompt.isEmpty ? "(not captured — check HALDEBUG-PROMPT logs)" : prompt

        return """
        {
          "turn": \(turn),
          "timestamp": "\(ISO8601DateFormatter().string(from: Date()))",
          "thinkingDuration": \(String(format: "%.2f", elapsed)),
          "model": "\(vm.selectedModel.id)",
          "selfKnowledgeEnabled": \(vm.enableSelfKnowledge),
          "salonModeEnabled": \(vm.salonConfig.isEnabled),
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

    // MARK: - JSON Helpers

    private func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func jsonStringEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Local HTTP API Server
//
// Programmatic access to Hal's pipeline for automated testing and tooling.
// Replaces file-polling with a clean synchronous HTTP interface.
//
// Endpoints (all require Authorization: Bearer <token>):
//   POST /chat      {"message": "..."}           → full diagnostic JSON
//   POST /command   {"command": "NUCLEAR_RESET"}  → JSON result
//   GET  /state                                   → settings state JSON
//
// Commands available via POST /command:
//   Model management: LIST_MODELS, DOWNLOAD_MODEL:<id>, MODEL_STATUS:<id>,
//                     SWITCH_MODEL:<id>, DELETE_MODEL:<id>, CURRENT_MODEL
//   Thread control:   NEW_THREAD, RESET_THREAD, NUCLEAR_RESET, CLEAR_TEST_DATA
//   Settings:         SET_TEMPERATURE:<f>, SET_MEMORY_DEPTH:<n>, SET_SELF_KNOWLEDGE:<bool>,
//                     SET_SIMILARITY_THRESHOLD:<f>, SET_MAX_RAG_CHARS:<n>, SET_RAG_DEDUP:<f>,
//                     SET_SYSTEM_PROMPT:<text>, SET_SYSTEM_PROMPT_STORED:<text>,
//                     CLEAR_SYSTEM_PROMPT, RESET_SETTINGS
//   Info:             GET_STATE, CURRENT_MODEL, LIST_MODELS, MODEL_STATUS:<id>
//
// Enable: Settings → Power User → Developer API toggle (default OFF).
// Setup:  python3 tests/hal_test.py setup <ip> 8766 <token>
// Port:   8766 (see apiPort comment below — per-app port family).

class LocalAPIServer {

    // Hal's API listener port. Each app in the Mark Friedlander multi-app
    // family uses its own port so multiple CC instances can each run their
    // own LocalAPIServer against the simulator (or the same Mac) without
    // colliding. Known assignments:
    //   Posey  → 8765
    //   Hal    → 8766
    // To extend: pick the next sequential port and document it here.
    static let apiPort: UInt16 = 8766

    private var listener: NWListener?
    private weak var chatViewModel: ChatViewModel?

    var isRunning: Bool { listener != nil }

    // MARK: - Token (Keychain-backed)

    private static let keychainService = "com.MarkFriedlander.Hal10000"
    private static let keychainAccount = "localAPIToken"

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
                    let token = Self.loadOrCreateToken()
                    let address = "\(LocalAPIServer.localIPAddress()):\(LocalAPIServer.apiPort)"
                    print("LocalAPI: Ready at \(address) token:\(token)")
                    DispatchQueue.main.async {
                        UIPasteboard.general.string = "\(LocalAPIServer.localIPAddress()):\(LocalAPIServer.apiPort):\(token)"
                    }
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
            respond(conn, status: 400, body: "{\"error\":\"Bad request\"}")
            return
        }
        guard req.token == apiToken else {
            respond(conn, status: 401, body: "{\"error\":\"Unauthorized\"}")
            return
        }
        let (status, body) = await route(req)
        respond(conn, status: status, body: body)
    }

    private func receiveRequest(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            var buf = Data()
            func next() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, done, err in
                    if let chunk { buf.append(chunk) }
                    if let text = String(data: buf, encoding: .utf8), text.contains("\r\n\r\n") {
                        let parts = text.components(separatedBy: "\r\n\r\n")
                        let hdr   = parts[0]
                        let body  = parts.dropFirst().joined(separator: "\r\n\r\n")
                        if let clLine = hdr.components(separatedBy: "\r\n")
                            .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                           let cl = Int(clLine.components(separatedBy: ":").last?
                                            .trimmingCharacters(in: .whitespaces) ?? "") {
                            if body.utf8.count >= cl { cont.resume(returning: buf); return }
                        } else {
                            cont.resume(returning: buf); return
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
        default:                   return (404, "{\"error\":\"Not found\"}")
        }
    }

    private func handleChat(body: Data?) async -> (Int, String) {
        guard let body,
              let json    = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = json["message"] as? String, !message.isEmpty else {
            return (400, "{\"error\":\"Missing 'message'\"}")
        }
        guard let vm = chatViewModel else {
            return (503, "{\"error\":\"ChatViewModel unavailable\"}")
        }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                var waited = 0
                while vm.isAIResponding && waited < 120 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
                guard !vm.isAIResponding else {
                    cont.resume(returning: (503, "{\"error\":\"Previous turn timed out\"}"))
                    return
                }
                let start = Date()
                vm.currentMessage = message
                await vm.sendMessage()
                let elapsed = Date().timeIntervalSince(start)
                let aiMessages = vm.messages.filter { !$0.isFromUser && !$0.isPartial }
                guard let lastAI = aiMessages.last else {
                    cont.resume(returning: (500, "{\"error\":\"No response generated\"}"))
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

    private func handleCommand(body: Data?) async -> (Int, String) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd  = json["command"] as? String, !cmd.isEmpty else {
            return (400, "{\"error\":\"Missing 'command'\"}")
        }
        guard let vm = chatViewModel else {
            return (503, "{\"error\":\"ChatViewModel unavailable\"}")
        }
        let result: String = await withCheckedContinuation { cont in
            Task { @MainActor in
                let r = await vm.testConsole.executeCommand(cmd, vm: vm)
                cont.resume(returning: r)
            }
        }
        return (200, result)
    }

    private func handleState() async -> (Int, String) {
        guard let vm = chatViewModel else {
            return (503, "{\"error\":\"ChatViewModel unavailable\"}")
        }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                let json = vm.testConsole.buildStateJSON(vm: vm)
                cont.resume(returning: (200, json))
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
