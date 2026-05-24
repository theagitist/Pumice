import CryptoKit
import Foundation

/// Deterministic identifier for a PDF annotation in the form
/// `p{pageIndex}-{6hex}`, where `6hex` is the first 6 hex characters of
/// `SHA-256(uuid-bytes | "|" | pageIndex)`.
///
/// Persisted into PDF annotations via PDFKit's
/// `setValue(_:forAnnotationKey: .name)`, which writes the `/NM` entry of the
/// annotation dictionary. The same UUID + page index always produces the
/// same string, so re-extracting a vault produces stable Markdown block IDs.
public struct AnnotationID: Sendable, Hashable {
    public let pageIndex: Int
    public let shortHash: String

    public var stringValue: String { "p\(pageIndex)-\(shortHash)" }

    public init(pageIndex: Int, annotationUUID: UUID) {
        self.pageIndex = pageIndex
        self.shortHash = Self.shortHash(for: annotationUUID, pageIndex: pageIndex)
    }

    /// Parse a string produced by `stringValue`. Returns `nil` if the string
    /// doesn't match the documented format.
    public init?(stringValue: String) {
        guard stringValue.hasPrefix("p") else { return nil }
        let withoutPrefix = stringValue.dropFirst()
        guard let dashIndex = withoutPrefix.firstIndex(of: "-") else { return nil }
        let pageString = withoutPrefix[..<dashIndex]
        let hashString = withoutPrefix[withoutPrefix.index(after: dashIndex)...]
        guard
            let page = Int(pageString),
            page >= 0,
            hashString.count == 6,
            hashString.allSatisfy({ $0.isHexDigit })
        else { return nil }
        self.pageIndex = page
        self.shortHash = String(hashString)
    }

    private init(pageIndex: Int, shortHash: String) {
        self.pageIndex = pageIndex
        self.shortHash = shortHash
    }

    private static func shortHash(for uuid: UUID, pageIndex: Int) -> String {
        var hasher = SHA256()
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        hasher.update(data: uuidBytes)
        hasher.update(data: Data("|\(pageIndex)".utf8))
        let digest = hasher.finalize()
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}
