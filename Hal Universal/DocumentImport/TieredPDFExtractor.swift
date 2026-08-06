// TieredPDFExtractor.swift
// Hal Universal — DocumentImport module
//
// Hal's PDF extraction orchestrator. This is the Hal-specific glue (not a Posey port):
// a deliberately simple two-tier policy in place of Posey's full page-confidence
// detector + reconciler (which do fusion repair, figure regions, and book-TOC handling
// we don't carry). For personal documents the policy that matters is: use the text
// layer when it's there, and OCR the pages that are scanned or image-only.
//
// Per page: read the PDFKit text layer (Tier 1). If it has real text, keep it. If it's
// empty or too thin (a scanned/photographed page), run Vision OCR (Tier 2) and use that.
// Each page is wrapped in its own autoreleasepool so a long scanned import stays within
// the iOS memory budget.

import Foundation
import PDFKit

// ==== LEGO START: 69 Tiered PDF Extractor (text layer + OCR fallback orchestration) ====

enum TieredPDFExtractor {

    /// A page's text layer must have at least this many non-whitespace characters to be
    /// trusted as real text. Below it, the page is treated as scanned/image and OCR'd.
    /// Tuned low so a sparse page (a form, a title page) still triggers OCR rather than
    /// being accepted as "has text" on a stray watermark or page number.
    static let minTextLayerChars = 24

    /// Extract text from a PDF, tier by tier. Returns nil ONLY when the file can't be
    /// opened as a PDF at all (damaged / protected); returns an empty string when it opens
    /// but neither the text layer nor OCR found anything (a blank or unreadable scan). The
    /// caller maps nil -> "couldn't open" and empty -> "no readable text".
    static func extract(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else {
            print("HALDEBUG-IMPORT: TieredPDF: could not open PDF at \(url.lastPathComponent)")
            return nil
        }

        var pageTexts: [String] = []
        var ocrPageCount = 0

        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }

                let tier1 = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if tier1.count >= minTextLayerChars {
                    pageTexts.append(tier1)
                    return
                }

                // Empty or thin text layer: a scanned or image-only page. OCR it.
                let tier2 = PDFTier2VisionExtractor.extract(page)
                if !tier2.isEmpty {
                    pageTexts.append(tier2)
                    ocrPageCount += 1
                } else if !tier1.isEmpty {
                    // OCR found nothing usable; keep whatever little the text layer had.
                    pageTexts.append(tier1)
                }
            }
        }

        let text = pageTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        print("HALDEBUG-IMPORT: TieredPDF: \(document.pageCount) pages, \(ocrPageCount) OCR'd, \(text.count) chars from \(url.lastPathComponent)")
        // Empty (not nil) when the PDF opened but yielded no text — the caller turns that
        // into the "no readable text" message, distinct from a can't-open failure.
        return text
    }
}

// ==== LEGO END: 69 Tiered PDF Extractor (text layer + OCR fallback orchestration) ====
