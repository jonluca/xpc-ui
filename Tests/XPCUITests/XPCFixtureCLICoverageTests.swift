import Foundation
import XCTest

final class XPCFixtureCLICoverageTests: XCTestCase {
    func testProjectBuildsDeterministicExecutableFixture() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCFixtureCLI/main.c")
        )

        XCTAssertTrue(project.contains("  XPCFixtureCLI:\n    type: tool"))
        XCTAssertTrue(project.contains("        XPCFixtureCLI: all"))
        XCTAssertTrue(source.contains("posix_spawn(&child_pid"))
        XCTAssertTrue(source.contains("open(\"/tmp\", O_RDONLY)"))
        XCTAssertTrue(source.contains("socket(AF_UNIX, SOCK_STREAM, 0)"))
        XCTAssertTrue(source.contains("xpc_connection_send_message_with_reply("))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
