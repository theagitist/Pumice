import Foundation
import Testing
@testable import PumiceCore

@Suite("MarkdownSerializer")
struct MarkdownSerializerTests {
    private static let id = AnnotationID(
        pageIndex: 11,
        annotationUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    @Test("Frontmatter renders with quoted values and trailing newline")
    func frontmatter() {
        let out = MarkdownSerializer.renderFrontmatter([
            FrontmatterEntry(key: "source", value: "Thesis.pdf"),
            FrontmatterEntry(key: "last_extracted", value: "2026-05-24T15:00:00Z")
        ])
        #expect(out == """
        ---
        source: "Thesis.pdf"
        last_extracted: "2026-05-24T15:00:00Z"
        ---

        """)
    }

    @Test("Empty frontmatter list yields empty string")
    func emptyFrontmatter() {
        #expect(MarkdownSerializer.renderFrontmatter([]) == "")
    }

    @Test("Frontmatter escapes embedded quotes and backslashes")
    func frontmatterEscaping() {
        let out = MarkdownSerializer.renderFrontmatter([
            FrontmatterEntry(key: "weird", value: #"he said "yes" \o/"#)
        ])
        #expect(out.contains(#""he said \"yes\" \\o/""#))
    }

    @Test("Single-line annotation block matches PRD template")
    func singleLineBlock() {
        let annotation = Annotation(
            id: Self.id,
            extractedText: "A critical sentence.",
            color: .yellow,
            attachedNote: "Important."
        )
        let block = MarkdownSerializer.renderBlock(
            annotation,
            pdfFilename: "Thesis.pdf",
            scheme: .obsidian(vaultName: "Polivoxia")
        )
        let expected = """
        > A critical sentence.
        > [Page 12](obsidian://open?vault=Polivoxia&file=Thesis.pdf#page=12) ^\(Self.id.stringValue)
        > *Tag:* #highlight/yellow
        > *Note:* Important.
        """
        #expect(block == expected)
    }

    @Test("Multi-line highlight text renders as multiple callout lines")
    func multiLineText() {
        let annotation = Annotation(
            id: Self.id,
            extractedText: "Line one.\nLine two.",
            color: .green
        )
        let block = MarkdownSerializer.renderBlock(
            annotation,
            pdfFilename: "x.pdf",
            scheme: .file
        )
        let lines = block.split(separator: "\n").map(String.init)
        #expect(lines[0] == "> Line one.")
        #expect(lines[1] == "> Line two.")
        #expect(lines[2].hasPrefix("> [Page 12]"))
        #expect(lines[3] == "> *Tag:* #highlight/green")
        // No note line.
        #expect(lines.count == 4)
    }

    @Test("Missing or empty note omits the Note line entirely")
    func omitEmptyNote() {
        let withNil = MarkdownSerializer.renderBlock(
            Annotation(id: Self.id, extractedText: "x", color: .red, attachedNote: nil),
            pdfFilename: "f.pdf",
            scheme: .file
        )
        let withEmpty = MarkdownSerializer.renderBlock(
            Annotation(id: Self.id, extractedText: "x", color: .red, attachedNote: ""),
            pdfFilename: "f.pdf",
            scheme: .file
        )
        #expect(!withNil.contains("*Note:*"))
        #expect(!withEmpty.contains("*Note:*"))
    }

    @Test("Note newlines are collapsed to spaces")
    func collapseNoteNewlines() {
        let annotation = Annotation(
            id: Self.id,
            extractedText: "t",
            color: .blue,
            attachedNote: "first\nsecond\nthird"
        )
        let block = MarkdownSerializer.renderBlock(
            annotation,
            pdfFilename: "x.pdf",
            scheme: .file
        )
        #expect(block.contains("> *Note:* first second third"))
        #expect(!block.contains("> *Note:* first\n"))
    }

    @Test("Extraction section composes heading + blocks")
    func extractionSection() {
        let stamp = MarkdownSerializer.parseISO("2026-05-24T15:00:00Z")!
        let annotation = Annotation(
            id: Self.id, extractedText: "x", color: .yellow, attachedNote: nil
        )
        let section = MarkdownSerializer.renderExtractionSection(
            timestamp: stamp,
            annotations: [annotation],
            pdfFilename: "f.pdf",
            scheme: .file
        )
        #expect(section.hasPrefix("## Extraction: 2026-05-24T15:00:00Z\n\n"))
        #expect(section.contains("> x"))
    }

    @Test("Empty annotation list yields empty extraction section")
    func emptyExtractionSection() {
        let stamp = Date(timeIntervalSince1970: 0)
        #expect(MarkdownSerializer.renderExtractionSection(
            timestamp: stamp, annotations: [], pdfFilename: "f.pdf", scheme: .file
        ) == "")
    }

    @Test("Removed section lists IDs as bullets")
    func removedSection() {
        let stamp = MarkdownSerializer.parseISO("2026-05-24T15:00:00Z")!
        let removed: [AnnotationID] = [Self.id]
        let section = MarkdownSerializer.renderRemovedSection(
            timestamp: stamp, removedIDs: removed
        )
        #expect(section.hasPrefix("## Removed in this sync: 2026-05-24T15:00:00Z\n\n"))
        #expect(section.contains("- ^\(Self.id.stringValue)"))
    }

    @Test("Empty removed list yields empty removed section")
    func emptyRemovedSection() {
        let stamp = Date(timeIntervalSince1970: 0)
        #expect(MarkdownSerializer.renderRemovedSection(
            timestamp: stamp, removedIDs: []
        ) == "")
    }
}
