#if canImport(PDFKit) && canImport(UIKit)
import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// `PDFAnnotation` subclass that draws its own appearance stream.
///
/// Why this exists: iOS PDFKit's default writer generates a broken
/// `/AP` (appearance stream) for `.ink` annotations — it sets the
/// stream's `/BBox` to a small local box but emits stroke drawing
/// commands in absolute page coordinates, so every stroke is clipped
/// away. PDF viewers that prefer `/AP` over `/InkList` (Preview.app,
/// macOS QuickLook, Files-app QuickLook on iPadOS, Adobe Reader)
/// render nothing. PDFKit's own reader falls back to `/InkList`,
/// which is the only reason Pumice itself shows the strokes correctly.
///
/// Overriding `draw(with:in:)` makes PDFKit capture our drawing into
/// the appearance stream instead of synthesizing its broken default.
/// We stroke the path in the same PDF page coordinates we use for
/// `/InkList`, and PDFKit handles the local-coord mapping correctly
/// when the drawing comes from our override.
public final class PumiceInkAnnotation: PDFAnnotation {
    private let strokePath: UIBezierPath
    private let strokePageWidth: CGFloat
    private let strokeUIColor: UIColor

    public init(
        path: UIBezierPath,
        strokeColor: UIColor,
        strokeWidth: CGFloat,
        bounds: CGRect
    ) {
        self.strokePath = path
        self.strokePageWidth = strokeWidth
        self.strokeUIColor = strokeColor
        super.init(bounds: bounds, forType: .ink, withProperties: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        UIGraphicsPushContext(context)
        context.saveGState()
        strokeUIColor.setStroke()
        strokePath.lineWidth = strokePageWidth
        strokePath.lineCapStyle = .round
        strokePath.lineJoinStyle = .round
        strokePath.stroke()
        context.restoreGState()
        UIGraphicsPopContext()
    }
}

/// Builds standard PDF `/Subtype /Ink` annotations from `Stroke` values, with
/// a deterministic `AnnotationID` stamped into the annotation's `/NM` entry.
public enum InkAnnotationBuilder {
    /// Build one `PDFAnnotation` per stroke.
    ///
    /// - Parameters:
    ///   - stroke: The stroke to serialize, in canvas-space coordinates.
    ///   - geometry: Mapping between the canvas and the destination page.
    ///   - pageIndex: Zero-based page index, embedded in the annotation ID.
    ///   - uuid: UUID seeding the deterministic ID. Defaults to a fresh UUID;
    ///     callers that already track a stable identifier (e.g. for an
    ///     existing in-memory drawing) should pass it in.
    public static func makeAnnotation(
        stroke: Stroke,
        geometry: PageGeometry,
        pageIndex: Int,
        uuid: UUID = UUID()
    ) -> PDFAnnotation {
        let pagePoints = stroke.points.map { geometry.pdfPoint(fromCanvas: $0) }
        let pageStrokeWidth = geometry.pdfLength(fromCanvas: stroke.width)
        return makeAnnotation(
            pagePoints: pagePoints,
            pageStrokeWidth: pageStrokeWidth,
            color: stroke.color,
            pageIndex: pageIndex,
            uuid: uuid
        )
    }

    /// Build a `/Ink` annotation from points already in PDF user space.
    ///
    /// Use this when the caller has already converted a canvas-space stroke
    /// into page coordinates (e.g. via `PDFView.convert(_:to: PDFPage)`),
    /// avoiding the round-trip through `PageGeometry`.
    public static func makeAnnotation(
        pagePoints: [CGPoint],
        pageStrokeWidth: CGFloat,
        color: StrokeColor,
        pageIndex: Int,
        uuid: UUID = UUID()
    ) -> PDFAnnotation {
        // Build the saved path as a polyline (move + lineTo through the
        // original samples). PDF's `/InkList` only encodes point lists,
        // not curves — iOS PDFKit is supposed to flatten any cubic
        // Bezier curves we add to an Ink annotation before serializing,
        // but it doesn't do so reliably: the saved annotation comes out
        // with an empty InkList, the file viewed in Preview/Files shows
        // no stroke at all, and Pumice's own round-trip looks fine only
        // because we hydrate the canvas from the in-memory annotation
        // before the write strips the data. Passing a polyline avoids
        // the flatten step entirely.
        let path = UIBezierPath()
        guard let firstPoint = pagePoints.first else {
            // Empty input: hand back a degenerate annotation rather than
            // crash. Caller should already have guarded on a minimum
            // point count.
            return PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
        }
        path.move(to: firstPoint)
        if pagePoints.count == 1 {
            // Single tap: a zero-length line so the dot still renders.
            path.addLine(to: firstPoint)
        } else {
            for point in pagePoints.dropFirst() {
                path.addLine(to: point)
            }
        }

        let bounds = path.cgPath.boundingBoxOfPath
            .insetBy(dx: -pageStrokeWidth, dy: -pageStrokeWidth)

        let id = AnnotationID(pageIndex: pageIndex, annotationUUID: uuid)
        let annotation = PumiceInkAnnotation(
            path: path,
            strokeColor: color.uiColor,
            strokeWidth: pageStrokeWidth,
            bounds: bounds
        )

        // Also add the path the standard way so `/InkList` carries the
        // points for any reader that prefers the data form over the
        // appearance stream. The subclass's `draw(with:in:)` is what
        // produces the (correct) /AP that everyone else renders.
        annotation.add(path)

        annotation.color = color.uiColor
        let border = PDFBorder()
        border.lineWidth = pageStrokeWidth
        annotation.border = border

        // Persist the deterministic ID. Empirically, iOS PDFKit's writer
        // drops `/NM` (PDFAnnotationKey.name) on write — even when set via
        // `withProperties:` at construction. /T (the annotation's
        // user-name entry, exposed as `userName`) does survive a write/read
        // cycle, so we use it as the stable identifier slot. Other PDF
        // readers will surface this as the annotation author; that's a
        // worthwhile trade for a deterministic, reconcilable ID.
        annotation.userName = id.stringValue

        return annotation
    }
}

extension StrokeColor {
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
