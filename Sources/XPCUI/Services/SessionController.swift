import AppKit
import Foundation

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var targetPID: Int32?
    @Published private(set) var targetPath: String?
    @Published private(set) var session: TraceSession?
    @Published var deepCaptureEnabled = true
    @Published var optionalNSXPCLifecycleAdapterEnabled = false
    @Published var endpointSecurityTelemetryEnabled = false
    @Published var kernelDeepModeEnabled = false
    @Published var selectedKernelCategories = Set(KernelTraceService.Category.allCases)
    @Published private(set) var kernelTraceStatus = "Off"
    @Published private(set) var endpointSecurityStatus = "Off"
    @Published private(set) var trackedPIDs = Set<Int32>()

    weak var store: EventStore?
    private let socketServer = TraceSocketServer()
    private let kernelTraceService = KernelTraceService()
    private let kernelTraceDecoder = KernelTraceEventDecoder()
    private var snapshotTimer: Timer?
    private var launchedProcess: Process?
    private var snapshotRefreshInFlight = false
    private var kernelTraceGeneration = 0
    private var kernelTracedPIDs = Set<Int32>()

    func stop() {
        socketServer.stop()
        kernelTraceService.stop()
        CaptureHelperClient.shared.stopKernelTrace()
        if endpointSecurityTelemetryEnabled {
            XPCUIEndpointSecurityStop()
        }
        kernelTraceGeneration += 1
        kernelTracedPIDs.removeAll()
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        snapshotRefreshInFlight = false
        launchedProcess = nil
        status = "Ready"
        kernelTraceStatus = "Off"
        endpointSecurityStatus = "Off"
        targetPID = nil
        targetPath = nil
        trackedPIDs.removeAll()
    }

    func launch(url: URL) async throws {
        try await launch(preflight: preflight(url: url))
    }

    func launch(preflight: TargetPreflight) async throws {
        guard preflight.canLaunch else {
            throw CocoaError(.executableNotLoadable, userInfo: [
                NSLocalizedDescriptionKey: "The selected target did not pass launch preflight.",
            ])
        }
        let url = preflight.targetURL
        stop()
        if let session {
            try? FileManager.default.removeItem(at: session.directoryURL)
        }
        let nextSession = try TraceSession.create()
        store?.begin(session: nextSession)
        try socketServer.start(session: nextSession) { [weak store] frame in
            store?.ingest(frame: frame)
        }
        session = nextSession
        status = "Launching \(url.lastPathComponent)"
        targetPath = url.path
        let environment = try traceEnvironment(for: nextSession, injectTracer: preflight.shouldInjectTracer)

        let pid: Int32
        if url.pathExtension.lowercased() == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            configuration.environment = environment
            let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            pid = application.processIdentifier
        } else {
            let process = Process()
            process.executableURL = url
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            launchedProcess = process
            pid = process.processIdentifier
        }
        targetPID = pid
        trackedPIDs = [pid]
        status = "Capturing \(url.lastPathComponent)"
        if kernelDeepModeEnabled {
            updateKernelTrace(pids: [pid], sessionID: nextSession.id)
        }
        startEndpointSecurity(pids: [pid], session: nextSession)
        refreshProcessTree(rootPID: pid, sessionID: nextSession.id)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshProcessTree(rootPID: pid, sessionID: nextSession.id)
            }
        }
    }

    func preflight(url: URL) async -> TargetPreflight {
        let deepCaptureEnabled = deepCaptureEnabled
        return await Task.detached(priority: .userInitiated) {
            TargetPreflightService.inspect(url: url, deepCaptureEnabled: deepCaptureEnabled)
        }.value
    }

    private func updateKernelTrace(pids: Set<Int32>, sessionID: String) {
        guard kernelDeepModeEnabled, pids != kernelTracedPIDs else { return }
        kernelTraceService.stop()
        kernelTraceGeneration += 1
        let generation = kernelTraceGeneration
        let decoder = kernelTraceDecoder
        guard !pids.isEmpty else {
            kernelTraceStatus = "Unavailable: no live process is available for kernel tracing."
            return
        }
        guard !selectedKernelCategories.isEmpty else {
            kernelTraceStatus = "Unavailable: select at least one kernel trace category."
            return
        }
        let categories = selectedKernelCategories
        let onLine: @Sendable (String) -> Void = { [weak store] line in
            guard
                let event = decoder.decode(line: line, sessionID: sessionID),
                let frame = try? JSONEncoder().encode(event)
            else {
                return
            }
            store?.ingest(frame: frame)
        }
        let onTermination: @Sendable (Int32) -> Void = { [weak self] status in
            Task { @MainActor [weak self] in
                guard self?.targetPID != nil, self?.kernelTraceGeneration == generation else { return }
                self?.kernelTraceStatus = status == 0
                    ? "Stopped"
                    : "Unavailable (DTrace exited with status \(status))"
            }
        }
        kernelTracedPIDs = pids
        let processCount = "\(pids.count) process\(pids.count == 1 ? "" : "es")"
        guard CaptureHelperClient.shared.isEnabled else {
            startDirectKernelTrace(
                pids: pids,
                categories: categories,
                processCount: processCount,
                onLine: onLine,
                onTermination: onTermination
            )
            return
        }
        kernelTraceStatus = "Requesting privileged trace for \(processCount)"
        let script = KernelTraceService.script(pids: pids, categories: categories)
        Task { [weak self] in
            let helperError = await CaptureHelperClient.shared.startKernelTrace(
                script: script,
                onLine: onLine,
                onTermination: onTermination
            )
            guard
                let self,
                self.targetPID != nil,
                self.kernelTraceGeneration == generation
            else {
                return
            }
            guard let helperError else {
                self.kernelTraceStatus = "Privileged helper tracing \(processCount)"
                return
            }
            self.startDirectKernelTrace(
                pids: pids,
                categories: categories,
                processCount: processCount,
                helperError: helperError,
                onLine: onLine,
                onTermination: onTermination
            )
        }
    }

    private func startDirectKernelTrace(
        pids: Set<Int32>,
        categories: Set<KernelTraceService.Category>,
        processCount: String,
        helperError: String? = nil,
        onLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) {
        do {
            try kernelTraceService.start(
                pids: pids,
                categories: categories,
                onLine: onLine,
                onTermination: onTermination
            )
            kernelTraceStatus = helperError == nil
                ? "Direct DTrace requested for \(processCount)"
                : "Direct DTrace fallback requested for \(processCount)"
        } catch {
            kernelTracedPIDs.removeAll()
            kernelTraceStatus = [helperError, error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    private func traceEnvironment(for session: TraceSession, injectTracer: Bool) throws -> [String: String] {
        var environment = [
            "XPCUI_SESSION_ID": session.id,
            "XPCUI_AUTH_TOKEN": session.authToken,
            "XPCUI_SOCKET_PATH": session.socketURL.path,
            "XPCUI_BLOBS_PATH": session.blobsURL.path,
        ]
        if injectTracer {
            guard let traceLibraryURL = Bundle.main.url(forResource: "XPCTrace", withExtension: "dylib") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "The injected XPCTrace dylib is missing from the app bundle.",
                ])
            }
            environment["DYLD_INSERT_LIBRARIES"] = traceLibraryURL.path
            if let optionalAdapters = Self.optionalAdaptersEnvironment(
                nsxpcLifecycleEnabled: optionalNSXPCLifecycleAdapterEnabled
            ) {
                environment["XPCUI_OPTIONAL_ADAPTERS"] = optionalAdapters
            }
        }
        return environment
    }

    nonisolated static func optionalAdaptersEnvironment(nsxpcLifecycleEnabled: Bool) -> String? {
        nsxpcLifecycleEnabled ? "nsxpc-lifecycle" : nil
    }

    private func refreshProcessTree(rootPID: Int32, sessionID: String) {
        guard !snapshotRefreshInFlight else { return }
        snapshotRefreshInFlight = true
        Task { [weak self] in
            let snapshot = await ProcessTreeService.snapshot(rootPID: rootPID)
            guard
                let self,
                self.session?.id == sessionID,
                self.targetPID == rootPID
            else {
                return
            }
            self.snapshotRefreshInFlight = false
            self.trackedPIDs = snapshot.processIDs
            self.store?.update(snapshot: snapshot)
            self.updateKernelTrace(pids: snapshot.processIDs, sessionID: sessionID)
            self.updateEndpointSecurity(pids: snapshot.processIDs)
        }
    }

    private func startEndpointSecurity(pids: Set<Int32>, session: TraceSession) {
        guard endpointSecurityTelemetryEnabled else { return }
        XPCUIEndpointSecurityStart(
            session.id,
            session.authToken,
            session.socketURL.path,
            pids.sorted().map { NSNumber(value: $0) }
        )
        endpointSecurityStatus = "Requested for \(pids.count) tracked process\(pids.count == 1 ? "" : "es")"
    }

    private func updateEndpointSecurity(pids: Set<Int32>) {
        guard endpointSecurityTelemetryEnabled else { return }
        XPCUIEndpointSecurityUpdateTrackedPIDs(pids.sorted().map { NSNumber(value: $0) })
        endpointSecurityStatus = "Tracking \(pids.count) process\(pids.count == 1 ? "" : "es")"
    }
}

struct TraceSession: Sendable {
    let id: String
    let authToken: String
    let directoryURL: URL
    let socketURL: URL
    let blobsURL: URL

    static func create() throws -> TraceSession {
        // UNIX-domain socket paths are limited to 104 bytes on macOS. A short,
        // private root leaves enough room for the random session identifier.
        let directoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("XPCUI-\(UUID().uuidString)", isDirectory: true)
        let blobsURL = directoryURL.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blobsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return TraceSession(
            id: UUID().uuidString,
            authToken: UUID().uuidString + UUID().uuidString,
            directoryURL: directoryURL,
            socketURL: directoryURL.appendingPathComponent("capture.sock"),
            blobsURL: blobsURL
        )
    }
}
