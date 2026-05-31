import XCTest
@testable import XPC_UI

final class CaptureEventTests: XCTestCase {
    func testCaptureEventRoundTripsStructuredPayload() throws {
        let event = CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: "session",
            sequence: 7,
            monotonicTimestamp: 123,
            pid: 42,
            parentPID: 1,
            threadID: 9,
            source: "fixture",
            category: "xpc",
            direction: "outgoing",
            operation: "send",
            serviceName: "com.example.fixture",
            summary: "fixture event",
            payload: .object([
                "nested": .array([.string("hello"), .bool(true), .number(42)]),
            ]),
            diagnostics: [],
            droppedEventCount: 0
        )

        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(CaptureEventEnvelope.self, from: data), event)
    }

    func testLegacyCaptureEventDefaultsAdditiveFields() throws {
        let event = try JSONDecoder().decode(
            CaptureEventEnvelope.self,
            from: Data(
                """
                {
                  "sessionID": "legacy",
                  "sequence": 1,
                  "monotonicTimestamp": 2,
                  "pid": 3,
                  "parentPID": 1,
                  "threadID": 4,
                  "source": "legacy-source",
                  "category": "xpc",
                  "direction": "outgoing",
                  "operation": "send",
                  "serviceName": null,
                  "summary": "legacy event",
                  "payload": null
                }
                """.utf8
            )
        )

        XCTAssertEqual(event.schemaVersion, 1)
        XCTAssertEqual(event.diagnostics, [])
        XCTAssertEqual(event.droppedEventCount, 0)
    }

    func testPerProcessSequencesProduceDistinctEventIDs() {
        let parent = makeEvent(pid: 42)
        let child = makeEvent(pid: 43)

        XCTAssertNotEqual(parent.id, child.id)
    }

    private func makeEvent(pid: Int32) -> CaptureEventEnvelope {
        CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: "session",
            sequence: 1,
            monotonicTimestamp: 2,
            pid: pid,
            parentPID: 1,
            threadID: 3,
            source: "injected-xpc",
            category: "xpc",
            direction: "outgoing",
            operation: "send",
            serviceName: nil,
            summary: "send",
            payload: nil,
            diagnostics: [],
            droppedEventCount: 0
        )
    }
}
