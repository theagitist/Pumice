#if canImport(PDFKit) && canImport(UIKit)
import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// Builds standard PDF `/Subtype /Highlight` annotations from `Highlight`
/// values, with a deterministic `AnnotationID` stamped into the annotation's
/// `/NM` entry and the underlying text written into `/Contents` so PDF
/// readers without our Markdown extraction layer can still surface it.
public enum HighlightAnnotationBuilder {
    /// - Parameters:
    ///   - highlight: The highlight to serialize. `highlight.quads` must
    ///     already be in PDF user-space coordinates.
    ///   - uuid: UUID seeding the deterministic ID. Defaults to a fresh
    ///     UUID; callers that already track a stable identifier should
    ///     pass it in to keep `/NM` aligned across reads.
    public static func makeAnnotation(
        highlight: Highlight,
        uuid: UUID = UUID()
    ) -> PDFAnnotation {
        let bounds = HighlightGeometry.boundingRect(highlight.quads)
        let id = AnnotationID(pageIndex: highlight.pageIndex, annotationUUID: uuid)
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .highlight,
            withProperties: nil
        )

        annotation.quadrilateralPoints = highlight.quads.flatMap { quad in
            [
                NSValue(cgPoint: quad.topLeft),
                NSValue(cgPoint: quad.topRight),
                NSValue(cgPoint: quad.bottomLeft),
                NSValue(cgPoint: quad.bottomRight)
            ]
        }
        annotation.color = highlight.color.rgba.uiColor
        annotation.contents = highlight.extractedText

        // See InkAnnotationBuilder for the rationale: /NM is dropped by
        // PDFKit's writer on iOS, so we persist the deterministic ID via
        // /T (`userName`) instead.
        annotation.userName = id.stringValue

        return annotation
    }
}
#endif
