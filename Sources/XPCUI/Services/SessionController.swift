import AppKit
import Foundation

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var targetPID: Int32?
    @Published private(set) var targetPath: String?
    @Published private(set) var session: TraceSession?
    @Published var deepCaptureEnabled = true

    weak var store: EventStore?

    func stop() {
        status = "Ready"
        targetPID = nil
        targetPath = nil
        session = nil
    }
}

struct TraceSession: Sendable {
    let id: String
    let authToken: String
    let directoryURL: URL
    let socketURL: URL
    let blobsURL: URL

    static func create() throws -> TraceSession {
        let directoryURL = FileManager.default.temporaryDirectory
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
