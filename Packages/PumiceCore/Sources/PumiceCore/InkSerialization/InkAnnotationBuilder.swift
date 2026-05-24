#if canImport(PDFKit) && canImport(UIKit)
import CoreGraphics
import Foundation
import PDFKit
import UIKit

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
        let cgPath = stroke.pdfPath(on: geometry)
        let pdfStrokeWidth = geometry.pdfLength(fromCanvas: stroke.width)
        let bounds = cgPath.boundingBoxOfPath
            .insetBy(dx: -pdfStrokeWidth, dy: -pdfStrokeWidth)

        let id = AnnotationID(pageIndex: pageIndex, annotationUUID: uuid)
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .ink,
            withProperties: nil
        )

        // PDFAnnotation's ink path is added in PDF page coordinates, matching
        // /Rect. PDFKit takes care of writing the /InkList entries when the
        // page is serialized.
        annotation.add(UIBezierPath(cgPath: cgPath))

        annotation.color = stroke.color.uiColor
        let border = PDFBorder()
        border.lineWidth = pdfStrokeWidth
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
