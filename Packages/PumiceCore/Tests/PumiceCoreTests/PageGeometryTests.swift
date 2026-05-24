import CoreGraphics
import Foundation
import Testing
@testable import PumiceCore

@Suite("PageGeometry")
struct PageGeometryTests {
    private static let usLetter = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let canvas = CGSize(width: 306, height: 396)

    @Test("Canvas top-left maps to PDF top-left of pageBounds")
    func topLeft() {
        let g = PageGeometry(canvasSize: Self.canvas, pageBounds: Self.usLetter)
        let pdf = g.pdfPoint(fromCanvas: CGPoint(x: 0, y: 0))
        #expect(pdf.x == 0)
        #expect(pdf.y == 792)
    }

    @Test("Canvas bottom-right maps to PDF bottom-right of pageBounds")
    func bottomRight() {
        let g = PageGeometry(canvasSize: Self.canvas, pageBounds: Self.usLetter)
        let pdf = g.pdfPoint(fromCanvas: CGPoint(x: 306, y: 396))
        #expect(pdf.x == 612)
        #expect(pdf.y == 0)
    }

    @Test("Canvas center maps to PDF center")
    func center() {
        let g = PageGeometry(canvasSize: Self.canvas, pageBounds: Self.usLetter)
        let pdf = g.pdfPoint(fromCanvas: CGPoint(x: 153, y: 198))
        #expect(pdf.x == 306)
        #expect(pdf.y == 396)
    }

    @Test("PDF-to-canvas inverts canvas-to-PDF")
    func roundTrip() {
        let g = PageGeometry(canvasSize: Self.canvas, pageBounds: Self.usLetter)
        let original = CGPoint(x: 42.5, y: 173.25)
        let pdf = g.pdfPoint(fromCanvas: original)
        let back = g.canvasPoint(fromPDF: pdf)
        #expect(abs(back.x - original.x) < 1e-9)
        #expect(abs(back.y - original.y) < 1e-9)
    }

    @Test("Non-zero pageBounds origin is respected")
    func nonZeroOrigin() {
        let bounds = CGRect(x: 50, y: 100, width: 612, height: 792)
        let g = PageGeometry(canvasSize: Self.canvas, pageBounds: bounds)
        let topLeft = g.pdfPoint(fromCanvas: .zero)
        #expect(topLeft.x == 50)
        #expect(topLeft.y == 892) // 100 + 792
        let bottomRight = g.pdfPoint(fromCanvas: CGPoint(x: 306, y: 396))
        #expect(bottomRight.x == 662) // 50 + 612
        #expect(bottomRight.y == 100)
    }

    @Test("Scale is page over canvas")
    func scale() {
        let g = PageGeometry(canvasSize: Self.canvas, pageBounds: Self.usLetter)
        #expect(g.scale.width == 2)
        #expect(g.scale.height == 2)
    }

    @Test("pdfLength averages x and y scale")
    func pdfLength() {
        let g = PageGeometry(
            canvasSize: CGSize(width: 100, height: 100),
            pageBounds: CGRect(x: 0, y: 0, width: 100, height: 200)
        )
        // scale.width == 1, scale.height == 2 → average == 1.5
        #expect(g.pdfLength(fromCanvas: 4) == 6)
    }
}
