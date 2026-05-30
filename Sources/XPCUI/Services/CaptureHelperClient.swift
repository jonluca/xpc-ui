import Foundation
import ServiceManagement

final class CaptureHelperClient: @unchecked Sendable {
    static let shared = CaptureHelperClient()

    private let traceLock = NSLock()
    private var activeTrace: ActiveHelperKernelTrace?

    private init() {}

    var isEnabled: Bool {
        SMAppService.daemon(plistName: "com.jonluca.xpcui.capture-helper.plist").status == .enabled
    }

    func snapshot(pid: Int32) async -> ProcessSnapshot? {
        await withCheckedContinuation { continuation in
            let connection = privilegedConnection()
            let completion = CompletionGate<ProcessSnapshot?>(continuation: continuation)
            let proxy = connection.value.remoteObjectProxyWithErrorHandler { _ in
                connection.invalidate()
                completion.resume(returning: nil)
            } as? CaptureHelperProtocol
            proxy?.snapshot(pid: pid) { data, _ in
                connection.invalidate()
                let snapshot = data.flatMap { try? JSONDecoder().decode(ProcessSnapshot.self, from: $0) }
                completion.resume(returning: snapshot)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                connection.invalidate()
                completion.resume(returning: nil)
            }
        }
    }

    func startKernelTrace(
        script: String,
        onLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) async -> String? {
        let traceID = UUID()
        let trace = ActiveHelperKernelTrace(
            id: traceID,
            onLine: onLine,
            onTermination: { [weak self] status in
                self?.clearActiveTrace(id: traceID)
                onTermination(status)
            }
        )
        replaceActiveTrace(with: trace)
        let error: String? = await withCheckedContinuation { continuation in
            let connection = privilegedConnection()
            let completion = CompletionGate<String?>(continuation: continuation)
            let proxy = connection.value.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate()
                completion.resume(returning: "Privileged helper unavailable: \(error.localizedDescription)")
            } as? CaptureHelperProtocol
            guard let proxy else {
                connection.invalidate()
                completion.resume(returning: "Privileged helper returned an invalid proxy.")
                return
            }
            proxy.startKernelTrace(script: script, receiverEndpoint: trace.listener.endpoint) { error in
                connection.invalidate()
                completion.resume(returning: error)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                connection.invalidate()
                completion.resume(returning: "Privileged helper did not respond.")
            }
        }
        if error != nil {
            clearActiveTrace(id: traceID)
        }
        return error
    }

    func stopKernelTrace() {
        traceLock.lock()
        let trace = activeTrace
        activeTrace = nil
        traceLock.unlock()
        trace?.stop()

        guard isEnabled else { return }
        let connection = privilegedConnection()
        let proxy = connection.value.remoteObjectProxyWithErrorHandler { _ in
            connection.invalidate()
        } as? CaptureHelperProtocol
        proxy?.stopKernelTrace {
            connection.invalidate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            connection.invalidate()
        }
    }

    private func privilegedConnection() -> SendableXPCConnection {
        let connection = SendableXPCConnection(
            NSXPCConnection(
                machServiceName: "com.jonluca.xpcui.capture-helper",
                options: .privileged
            )
        )
        connection.value.remoteObjectInterface = NSXPCInterface(with: CaptureHelperProtocol.self)
        connection.value.resume()
        return connection
    }

    private func replaceActiveTrace(with trace: ActiveHelperKernelTrace) {
        traceLock.lock()
        let previousTrace = activeTrace
        activeTrace = trace
        traceLock.unlock()
        previousTrace?.stop()
    }

    private func clearActiveTrace(id: UUID) {
        traceLock.lock()
        let trace = activeTrace?.id == id ? activeTrace : nil
        if trace != nil {
            activeTrace = nil
        }
        traceLock.unlock()
        trace?.stop()
    }
}

private final class ActiveHelperKernelTrace: NSObject, NSXPCListenerDelegate, CaptureHelperKernelTraceReceiver, @unchecked Sendable {
    let id: UUID
    let listener = NSXPCListener.anonymous()

    private let onLine: @Sendable (String) -> Void
    private let onTermination: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    init(
        id: UUID,
        onLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) {
        self.id = id
        self.onLine = onLine
        self.onTermination = onTermination
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CaptureHelperKernelTraceReceiver.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.lock()
            self.connections.removeAll { $0 === connection }
            self.lock.unlock()
        }
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.resume()
        return true
    }

    func receiveKernelTraceLine(_ line: String) {
        onLine(line)
    }

    func kernelTraceDidTerminate(status: Int32) {
        onTermination(status)
    }

    func stop() {
        listener.invalidate()
        lock.lock()
        let connections = connections
        self.connections.removeAll()
        lock.unlock()
        connections.forEach { $0.invalidate() }
    }
}

private final class SendableXPCConnection: @unchecked Sendable {
    let value: NSXPCConnection

    init(_ value: NSXPCConnection) {
        self.value = value
    }

    func invalidate() {
        value.invalidate()
    }
}

private final class CompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
