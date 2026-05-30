import Darwin
import Foundation
import XCTest
@testable import XPC_UI

final class TraceSocketServerTests: XCTestCase {
    func testServerAcceptsFramesAfterAuthentication() throws {
        let session = try TraceSession.create()
        defer { try? FileManager.default.removeItem(at: session.directoryURL) }
        let server = TraceSocketServer()
        defer { server.stop() }
        let received = expectation(description: "Received authenticated frame")
        let expected = Data("capture-event".utf8)
        try server.start(session: session) { frame in
            XCTAssertEqual(frame, expected)
            received.fulfill()
        }

        let descriptor = try connect(to: session.socketURL.path)
        defer { Darwin.close(descriptor) }
        try writeFrame(try JSONEncoder().encode(TraceAuthentication(authToken: session.authToken)), to: descriptor)
        try writeFrame(expected, to: descriptor)

        wait(for: [received], timeout: 1)
    }

    func testServerRejectsFramesWithWrongToken() throws {
        let session = try TraceSession.create()
        defer { try? FileManager.default.removeItem(at: session.directoryURL) }
        let server = TraceSocketServer()
        defer { server.stop() }
        let received = expectation(description: "Rejected unauthenticated frame")
        received.isInverted = true
        try server.start(session: session) { _ in received.fulfill() }

        let descriptor = try connect(to: session.socketURL.path)
        defer { Darwin.close(descriptor) }
        try writeFrame(try JSONEncoder().encode(TraceAuthentication(authToken: "wrong-token")), to: descriptor)
        try writeFrame(Data("capture-event".utf8), to: descriptor)

        wait(for: [received], timeout: 0.1)
    }

    private func connect(to path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { characters in
                path.withCString { strncpy(characters, $0, capacity - 1) }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw posixError()
        }
        return descriptor
    }

    private func writeFrame(_ data: Data, to descriptor: Int32) throws {
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll(Data($0), to: descriptor) }
        try writeAll(data, to: descriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), data.count - offset)
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
