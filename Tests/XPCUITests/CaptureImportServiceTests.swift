import Foundation
import XCTest
@testable import XPC_UI

final class CaptureImportServiceTests: XCTestCase {
    func testReopenExportRestoresSnapshotAndLazyBlobAccess() throws {
        let session = try TraceSession.create()
        let export = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xpcapture")
        defer {
            try? FileManager.default.removeItem(at: session.directoryURL)
            try? FileManager.default.removeItem(at: export)
        }
        let payload: JSONValue = .object(["message": .string("full fidelity")])
        try JSONEncoder().encode(payload).write(
            to: session.blobsURL.appendingPathComponent("payload.json")
        )
        try CaptureExportService.write(
            session: session,
            events: [
                makeEvent(
                    sessionID: session.id,
                    sequence: 1,
                    payload: .object([
                        "type": .string("lazy-json"),
                        "encoding": .string("json"),
                        "blobReference": .string("payload.json"),
                    ])
                ),
            ],
            snapshot: ProcessTreeSnapshot(rootPID: 3, processes: [makeProcess(pid: 3)]),
            droppedEventCount: 0,
            targetPID: 3,
            targetPath: "/tmp/example",
            to: export
        )

        let reopened = try CaptureImportService.read(from: export)
        let blobStore = BlobStore()
        blobStore.configure(blobsURL: reopened.blobsURL)

        XCTAssertEqual(reopened.manifest.targetPID, 3)
        XCTAssertEqual(reopened.snapshot?.rootPID, 3)
        XCTAssertEqual(reopened.events.count, 1)
        XCTAssertEqual(
            blobStore.loadLazyPayload(try XCTUnwrap(reopened.events.first?.payload)),
            payload
        )
    }

    func testReopenRetainsNewestTimelineWindowAndFullJournalMetadata() throws {
        let session = try TraceSession.create()
        let export = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xpcapture")
        defer {
            try? FileManager.default.removeItem(at: session.directoryURL)
            try? FileManager.default.removeItem(at: export)
        }
        let events = (1...5).map {
            makeEvent(
                sessionID: session.id,
                sequence: UInt64($0),
                pid: Int32($0),
                serviceName: "com.example.service.\($0)"
            )
        }
        try CaptureExportService.write(
            session: session,
            events: events,
            snapshot: nil,
            droppedEventCount: 0,
            targetPID: 1,
            targetPath: "/tmp/example",
            to: export
        )

        let reopened = try CaptureImportService.read(from: export, timelineRetentionLimit: 2)

        XCTAssertEqual(reopened.parsedEventCount, 5)
        XCTAssertEqual(reopened.events.map(\.sequence), [4, 5])
        XCTAssertEqual(reopened.observedProcessIDs, Set([1, 2, 3, 4, 5]))
        XCTAssertEqual(reopened.xpcServicesByPID[1], ["com.example.service.1"])
    }

    func testReopenRejectsManifestEventCountMismatch() throws {
        let session = try TraceSession.create()
        let export = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xpcapture")
        defer {
            try? FileManager.default.removeItem(at: session.directoryURL)
            try? FileManager.default.removeItem(at: export)
        }
        try CaptureExportService.write(
            session: session,
            events: [makeEvent(sessionID: session.id, sequence: 1)],
            snapshot: nil,
            droppedEventCount: 0,
            targetPID: 3,
            targetPath: "/tmp/example",
            to: export
        )
        let manifestURL = export.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["eventCount"] = 2
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        XCTAssertThrowsError(try CaptureImportService.read(from: export)) { error in
            guard
                case CaptureImportService.ImportError.eventCountMismatch(expected: 2, actual: 1) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testEventStoreInstallsOfflineCaptureWorkspaceState() async throws {
        let session = try TraceSession.create()
        let export = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xpcapture")
        defer {
            try? FileManager.default.removeItem(at: session.directoryURL)
            try? FileManager.default.removeItem(at: export)
        }
        try CaptureExportService.write(
            session: session,
            events: [makeEvent(sessionID: session.id, sequence: 1, pid: 3)],
            snapshot: ProcessTreeSnapshot(rootPID: 3, processes: [makeProcess(pid: 3)]),
            droppedEventCount: 4,
            dropCounters: CaptureExportService.DropCounters(
                total: 4,
                uiBuffer: 1,
                journal: 2,
                collectors: [
                    CaptureExportService.CollectorDropCounter(
                        source: "xpc-trace",
                        pid: 3,
                        droppedEventCount: 1
                    ),
                ]
            ),
            targetPID: 3,
            targetPath: "/tmp/example",
            to: export
        )
        let store = EventStore()

        try await store.openCapture(at: export)

        XCTAssertEqual(store.totalCapturedEventCount, 1)
        XCTAssertEqual(store.events.map(\.sequence), [1])
        XCTAssertEqual(store.categories, ["all", "xpc"])
        XCTAssertEqual(store.xpcServicesByPID[3], ["com.example.service"])
        XCTAssertEqual(store.offlineCaptureManifest?.eventCount, 1)
        XCTAssertEqual(store.timelineTitle, "Offline Capture: \(export.lastPathComponent)")
        XCTAssertEqual(store.sessionController.status, "Offline \(export.lastPathComponent)")
        XCTAssertEqual(store.sessionController.trackedPIDs, Set([3]))
        XCTAssertEqual(store.droppedEventCount, 4)
        XCTAssertEqual(store.appDroppedEventCount, 1)
        XCTAssertEqual(store.journalDroppedEventCount, 2)
        XCTAssertEqual(store.tracerDroppedEventCount, 1)
    }

    private func makeEvent(
        sessionID: String,
        sequence: UInt64,
        pid: Int32 = 3,
        serviceName: String = "com.example.service",
        payload: JSONValue = .object(["message": .string("hello")])
    ) -> CaptureEventEnvelope {
        CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: sessionID,
            sequence: sequence,
            monotonicTimestamp: sequence,
            pid: pid,
            parentPID: 1,
            threadID: 4,
            source: "test",
            category: "xpc",
            direction: "outgoing",
            operation: "send",
            serviceName: serviceName,
            summary: "send",
            payload: payload,
            diagnostics: [],
            droppedEventCount: 0
        )
    }

    private func makeProcess(pid: Int32) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPID: 1,
            name: "example",
            path: "/tmp/example",
            error: nil,
            files: [],
            sockets: [],
            machPorts: [],
            machPortSpace: nil
        )
    }
}
