import Foundation
import ServiceManagement

@MainActor
final class DiagnosticsService: ObservableObject {
    private static let helperPlistName = "com.jonluca.xpcui.capture-helper.plist"

    @Published private(set) var capabilities: [CapabilityStatus] = []
    @Published private(set) var isRefreshing = false

    func refresh() {
        isRefreshing = true
        let helperStatus = SMAppService.daemon(plistName: Self.helperPlistName).status
        let helperPlistAvailable = Self.bundledHelperPlistAvailable
        let traceLibraryAvailable = Bundle.main.url(forResource: "XPCTrace", withExtension: "dylib") != nil
        Task {
            let sipOutput = await Task.detached(priority: .utility) {
                Self.commandOutput("/usr/bin/csrutil", arguments: ["status"])
            }.value
            let sipEnabled = sipOutput.localizedCaseInsensitiveContains("enabled")
            let endpointSecurityStatus = await EndpointSecurityAdapter.shared.diagnosticStatus()
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
                    level: Self.helperLevel(for: helperStatus, bundledPlistAvailable: helperPlistAvailable),
                    detail: Self.helperDetail(for: helperStatus, bundledPlistAvailable: helperPlistAvailable)
                ),
                CapabilityStatus(
                    id: "nsxpc-lifecycle",
                    title: "Optional NSXPC lifecycle adapter",
                    level: traceLibraryAvailable ? .available : .unavailable,
                    detail: traceLibraryAvailable
                        ? "A replaceable NSXPCConnection initializer adapter is bundled and enabled by default when available. It uses Objective-C swizzling and can be disabled before launch."
                        : "The optional NSXPCConnection adapter requires the injected XPCTrace dylib."
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
                    level: .available,
                    detail: "Mach namespace snapshots are available. Per-target task_for_pid denials remain visible with a capability note."
                ),
                CapabilityStatus(
                    id: "endpoint-security",
                    title: "Endpoint Security telemetry",
                    level: endpointSecurityStatus.level,
                    detail: endpointSecurityStatus.detail
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
        try SMAppService.daemon(plistName: Self.helperPlistName).register()
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

    static func helperLevel(
        for status: SMAppService.Status,
        bundledPlistAvailable: Bool
    ) -> CapabilityStatus.Level {
        switch status {
        case .enabled: .available
        case .requiresApproval: .limited
        case .notRegistered: bundledPlistAvailable ? .limited : .unavailable
        case .notFound: bundledPlistAvailable ? .limited : .unavailable
        @unknown default: .limited
        }
    }

    static func helperDetail(for status: SMAppService.Status, bundledPlistAvailable: Bool) -> String {
        switch status {
        case .enabled: "The LaunchDaemon is registered and enabled."
        case .requiresApproval: "Registration requires approval in System Settings."
        case .notRegistered where bundledPlistAvailable: "The bundled LaunchDaemon is not registered."
        case .notFound where bundledPlistAvailable:
            "The LaunchDaemon plist is bundled, but ServiceManagement cannot discover it from this build. Registration requires a signed, notarized app bundle installed in /Applications."
        case .notRegistered, .notFound: "The bundled LaunchDaemon plist was not found."
        @unknown default: "The helper reported an unknown registration state."
        }
    }

    private static var bundledHelperPlistAvailable: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons")
                .appendingPathComponent(helperPlistName)
                .path
        )
    }
}
