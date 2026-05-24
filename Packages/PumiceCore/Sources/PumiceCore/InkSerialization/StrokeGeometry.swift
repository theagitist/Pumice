import CoreGraphics
import Foundation

extension Stroke {
    /// Smoothed `CGPath` in PDF user space, ready to be wrapped in a platform
    /// bezier path and added to a `PDFAnnotation` of subtype `.ink`.
    ///
    /// Points are first mapped through `geometry`, then connected by
    /// centripetal Catmull-Rom segments (rendered as cubic Béziers) so the
    /// curve follows the original gesture rather than a jagged polyline.
    public func pdfPath(on geometry: PageGeometry) -> CGPath {
        let pdfPoints = points.map { geometry.pdfPoint(fromCanvas: $0) }
        return Self.smoothPath(through: pdfPoints)
    }

    /// Smooth a polyline into a cubic-Bézier `CGPath` using a centripetal
    /// Catmull-Rom interpolation.
    public static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)

        if points.count == 1 {
            // Degenerate: a zero-length segment so the stroke still renders
            // as a dot.
            path.addLine(to: first)
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        // For each segment p1 -> p2, derive cubic control points from the
        // neighbouring points p0 and p3. End segments reuse their endpoint as
        // the missing neighbour, which keeps the tangent at the boundary.
        for i in 0..<(points.count - 1) {
            let p0 = i == 0 ? points[0] : points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : p2

            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
