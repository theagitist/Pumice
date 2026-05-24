import CoreGraphics
import Foundation
import PDFKit
import PumiceCore
@testable import Pumice
import Testing
import UIKit

/// Integration tests for the snap-to-text flow in the live reader: given a
/// PDF with selectable text, a pencil gesture that crosses some of it
/// should produce a `/Subtype /Highlight` annotation matching the
/// underlying text — not freehand ink.
@Suite("F03 snap-to-text")
@MainActor
struct SnapToTextTests {
    @Test("Gesture across text snaps to a /Highlight annotation with the right metadata")
    func gestureAcrossTextSnaps() throws {
        let phrase = "PUMICE SNAP TEST"
        let document = try #require(makeTextPDF(text: phrase))
        let page = try #require(document.page(at: 0))

        // Find where PDFKit lays out the text so the gesture endpoints land
        // inside its bounding rect.
        let fullPage = page.bounds(for: .mediaBox)
        let allText = try #require(page.selection(for: fullPage))
        let textBounds = allText.bounds(for: page)
        try #require(textBounds.width > 0)
        try #require(textBounds.height > 0)

        let from = CGPoint(x: textBounds.minX + 1, y: textBounds.midY)
        let to = CGPoint(x: textBounds.maxX - 1, y: textBounds.midY)

        let annotation = try #require(PDFReaderViewController.buildSnapAnnotation(
            firstPagePoint: from,
            lastPagePoint: to,
            on: page,
            pageIndex: 0,
            strokeColor: HighlightColor.yellow.rgba
        ))
        page.addAnnotation(annotation)

        let highlights = page.annotations.filter { $0.type == "Highlight" }
        #expect(highlights.count == 1)
        let h = try #require(highlights.first)

        let quads = try #require(h.quadrilateralPoints)
        // At least one line — four corner points per quad.
        #expect(quads.count >= 4)
        #expect(quads.count.isMultiple(of: 4))

        let contents = try #require(h.contents)
        #expect(contents.contains("PUMICE"))

        let parsedID = try #require(AnnotationID(stringValue: h.userName ?? ""))
        #expect(parsedID.pageIndex == 0)
    }

    @Test("Gesture entirely off-text returns false and adds nothing")
    func gestureOffTextDoesNotSnap() throws {
        let document = try #require(makeTextPDF(text: "x"))
        let page = try #require(document.page(at: 0))

        // Endpoints in the bottom-right corner, away from the single
        // top-of-page character.
        let pageBounds = page.bounds(for: .mediaBox)
        let from = CGPoint(x: pageBounds.maxX - 10, y: pageBounds.minY + 5)
        let to = CGPoint(x: pageBounds.maxX - 5, y: pageBounds.minY + 1)

        let annotation = PDFReaderViewController.buildSnapAnnotation(
            firstPagePoint: from,
            lastPagePoint: to,
            on: page,
            pageIndex: 0,
            strokeColor: HighlightColor.yellow.rgba
        )
        #expect(annotation == nil)
        #expect(page.annotations.isEmpty)
    }

    @Test("Snap honours the stroke colour via closest-match")
    func colorMatching() throws {
        let document = try #require(makeTextPDF(text: "RED HIGHLIGHT"))
        let page = try #require(document.page(at: 0))

        let allText = try #require(page.selection(for: page.bounds(for: .mediaBox)))
        let textBounds = allText.bounds(for: page)
        let from = CGPoint(x: textBounds.minX + 1, y: textBounds.midY)
        let to = CGPoint(x: textBounds.maxX - 1, y: textBounds.midY)

        let crimson = StrokeColor(red: 0.95, green: 0.10, blue: 0.10, alpha: 1.0)
        let annotation = try #require(PDFReaderViewController.buildSnapAnnotation(
            firstPagePoint: from,
            lastPagePoint: to,
            on: page,
            pageIndex: 0,
            strokeColor: crimson
        ))
        page.addAnnotation(annotation)

        let highlight = try #require(page.annotations.first { $0.type == "Highlight" })
        // Annotation colour matches HighlightColor.red.rgba (not the input
        // crimson directly — we always map onto the 5-colour taxonomy).
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let uiColor = try #require(highlight.color)
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let canonicalRed = HighlightColor.red.rgba
        #expect(abs(r - canonicalRed.red) < 0.01)
        #expect(abs(g - canonicalRed.green) < 0.01)
        #expect(abs(b - canonicalRed.blue) < 0.01)
    }

    // MARK: - Helpers

    private func makeTextPDF(text: String) -> PDFDocument? {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.black
            ]
            NSAttributedString(string: text, attributes: attrs)
                .draw(at: CGPoint(x: 50, y: 100))
        }
        return PDFDocument(data: data)
    }
}
