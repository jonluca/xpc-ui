import Foundation
import XCTest

final class XPCTraceHookCoverageTests: XCTestCase {
    func testPublicSessionHooksRemainInterposed() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCTrace/XPCTrace.c"))
        let hooks = [
            "xpc_session_create_xpc_service",
            "xpc_session_create_mach_service",
            "xpc_session_set_incoming_message_handler",
            "xpc_session_send_message",
            "xpc_session_send_message_with_reply_async",
            "xpc_session_send_message_with_reply_sync",
        ]

        for hook in hooks {
            let replacement = "xpcui_" + hook.dropFirst("xpc_".count)
            XCTAssertTrue(
                source.contains("XPCUI_INTERPOSE(\(replacement), \(hook));"),
                "Missing public session hook: \(hook)"
            )
        }
    }

    func testTracerIsBundledWithoutLinkingItIntoTheInspector() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))

        XCTAssertTrue(
            project.contains(
                """
                      - target: XPCTrace
                        embed: true
                        link: false
                """
            )
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
