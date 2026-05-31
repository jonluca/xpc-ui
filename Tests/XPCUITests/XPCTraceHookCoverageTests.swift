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

    func testTracerSnapshotsPayloadBeforeDeferredSerialization() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCTrace/XPCTrace.c"))

        XCTAssertTrue(source.contains("xpc_object_t snapshot = xpc_copy(payload);"))
        XCTAssertTrue(source.contains(".payload = xpcui_copy_payload_snapshot(payload, &payload_snapshot_fallback)"))
        XCTAssertTrue(source.contains("payload-snapshot-fallback"))
    }

    func testTracerUsesBoundedNonblockingHookQueue() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCTrace/XPCTrace.c"))

        XCTAssertTrue(source.contains("#define XPCUI_QUEUE_CAPACITY 4096"))
        XCTAssertTrue(source.contains("pthread_mutex_trylock(&xpcui_queue_lock)"))
        XCTAssertTrue(source.contains("if (xpcui_queue_count >= XPCUI_QUEUE_CAPACITY)"))
        XCTAssertTrue(source.contains("atomic_fetch_add_explicit(&xpcui_dropped, 1"))
    }

    func testInterceptionRulesRemainBoundedAndOptIn() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCTrace/XPCTrace.c"))

        XCTAssertTrue(source.contains("#define XPCUI_INTERCEPTION_RULE_CAPACITY 32"))
        XCTAssertTrue(source.contains("getenv(\"XPCUI_INTERCEPTION_RULES_PATH\")"))
        XCTAssertTrue(source.contains("atomic_load_explicit(&xpcui_interception_enabled, memory_order_relaxed)"))
        XCTAssertTrue(source.contains("xpcui_apply_interception("))
        XCTAssertTrue(source.contains("xpc_dictionary_set_string("))
        XCTAssertTrue(source.contains("xpc_dictionary_set_int64("))
        XCTAssertTrue(source.contains("xpcui_dictionary_get_key_path("))
        XCTAssertTrue(source.contains("XPCUI_INTERCEPTION_KEY_PATH_DEPTH 8"))
        XCTAssertTrue(source.contains("interception_rule_ids"))
        XCTAssertTrue(source.contains("intercepted-rule:%s"))
    }

    func testOptionalNSXPCAdapterCanBeDisabledBeforeLaunch() {
        XCTAssertNil(SessionController.optionalAdaptersEnvironment(nsxpcLifecycleEnabled: false))
        XCTAssertEqual(
            SessionController.optionalAdaptersEnvironment(nsxpcLifecycleEnabled: true),
            "nsxpc-lifecycle"
        )
    }

    @MainActor
    func testAvailableInspectionModesStartEnabled() {
        let controller = SessionController()

        XCTAssertTrue(controller.deepCaptureEnabled)
        XCTAssertEqual(
            controller.optionalNSXPCLifecycleAdapterEnabled,
            Bundle.main.url(forResource: "XPCTrace", withExtension: "dylib") != nil
        )
        XCTAssertEqual(controller.endpointSecurityTelemetryEnabled, EndpointSecurityAdapter.isEmbedded)
        XCTAssertEqual(controller.kernelDeepModeEnabled, KernelTraceService.isAvailable)
        XCTAssertFalse(controller.interceptionRules.enabled)
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

    func testFixtureExercisesPublicSessionTraffic() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCFixture/XPCFixtureTraffic.c")
        )

        XCTAssertTrue(source.contains("xpc_session_create_xpc_service("))
        XCTAssertTrue(source.contains("xpc_session_send_message_with_reply_async("))
        XCTAssertTrue(source.contains("xpc_session_send_message_with_reply_sync("))
        XCTAssertTrue(source.contains("xpc_session_send_message("))
        XCTAssertTrue(source.contains("xpc_session_cancel("))
        XCTAssertTrue(source.contains("xpcui_fixture_missing_service_name"))
        XCTAssertTrue(source.contains("xpc_session_create_mach_service("))
    }

    func testPublicSessionHooksEmitStructuredRichErrors() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/XPCTrace/XPCTrace.c"))

        XCTAssertTrue(source.contains("XPC_TYPE_RICH_ERROR"))
        XCTAssertTrue(source.contains("\"{\\\"type\\\":\\\"rich-error\\\",\\\"canRetry\\\":%s,\\\"description\\\":\""))
        XCTAssertTrue(source.contains("\"session-create-error\""))
        XCTAssertTrue(source.contains("\"session-send-error\""))
        XCTAssertTrue(source.contains("\"session-reply-error\""))
        XCTAssertTrue(source.contains("\"session-reply-sync-error\""))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
