import ServiceManagement
import XCTest
@testable import XPC_UI

@MainActor
final class DiagnosticsServiceTests: XCTestCase {
    func testBundledUnsignedHelperReportsLimitedInsteadOfMissing() {
        XCTAssertEqual(
            DiagnosticsService.helperLevel(for: .notFound, bundledPlistAvailable: true),
            .limited
        )
        XCTAssertTrue(
            DiagnosticsService.helperDetail(for: .notFound, bundledPlistAvailable: true)
                .contains("signed, notarized app bundle")
        )
        XCTAssertTrue(
            DiagnosticsService.helperDetail(for: .notFound, bundledPlistAvailable: true)
                .contains("/Applications")
        )
    }

    func testMissingHelperPlistReportsUnavailable() {
        XCTAssertEqual(
            DiagnosticsService.helperLevel(for: .notFound, bundledPlistAvailable: false),
            .unavailable
        )
        XCTAssertTrue(
            DiagnosticsService.helperDetail(for: .notFound, bundledPlistAvailable: false)
                .contains("was not found")
        )
    }
}
