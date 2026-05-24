import Foundation

/// Outcome of reconciling current PDF annotations against an existing
/// extraction Markdown file.
public struct ReconciliationResult: Sendable {
    /// New Markdown content to write to disk. Identical to the input when
    /// there are no changes.
    public let markdown: String
    public let summary: Summary

    public struct Summary: Sendable, Hashable {
        public let new: Set<AnnotationID>
        public let modified: Set<AnnotationID>
        public let removed: Set<AnnotationID>
        public let unchanged: Set<AnnotationID>

        public var hasChanges: Bool {
            !new.isEmpty || !modified.isEmpty || !removed.isEmpty
        }
    }
}

/// Reconciles the current set of PDF annotations against a previously
/// generated extraction Markdown file, following the PRD's F05 rules:
///   * Unchanged IDs are ignored.
///   * New and modified IDs are appended as a new `## Extraction:` section.
///   * Removed IDs are appended to a `## Removed in this sync:` section.
///   * Existing body content is preserved verbatim — the file accumulates
///     history rather than overwriting it.
///   * Frontmatter `last_extracted` is updated; unknown keys are preserved.
public enum ExtractionEngine {
    public static func reconcile(
        existingMarkdown: String?,
        annotations: [Annotation],
        sourceFilename: String,
        scheme: URIScheme,
        now: Date = Date()
    ) -> ReconciliationResult {
        let currentByID = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })

        if let existing = existingMarkdown {
            return reconcileExisting(
                existing: existing,
                currentByID: currentByID,
                sourceFilename: sourceFilename,
                scheme: scheme,
                now: now
            )
        }

        // First extraction — emit a fresh file.
        let frontmatter = [
            FrontmatterEntry(key: "source", value: sourceFilename),
            FrontmatterEntry(key: "last_extracted", value: MarkdownSerializer.isoString(now))
        ]
        let sorted = sortForOutput(annotations)
        let section = MarkdownSerializer.renderExtractionSection(
            timestamp: now,
            annotations: sorted,
            pdfFilename: sourceFilename,
            scheme: scheme
        )
        let markdown = MarkdownSerializer.renderFrontmatter(frontmatter) + "\n" + section
        return ReconciliationResult(
            markdown: markdown,
            summary: ReconciliationResult.Summary(
                new: Set(currentByID.keys),
                modified: [],
                removed: [],
                unchanged: []
            )
        )
    }

    private static func reconcileExisting(
        existing: String,
        currentByID: [AnnotationID: Annotation],
        sourceFilename: String,
        scheme: URIScheme,
        now: Date
    ) -> ReconciliationResult {
        let parsed = MarkdownParser.parse(existing)
        let existingMap = parsed.latestByID

        var newIDs: Set<AnnotationID> = []
        var modifiedIDs: Set<AnnotationID> = []
        var unchangedIDs: Set<AnnotationID> = []
        var toAppend: [Annotation] = []

        for (id, ann) in currentByID {
            if let prev = existingMap[id] {
                if prev.extractedText == ann.extractedText,
                   prev.color == ann.color,
                   prev.attachedNote == ann.attachedNote {
                    unchangedIDs.insert(id)
                } else {
                    modifiedIDs.insert(id)
                    toAppend.append(ann)
                }
            } else {
                newIDs.insert(id)
                toAppend.append(ann)
            }
        }

        let removedIDs = Set(existingMap.keys).subtracting(currentByID.keys)

        let summary = ReconciliationResult.Summary(
            new: newIDs,
            modified: modifiedIDs,
            removed: removedIDs,
            unchanged: unchangedIDs
        )

        if !summary.hasChanges {
            return ReconciliationResult(markdown: existing, summary: summary)
        }

        let updatedFrontmatter = updatingLastExtracted(
            parsed.frontmatter,
            sourceFilename: sourceFilename,
            now: now
        )

        let appendix = buildAppendix(
            toAppend: sortForOutput(toAppend),
            removedIDs: removedIDs,
            sourceFilename: sourceFilename,
            scheme: scheme,
            now: now
        )

        let frontmatterText = MarkdownSerializer.renderFrontmatter(updatedFrontmatter)
        let body = normalizedBody(parsed.body)
        let markdown = frontmatterText + body + appendix
        return ReconciliationResult(markdown: markdown, summary: summary)
    }

    private static func updatingLastExtracted(
        _ entries: [FrontmatterEntry],
        sourceFilename: String,
        now: Date
    ) -> [FrontmatterEntry] {
        var out = entries
        let stamp = FrontmatterEntry(
            key: "last_extracted",
            value: MarkdownSerializer.isoString(now)
        )
        if let idx = out.firstIndex(where: { $0.key == "last_extracted" }) {
            out[idx] = stamp
        } else {
            out.append(stamp)
        }
        if !out.contains(where: { $0.key == "source" }) {
            out.insert(
                FrontmatterEntry(key: "source", value: sourceFilename),
                at: 0
            )
        }
        return out
    }

    private static func buildAppendix(
        toAppend: [Annotation],
        removedIDs: Set<AnnotationID>,
        sourceFilename: String,
        scheme: URIScheme,
        now: Date
    ) -> String {
        var out = ""
        if !toAppend.isEmpty {
            let section = MarkdownSerializer.renderExtractionSection(
                timestamp: now,
                annotations: toAppend,
                pdfFilename: sourceFilename,
                scheme: scheme
            )
            out += "\n" + section
        }
        if !removedIDs.isEmpty {
            let sortedRemoved = removedIDs.sorted { $0.stringValue < $1.stringValue }
            let section = MarkdownSerializer.renderRemovedSection(
                timestamp: now,
                removedIDs: sortedRemoved
            )
            out += "\n" + section
        }
        return out
    }

    /// Ensure the existing body ends with exactly one trailing newline so the
    /// appended section starts on a fresh line.
    private static func normalizedBody(_ body: String) -> String {
        var out = body
        while out.hasSuffix("\n\n") { out.removeLast() }
        if !out.isEmpty, !out.hasSuffix("\n") { out.append("\n") }
        return out
    }

    private static func sortForOutput(_ annotations: [Annotation]) -> [Annotation] {
        annotations.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.id.shortHash < $1.id.shortHash
        }
    }
}
