// HTMLTextExtractor.swift
// Hal Universal — DocumentImport module
//
// Real HTML text extraction. Hal used to feed the raw file straight into RAG, tags and
// all (`<html><body><p>...`), which is garbage to reason over. This pulls readable prose
// out of an HTML document: it drops the non-content elements (script/style/head/comments),
// turns block-level boundaries into line breaks so structure survives, strips the
// remaining tags, and decodes HTML entities.
//
// Deliberately a lightweight standalone stripper (not NSAttributedString's HTML importer,
// which is main-thread-only and pulls in WebKit, and not Posey's much larger structure-
// preserving HTMLDocumentImporter). Good enough to give the LLM clean text to converse
// over; the richer importer can be ported later if a real need shows up.

import Foundation

// ==== LEGO START: 70 HTML Text Extractor (tag-stripping readable text) ====

enum HTMLTextExtractor {

    /// Read an HTML file and return readable plain text. Auto-detects the file's encoding
    /// (HTML in the wild is often Latin-1 / Windows-1252, not UTF-8), falling back to UTF-8.
    /// Returns nil only if the file can't be read as text at all.
    static func extract(from url: URL) -> String? {
        var used: String.Encoding = .utf8
        let raw: String
        if let s = try? String(contentsOf: url, usedEncoding: &used) {
            raw = s
        } else if let s = try? String(contentsOf: url, encoding: .utf8) {
            raw = s
        } else if let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
            raw = s
        } else {
            return nil
        }
        let text = plainText(fromHTML: raw)
        return text.isEmpty ? nil : text
    }

    /// Convert an HTML string to readable plain text.
    static func plainText(fromHTML html: String) -> String {
        var s = html

        // 1. Drop whole non-content elements (script, style, head, noscript, svg) and comments.
        for tag in ["script", "style", "head", "noscript", "svg"] {
            s = removingElement(tag, from: s)
        }
        s = replacingRegex(#"<!--.*?-->"#, in: s, with: " ", dotAll: true)

        // 2. Turn block-level boundaries into newlines so paragraphs/headings/list items and
        //    table rows don't run together once the tags are gone. <br> -> single newline;
        //    the block closers/openers -> paragraph break.
        s = replacingRegex(#"<br\s*/?>"#, in: s, with: "\n")
        let blockBoundary = #"</?(p|div|section|article|header|footer|h[1-6]|ul|ol|li|tr|table|blockquote|pre|figure|figcaption|main|nav|aside|hr)(\s[^>]*)?>"#
        s = replacingRegex(blockBoundary, in: s, with: "\n\n")

        // 3. Strip all remaining tags.
        s = replacingRegex(#"<[^>]+>"#, in: s, with: "")

        // 4. Decode entities.
        s = decodingEntities(s)

        // 5. Collapse whitespace: trim each line, drop runs of spaces/tabs, cap blank runs
        //    at one blank line, so the result reads as clean paragraphs.
        s = replacingRegex(#"[ \t\u{00A0}]+"#, in: s, with: " ")
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append("") }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Remove `<tag ...>...</tag>` blocks entirely (case-insensitive, spanning newlines).
    private static func removingElement(_ tag: String, from s: String) -> String {
        replacingRegex("<\(tag)(\\s[^>]*)?>.*?</\(tag)\\s*>", in: s, with: " ", dotAll: true)
    }

    private static func replacingRegex(_ pattern: String, in s: String, with repl: String, dotAll: Bool = false) -> String {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: repl)
    }

    /// Decode the HTML entities that actually show up in prose: the five named XML
    /// entities, common typographic ones, `&nbsp;`, and numeric (`&#160;` / `&#xA0;`).
    private static func decodingEntities(_ s: String) -> String {
        var result = s
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
            "&mdash;": "-", "&ndash;": "-", "&hellip;": "...",
            "&rsquo;": "'", "&lsquo;": "'", "&ldquo;": "\"", "&rdquo;": "\"",
            "&copy;": "(c)", "&reg;": "(r)", "&trade;": "(tm)", "&deg;": " degrees"
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric entities: decimal (&#160;) and hex (&#xA0;).
        result = replacingNumericEntities(result)
        return result
    }

    private static func replacingNumericEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = ns.substring(with: m.range(at: 1))
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                out += String(scalar)
            } else {
                out += ns.substring(with: m.range) // leave it as-is if it doesn't decode
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

// ==== LEGO END: 70 HTML Text Extractor (tag-stripping readable text) ====
