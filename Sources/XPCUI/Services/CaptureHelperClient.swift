import Foundation

final class CaptureHelperClient: @unchecked Sendable {
    static let shared = CaptureHelperClient()

    private init() {}

    func snapshot(pid: Int32) async -> ProcessSnapshot? {
        await withCheckedContinuation { continuation in
            let connection = SendableXPCConnection(
                NSXPCConnection(
                    machServiceName: "com.jonluca.xpcui.capture-helper",
                    options: .privileged
                )
            )
            connection.value.remoteObjectInterface = NSXPCInterface(with: CaptureHelperProtocol.self)
            connection.value.resume()
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
