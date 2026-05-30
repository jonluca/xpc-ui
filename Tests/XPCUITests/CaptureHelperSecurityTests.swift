import Foundation
import XCTest

final class CaptureHelperSecurityTests: XCTestCase {
    func testPrivilegedHelperRequiresValidSameTeamAppCode() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CaptureHelper/main.swift")
        )

        XCTAssertTrue(source.contains("SecCodeCheckValidity(code, [], nil)"))
        XCTAssertTrue(source.contains("kSecCodeInfoIdentifier"))
        XCTAssertTrue(source.contains("kSecCodeInfoTeamIdentifier"))
        XCTAssertTrue(source.contains("SecCodeCopySelf"))
        XCTAssertTrue(source.contains("identifier == \"com.jonluca.xpcui\" && teamIdentifier == ownTeamIdentifier"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
