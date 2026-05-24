import Foundation
import Testing
@testable import PumiceCore

@Suite("MarkdownParser")
struct MarkdownParserTests {
    private static let id = AnnotationID(
        pageIndex: 11,
        annotationUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    @Test("Parses frontmatter into ordered FrontmatterEntry list")
    func frontmatter() {
        let md = """
        ---
        source: "Thesis.pdf"
        last_extracted: "2026-05-24T15:00:00Z"
        my_custom: "preserve me"
        ---

        body
        """
        let parsed = MarkdownParser.parse(md)
        #expect(parsed.frontmatter.map(\.key) == ["source", "last_extracted", "my_custom"])
        #expect(parsed.frontmatter[0].value == "Thesis.pdf")
        #expect(parsed.frontmatter[2].value == "preserve me")
    }

    @Test("Frontmatter values are unescaped on parse")
    func unescape() {
        let md = """
        ---
        weird: "he said \\"yes\\" \\\\o/"
        ---

        """
        let parsed = MarkdownParser.parse(md)
        #expect(parsed.frontmatter.first?.value == #"he said "yes" \o/"#)
    }

    @Test("No frontmatter leaves body intact")
    func noFrontmatter() {
        let md = "just a body line\nanother"
        let parsed = MarkdownParser.parse(md)
        #expect(parsed.frontmatter.isEmpty)
        #expect(parsed.body == md)
    }

    @Test("Parses a single annotation block emitted by the serializer")
    func parseSingleBlock() {
        let annotation = Annotation(
            id: Self.id, extractedText: "The quote.", color: .yellow, attachedNote: "Note text."
        )
        let block = MarkdownSerializer.renderBlock(
            annotation, pdfFilename: "Thesis.pdf", scheme: .obsidian(vaultName: "V")
        )
        let parsed = MarkdownParser.parse(block)
        #expect(parsed.entries.count == 1)
        let entry = parsed.entries[0]
        #expect(entry.id == Self.id)
        #expect(entry.extractedText == "The quote.")
        #expect(entry.color == .yellow)
        #expect(entry.attachedNote == "Note text.")
    }

    @Test("Parses multi-line text annotation")
    func parseMultiLineText() {
        let annotation = Annotation(
            id: Self.id,
            extractedText: "First line.\nSecond line.\nThird line.",
            color: .blue
        )
        let block = MarkdownSerializer.renderBlock(
            annotation, pdfFilename: "f.pdf", scheme: .file
        )
        let parsed = MarkdownParser.parse(block)
        #expect(parsed.entries.first?.extractedText == "First line.\nSecond line.\nThird line.")
    }

    @Test("Block without a Note line parses with nil attachedNote")
    func noNote() {
        let annotation = Annotation(
            id: Self.id, extractedText: "t", color: .red, attachedNote: nil
        )
        let block = MarkdownSerializer.renderBlock(
            annotation, pdfFilename: "f.pdf", scheme: .file
        )
        let parsed = MarkdownParser.parse(block)
        #expect(parsed.entries.first?.attachedNote == nil)
    }

    @Test("Multiple blocks separated by a blank line are all parsed")
    func multipleBlocks() {
        let id2 = AnnotationID(pageIndex: 3, annotationUUID: UUID())
        let a1 = Annotation(id: Self.id, extractedText: "one", color: .yellow)
        let a2 = Annotation(id: id2, extractedText: "two", color: .green)
        let combined = MarkdownSerializer.renderBlock(a1, pdfFilename: "f.pdf", scheme: .file)
            + "\n\n"
            + MarkdownSerializer.renderBlock(a2, pdfFilename: "f.pdf", scheme: .file)
        let parsed = MarkdownParser.parse(combined)
        #expect(parsed.entries.map(\.id) == [Self.id, id2])
    }

    @Test("latestByID returns the last occurrence for each ID")
    func latestByIDWins() {
        let a1 = Annotation(id: Self.id, extractedText: "original", color: .yellow)
        let a2 = Annotation(id: Self.id, extractedText: "revised", color: .green)
        let combined = MarkdownSerializer.renderBlock(a1, pdfFilename: "f.pdf", scheme: .file)
            + "\n\n"
            + MarkdownSerializer.renderBlock(a2, pdfFilename: "f.pdf", scheme: .file)
        let parsed = MarkdownParser.parse(combined)
        let latest = parsed.latestByID[Self.id]
        #expect(latest?.extractedText == "revised")
        #expect(latest?.color == .green)
    }

    @Test("Non-callout lines are ignored when finding blocks")
    func ignoresProse() {
        let md = """
        Some preamble.

        ## Extraction: 2026-05-24T15:00:00Z

        > The quote.
        > [Page 12](file.pdf#page=12) ^\(Self.id.stringValue)
        > *Tag:* #highlight/yellow

        Some other prose.
        """
        let parsed = MarkdownParser.parse(md)
        #expect(parsed.entries.count == 1)
        #expect(parsed.entries.first?.id == Self.id)
    }
}
