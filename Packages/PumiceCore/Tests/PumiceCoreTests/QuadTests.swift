import CoreGraphics
import Foundation
import Testing
@testable import PumiceCore

@Suite("Quad")
struct QuadTests {
    @Test("Quad(rect:) places corners with PDF-style y-up semantics")
    func fromRect() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 30)
        let quad = Quad(rect: rect)
        #expect(quad.topLeft == CGPoint(x: 10, y: 50))
        #expect(quad.topRight == CGPoint(x: 110, y: 50))
        #expect(quad.bottomLeft == CGPoint(x: 10, y: 20))
        #expect(quad.bottomRight == CGPoint(x: 110, y: 20))
    }

    @Test("quadPoints emits TL, TR, BL, BR in PDFKit's preferred order")
    func quadPointsOrder() {
        let q = Quad(
            topLeft: CGPoint(x: 1, y: 4),
            topRight: CGPoint(x: 3, y: 4),
            bottomLeft: CGPoint(x: 1, y: 2),
            bottomRight: CGPoint(x: 3, y: 2)
        )
        #expect(q.quadPoints == [1, 4, 3, 4, 1, 2, 3, 2])
    }

    @Test("Bounding rect covers all four corners of a non-rectangular quad")
    func boundingRectNonRect() {
        let q = Quad(
            topLeft: CGPoint(x: 0, y: 10),
            topRight: CGPoint(x: 15, y: 12),
            bottomLeft: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 14, y: 1)
        )
        let bb = q.boundingRect
        #expect(bb.minX == 0)
        #expect(bb.maxX == 15)
        #expect(bb.minY == 0)
        #expect(bb.maxY == 12)
    }

    @Test("Bounding rect of an axis-aligned quad matches its source rect")
    func boundingRectAxisAligned() {
        let rect = CGRect(x: 5, y: 7, width: 11, height: 13)
        #expect(Quad(rect: rect).boundingRect == rect)
    }
}
