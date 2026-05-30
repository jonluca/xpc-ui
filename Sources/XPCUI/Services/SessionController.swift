import AppKit
import Foundation

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var targetPID: Int32?
    @Published private(set) var targetPath: String?
    @Published private(set) var session: TraceSession?
    @Published var deepCaptureEnabled = true
    @Published var kernelDeepModeEnabled = false
    @Published private(set) var kernelTraceStatus = "Off"

    weak var store: EventStore?
    private let socketServer = TraceSocketServer()
    private let kernelTraceService = KernelTraceService()
    private let kernelTraceDecoder = KernelTraceEventDecoder()
    private var snapshotTimer: Timer?
    private var launchedProcess: Process?

    func stop() {
        socketServer.stop()
        kernelTraceService.stop()
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        launchedProcess = nil
        status = "Ready"
        kernelTraceStatus = "Off"
        targetPID = nil
        targetPath = nil
    }

    func launch(url: URL) async throws {
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
        let environment = try traceEnvironment(for: nextSession)

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
        status = "Capturing \(url.lastPathComponent)"
        if kernelDeepModeEnabled {
            startKernelTrace(pid: pid, sessionID: nextSession.id)
        }
        refreshSnapshot(pid: pid)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot(pid: pid)
            }
        }
    }

    private func startKernelTrace(pid: Int32, sessionID: String) {
        let decoder = kernelTraceDecoder
        do {
            try kernelTraceService.start(
                pid: pid,
                categories: Set(KernelTraceService.Category.allCases),
                onLine: { [weak store] line in
                    guard
                        let event = decoder.decode(line: line, sessionID: sessionID),
                        let frame = try? JSONEncoder().encode(event)
                    else {
                        return
                    }
                    store?.ingest(frame: frame)
                },
                onTermination: { [weak self] status in
                    Task { @MainActor [weak self] in
                        guard self?.targetPID != nil else { return }
                        self?.kernelTraceStatus = status == 0
                            ? "Stopped"
                            : "Unavailable (DTrace exited with status \(status))"
                    }
                }
            )
            kernelTraceStatus = "Requested for PID \(pid)"
        } catch {
            kernelTraceStatus = "Unavailable: \(error.localizedDescription)"
        }
    }

    private func traceEnvironment(for session: TraceSession) throws -> [String: String] {
        var environment = [
            "XPCUI_SESSION_ID": session.id,
            "XPCUI_AUTH_TOKEN": session.authToken,
            "XPCUI_SOCKET_PATH": session.socketURL.path,
        ]
        if deepCaptureEnabled {
            guard let traceLibraryURL = Bundle.main.url(forResource: "XPCTrace", withExtension: "dylib") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "The injected XPCTrace dylib is missing from the app bundle.",
                ])
            }
            environment["DYLD_INSERT_LIBRARIES"] = traceLibraryURL.path
        }
        return environment
    }

    private func refreshSnapshot(pid: Int32) {
        Task { [weak store] in
            let snapshot = await ProcessSnapshotService.snapshot(pid: pid)
            store?.update(snapshot: snapshot)
        }
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
