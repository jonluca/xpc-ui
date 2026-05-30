import Foundation
import XCTest
@testable import XPC_UI

final class CaptureExportServiceTests: XCTestCase {
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
            snapshot: nil,
            droppedEventCount: 0,
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

        let lines = try String(
            contentsOf: export.appendingPathComponent("events.ndjson"),
            encoding: .utf8
        ).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(CaptureEventEnvelope.self, from: Data(lines[0].utf8)),
            event
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("blobs").path))
    }
}
