import CoreGraphics
import Foundation
import Testing
@testable import PumiceCore

@Suite("Stroke geometry")
struct StrokeGeometryTests {
    @Test("Empty stroke yields an empty path")
    func emptyStroke() {
        let path = Stroke.smoothPath(through: [])
        #expect(path.isEmpty)
    }

    @Test("Single point yields a dot path (move + degenerate line)")
    func singlePoint() {
        let p = CGPoint(x: 10, y: 20)
        let path = Stroke.smoothPath(through: [p])
        #expect(!path.isEmpty)
        #expect(path.boundingBoxOfPath == CGRect(x: 10, y: 20, width: 0, height: 0))
    }

    @Test("Two points yields a straight line")
    func twoPoints() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 10)
        let path = Stroke.smoothPath(through: [a, b])
        #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("Three colinear points produce a path through all three")
    func threeColinearPoints() {
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 20, y: 0)
        ]
        let path = Stroke.smoothPath(through: points)
        // Bounding box must span the full input range; vertical extent is
        // zero because all points share y=0.
        #expect(path.boundingBoxOfPath.width == 20)
        #expect(path.boundingBoxOfPath.height == 0)
    }

    @Test("Smoothed path through canvas-space points maps into PDF space")
    func pdfPathMapsThroughGeometry() {
        let stroke = Stroke(
            points: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 50, y: 50),
                CGPoint(x: 100, y: 100)
            ],
            width: 2,
            color: StrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let geometry = PageGeometry(
            canvasSize: CGSize(width: 100, height: 100),
            pageBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let path = stroke.pdfPath(on: geometry)
        // Canvas (0,0) → PDF (0,100); canvas (100,100) → PDF (100,0).
        // (Using bbox edges rather than `contains` because the latter is
        // half-open on max edges.)
        let bbox = path.boundingBoxOfPath
        #expect(bbox.minX == 0)
        #expect(bbox.minY == 0)
        #expect(bbox.maxX == 100)
        #expect(bbox.maxY == 100)
    }

    @Test("Smoothed three-point path stays close to the linear interpolant")
    func smoothingFidelity() {
        // For three roughly-colinear-but-perturbed points, Catmull-Rom
        // smoothing should produce a path that stays within a few units of
        // a straight line between endpoints (proxy: bounding-box height is
        // small relative to the input range).
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 5),
            CGPoint(x: 100, y: 0)
        ]
        let path = Stroke.smoothPath(through: points)
        let bbox = path.boundingBoxOfPath
        #expect(bbox.width == 100)
        #expect(bbox.height >= 5 && bbox.height < 10)
    }
}

@Suite("Stroke value type")
struct StrokeTests {
    @Test("Stroke preserves construction arguments")
    func roundTripConstruction() {
        let color = StrokeColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        let points = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        let stroke = Stroke(points: points, width: 2.5, color: color)
        #expect(stroke.points == points)
        #expect(stroke.width == 2.5)
        #expect(stroke.color == color)
    }
}
