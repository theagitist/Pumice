import Foundation

/// A PDF annotation reduced to the fields the Markdown extraction engine
/// cares about. Per the PRD's F05 spec, "modified" is strictly defined as any
/// change to the tuple `(extractedText, color, attachedNote)`; those three
/// fields are the reconciliation fingerprint.
public struct Annotation: Sendable, Hashable {
    public let id: AnnotationID
    public let extractedText: String
    public let color: HighlightColor
    public let attachedNote: String?

    public init(
        id: AnnotationID,
        extractedText: String,
        color: HighlightColor,
        attachedNote: String? = nil
    ) {
        self.id = id
        self.extractedText = extractedText
        self.color = color
        self.attachedNote = attachedNote
    }

    /// Page index encoded in the annotation's identifier.
    public var pageIndex: Int { id.pageIndex }
}
