import Foundation
import Security

private final class CaptureHelper: NSObject, CaptureHelperProtocol {
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
