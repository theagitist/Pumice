import Foundation

/// Deterministic identifier for a PDF annotation in the form
/// `p{pageIndex}-{6hex}`, where `6hex` is the lower 24 bits of an FNV-1a
/// hash of `uuid-bytes | "|" | pageIndex`.
///
/// Persisted into PDF annotations via PDFKit's
/// `setValue(_:forAnnotationKey: .name)`, which writes the `/NM` entry of the
/// annotation dictionary. The same UUID + page index always produces the
/// same string, so re-extracting a vault produces stable Markdown block IDs.
///
/// FNV-1a is used (rather than SHA-256) because the identifier is only 24
/// bits anyway — cryptographic strength buys nothing here, and the simpler
/// hash keeps the package free of CryptoKit's macOS 10.15 minimum, which
/// would otherwise force declaring macOS as a supported platform.
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
        // FNV-1a, 32-bit. Iterate the 16 UUID bytes followed by "|" and the
        // decimal page index, then mask to 24 bits for a 6-hex-char output.
        var hash: UInt32 = 2_166_136_261 // FNV offset basis
        let prime: UInt32 = 16_777_619   // FNV prime
        let mix: (UInt8) -> Void = { byte in
            hash ^= UInt32(byte)
            hash = hash &* prime
        }
        withUnsafeBytes(of: uuid.uuid) { buffer in
            for byte in buffer { mix(byte) }
        }
        for byte in "|\(pageIndex)".utf8 { mix(byte) }
        return String(format: "%06x", hash & 0xFFFFFF)
    }
}
