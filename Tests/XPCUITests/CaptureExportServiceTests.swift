import Foundation
import XCTest
@testable import XPC_UI

final class CaptureExportServiceTests: XCTestCase {
    func testTraceSessionUsesPrivateDirectoryPermissions() throws {
        let session = try TraceSession.create()
        defer { try? FileManager.default.removeItem(at: session.directoryURL) }

        let manager = FileManager.default
        let sessionMode = try XCTUnwrap(
            manager.attributesOfItem(atPath: session.directoryURL.path)[.posixPermissions] as? NSNumber
        )
        let blobsMode = try XCTUnwrap(
            manager.attributesOfItem(atPath: session.blobsURL.path)[.posixPermissions] as? NSNumber
        )

        XCTAssertEqual(sessionMode.intValue & 0o777, 0o700)
        XCTAssertEqual(blobsMode.intValue & 0o777, 0o700)
    }

    func testExportWritesReopenableBundle() throws {
        let session = try TraceSession.create()
        let export = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xpcapture")
        defer {
            try? FileManager.default.removeItem(at: session.directoryURL)
            try? FileManager.default.removeItem(at: export)
        }
        let event = CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: session.id,
            sequence: 1,
            monotonicTimestamp: 2,
            pid: 3,
            parentPID: 1,
            threadID: 4,
            source: "test",
            category: "xpc",
            direction: "outgoing",
            operation: "send",
            serviceName: "com.example.service",
            summary: "send",
            payload: .object(["message": .string("hello")]),
            diagnostics: [],
            droppedEventCount: 0
        )

        try CaptureExportService.write(
            session: session,
            events: [event],
            snapshot: ProcessTreeSnapshot(
                rootPID: 3,
                processes: [
                    ProcessSnapshot(
                        pid: 3,
                        parentPID: 1,
                        name: "example",
                        path: "/tmp/example",
                        error: nil,
                        files: [],
                        sockets: [],
                        machPorts: [],
                        machPortSpace: nil
                    ),
                    ProcessSnapshot(
                        pid: 4,
                        parentPID: 3,
                        name: "child",
                        path: "/tmp/child",
                        error: nil,
                        files: [],
                        sockets: [],
                        machPorts: [],
                        machPortSpace: nil
                    ),
                ]
            ),
            droppedEventCount: 9,
            dropCounters: CaptureExportService.DropCounters(
                total: 9,
                uiBuffer: 2,
                collectors: [
                    CaptureExportService.CollectorDropCounter(
                        source: "xpc-trace",
                        pid: 3,
                        droppedEventCount: 7
                    ),
                ]
            ),
            capabilityResults: [
                CaptureExportService.CapabilityResult(
                    id: "injection",
                    title: "Injected XPC payload capture",
                    level: "available",
                    detail: "The bundled XPCTrace dylib will be injected at launch."
                ),
            ],
            targetPID: 3,
            targetPath: "/tmp/example",
            to: export
        )

        let manifestData = try Data(contentsOf: export.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureExportService.Manifest.self, from: manifestData)
        XCTAssertEqual(manifest.eventCount, 1)
        XCTAssertTrue(manifest.includesFullFidelityPayloads)
        XCTAssertEqual(manifest.dropCounters?.total, 9)
        XCTAssertEqual(manifest.dropCounters?.uiBuffer, 2)
        XCTAssertEqual(manifest.dropCounters?.collectors.first?.droppedEventCount, 7)
        XCTAssertEqual(manifest.capabilityResults?.first?.id, "injection")

        let lines = try String(
            contentsOf: export.appendingPathComponent("events.ndjson"),
            encoding: .utf8
        ).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(CaptureEventEnvelope.self, from: Data(lines[0].utf8)),
            event
        )
        let snapshot = try JSONDecoder().decode(
            ProcessTreeSnapshot.self,
            from: Data(contentsOf: export.appendingPathComponent("snapshot.json"))
        )
        XCTAssertEqual(snapshot.rootPID, 3)
        XCTAssertEqual(snapshot.processes.map(\.pid), [3, 4])
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("blobs").path))
    }

    func testLegacyManifestWithoutStructuredResultsStillDecodes() throws {
        let manifest = """
        {
          "schemaVersion": 1,
          "sessionID": "legacy",
          "exportedAt": "2026-05-30T00:00:00Z",
          "eventCount": 0,
          "droppedEventCount": 0,
          "targetPID": null,
          "targetPath": null,
          "includesFullFidelityPayloads": true,
          "capabilityNotes": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CaptureExportService.Manifest.self, from: Data(manifest.utf8))

        XCTAssertNil(decoded.capabilityResults)
        XCTAssertNil(decoded.dropCounters)
    }
}
