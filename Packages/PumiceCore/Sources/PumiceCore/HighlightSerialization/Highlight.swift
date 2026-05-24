import CoreGraphics
import Foundation

/// A snap-to-text highlight: the collection of per-line `Quad`s the user
/// selected, plus the colour, the page they live on, and the metadata
/// needed by the Markdown extraction layer.
///
/// Quads are stored in PDF user-space coordinates, which is the same space
/// PDFKit's `PDFSelection.bounds(for:)` returns — no coordinate conversion
/// is needed once the selection has been resolved to text.
public struct Highlight: Sendable, Hashable {
    public let quads: [Quad]
    public let color: HighlightColor
    public let pageIndex: Int
    public let extractedText: String
    public let attachedNote: String?

    public init(
        quads: [Quad],
        color: HighlightColor,
        pageIndex: Int,
        extractedText: String,
        attachedNote: String? = nil
    ) {
        self.quads = quads
        self.color = color
        self.pageIndex = pageIndex
        self.extractedText = extractedText
        self.attachedNote = attachedNote
    }

    /// Bridge into the Markdown extraction layer. The supplied UUID seeds
    /// the deterministic `AnnotationID`; pass the same UUID that's already
    /// persisted into the PDF annotation's `/NM` entry to keep IDs aligned
    /// across the PDF and the extracted Markdown.
    public func annotation(uuid: UUID) -> Annotation {
        Annotation(
            id: AnnotationID(pageIndex: pageIndex, annotationUUID: uuid),
            extractedText: extractedText,
            color: color,
            attachedNote: attachedNote
        )
    }
}
