import Foundation
import XCTest
@testable import XPC_UI

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

    func testOptionalNSXPCAdapterRequiresExplicitOptIn() {
        XCTAssertNil(SessionController.optionalAdaptersEnvironment(nsxpcLifecycleEnabled: false))
        XCTAssertEqual(
            SessionController.optionalAdaptersEnvironment(nsxpcLifecycleEnabled: true),
            "nsxpc-lifecycle"
        )
    }

    func testOptionalNSXPCAdapterOwnsReplaceableInitializerHooks() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCTrace/XPCTraceOptionalAdapters.m")
        )

        XCTAssertTrue(source.contains("xpcui_optional_adapter_t adapters[]"))
        XCTAssertTrue(source.contains("{\"nsxpc-lifecycle\", xpcui_install_nsxpc_lifecycle_adapter}"))
        XCTAssertTrue(source.contains("@selector(initWithServiceName:)"))
        XCTAssertTrue(source.contains("@selector(initWithMachServiceName:options:)"))
        XCTAssertTrue(source.contains("@selector(initWithListenerEndpoint:)"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
