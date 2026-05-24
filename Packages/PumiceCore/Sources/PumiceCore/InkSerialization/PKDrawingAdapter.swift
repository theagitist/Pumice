#if canImport(PencilKit) && canImport(UIKit)
import CoreGraphics
import PencilKit
import UIKit

extension Stroke {
    /// Convert a `PKDrawing` into the platform-neutral `Stroke`
    /// representation. Per the PRD trade-off (F03), per-sample pressure,
    /// tilt, and azimuth are dropped and per-sample width is averaged into
    /// a single annotation-level width.
    public static func strokes(from drawing: PKDrawing) -> [Stroke] {
        drawing.strokes.map(Stroke.init(pkStroke:))
    }

    public init(pkStroke: PKStroke) {
        var locations: [CGPoint] = []
        var widthSum: CGFloat = 0
        var widthCount: Int = 0
        locations.reserveCapacity(pkStroke.path.count)

        // Iterating PKStrokePath as a RandomAccessCollection yields its
        // keyframes (sparse control points). The polyline is later smoothed
        // by `Stroke.smoothPath` so the on-page curve follows the gesture.
        // Switching to `path.interpolatedPoints(strideBy:)` for denser
        // sampling is a low-risk refinement we can do once we benchmark the
        // round-tripped output in real PDF readers.
        for point in pkStroke.path {
            locations.append(point.location)
            let avg = (point.size.width + point.size.height) / 2
            widthSum += avg
            widthCount += 1
        }

        let width = widthCount > 0 ? widthSum / CGFloat(widthCount) : 1
        let color = StrokeColor(uiColor: pkStroke.ink.color)
        self.init(points: locations, width: width, color: color)
    }
}

extension StrokeColor {
    public init(uiColor: UIColor) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            self.init(red: r, green: g, blue: b, alpha: a)
        } else {
            // Defensive fallback for colours that don't decompose into RGBA
            // (pattern colours, exotic colour spaces). PencilKit only emits
            // solid sRGB-able colours, so this branch is unreachable in
            // practice — kept to keep the initialiser total.
            self.init(red: 0, green: 0, blue: 0, alpha: 1)
        }
    }
}
#endif
