import Foundation
import Security
import ServiceManagement

@MainActor
final class DiagnosticsService: ObservableObject {
    @Published private(set) var capabilities: [CapabilityStatus] = []
    @Published private(set) var isRefreshing = false

    func refresh() {
        isRefreshing = true
        let helperStatus = SMAppService.daemon(plistName: "com.jonluca.xpcui.capture-helper.plist").status
        let traceLibraryAvailable = Bundle.main.url(forResource: "XPCTrace", withExtension: "dylib") != nil
        Task {
            let sipOutput = await Task.detached(priority: .utility) {
                Self.commandOutput("/usr/bin/csrutil", arguments: ["status"])
            }.value
            let sipEnabled = sipOutput.localizedCaseInsensitiveContains("enabled")
            capabilities = [
                CapabilityStatus(
                    id: "injected-xpc",
                    title: "Injected XPC payload capture",
                    level: traceLibraryAvailable ? .available : .unavailable,
                    detail: traceLibraryAvailable
                        ? "The XPCTrace dylib is bundled and ready for launch-time injection."
                        : "The XPCTrace dylib is missing from the app bundle."
                ),
                CapabilityStatus(
                    id: "helper",
                    title: "Privileged capture helper",
                    level: Self.level(for: helperStatus),
                    detail: Self.detail(for: helperStatus)
                ),
                CapabilityStatus(
                    id: "sip",
                    title: "System Integrity Protection",
                    level: sipEnabled ? .limited : .available,
                    detail: sipEnabled
                        ? "SIP is enabled. Protected targets will reject some deep inspection."
                        : "SIP appears disabled for this dedicated lab Mac."
                ),
                CapabilityStatus(
                    id: "mach",
                    title: "Mach namespace snapshots",
                    level: .limited,
                    detail: "Available per target when task_for_pid is permitted; denied targets remain visible with a capability note."
                ),
                CapabilityStatus(
                    id: "endpoint-security",
                    title: "Endpoint Security telemetry",
                    level: Self.hasEndpointSecurityEntitlement ? .available : .unavailable,
                    detail: Self.hasEndpointSecurityEntitlement
                        ? "The restricted Endpoint Security client entitlement is present."
                        : EndpointSecurityAdapter.activationNote
                ),
                CapabilityStatus(
                    id: "kernel",
                    title: "Kernel deep mode",
                    level: sipEnabled ? .limited : .available,
                    detail: sipEnabled
                        ? "DTrace adapters are present, but SIP and privileges restrict syscall and mach_trap coverage."
                        : "The lab Mac is ready for privileged DTrace adapters."
                ),
            ]
            isRefreshing = false
        }
    }

    func registerHelper() throws {
        try SMAppService.daemon(plistName: "com.jonluca.xpcui.capture-helper.plist").register()
        refresh()
    }

    nonisolated private static func commandOutput(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch {
            return error.localizedDescription
        }
    }

    private static var hasEndpointSecurityEntitlement: Bool {
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                EndpointSecurityAdapter.requiredEntitlement as CFString,
                nil
            )
        else {
            return false
        }
        return value as? Bool == true
    }

    private static func level(for status: SMAppService.Status) -> CapabilityStatus.Level {
        switch status {
        case .enabled: .available
        case .requiresApproval: .limited
        case .notRegistered, .notFound: .unavailable
        @unknown default: .limited
        }
    }

    private static func detail(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "The LaunchDaemon is registered and enabled."
        case .requiresApproval: "Registration requires approval in System Settings."
        case .notRegistered: "The bundled LaunchDaemon is not registered."
        case .notFound: "The bundled LaunchDaemon plist was not found."
        @unknown default: "The helper reported an unknown registration state."
        }
    }
}
