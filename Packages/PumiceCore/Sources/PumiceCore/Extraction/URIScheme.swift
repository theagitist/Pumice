import Foundation

/// User-selectable URI scheme for the links emitted next to each extracted
/// annotation. `.obsidian` produces deep-links into the named vault;
/// `.file` produces a relative reference suitable for any Markdown renderer
/// that can resolve sibling files.
///
/// Logseq support is intentionally omitted for now: its public URI scheme
/// for jumping to a page within a PDF asset is not stable enough to commit
/// to. Add `.logseq(...)` once the format is settled.
public enum URIScheme: Sendable, Hashable {
    case obsidian(vaultName: String)
    case file

    /// Build the URI string to embed in `[Page N](link)` for a given page
    /// (1-based, matching how humans count pages) and PDF filename.
    public func link(pageNumber: Int, pdfFilename: String) -> String {
        switch self {
        case .obsidian(let vault):
            let v = Self.percentEncode(vault, allowed: .urlQueryValueAllowed)
            let f = Self.percentEncode(pdfFilename, allowed: .urlQueryValueAllowed)
            return "obsidian://open?vault=\(v)&file=\(f)#page=\(pageNumber)"
        case .file:
            let f = Self.percentEncode(pdfFilename, allowed: .urlPathAllowed)
            return "\(f)#page=\(pageNumber)"
        }
    }

    private static func percentEncode(_ string: String, allowed: CharacterSet) -> String {
        string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

private extension CharacterSet {
    /// Same as `.urlQueryAllowed` but excludes `=`, `&`, `+` so values can
    /// safely contain those characters when embedded as query-string values.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "=&+")
        return set
    }()
}
