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
        let userReferences: UInt32?

        var id: UInt32 { name }

        var rightsText: String {
            let labels = Self.rightLabels.compactMap { mask, label in
                typeBits & mask == 0 ? nil : label
            }
            return labels.isEmpty ? "opaque" : labels.joined(separator: ", ")
        }

        private static let rightLabels: [(UInt32, String)] = [
            (1 << 16, "send"),
            (1 << 17, "receive"),
            (1 << 18, "send-once"),
            (1 << 19, "port-set"),
            (1 << 20, "dead-name"),
            (1 << 31, "dead-name request"),
            (1 << 30, "send-possible request"),
            (1 << 29, "delayed send-possible request"),
        ]
    }

    struct MachPortSpace: Codable, Sendable {
        let generationMask: UInt32
        let tableSize: UInt32
        let tableEntryCount: UInt32
        let treeEntryCount: UInt32
    }

    let pid: Int32
    var parentPID: Int32?
    var name: String?
    var path: String?
    let error: String?
    let files: [OpenFile]
    let sockets: [Socket]
    let machPorts: [MachPort]
    let machPortSpace: MachPortSpace?

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
            machPorts: [],
            machPortSpace: nil
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

struct ProcessResourceDelta: Equatable, Sendable {
    let addedFileIDs: Set<String>
    let removedFileIDs: Set<String>
    let addedSocketIDs: Set<String>
    let removedSocketIDs: Set<String>
    let addedMachPortNames: Set<UInt32>
    let removedMachPortNames: Set<UInt32>

    var isEmpty: Bool {
        addedFileIDs.isEmpty
            && removedFileIDs.isEmpty
            && addedSocketIDs.isEmpty
            && removedSocketIDs.isEmpty
            && addedMachPortNames.isEmpty
            && removedMachPortNames.isEmpty
    }

    static func between(previous: ProcessSnapshot, current: ProcessSnapshot) -> ProcessResourceDelta {
        delta(
            previousFileIDs: Set(previous.files.map(\.id)),
            currentFileIDs: Set(current.files.map(\.id)),
            previousSocketIDs: Set(previous.sockets.map(\.id)),
            currentSocketIDs: Set(current.sockets.map(\.id)),
            previousMachPortNames: Set(previous.machPorts.map(\.name)),
            currentMachPortNames: Set(current.machPorts.map(\.name))
        )
    }

    static func delta(
        previousFileIDs: Set<String>,
        currentFileIDs: Set<String>,
        previousSocketIDs: Set<String>,
        currentSocketIDs: Set<String>,
        previousMachPortNames: Set<UInt32>,
        currentMachPortNames: Set<UInt32>
    ) -> ProcessResourceDelta {
        ProcessResourceDelta(
            addedFileIDs: currentFileIDs.subtracting(previousFileIDs),
            removedFileIDs: previousFileIDs.subtracting(currentFileIDs),
            addedSocketIDs: currentSocketIDs.subtracting(previousSocketIDs),
            removedSocketIDs: previousSocketIDs.subtracting(currentSocketIDs),
            addedMachPortNames: currentMachPortNames.subtracting(previousMachPortNames),
            removedMachPortNames: previousMachPortNames.subtracting(currentMachPortNames)
        )
    }
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
