import Foundation
import SystemExtensions

@MainActor
final class EndpointSecurityAdapter: NSObject, ObservableObject {
    static let shared = EndpointSecurityAdapter()
    nonisolated static let extensionIdentifier = "com.jonluca.xpcui.endpoint-security"
    static let requiredEntitlement = "com.apple.developer.endpoint-security.client"

    static let plannedSubscriptions = [
        "ES_EVENT_TYPE_NOTIFY_EXEC",
        "ES_EVENT_TYPE_NOTIFY_EXIT",
        "ES_EVENT_TYPE_NOTIFY_FORK",
        "ES_EVENT_TYPE_NOTIFY_OPEN",
        "ES_EVENT_TYPE_NOTIFY_CLOSE",
        "ES_EVENT_TYPE_NOTIFY_UIPC_CONNECT",
        "ES_EVENT_TYPE_NOTIFY_XPC_CONNECT",
    ]

    static let activationNote =
        "The embedded Endpoint Security extension requires Apple's restricted entitlement, user activation, and Full Disk Access."

    @Published private(set) var activationStatus = "Not requested"

    private override init() {}

    nonisolated static var isEmbedded: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/SystemExtensions")
                .appendingPathComponent("\(extensionIdentifier).systemextension")
                .path
        )
    }

    func activate() {
        activationStatus = "Requesting system extension activation"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        activationStatus = "Requesting system extension deactivation"
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension EndpointSecurityAdapter: @preconcurrency OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        activationStatus = "Waiting for approval in System Settings"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            activationStatus = "System extension request completed"
        case .willCompleteAfterReboot:
            activationStatus = "System extension request will complete after reboot"
        @unknown default:
            activationStatus = "System extension request returned an unknown result"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        activationStatus = "System extension request failed: \(error.localizedDescription)"
    }
}
