import Foundation
import XCTest

final class EndpointSecurityAdapterTests: XCTestCase {
    func testProjectEmbedsEntitlementGatedSystemExtension() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        let entitlements = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/EndpointSecurityExtension/EndpointSecurityExtension.entitlements"
            )
        )
        let info = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/EndpointSecurityExtension/Info.plist")
        )

        XCTAssertTrue(project.contains("  EndpointSecurityExtension:\n    type: system-extension"))
        XCTAssertTrue(project.contains("      - target: EndpointSecurityExtension\n        embed: true"))
        XCTAssertTrue(entitlements.contains("com.apple.developer.endpoint-security.client"))
        XCTAssertTrue(info.contains("NSEndpointSecurityMachServiceName"))
        XCTAssertTrue(info.contains("com.jonluca.xpcui.endpoint-security"))
    }

    func testExtensionRoutesSupportedNotificationsThroughSharedEnvelopeStream() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/EndpointSecurityExtension/main.c")
        )

        XCTAssertTrue(source.contains("es_new_client(&xpcui_es_client"))
        XCTAssertTrue(source.contains("ES_EVENT_TYPE_NOTIFY_EXEC"))
        XCTAssertTrue(source.contains("ES_EVENT_TYPE_NOTIFY_FORK"))
        XCTAssertTrue(source.contains("ES_EVENT_TYPE_NOTIFY_OPEN"))
        XCTAssertTrue(source.contains("ES_EVENT_TYPE_NOTIFY_UIPC_CONNECT"))
        XCTAssertTrue(source.contains("ES_EVENT_TYPE_NOTIFY_XPC_CONNECT"))
        XCTAssertTrue(source.contains("\\\"source\\\":\\\"endpoint-security\\\""))
        XCTAssertTrue(source.contains("XPCUI_ES_MAX_PENDING_EVENTS"))
        XCTAssertTrue(source.contains("xpcui_snapshot_config(event, pid)"))
        XCTAssertTrue(source.contains("xpcui_track_pid(event->child_pid)"))
    }

    func testAppBridgeSendsSessionAndDescendantConfiguration() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/EndpointSecurityBridge/EndpointSecurityBridge.m"
            )
        )

        XCTAssertTrue(source.contains("xpc_dictionary_set_string(message, \"sessionID\""))
        XCTAssertTrue(source.contains("xpc_dictionary_set_string(message, \"authToken\""))
        XCTAssertTrue(source.contains("xpc_dictionary_set_string(message, \"socketPath\""))
        XCTAssertTrue(source.contains("@\"update-tracked-pids\""))
        XCTAssertTrue(source.contains("@\"stop\""))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
