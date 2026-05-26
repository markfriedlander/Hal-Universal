// DocumentImportManager.swift
// Hal Universal
//
// Document ingest pipeline — every path by which user-provided files
// become searchable memory rows. Extracted from Hal.swift on
// 2026-05-26 as refactor #4 of the refactor-as-you-go sweep.
//
// The three LEGO blocks preserved below are this file's outline:
//
//   LEGO 27   — `DocumentImportManager` (the main pipeline). Takes
//               file URLs, dispatches by extension to the right
//               extractor (PDF via PDFKit, RTF via NSAttributedString,
//               docx via the embedded DocxParser, txt/md/csv/json/xml/
//               html via straight UTF-8 decode), runs entity
//               extraction via NaturalLanguage's NLTagger, chunks the
//               resulting text, hands chunks to MemoryStore as
//               document-source memory rows, and emits a chat-side
//               summary turn so the user sees the import landed.
//
//   LEGO 27.1 — `DocxParser`. Self-contained iOS-native docx reader:
//               a minimal pure-Swift MiniZip implementation (PKZIP
//               local-file-header walker + raw-deflate decompression
//               via libcompression) plus an XMLParser delegate that
//               extracts plain text from `word/document.xml`. Ships
//               in the app target so we don't need a third-party
//               dependency. macCatalyst used to handle docx via
//               NSAttributedString.DocumentType — that path was
//               retired in v2.0 when Hal moved off Catalyst to a
//               unified iOS build.
//
//   LEGO 28   — Value types `ProcessedDocument` and
//               `DocumentImportSummary`. The pipeline's
//               input/output records — a `ProcessedDocument` is
//               what an individual file becomes after extraction +
//               chunking + entity tagging; the summary aggregates a
//               multi-file import for UI display.
//
// Why one file: the three blocks describe one user-visible feature
// ("Hal can read a document I give it"). DocxParser is a pure utility
// with zero outward references that only DocumentImportManager calls;
// the value types are this pipeline's input/output. Splitting them
// would create a synthetic three-file unit with no reduction in
// coupling.
//
// External dependencies (all in the Hal Universal target):
//   - halLog                       — global logging (Hal.swift)
//   - ChatViewModel                — passed in to publish import
//                                    summary turns; never observed
//   - MemoryStore                  — receives stored chunks
//   - NamedEntity                  — value type defined near the top
//                                    of Hal.swift
//   - LocalAPIServer.swift         — owns the `importFromPath`
//                                    extension that calls our three
//                                    module-internal entry points
//                                    (processURLImmediatelyWithEntities,
//                                    storeDocumentsInMemoryWithEntities,
//                                    generateImportMessages). Visibility
//                                    on those three was already widened
//                                    in refactor #3.
//
// Standing rules followed here:
//   - LEGO markers preserved verbatim from Hal.swift so the
//     numbering chain still reads end-to-end when both files are
//     concatenated by sync_hal_source.sh.
//   - Comments throughout are evergreen — they explain why the code
//     looks the way it does, not when it was written.

import Foundation
import SwiftUI
import Combine
import NaturalLanguage
import PDFKit
import UniformTypeIdentifiers
import Compression  // libcompression — raw-deflate used by DocxParser/MiniZip

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
        "htm": "HTML Document",
        "docx": "Microsoft Word"
    ]

    // .doc (legacy Word binary format pre-2007) is intentionally not in
    // supportedFormats — there is no reliable iOS-native parser for it.
    // The case in processDocumentImmediatelyWithEntities() catches it
    // separately and emits a clear "save as .docx" error rather than
    // a generic unsupported-format message.

    private init() {} // Private initializer for singleton

    // Helper to check if format is supported.
    private func isFormatSupported(_ fileExtension: String) -> Bool {
        supportedFormats.keys.contains(fileExtension)
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
    // Visibility broadened from `private` to module-internal on 2026-05-26
    // when the API-helper extension that calls this method moved to
    // LocalAPIServer.swift. Still target-internal; no public surface.
    func processURLImmediatelyWithEntities(_ url: URL) async -> ([ProcessedDocument], [String]) {
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
        case legacyDocFormat(String)      // .doc binary format

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
            case .legacyDocFormat(let filename):
                return "Legacy .doc format not supported on iOS: \(filename). Please open the file in Word, Pages, or any modern editor and save as .docx, then re-import."
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
            
        case "docx":
            // Office Open XML format. A .docx file is a zip archive with
            // word/document.xml inside containing the run-text. iOS has no
            // built-in NSAttributedString reader for it (Mac AppKit can read
            // .docFormat / .officeOpenXML but iOS UIKit can't), so we do
            // the extraction ourselves with a minimal PKZIP reader (see
            // MiniZip below) + XMLParser walking <w:t> elements.
            do {
                let content = try DocxTextExtractor.extractText(from: url)
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars from DOCX")
                if content.isEmpty {
                    throw DocumentProcessingError.unsupportedFileFormat(url.lastPathComponent)
                }
                return content
            } catch {
                print("HALDEBUG-IMPORT: DOCX extraction failed: \(error.localizedDescription)")
                throw DocumentProcessingError.unsupportedFileFormat(url.lastPathComponent)
            }

        case "doc":
            // Legacy binary Word format (pre-2007). No reliable iOS-native
            // parser exists and the format is essentially obsolete — Word
            // 2007+ defaults to .docx. Tell the user how to convert.
            print("HALDEBUG-IMPORT: .doc legacy binary format rejected: \(url.lastPathComponent)")
            throw DocumentProcessingError.legacyDocFormat(url.lastPathComponent)

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
    
    // docx extraction lives in DocxTextExtractor (defined below). The macOS
    // NSAttributedString path that used to live here only worked under
    // Mac Catalyst, which we don't ship; the iOS-native zip + XML parse
    // works on iPhone, iPad, and "Designed for iPad" on Mac.

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

        // NOTE (May 12, 2026): The previous AFM-availability guard here was
        // dead defensive code — Hal's minimum deployment target is iOS 26,
        // which ships only on AFM-capable hardware, AND we now route through
        // the active model (which may be Gemma anyway). Removed the guard so
        // users in Gemma mode actually get a summary instead of just the
        // filename. Falling through to the unified path below.

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
            
            // PRIVACY FIX: Use active model from chatViewModel
            let llmService = LLMService(model: chatViewModel.selectedModel)
            // Chat-message path so chat-template models work.
            let summary = try await llmService.generateChatResponse(
                messages: [.system("You produce concise one-sentence document summaries."), .user(prompt)],
                temperature: 0.3
            )
            print("HALDEBUG-IMPORT: Generated entity-enhanced summary: \(summary)")
            return summary

        } catch {
            print("HALDEBUG-IMPORT: LLM summarization failed for \(document.filename): \(error)")
            return "Document: \(document.filename)"
        }
    }

    // ENHANCED: Store documents in unified memory with entity keywords (from Hal10000App.swift)
    // Visibility broadened from `private` to module-internal on 2026-05-26
    // (see processURLImmediatelyWithEntities for context).
    func storeDocumentsInMemoryWithEntities(_ documents: [ProcessedDocument]) async {
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
    // Visibility broadened from `private` to module-internal on 2026-05-26
    // (see processURLImmediatelyWithEntities for context).
    func generateImportMessages(documentSummaries: [String],
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


// ==== LEGO START: 27.1 DOCX Parser (MiniZip + XML text extraction) ====
//
// iOS-native .docx text extractor. A .docx file is an OPC zip archive
// containing word/document.xml; that XML's <w:t> elements hold the
// run-text. iOS UIKit has no NSAttributedString reader for .docx (only
// macOS AppKit does), so we ship our own minimal zip reader + XMLParser.
// Zero third-party dependencies — just Foundation + Compression.

import Compression

private enum MiniZipError: Error, CustomStringConvertible {
    case notAZip
    case unsupportedCompression(UInt16)
    case decompressFailed
    case zip64Unsupported
    case truncated

    var description: String {
        switch self {
        case .notAZip: return "Not a valid zip archive (no End-of-Central-Directory record)"
        case .unsupportedCompression(let m): return "Unsupported zip compression method \(m) (only Store=0 and Deflate=8 are handled)"
        case .decompressFailed: return "Deflate decompression failed"
        case .zip64Unsupported: return "ZIP64 archives not supported by MiniZip"
        case .truncated: return "Zip data truncated or central-directory entry malformed"
        }
    }
}

private struct MiniZipEntry {
    let name: String
    let compressedSize: Int
    let uncompressedSize: Int
    let method: UInt16       // 0=stored, 8=deflate
    let localHeaderOffset: Int
}

private enum MiniZip {
    // PKZIP magic numbers.
    static let eocdSignature: UInt32 = 0x06054b50
    static let centralFileHeader: UInt32 = 0x02014b50
    static let localFileHeader: UInt32 = 0x04034b50

    // Use loadUnaligned: zip multi-byte fields are NOT 4/2-byte-aligned
    // (e.g. compressedSize is at offset cdOffset+20, name lengths are
    // single bytes that shift everything). The regular `load(fromByteOffset:as:)`
    // crashes with an alignment assertion in debug builds; loadUnaligned
    // does the byte-wise read safely. Added 2026-05-19.
    static func u32(_ d: Data, _ off: Int) -> UInt32 {
        return d.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
        }
    }
    static func u16(_ d: Data, _ off: Int) -> UInt16 {
        return d.withUnsafeBytes { raw in
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
        }
    }

    /// Parse the End-of-Central-Directory record and walk the central
    /// directory entries. Returns a list of all entries with their offsets
    /// and sizes so the caller can decide which ones to actually decompress.
    static func entries(in data: Data) throws -> [MiniZipEntry] {
        guard data.count >= 22 else { throw MiniZipError.notAZip }
        // Scan the last (22 + 65535) bytes for the EOCD signature. The zip
        // comment, if any, lives between EOCD and EOF; max comment length
        // is 65535 per the spec.
        let scanStart = max(0, data.count - (22 + 65535))
        var eocdOffset: Int? = nil
        var i = data.count - 22
        while i >= scanStart {
            if u32(data, i) == eocdSignature {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw MiniZipError.notAZip }

        let totalEntries = Int(u16(data, eocd + 10))
        let centralDirOffset = Int(u32(data, eocd + 16))

        // ZIP64 sentinel — central directory offset 0xFFFFFFFF means we'd
        // need to parse the ZIP64 locator/EOCD records. Not implemented;
        // docx files never use ZIP64 (they're tens to hundreds of KB).
        if centralDirOffset == 0xFFFFFFFF { throw MiniZipError.zip64Unsupported }

        var entries: [MiniZipEntry] = []
        var cursor = centralDirOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count,
                  u32(data, cursor) == centralFileHeader else {
                throw MiniZipError.truncated
            }
            let method = u16(data, cursor + 10)
            let compressedSize = Int(u32(data, cursor + 20))
            let uncompressedSize = Int(u32(data, cursor + 24))
            let nameLen = Int(u16(data, cursor + 28))
            let extraLen = Int(u16(data, cursor + 30))
            let commentLen = Int(u16(data, cursor + 32))
            let localOffset = Int(u32(data, cursor + 42))

            // ZIP64 size sentinel — again, not implemented.
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                throw MiniZipError.zip64Unsupported
            }

            let nameStart = cursor + 46
            guard nameStart + nameLen <= data.count else { throw MiniZipError.truncated }
            let name = String(data: data.subdata(in: nameStart..<nameStart + nameLen), encoding: .utf8) ?? ""
            entries.append(MiniZipEntry(
                name: name,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                method: method,
                localHeaderOffset: localOffset
            ))
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Extract one entry's decompressed bytes from the source data.
    /// Supports stored (method 0) and deflated (method 8) entries — the
    /// only two methods Office Open XML packages use in practice.
    static func extract(_ entry: MiniZipEntry, from data: Data) throws -> Data {
        let lh = entry.localHeaderOffset
        guard lh + 30 <= data.count,
              u32(data, lh) == localFileHeader else {
            throw MiniZipError.truncated
        }
        // Local file header repeats name & extra; lengths can differ from
        // the central directory entry, so re-read here rather than reusing.
        let nameLen = Int(u16(data, lh + 26))
        let extraLen = Int(u16(data, lh + 28))
        let dataStart = lh + 30 + nameLen + extraLen
        let dataEnd = dataStart + entry.compressedSize
        guard dataEnd <= data.count else { throw MiniZipError.truncated }
        let payload = data.subdata(in: dataStart..<dataEnd)

        switch entry.method {
        case 0:
            return payload
        case 8:
            // Apple's Compression framework's COMPRESSION_ZLIB is "raw
            // deflate" (no zlib RFC 1950 header) — exactly what zip
            // stores. Output buffer sized to uncompressedSize + 1KB pad.
            let outSize = max(entry.uncompressedSize + 1024, 64 * 1024)
            var out = Data(count: outSize)
            let written: Int = payload.withUnsafeBytes { srcRaw in
                let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                return out.withUnsafeMutableBytes { dstRaw in
                    let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                    return compression_decode_buffer(dst, outSize, src, payload.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { throw MiniZipError.decompressFailed }
            return out.prefix(written)
        default:
            throw MiniZipError.unsupportedCompression(entry.method)
        }
    }
}

enum DocxParseError: Error, LocalizedError {
    case notADocx
    case documentXmlMissing
    case xmlParseFailed(String?)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .notADocx: return "Not a valid .docx archive."
        case .documentXmlMissing: return ".docx is missing word/document.xml."
        case .xmlParseFailed(let msg): return "Failed to parse word/document.xml: \(msg ?? "unknown error")."
        case .readFailed(let msg): return "Failed to read .docx file: \(msg)."
        }
    }
}

/// Extracts the run-text from a .docx file's word/document.xml. Whitespace
/// is preserved approximately: each `<w:p>` paragraph becomes a `\n`,
/// each `<w:br/>` becomes a `\n`, each `<w:tab/>` becomes a `\t`, and
/// adjacent `<w:t>` runs concatenate without space. Tables, headers,
/// footers, comments, and tracked-changes content are intentionally not
/// included — the chat-import use case wants the body text. If the use
/// case expands later, parse word/header*.xml / word/footer*.xml /
/// word/tables/* the same way.
final class DocxTextExtractor: NSObject, XMLParserDelegate {
    static func extractText(from url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw DocxParseError.readFailed(error.localizedDescription)
        }
        let entries: [MiniZipEntry]
        do { entries = try MiniZip.entries(in: data) } catch {
            throw DocxParseError.notADocx
        }
        guard let docEntry = entries.first(where: { $0.name == "word/document.xml" }) else {
            throw DocxParseError.documentXmlMissing
        }
        let xmlData: Data
        do { xmlData = try MiniZip.extract(docEntry, from: data) } catch {
            throw DocxParseError.xmlParseFailed("\(error)")
        }
        let extractor = DocxTextExtractor()
        let parser = XMLParser(data: xmlData)
        parser.delegate = extractor
        guard parser.parse() else {
            throw DocxParseError.xmlParseFailed(parser.parserError?.localizedDescription)
        }
        // Collapse runs of 3+ newlines (from nested paragraph wrappers)
        // down to a paragraph break. Trim outer whitespace.
        let collapsed = extractor.buffer
            .replacingOccurrences(of: "\n\n\n", with: "\n\n", options: .literal)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    private var buffer = ""
    private var insideRunText = false

    /// Local element name regardless of namespace prefix. XMLParser
    /// without `.shouldProcessNamespaces` reports qualified names like
    /// "w:t"; this strips the prefix.
    private func localName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...])
        }
        return elementName
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "t":
            insideRunText = true
        case "tab":
            buffer += "\t"
        case "br":
            buffer += "\n"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideRunText {
            buffer += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(elementName) {
        case "t":
            insideRunText = false
        case "p":
            // Paragraph end: newline separator.
            buffer += "\n"
        default:
            break
        }
    }
}

// ==== LEGO END: 27.1 DOCX Parser ====



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
