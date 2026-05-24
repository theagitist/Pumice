import CoreGraphics
import Foundation

/// Pure helpers for shaping `Quad` arrays into the values a PDF `/Highlight`
/// annotation needs: the flat `/QuadPoints` array and the bounding `/Rect`.
public enum HighlightGeometry {
    /// Concatenate every quad's eight-float representation, line by line.
    /// The output is suitable for splicing directly into `/QuadPoints`.
    public static func quadPointsArray(_ quads: [Quad]) -> [CGFloat] {
        quads.flatMap(\.quadPoints)
    }

    /// Tight axis-aligned bounding box covering all quads. Returns `.zero`
    /// for an empty array so callers can use it as a no-op `/Rect`.
    public static func boundingRect(_ quads: [Quad]) -> CGRect {
        guard let first = quads.first?.boundingRect else { return .zero }
        return quads.dropFirst().reduce(first) { $0.union($1.boundingRect) }
    }
}

extension HighlightColor {
    /// Canonical RGBA fill colour for rendering. Alpha is 1.0 — PDF readers
    /// apply translucency themselves when displaying `/Subtype /Highlight`.
    ///
    /// Values chosen to read as classic highlighter pastels on white paper
    /// and to remain distinguishable in dark mode.
    public var rgba: StrokeColor {
        switch self {
        case .yellow: StrokeColor(red: 1.00, green: 0.92, blue: 0.23, alpha: 1.0)
        case .green:  StrokeColor(red: 0.45, green: 0.85, blue: 0.30, alpha: 1.0)
        case .blue:   StrokeColor(red: 0.40, green: 0.70, blue: 1.00, alpha: 1.0)
        case .red:    StrokeColor(red: 1.00, green: 0.40, blue: 0.40, alpha: 1.0)
        case .purple: StrokeColor(red: 0.70, green: 0.50, blue: 1.00, alpha: 1.0)
        }
    }
}
