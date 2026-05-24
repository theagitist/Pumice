import Testing
@testable import Pumice

@Suite("Pumice scaffolding")
struct PumiceTests {
    @Test("Test target compiles and links the app")
    func smoke() {
        // Real coverage lands with the serialisation and Markdown
        // reconciliation engines (PRD targets 85% on those modules).
        #expect(Bool(true))
    }
}
