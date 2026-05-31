import Foundation
import XCTest

final class XPCFixtureCLICoverageTests: XCTestCase {
    func testProjectBuildsDeterministicExecutableFixture() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCFixtureCLI/main.c")
        )
        let service = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCFixtureMachService/main.c")
        )
        let wrapper = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/fixture_mach_service.py")
        )

        XCTAssertTrue(project.contains("  XPCFixtureCLI:\n    type: tool"))
        XCTAssertTrue(project.contains("        XPCFixtureCLI: all"))
        XCTAssertTrue(project.contains("  XPCFixtureMachService:\n    type: tool"))
        XCTAssertTrue(project.contains("        XPCFixtureMachService: all"))
        XCTAssertTrue(source.contains("posix_spawn(&child_pid"))
        XCTAssertTrue(source.contains("open(\"/tmp\", O_RDONLY)"))
        XCTAssertTrue(source.contains("socket(AF_UNIX, SOCK_STREAM, 0)"))
        XCTAssertTrue(source.contains("xpc_connection_send_message_with_reply("))
        XCTAssertTrue(source.contains("--stress-lifecycle"))
        XCTAssertTrue(source.contains("xpcui_trace_optional_lifecycle"))
        XCTAssertTrue(source.contains("--stress-xpc"))
        XCTAssertTrue(source.contains("xpc_connection_send_message(connection, message)"))
        XCTAssertTrue(source.contains("--interception-probe"))
        XCTAssertTrue(source.contains("com.jonluca.xpcui.fixture.mach-service"))
        XCTAssertFalse(source.contains("com.apple." + "cfprefsd"))
        XCTAssertTrue(service.contains("XPC_CONNECTION_MACH_SERVICE_LISTENER"))
        XCTAssertTrue(service.contains("xpc_dictionary_set_value(reply, \"received\", probe)"))
        XCTAssertTrue(wrapper.contains("\"launchctl\", \"bootstrap\""))
        XCTAssertTrue(wrapper.contains("\"launchctl\", \"bootout\""))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
