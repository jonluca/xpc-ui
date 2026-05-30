import XCTest
@testable import XPCUI

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
}
