import CoreGraphics
import Foundation

/// Four corner points of a single highlighted text rectangle in PDF user
/// space (origin bottom-left, y increases upward).
///
/// The corner ordering used by `quadPoints` is top-left, top-right,
/// bottom-left, bottom-right. The PDF 1.7 spec describes the canonical order
/// as counter-clockwise, but PDFKit, Apple Preview, and Adobe Acrobat all
/// emit and consume the TL / TR / BL / BR ordering used here. Following the
/// de facto convention maximises round-trip compatibility.
public struct Quad: Sendable, Hashable {
    public let topLeft: CGPoint
    public let topRight: CGPoint
    public let bottomLeft: CGPoint
    public let bottomRight: CGPoint

    public init(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// Axis-aligned quad covering `rect`, interpreted as PDF user space
    /// (so `rect.maxY` is the visual top of the rectangle).
    public init(rect: CGRect) {
        self.init(
            topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        )
    }

    /// Flat eight-float array suitable for splicing into a PDF `/QuadPoints`
    /// entry, in the TL / TR / BL / BR ordering documented on the type.
    public var quadPoints: [CGFloat] {
        [
            topLeft.x, topLeft.y,
            topRight.x, topRight.y,
            bottomLeft.x, bottomLeft.y,
            bottomRight.x, bottomRight.y
        ]
    }

    /// Tight axis-aligned bounding box of the four corners.
    public var boundingRect: CGRect {
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
        let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
