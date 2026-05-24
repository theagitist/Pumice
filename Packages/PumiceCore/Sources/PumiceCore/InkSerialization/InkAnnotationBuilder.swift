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

        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .ink,
            withProperties: nil
        )

        // PDFAnnotation's ink path is added in PDF page coordinates, matching
        // /Rect. PDFKit takes care of writing the /InkList entries when the
        // page is serialized. Verified empirically by round-trip; revisit
        // if reader compatibility breaks.
        annotation.add(UIBezierPath(cgPath: cgPath))

        annotation.color = stroke.color.uiColor
        let border = PDFBorder()
        border.lineWidth = pdfStrokeWidth
        annotation.border = border

        let id = AnnotationID(pageIndex: pageIndex, annotationUUID: uuid)
        annotation.setValue(id.stringValue, forAnnotationKey: .name)

        return annotation
    }
}

extension StrokeColor {
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
