import Foundation
import Testing
@testable import PumiceCore

@Suite("URIScheme")
struct URISchemeTests {
    @Test("Obsidian scheme encodes vault and filename, appends page fragment")
    func obsidianBasic() {
        let scheme = URIScheme.obsidian(vaultName: "Polivoxia")
        let link = scheme.link(pageNumber: 12, pdfFilename: "Thesis.pdf")
        #expect(link == "obsidian://open?vault=Polivoxia&file=Thesis.pdf#page=12")
    }

    @Test("Obsidian scheme percent-encodes spaces and reserved characters")
    func obsidianEncoding() {
        let scheme = URIScheme.obsidian(vaultName: "My Vault")
        let link = scheme.link(pageNumber: 3, pdfFilename: "A & B (notes).pdf")
        #expect(link.contains("vault=My%20Vault"))
        #expect(link.contains("file=A%20%26%20B%20(notes).pdf"))
        #expect(link.hasSuffix("#page=3"))
    }

    @Test("File scheme produces a relative reference with page fragment")
    func fileBasic() {
        let link = URIScheme.file.link(pageNumber: 5, pdfFilename: "doc.pdf")
        #expect(link == "doc.pdf#page=5")
    }

    @Test("File scheme percent-encodes spaces")
    func fileEncoding() {
        let link = URIScheme.file.link(pageNumber: 1, pdfFilename: "my file.pdf")
        #expect(link == "my%20file.pdf#page=1")
    }
}

@Suite("HighlightColor")
struct HighlightColorTests {
    @Test("All five PRD colours are present")
    func allCases() {
        let slugs = HighlightColor.allCases.map(\.slug)
        #expect(slugs == ["yellow", "green", "blue", "red", "purple"])
    }

    @Test("Slug round-trips through init")
    func slugRoundTrip() {
        for color in HighlightColor.allCases {
            #expect(HighlightColor(slug: color.slug) == color)
        }
    }

    @Test("Unknown slug yields nil")
    func unknownSlug() {
        #expect(HighlightColor(slug: "magenta") == nil)
    }
}
