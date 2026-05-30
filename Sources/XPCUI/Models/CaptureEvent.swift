import Foundation

struct CaptureEventEnvelope: Codable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: String
    var sequence: UInt64
    var monotonicTimestamp: UInt64
    var pid: Int32
    var parentPID: Int32
    var threadID: UInt64
    var source: String
    var category: String
    var direction: String
    var operation: String
    var serviceName: String?
    var summary: String
    var payload: JSONValue?
    var diagnostics: [String]
    var droppedEventCount: UInt64

    var id: String { "\(sessionID):\(source):\(sequence)" }

    var timestampText: String {
        let seconds = Double(monotonicTimestamp) / 1_000_000_000
        return seconds.formatted(.number.precision(.fractionLength(6)))
    }
}

struct TraceAuthentication: Codable {
    let authToken: String
}

struct ProcessSnapshot: Codable, Identifiable, Sendable {
    struct OpenFile: Codable, Identifiable, Sendable {
        let fd: Int32
        let path: String
        let isDirectory: Bool

        var id: String { "\(fd):\(path)" }
    }

    struct Socket: Codable, Identifiable, Sendable {
        let fd: Int32
        let family: Int32
        let type: Int32
        let protocolNumber: Int32
        let localEndpoint: String?
        let remoteEndpoint: String?

        var id: String { "\(fd):\(family):\(localEndpoint ?? ""):\(remoteEndpoint ?? "")" }
    }

    struct MachPort: Codable, Identifiable, Sendable {
        let name: UInt32
        let typeBits: UInt32

        var id: UInt32 { name }
    }

    let pid: Int32
    var parentPID: Int32?
    var name: String?
    var path: String?
    let error: String?
    let files: [OpenFile]
    let sockets: [Socket]
    let machPorts: [MachPort]

    var id: Int32 { pid }

    static func unavailable(pid: Int32, error: String) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPID: nil,
            name: nil,
            path: nil,
            error: error,
            files: [],
            sockets: [],
            machPorts: []
        )
    }

    func identified(as process: TrackedProcess) -> ProcessSnapshot {
        var snapshot = self
        snapshot.parentPID = process.parentPID
        snapshot.name = process.name
        snapshot.path = process.path
        return snapshot
    }
}

struct TrackedProcess: Codable, Hashable, Identifiable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let path: String

    var id: Int32 { pid }
}

struct ProcessTreeSnapshot: Codable, Sendable {
    let rootPID: Int32
    let processes: [ProcessSnapshot]

    var processIDs: Set<Int32> { Set(processes.map(\.pid)) }
}

struct CapabilityStatus: Identifiable, Sendable {
    enum Level: String, Sendable {
        case available
        case limited
        case unavailable
    }

    let id: String
    let title: String
    let level: Level
    let detail: String
}
