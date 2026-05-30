import Foundation

enum CaptureExportService {
    struct Manifest: Codable {
        let schemaVersion: Int
        let sessionID: String
        let exportedAt: Date
        let eventCount: Int
        let droppedEventCount: UInt64
        let targetPID: Int32?
        let targetPath: String?
        let includesFullFidelityPayloads: Bool
        let capabilityNotes: [String]
    }

    static func write(
        session: TraceSession,
        events: [CaptureEventEnvelope],
        snapshot: ProcessSnapshot?,
        droppedEventCount: UInt64,
        targetPID: Int32?,
        targetPath: String?,
        to destination: URL
    ) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = Manifest(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: session.id,
            exportedAt: Date(),
            eventCount: events.count,
            droppedEventCount: droppedEventCount,
            targetPID: targetPID,
            targetPath: targetPath,
            includesFullFidelityPayloads: true,
            capabilityNotes: [
                "Payloads are exported without redaction.",
                "Protected targets may have capability gaps recorded by the app.",
            ]
        )
        try encoder.encode(manifest).write(
            to: destination.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        let compactEncoder = JSONEncoder()
        var eventStream = Data()
        for event in events {
            eventStream.append(try compactEncoder.encode(event))
            eventStream.append(0x0a)
        }
        try eventStream.write(to: destination.appendingPathComponent("events.ndjson"), options: .atomic)
        if let snapshot {
            try encoder.encode(snapshot).write(
                to: destination.appendingPathComponent("snapshot.json"),
                options: .atomic
            )
        }
        let exportedBlobsURL = destination.appendingPathComponent("blobs", isDirectory: true)
        if manager.fileExists(atPath: session.blobsURL.path) {
            try manager.copyItem(at: session.blobsURL, to: exportedBlobsURL)
        } else {
            try manager.createDirectory(at: exportedBlobsURL, withIntermediateDirectories: true)
        }
    }
}
