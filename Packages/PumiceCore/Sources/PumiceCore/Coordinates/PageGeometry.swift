import CoreGraphics
import Foundation

/// Mapping between canvas-space coordinates (PencilKit/UIKit: origin
/// top-left, y increases downward) and PDF user-space coordinates (PDFKit:
/// origin bottom-left, y increases upward) for a single page.
///
/// Kept dependency-free of PencilKit and PDFKit so coordinate logic is
/// exercised by `swift test` without simulator infrastructure.
public struct PageGeometry: Sendable, Hashable {
    /// Size of the on-screen canvas displaying the page, in canvas points.
    public let canvasSize: CGSize
    /// Intrinsic page bounds in PDF user space (as returned by
    /// `PDFPage.bounds(for: .mediaBox)`). Often has a non-zero origin for
    /// pages with a custom MediaBox.
    public let pageBounds: CGRect

    public init(canvasSize: CGSize, pageBounds: CGRect) {
        self.canvasSize = canvasSize
        self.pageBounds = pageBounds
    }

    /// Per-axis scale factor mapping a canvas-space length to PDF user space.
    public var scale: CGSize {
        CGSize(
            width: pageBounds.width / canvasSize.width,
            height: pageBounds.height / canvasSize.height
        )
    }

    public func pdfPoint(fromCanvas canvasPoint: CGPoint) -> CGPoint {
        let s = scale
        let x = pageBounds.minX + canvasPoint.x * s.width
        let yFromTop = canvasPoint.y * s.height
        let y = pageBounds.maxY - yFromTop
        return CGPoint(x: x, y: y)
    }

    public func canvasPoint(fromPDF pdfPoint: CGPoint) -> CGPoint {
        let s = scale
        let x = (pdfPoint.x - pageBounds.minX) / s.width
        let yFromBottom = pdfPoint.y - pageBounds.minY
        let yFromTop = pageBounds.height - yFromBottom
        let y = yFromTop / s.height
        return CGPoint(x: x, y: y)
    }

    /// Convert a canvas-space length (e.g. a stroke width) to PDF user-space.
    /// Uses the average of x and y scale so non-uniform scaling produces a
    /// predictable single value.
    public func pdfLength(fromCanvas length: CGFloat) -> CGFloat {
        let s = scale
        return length * (s.width + s.height) / 2
    }
}
