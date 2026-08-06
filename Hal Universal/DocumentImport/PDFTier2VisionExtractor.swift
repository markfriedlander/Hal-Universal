// PDFTier2VisionExtractor.swift
// Hal Universal — DocumentImport module
//
// PORTED (slimmed) from Posey's Services/Import/PDFTier12Reconciler.swift (the
// PDFTier2VisionExtractor half). Same name + `extract(_:)` shape so future Posey
// improvements re-port cleanly. Slimmed for Hal: dropped `PDFWatermarkStripper`
// (Posey strips ChmMagic / Calibre / Aspose converter watermarks that appear in
// pirated-book PDFs; personal documents don't carry them). Everything else — the
// render parameters, the confidence floor, and the jetsam-safe autoreleasepool — is
// carried over verbatim.

import CoreGraphics
import Foundation
import PDFKit
import Vision

// ==== LEGO START: 68 PDF Tier-2 Vision OCR Extractor (render + recognize) ====

/// Runs Apple Vision OCR on a rendered PDF page. Used by `TieredPDFExtractor` when a
/// page's text layer is empty or too thin (a scanned or image page). The per-page cost
/// is ~1s, so callers only invoke it on pages that actually need it.
struct PDFTier2VisionExtractor {

    /// Average Vision confidence required to accept the output. Below this the page is
    /// treated as garbled and the caller keeps whatever the text layer had.
    static let minAvgConfidence: Float = 0.75

    /// Render scale. 4x of 72 DPI = 288 DPI, within Vision's recommended OCR range.
    /// Higher wastes memory for negligible accuracy gain on most documents.
    static let renderScale: CGFloat = 4.0

    /// Run Vision OCR on the page. Returns structure-preserving recognized text (via
    /// `OCRLineReflow`), or an empty string on render failure, Vision failure, no
    /// observations, or sub-confidence output.
    ///
    /// Wrapped in `autoreleasepool` so the rendered CGImage + Vision observations drain
    /// after each per-page call. Without it, long scanned imports blew past the iOS
    /// jetsam ceiling and the app was killed mid-import (Posey, iPhone 16 Plus).
    static func extract(_ page: PDFPage) -> String {
        autoreleasepool {
            guard let image = render(page) else { return "" }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }

            let observations = request.results ?? []
            let candidates = observations.compactMap { $0.topCandidates(1).first }
            guard !candidates.isEmpty else { return "" }

            let avg = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
            guard avg >= minAvgConfidence else { return "" }

            // Reflow by line geometry rather than flattening every recognized line into a
            // space-joined run-on, so forms/letters keep their line and paragraph breaks.
            return OCRLineReflow.reflow(observations)
        }
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(1, Int(bounds.width * renderScale))
        let height = max(1, Int(bounds.height * renderScale))

        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: renderScale, y: renderScale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

// ==== LEGO END: 68 PDF Tier-2 Vision OCR Extractor (render + recognize) ====
