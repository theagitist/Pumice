import Foundation
import Testing
@testable import PumiceCore

@Suite("AnnotationID")
struct AnnotationIDTests {
    @Test("Same UUID and page produce the same hash")
    func deterministic() {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let a = AnnotationID(pageIndex: 12, annotationUUID: uuid)
        let b = AnnotationID(pageIndex: 12, annotationUUID: uuid)
        #expect(a.stringValue == b.stringValue)
    }

    @Test("Different page indices produce different hashes for the same UUID")
    func pageIndexAffectsHash() {
        let uuid = UUID()
        let a = AnnotationID(pageIndex: 0, annotationUUID: uuid)
        let b = AnnotationID(pageIndex: 1, annotationUUID: uuid)
        #expect(a.shortHash != b.shortHash)
    }

    @Test("Different UUIDs produce different hashes for the same page index")
    func uuidAffectsHash() {
        let a = AnnotationID(pageIndex: 5, annotationUUID: UUID())
        let b = AnnotationID(pageIndex: 5, annotationUUID: UUID())
        #expect(a.shortHash != b.shortHash)
    }

    @Test("stringValue has the documented format")
    func format() {
        let id = AnnotationID(
            pageIndex: 7,
            annotationUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        #expect(id.stringValue.hasPrefix("p7-"))
        let parts = id.stringValue.split(separator: "-")
        #expect(parts.count == 2)
        #expect(parts[1].count == 6)
        #expect(parts[1].allSatisfy { $0.isHexDigit })
    }

    @Test("init(stringValue:) round-trips a generated ID")
    func parseRoundTrip() {
        let original = AnnotationID(pageIndex: 42, annotationUUID: UUID())
        let parsed = AnnotationID(stringValue: original.stringValue)
        #expect(parsed?.pageIndex == 42)
        #expect(parsed?.shortHash == original.shortHash)
        #expect(parsed?.stringValue == original.stringValue)
    }

    @Test("init(stringValue:) rejects bad inputs", arguments: [
        "",
        "x12-abc123",        // missing 'p' prefix
        "p-abc123",          // missing page index
        "p12abc123",         // missing dash
        "p12-abc12",         // hash too short
        "p12-abc1234",       // hash too long
        "p12-xyz123",        // non-hex chars
        "p-1-abc123"         // negative page index
    ])
    func rejectsMalformed(_ input: String) {
        #expect(AnnotationID(stringValue: input) == nil)
    }
}
