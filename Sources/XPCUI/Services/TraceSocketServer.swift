import Darwin
import Foundation

final class TraceSocketServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case socketCreation(Int32)
        case pathTooLong
        case bind(Int32)
        case listen(Int32)

        var errorDescription: String? {
            switch self {
            case let .socketCreation(code): "Unable to create capture socket: \(String(cString: strerror(code)))"
            case .pathTooLong: "The transient capture socket path is too long"
            case let .bind(code): "Unable to bind capture socket: \(String(cString: strerror(code)))"
            case let .listen(code): "Unable to listen on capture socket: \(String(cString: strerror(code)))"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.jonluca.xpcui.socket-server", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "com.jonluca.xpcui.socket-connections", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var listeningSocket: Int32 = -1
    private var socketPath: String?
    private var running = false

    func start(session: TraceSession, onFrame: @escaping @Sendable (Data) -> Void) throws {
        stop()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.socketCreation(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = session.socketURL.path
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < pathCapacity else {
            Darwin.close(descriptor)
            throw ServerError.pathTooLong
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { characters in
                path.withCString { source in
                    strncpy(characters, source, pathCapacity - 1)
                }
            }
        }
        Darwin.unlink(path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ServerError.bind(code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 32) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ServerError.listen(code)
        }
        lock.lock()
        listeningSocket = descriptor
        socketPath = path
        running = true
        lock.unlock()
        queue.async { [weak self] in
            self?.acceptConnections(authToken: session.authToken, onFrame: onFrame)
        }
    }

    func stop() {
        lock.lock()
        let descriptor = listeningSocket
        let path = socketPath
        listeningSocket = -1
        socketPath = nil
        running = false
        lock.unlock()
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        if let path {
            Darwin.unlink(path)
        }
    }

    private func acceptConnections(authToken: String, onFrame: @escaping @Sendable (Data) -> Void) {
        while isRunning {
            let descriptor = Darwin.accept(currentSocket, nil, nil)
            guard descriptor >= 0 else {
                if isRunning { continue }
                return
            }
            connectionQueue.async {
                self.consume(descriptor: descriptor, authToken: authToken, onFrame: onFrame)
            }
        }
    }

    private func consume(descriptor: Int32, authToken: String, onFrame: @escaping @Sendable (Data) -> Void) {
        defer { Darwin.close(descriptor) }
        guard
            let authenticationFrame = readFrame(from: descriptor),
            let authentication = try? JSONDecoder().decode(TraceAuthentication.self, from: authenticationFrame),
            authentication.authToken == authToken
        else {
            return
        }
        while let frame = readFrame(from: descriptor) {
            onFrame(frame)
        }
    }

    private func readFrame(from descriptor: Int32) -> Data? {
        guard let header = readExactly(byteCount: 4, from: descriptor) else { return nil }
        let length = header.withUnsafeBytes { pointer -> UInt32 in
            pointer.load(as: UInt32.self).bigEndian
        }
        guard length > 0, length <= 64 * 1024 * 1024 else { return nil }
        return readExactly(byteCount: Int(length), from: descriptor)
    }

    private func readExactly(byteCount: Int, from descriptor: Int32) -> Data? {
        var data = Data(count: byteCount)
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.read(descriptor, baseAddress.advanced(by: offset), byteCount - offset)
                if count <= 0 { return -1 }
                offset += count
            }
            return offset
        }
        return readCount == byteCount ? data : nil
    }

    private var currentSocket: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return listeningSocket
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}
