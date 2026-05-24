import Foundation

/// Pure rendering of Pumice's Markdown extraction format. See the PRD's
/// "Data Model & Schema" section for the template.
///
/// Format constraints applied here:
///  * Frontmatter values are double-quoted; quotes and backslashes are
///    escaped JSON-style.
///  * Multi-line `extractedText` is rendered as multiple `> `-prefixed lines
///    above the anchor line.
///  * Notes are normalized to a single line; embedded newlines are replaced
///    with spaces. This matches what the PencilKit "attach text note"
///    interaction emits in practice; multi-line notes can come back later
///    if a user-facing flow requires them.
public enum MarkdownSerializer {
    public static func renderFrontmatter(_ entries: [FrontmatterEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var out = "---\n"
        for entry in entries {
            out += "\(entry.key): \"\(FrontmatterCoding.escape(entry.value))\"\n"
        }
        out += "---\n"
        return out
    }

    public static func renderBlock(
        _ annotation: Annotation,
        pdfFilename: String,
        scheme: URIScheme
    ) -> String {
        let pageNumber = annotation.pageIndex + 1
        let link = scheme.link(pageNumber: pageNumber, pdfFilename: pdfFilename)

        var lines: [String] = []
        let textLines = annotation.extractedText
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in textLines {
            lines.append("> \(line)")
        }
        lines.append("> [Page \(pageNumber)](\(link)) ^\(annotation.id.stringValue)")
        lines.append("> *Tag:* #highlight/\(annotation.color.slug)")
        if let note = annotation.attachedNote, !note.isEmpty {
            let singleLine = note.replacingOccurrences(of: "\n", with: " ")
            lines.append("> *Note:* \(singleLine)")
        }
        return lines.joined(separator: "\n")
    }

    public static func renderExtractionSection(
        timestamp: Date,
        annotations: [Annotation],
        pdfFilename: String,
        scheme: URIScheme
    ) -> String {
        guard !annotations.isEmpty else { return "" }
        let heading = "## Extraction: \(isoString(timestamp))"
        let blocks = annotations.map {
            renderBlock($0, pdfFilename: pdfFilename, scheme: scheme)
        }
        return "\(heading)\n\n\(blocks.joined(separator: "\n\n"))\n"
    }

    public static func renderRemovedSection(
        timestamp: Date,
        removedIDs: [AnnotationID]
    ) -> String {
        guard !removedIDs.isEmpty else { return "" }
        let heading = "## Removed in this sync: \(isoString(timestamp))"
        let bullets = removedIDs.map { "- ^\($0.stringValue)" }
        return "\(heading)\n\n\(bullets.joined(separator: "\n"))\n"
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Inverse of `isoString`, for tests and round-trip parsing of headings.
    static func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
