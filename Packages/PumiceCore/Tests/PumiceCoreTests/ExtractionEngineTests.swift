import Foundation
import Testing
@testable import PumiceCore

@Suite("ExtractionEngine")
struct ExtractionEngineTests {
    private static let now = MarkdownSerializer.parseISO("2026-05-24T15:00:00Z")!
    private static let later = MarkdownSerializer.parseISO("2026-06-01T10:00:00Z")!

    private static let uuidA = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let uuidB = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!

    private static let idA1 = AnnotationID(pageIndex: 1, annotationUUID: uuidA)
    private static let idB7 = AnnotationID(pageIndex: 7, annotationUUID: uuidB)

    private static func ann(
        _ id: AnnotationID,
        text: String = "text",
        color: HighlightColor = .yellow,
        note: String? = nil
    ) -> Annotation {
        Annotation(id: id, extractedText: text, color: color, attachedNote: note)
    }

    @Test("First extraction (no existing file) emits frontmatter and one section")
    func firstExtraction() {
        let annotation = Self.ann(Self.idA1, text: "hello", color: .yellow)
        let result = ExtractionEngine.reconcile(
            existingMarkdown: nil,
            annotations: [annotation],
            sourceFilename: "Thesis.pdf",
            scheme: .obsidian(vaultName: "V"),
            now: Self.now
        )
        #expect(result.summary.new == [Self.idA1])
        #expect(result.summary.modified.isEmpty)
        #expect(result.summary.removed.isEmpty)
        #expect(result.markdown.contains(#"source: "Thesis.pdf""#))
        #expect(result.markdown.contains(#"last_extracted: "2026-05-24T15:00:00Z""#))
        #expect(result.markdown.contains("## Extraction: 2026-05-24T15:00:00Z"))
        #expect(result.markdown.contains("> hello"))
    }

    @Test("All-unchanged returns existing markdown verbatim")
    func unchangedIsNoOp() {
        let existing = ExtractionEngine.reconcile(
            existingMarkdown: nil,
            annotations: [Self.ann(Self.idA1, text: "hi")],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.now
        ).markdown

        let again = ExtractionEngine.reconcile(
            existingMarkdown: existing,
            annotations: [Self.ann(Self.idA1, text: "hi")],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(again.markdown == existing)
        #expect(again.summary.hasChanges == false)
        #expect(again.summary.unchanged == [Self.idA1])
    }

    @Test("New annotation appended as a new Extraction section")
    func newAnnotationAppended() {
        let existing = ExtractionEngine.reconcile(
            existingMarkdown: nil,
            annotations: [Self.ann(Self.idA1, text: "first")],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.now
        ).markdown

        let result = ExtractionEngine.reconcile(
            existingMarkdown: existing,
            annotations: [
                Self.ann(Self.idA1, text: "first"),
                Self.ann(Self.idB7, text: "fresh")
            ],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(result.summary.new == [Self.idB7])
        #expect(result.summary.unchanged == [Self.idA1])
        // First section still present, new section appended.
        #expect(result.markdown.contains("## Extraction: 2026-05-24T15:00:00Z"))
        #expect(result.markdown.contains("## Extraction: 2026-06-01T10:00:00Z"))
        #expect(result.markdown.contains("> fresh"))
        // last_extracted updated.
        #expect(result.markdown.contains(#"last_extracted: "2026-06-01T10:00:00Z""#))
    }

    @Test("Modified annotation appended; existing block unchanged")
    func modifiedAppendedHistoryPreserved() {
        let existing = ExtractionEngine.reconcile(
            existingMarkdown: nil,
            annotations: [Self.ann(Self.idA1, text: "original", color: .yellow)],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.now
        ).markdown

        let result = ExtractionEngine.reconcile(
            existingMarkdown: existing,
            annotations: [Self.ann(Self.idA1, text: "revised", color: .green)],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(result.summary.modified == [Self.idA1])
        // Original block lives on in the file.
        #expect(result.markdown.contains("> original"))
        // Plus the revised block has been appended.
        #expect(result.markdown.contains("> revised"))
        #expect(result.markdown.contains("#highlight/green"))
    }

    @Test("Note-only change triggers modification")
    func noteChangeIsModification() {
        let existing = ExtractionEngine.reconcile(
            existingMarkdown: nil,
            annotations: [Self.ann(Self.idA1, text: "t", color: .yellow, note: "original note")],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.now
        ).markdown

        let result = ExtractionEngine.reconcile(
            existingMarkdown: existing,
            annotations: [Self.ann(Self.idA1, text: "t", color: .yellow, note: "new note")],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(result.summary.modified == [Self.idA1])
        #expect(result.markdown.contains("> *Note:* original note"))
        #expect(result.markdown.contains("> *Note:* new note"))
    }

    @Test("Removed annotation appended to Removed in this sync section")
    func removedSectionAppended() {
        let existing = ExtractionEngine.reconcile(
            existingMarkdown: nil,
            annotations: [
                Self.ann(Self.idA1, text: "alpha"),
                Self.ann(Self.idB7, text: "beta")
            ],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.now
        ).markdown

        let result = ExtractionEngine.reconcile(
            existingMarkdown: existing,
            annotations: [Self.ann(Self.idA1, text: "alpha")],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(result.summary.removed == [Self.idB7])
        #expect(result.markdown.contains("## Removed in this sync: 2026-06-01T10:00:00Z"))
        #expect(result.markdown.contains("- ^\(Self.idB7.stringValue)"))
        // Removed annotation's original content is still in the file.
        #expect(result.markdown.contains("> beta"))
    }

    @Test("Mixed diff: new + modified + removed in one reconcile")
    func mixedDiff() {
        let idC = AnnotationID(pageIndex: 4, annotationUUID: UUID(
            uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        )!)
        let existing = ExtractionEngine.reconcile(
            existingMarkdown: nil,
            annotations: [
                Self.ann(Self.idA1, text: "keep me"),
                Self.ann(Self.idB7, text: "delete me")
            ],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.now
        ).markdown

        let result = ExtractionEngine.reconcile(
            existingMarkdown: existing,
            annotations: [
                Self.ann(Self.idA1, text: "edited keep"),  // modified
                Self.ann(idC, text: "added")          // new
            ],
            sourceFilename: "f.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(result.summary.new == [idC])
        #expect(result.summary.modified == [Self.idA1])
        #expect(result.summary.removed == [Self.idB7])
        #expect(result.summary.unchanged.isEmpty)
        #expect(result.markdown.contains("> edited keep"))
        #expect(result.markdown.contains("> added"))
        #expect(result.markdown.contains("- ^\(Self.idB7.stringValue)"))
    }

    @Test("Unknown frontmatter keys are preserved across reconciliations")
    func unknownFrontmatterPreserved() {
        let withCustom = """
        ---
        source: "Thesis.pdf"
        last_extracted: "2026-05-24T15:00:00Z"
        my_topic: "queer-kinship"
        ---

        """
        let result = ExtractionEngine.reconcile(
            existingMarkdown: withCustom,
            annotations: [Self.ann(Self.idA1, text: "new")],
            sourceFilename: "Thesis.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(result.markdown.contains(#"my_topic: "queer-kinship""#))
        // last_extracted updated.
        #expect(result.markdown.contains(#"last_extracted: "2026-06-01T10:00:00Z""#))
    }

    @Test("source frontmatter is inserted when missing from existing file")
    func sourceInsertedIfMissing() {
        let withoutSource = """
        ---
        last_extracted: "2026-05-24T15:00:00Z"
        ---

        """
        let result = ExtractionEngine.reconcile(
            existingMarkdown: withoutSource,
            annotations: [Self.ann(Self.idA1, text: "x")],
            sourceFilename: "Recovered.pdf",
            scheme: .file,
            now: Self.later
        )
        #expect(result.markdown.contains(#"source: "Recovered.pdf""#))
    }
}
