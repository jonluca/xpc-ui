import AppKit
import Foundation
import SystemExtensions

@MainActor
final class EndpointSecurityAdapter: NSObject, ObservableObject {
    struct DiagnosticStatus: Sendable {
        let level: CapabilityStatus.Level
        let detail: String
    }

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

    @Published private(set) var activationStatus = "Not requested"

    private struct PendingPropertiesRequest {
        let request: OSSystemExtensionRequest
        let continuation: CheckedContinuation<DiagnosticStatus, Never>
    }

    private var pendingPropertiesRequests: [ObjectIdentifier: PendingPropertiesRequest] = [:]

    private override init() {}

    nonisolated static var isEmbedded: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/SystemExtensions")
                .appendingPathComponent("\(extensionIdentifier).systemextension")
                .path
        )
    }

    func diagnosticStatus() async -> DiagnosticStatus {
        guard Self.isEmbedded else {
            return Self.diagnosticStatus(isEmbedded: false)
        }
        return await withCheckedContinuation { continuation in
            let request = OSSystemExtensionRequest.propertiesRequest(
                forExtensionWithIdentifier: Self.extensionIdentifier,
                queue: .main
            )
            let identifier = ObjectIdentifier(request)
            pendingPropertiesRequests[identifier] = PendingPropertiesRequest(
                request: request,
                continuation: continuation
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    nonisolated static func diagnosticStatus(
        isEmbedded: Bool,
        hasEnabledExtension: Bool = false,
        hasAwaitingApprovalExtension: Bool = false,
        hasUninstallingExtension: Bool = false,
        lookupError: String? = nil
    ) -> DiagnosticStatus {
        guard isEmbedded else {
            return DiagnosticStatus(
                level: .unavailable,
                detail: "The Endpoint Security system extension is missing from the app bundle."
            )
        }
        if hasEnabledExtension {
            return DiagnosticStatus(
                level: .available,
                detail: "The Endpoint Security system extension is embedded and active. Event delivery still depends on Full Disk Access."
            )
        }
        if hasAwaitingApprovalExtension {
            return DiagnosticStatus(
                level: .limited,
                detail: "The embedded Endpoint Security system extension is waiting for approval in System Settings."
            )
        }
        if hasUninstallingExtension {
            return DiagnosticStatus(
                level: .limited,
                detail: "The Endpoint Security system extension is being removed and may require a restart before it can be activated again."
            )
        }
        if let lookupError {
            return DiagnosticStatus(
                level: .limited,
                detail: "The embedded Endpoint Security system extension status could not be read: \(lookupError)"
            )
        }
        return DiagnosticStatus(
            level: .limited,
            detail: "The embedded Endpoint Security system extension requires Apple's restricted entitlement, user activation, and Full Disk Access."
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

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func completePropertiesRequest(
        _ request: OSSystemExtensionRequest,
        status: DiagnosticStatus
    ) -> Bool {
        guard let pending = pendingPropertiesRequests.removeValue(forKey: ObjectIdentifier(request)) else {
            return false
        }
        pending.continuation.resume(returning: status)
        return true
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

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        completePropertiesRequest(
            request,
            status: Self.diagnosticStatus(
                isEmbedded: Self.isEmbedded,
                hasEnabledExtension: properties.contains { $0.isEnabled && !$0.isUninstalling },
                hasAwaitingApprovalExtension: properties.contains(where: \.isAwaitingUserApproval),
                hasUninstallingExtension: properties.contains(where: \.isUninstalling)
            )
        )
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
        if completePropertiesRequest(
            request,
            status: Self.diagnosticStatus(isEmbedded: Self.isEmbedded, lookupError: error.localizedDescription)
        ) {
            return
        }
        activationStatus = "System extension request failed: \(error.localizedDescription)"
    }
}
