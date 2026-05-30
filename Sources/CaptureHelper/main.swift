import Foundation
import Security

private final class CaptureHelper: NSObject, CaptureHelperProtocol {
    private let traceLock = NSLock()
    private var activeTrace: HelperKernelTrace?

    func snapshot(pid: Int32, withReply reply: @escaping (Data?, String?) -> Void) {
        guard let pointer = XPCUICopyProcessSnapshotJSON(pid) else {
            reply(nil, "Native snapshot returned no data")
            return
        }
        defer { XPCUIFreeCString(pointer) }
        reply(Data(bytes: pointer, count: strlen(pointer)), nil)
    }

    func kernelTracingStatus(withReply reply: @escaping (String) -> Void) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/dtrace")
        process.arguments = ["-l", "-n", "syscall:::entry"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            reply(process.terminationStatus == 0 ? "DTrace syscall probes are available." : output)
        } catch {
            reply("Unable to run DTrace preflight: \(error.localizedDescription)")
        }
    }

    func startKernelTrace(
        script: String,
        receiverEndpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (String?) -> Void
    ) {
        let trace = HelperKernelTrace(script: script, receiverEndpoint: receiverEndpoint)
        traceLock.lock()
        let previousTrace = activeTrace
        activeTrace = trace
        traceLock.unlock()
        previousTrace?.stop()
        do {
            try trace.start { [weak self, weak trace] in
                guard let self, let trace else { return }
                self.clear(trace: trace)
            }
            reply(nil)
        } catch {
            clear(trace: trace)
            trace.stop()
            reply("Unable to start privileged DTrace: \(error.localizedDescription)")
        }
    }

    func stopKernelTrace(withReply reply: @escaping () -> Void) {
        traceLock.lock()
        let trace = activeTrace
        activeTrace = nil
        traceLock.unlock()
        trace?.stop()
        reply()
    }

    private func clear(trace: HelperKernelTrace) {
        traceLock.lock()
        if activeTrace === trace {
            activeTrace = nil
        }
        traceLock.unlock()
    }
}

private final class HelperKernelTrace: @unchecked Sendable {
    private let script: String
    private let pipe = Pipe()
    private let process = Process()
    private let lineBuffer = KernelTraceLineBuffer()
    private let callbackConnection: NSXPCConnection

    init(script: String, receiverEndpoint: NSXPCListenerEndpoint) {
        self.script = script
        callbackConnection = NSXPCConnection(listenerEndpoint: receiverEndpoint)
    }

    func start(onTermination: @escaping @Sendable () -> Void) throws {
        callbackConnection.remoteObjectInterface = NSXPCInterface(with: CaptureHelperKernelTraceReceiver.self)
        callbackConnection.resume()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/dtrace")
        process.arguments = ["-q", "-n", script]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.emit(data: handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.pipe.fileHandleForReading.readabilityHandler = nil
            self.emit(data: self.pipe.fileHandleForReading.readDataToEndOfFile())
            self.lineBuffer.finish().forEach(self.emit(line:))
            self.receiver?.kernelTraceDidTerminate(status: process.terminationStatus)
            self.callbackConnection.invalidate()
            onTermination()
        }
        try process.run()
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        } else {
            callbackConnection.invalidate()
        }
    }

    private var receiver: CaptureHelperKernelTraceReceiver? {
        callbackConnection.remoteObjectProxy as? CaptureHelperKernelTraceReceiver
    }

    private func emit(data: Data) {
        lineBuffer.append(data).forEach(emit(line:))
    }

    private func emit(line: String) {
        receiver?.receiveKernelTraceLine(line)
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let helper = CaptureHelper()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard Self.isTrustedClient(pid: connection.processIdentifier) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: CaptureHelperProtocol.self)
        connection.exportedObject = helper
        connection.resume()
        return true
    }

    private static func isTrustedClient(pid: pid_t) -> Bool {
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return false
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let signingInformation = information as? [CFString: Any],
              let identifier = signingInformation[kSecCodeInfoIdentifier] as? String
        else {
            return false
        }
        return identifier == "com.jonluca.xpcui"
    }
}

private let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: "com.jonluca.xpcui.capture-helper")
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
