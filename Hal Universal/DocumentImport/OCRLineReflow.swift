// OCRLineReflow.swift
// Hal Universal — DocumentImport module
//
// PORTED (slimmed) from Posey's Services/Import/OCRLineReflow.swift. Kept the same
// name + public shape so future Posey improvements re-port as a near-drop-in. What's
// slimmed for Hal: the table-of-contents special-case (Posey's `isTOCContent` calls
// book-oriented TOC detectors — PDFTOCDetector / PDFGeneralizedTOCDetector — which we
// deliberately don't carry, since Hal handles personal documents, not scanned books).
// Here `isTOCContent` is a lightweight standalone heuristic; restore the full detectors
// if Hal ever wants real book-TOC handling.

import CoreGraphics
import Foundation
import Vision

// ==== LEGO START: 67 OCR Line Reflow (Vision geometry -> structure-preserving text) ====

/// Reflows Apple Vision OCR observations into text that preserves the page's LINE /
/// PARAGRAPH structure, instead of flattening every recognized line into one
/// space-joined run-on.
///
/// The signal (from Posey's empirical calibration): Vision returns one observation per
/// visual line, each with a normalized `boundingBox` (origin bottom-left). A line that
/// fills the text column to the right margin is a soft wrap -> join with a space. A line
/// that ends well short of the margin is a hard break (a form field, a heading, a
/// paragraph's final line) -> start a new paragraph. Hard breaks are emitted as `\n\n`
/// so downstream chunking treats each as its own unit; soft wraps stay in one paragraph.
enum OCRLineReflow {

    /// Fraction of PAGE width a line must reach to be treated as a soft wrap
    /// (margin-filling) rather than a hard line break.
    static let marginFillThreshold: CGFloat = 0.74

    /// Two observations whose vertical centers are within this normalized delta are
    /// treated as fragments of the SAME visual line (Vision sometimes splits a line into
    /// several horizontal boxes) and joined with a space.
    static let sameLineMidYDelta: CGFloat = 0.012

    private struct Fragment {
        let text: String
        let minX: CGFloat
        let maxX: CGFloat
        let midY: CGFloat
    }

    /// A merged visual line: same-midY fragments joined left-to-right.
    struct VisualLine {
        let text: String
        /// Right extent of the line (max fragment maxX), normalized 0-1.
        let maxX: CGFloat
    }

    /// Reflow Vision observations into structure-preserving text.
    static func reflow(_ observations: [VNRecognizedTextObservation]) -> String {
        var fragments: [Fragment] = []
        for o in observations {
            guard let candidate = o.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let box = o.boundingBox
            fragments.append(Fragment(text: text, minX: box.minX, maxX: box.maxX, midY: box.midY))
        }
        guard !fragments.isEmpty else { return "" }
        return reflowLines(mergeVisualLines(fragments))
    }

    /// Merge fragments into visual lines (group by midY, order left-to-right),
    /// top-to-bottom.
    private static func mergeVisualLines(_ fragments: [Fragment]) -> [VisualLine] {
        let sorted = fragments.sorted { a, b in
            if abs(a.midY - b.midY) < sameLineMidYDelta { return a.minX < b.minX }
            return a.midY > b.midY
        }
        var lines: [VisualLine] = []
        var curText = sorted[0].text
        var curMaxX = sorted[0].maxX
        var curMidY = sorted[0].midY
        for i in 1..<sorted.count {
            let f = sorted[i]
            if abs(f.midY - curMidY) < sameLineMidYDelta {
                curText += " " + f.text
                curMaxX = max(curMaxX, f.maxX)
            } else {
                lines.append(VisualLine(text: curText, maxX: curMaxX))
                curText = f.text; curMaxX = f.maxX; curMidY = f.midY
            }
        }
        lines.append(VisualLine(text: curText, maxX: curMaxX))
        return lines
    }

    /// Turn visual lines into structure-preserving text. A TOC-like page keeps every
    /// line as its own paragraph (list structure); a normal page uses the geometry
    /// reflow (soft wrap where a line fills the margin, hard break where it ends short).
    static func reflowLines(_ lines: [VisualLine]) -> String {
        guard !lines.isEmpty else { return "" }
        if isTOCContent(lines.map(\.text)) {
            return lines.map(\.text).joined(separator: "\n\n")
        }
        var out = lines[0].text
        for i in 1..<lines.count {
            if lines[i - 1].maxX >= marginFillThreshold {
                out += " " + lines[i].text          // soft wrap (same paragraph)
            } else {
                out += "\n\n" + lines[i].text        // hard break (new paragraph)
            }
        }
        return out
    }

    /// Lightweight standalone TOC heuristic (Hal-slimmed). Posey gates this on precise
    /// Contents-anchor + entry-density detectors; here we only catch the obvious case (a
    /// "Contents"/"Table of Contents" heading with several dot-leader lines) so a list
    /// page isn't reflowed into a run-on. Good enough for personal docs; the richer
    /// detectors can be ported later.
    static func isTOCContent(_ lines: [String]) -> Bool {
        let blob = lines.joined(separator: "\n")
        let lower = blob.lowercased()
        guard lower.contains("contents") else { return false }
        // Count lines that look like TOC entries: a dot leader (". . ." or "…") or a
        // trailing page number.
        let entryLike = lines.filter { line in
            line.contains("....") || line.contains("…")
                || line.range(of: #"\s\d{1,4}$"#, options: .regularExpression) != nil
        }
        return entryLike.count >= 3
    }
}

// ==== LEGO END: 67 OCR Line Reflow (Vision geometry -> structure-preserving text) ====
