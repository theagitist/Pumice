import Foundation

/// Parsed representation of a Pumice extraction Markdown file. Captures
/// enough structure for the reconciler to diff (per-ID `latestByID`) while
/// preserving the original body verbatim (`body`) so the engine's
/// append-only invariant is easy to honour.
public struct ParsedDocument: Sendable, Hashable {
    public let frontmatter: [FrontmatterEntry]
    public let body: String
    public let entries: [ParsedEntry]

    public struct ParsedEntry: Sendable, Hashable {
        public let id: AnnotationID
        public let extractedText: String
        public let color: HighlightColor?
        public let attachedNote: String?
    }

    /// Last-wins lookup: per ID, the most recent `ParsedEntry` in document
    /// order. This is the canonical "current recorded state" for diffing.
    public var latestByID: [AnnotationID: ParsedEntry] {
        var map: [AnnotationID: ParsedEntry] = [:]
        for entry in entries { map[entry.id] = entry }
        return map
    }
}

public enum MarkdownParser {
    public static func parse(_ markdown: String) -> ParsedDocument {
        let lines = markdown.components(separatedBy: "\n")
        let (frontmatter, bodyStart) = parseFrontmatter(lines: lines)
        let bodyLines = bodyStart < lines.count ? Array(lines[bodyStart...]) : []
        let body = bodyLines.joined(separator: "\n")
        let entries = extractEntries(from: bodyLines)
        return ParsedDocument(frontmatter: frontmatter, body: body, entries: entries)
    }

    private static func parseFrontmatter(lines: [String]) -> ([FrontmatterEntry], Int) {
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---"
        else {
            return ([], 0)
        }
        var entries: [FrontmatterEntry] = []
        var i = 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                return (entries, i + 1)
            }
            if let entry = parseFrontmatterLine(lines[i]) {
                entries.append(entry)
            }
            i += 1
        }
        // No closing ---: treat whole input as frontmatter-less (defensive).
        return ([], 0)
    }

    private static func parseFrontmatterLine(_ line: String) -> FrontmatterEntry? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var rawValue = String(line[line.index(after: colonIdx)...])
            .trimmingCharacters(in: .whitespaces)
        if rawValue.count >= 2,
           rawValue.hasPrefix("\""),
           rawValue.hasSuffix("\"") {
            rawValue = String(rawValue.dropFirst().dropLast())
            rawValue = FrontmatterCoding.unescape(rawValue)
        }
        return FrontmatterEntry(key: key, value: rawValue)
    }

    // NSRegularExpression instead of a Swift Regex literal so the package
    // doesn't have to declare a macOS-13+ baseline for the test host.
    private static let anchorRegex: NSRegularExpression = {
        // The pattern is a compile-time constant, so the initialiser cannot
        // fail.
        try! NSRegularExpression(
            pattern: #"\^p(\d+)-([0-9a-f]{6})\b"#,
            options: []
        )
    }()

    private static func extractEntries(from lines: [String]) -> [ParsedDocument.ParsedEntry] {
        var entries: [ParsedDocument.ParsedEntry] = []
        var blockStart: Int? = nil

        for (i, line) in lines.enumerated() {
            let isCallout = line.hasPrefix(">")
            if isCallout {
                if blockStart == nil { blockStart = i }
            } else if let start = blockStart {
                if let entry = parseBlock(Array(lines[start..<i])) {
                    entries.append(entry)
                }
                blockStart = nil
            }
        }
        if let start = blockStart, let entry = parseBlock(Array(lines[start..<lines.count])) {
            entries.append(entry)
        }
        return entries
    }

    private static func parseBlock(_ block: [String]) -> ParsedDocument.ParsedEntry? {
        let inner = block.map(stripCalloutPrefix)

        var anchorIdx: Int? = nil
        var foundID: AnnotationID? = nil
        for (i, line) in inner.enumerated() {
            let fullRange = NSRange(line.startIndex..., in: line)
            guard let match = Self.anchorRegex.firstMatch(in: line, options: [], range: fullRange),
                  let pageRange = Range(match.range(at: 1), in: line),
                  let hashRange = Range(match.range(at: 2), in: line),
                  let page = Int(line[pageRange]),
                  let id = AnnotationID(stringValue: "p\(page)-\(line[hashRange])")
            else { continue }
            anchorIdx = i
            foundID = id
            break
        }
        guard let anchorIdx, let foundID else { return nil }

        let textLines = Array(inner[0..<anchorIdx])
        let extractedText = textLines.joined(separator: "\n")

        var color: HighlightColor? = nil
        var note: String? = nil
        for i in (anchorIdx + 1)..<inner.count {
            let line = inner[i]
            if let slug = parseTagLine(line) {
                color = HighlightColor(slug: slug)
            } else if let n = parseNoteLine(line) {
                note = n
            }
        }
        return ParsedDocument.ParsedEntry(
            id: foundID,
            extractedText: extractedText,
            color: color,
            attachedNote: note
        )
    }

    private static func stripCalloutPrefix(_ line: String) -> String {
        var s = Substring(line)
        if s.hasPrefix(">") { s = s.dropFirst() }
        if s.hasPrefix(" ") { s = s.dropFirst() }
        return String(s)
    }

    private static func parseTagLine(_ line: String) -> String? {
        guard line.hasPrefix("*Tag:*") else { return nil }
        let after = line.dropFirst("*Tag:*".count).trimmingCharacters(in: .whitespaces)
        guard after.hasPrefix("#highlight/") else { return nil }
        return String(after.dropFirst("#highlight/".count))
    }

    private static func parseNoteLine(_ line: String) -> String? {
        guard line.hasPrefix("*Note:*") else { return nil }
        return String(line.dropFirst("*Note:*".count)).trimmingCharacters(in: .whitespaces)
    }
}
