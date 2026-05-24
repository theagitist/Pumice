import Foundation

/// A single YAML-ish `key: "value"` pair in the Markdown frontmatter.
///
/// Stored as an ordered list (not a dictionary) so user-added keys survive
/// round-tripping in insertion order.
public struct FrontmatterEntry: Sendable, Hashable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

enum FrontmatterCoding {
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unescape(_ quoted: String) -> String {
        var out = ""
        var iter = quoted.makeIterator()
        while let c = iter.next() {
            if c == "\\", let next = iter.next() {
                out.append(next)
            } else {
                out.append(c)
            }
        }
        return out
    }
}
