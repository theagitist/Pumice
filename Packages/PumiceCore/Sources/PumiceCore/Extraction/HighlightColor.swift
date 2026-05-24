import Foundation

/// The five highlight colours mandated by the PRD's "Color Taxonomy &
/// Hardware Matrix". Serialised into Markdown as `#highlight/{slug}` tags.
public enum HighlightColor: String, Sendable, Hashable, CaseIterable {
    case yellow
    case green
    case blue
    case red
    case purple

    /// Tag slug used in `#highlight/{slug}` Markdown tags.
    public var slug: String { rawValue }

    /// Parse the slug returned by `slug`.
    public init?(slug: String) {
        self.init(rawValue: slug)
    }
}
