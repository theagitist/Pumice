import CoreGraphics
import Foundation

/// PencilKit-independent representation of a single freehand stroke, reduced
/// to the geometry that survives the round trip into a PDF `/Subtype /Ink`
/// annotation: a polyline of canvas-space points plus a single annotation-
/// level width and colour.
///
/// Per the PRD trade-off, we intentionally drop PencilKit's per-sample
/// pressure, tilt, azimuth, and time data, and we collapse per-sample width
/// variation into a single representative `width`. These attributes have no
/// representation in `/Ink`, so persisting them would create a copy of the
/// drawing that other PDF readers can't render or edit.
public struct Stroke: Sendable, Hashable {
    /// Polyline of stroke positions in canvas space (top-left origin).
    public let points: [CGPoint]
    /// Single representative stroke width in canvas points.
    public let width: CGFloat
    /// Stroke colour in RGBA, each channel in `[0, 1]`.
    public let color: StrokeColor

    public init(points: [CGPoint], width: CGFloat, color: StrokeColor) {
        self.points = points
        self.width = width
        self.color = color
    }
}

public struct StrokeColor: Sendable, Hashable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
