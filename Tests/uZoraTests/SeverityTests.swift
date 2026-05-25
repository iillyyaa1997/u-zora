import Testing
@testable import uZora

@Suite("Severity comparison")
struct SeverityTests {
    @Test func ordering() {
        #expect(Severity.info < Severity.warn)
        #expect(Severity.warn < Severity.critical)
        #expect(Severity.info < Severity.critical)
    }

    @Test func equalityNotLess() {
        #expect(!(Severity.warn < Severity.warn))
        #expect(Severity.info == Severity.info)
    }
}
