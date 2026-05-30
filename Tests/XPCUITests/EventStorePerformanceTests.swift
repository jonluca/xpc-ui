import XCTest
@testable import XPC_UI

final class EventStorePerformanceTests: XCTestCase {
    func testPendingQueueRemainsBoundedAtSixtySecondSyntheticRate() {
        let queue = PendingEvents(maxCount: 100_000)
        let event = syntheticEvent()

        for _ in 0 ..< (25_000 * 60) {
            queue.append(event)
        }

        XCTAssertEqual(queue.bufferedEventCount, 100_000)
        let batch = queue.drain()
        XCTAssertEqual(batch.events.count, 100_000)
        XCTAssertEqual(batch.overflowDrops, 1_400_000)
        XCTAssertEqual(queue.bufferedEventCount, 0)
    }

    func testTimelineAppendsRowsUntilGenerationChanges() {
        XCTAssertEqual(
            TimelineTable.updateStrategy(
                previousCount: 100,
                nextCount: 125,
                previousGeneration: 4,
                nextGeneration: 4
            ),
            .insertRows(100 ..< 125)
        )
        XCTAssertEqual(
            TimelineTable.updateStrategy(
                previousCount: 125,
                nextCount: 125,
                previousGeneration: 4,
                nextGeneration: 4
            ),
            .noChanges
        )
        XCTAssertEqual(
            TimelineTable.updateStrategy(
                previousCount: 125,
                nextCount: 80,
                previousGeneration: 4,
                nextGeneration: 5
            ),
            .reload
        )
    }

    private func syntheticEvent() -> CaptureEventEnvelope {
        CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: "stress",
            sequence: 1,
            monotonicTimestamp: 1,
            pid: 2,
            parentPID: 1,
            threadID: 3,
            source: "synthetic",
            category: "xpc",
            direction: "outgoing",
            operation: "send",
            serviceName: "com.example.synthetic",
            summary: "synthetic event",
            payload: nil,
            diagnostics: [],
            droppedEventCount: 0
        )
    }
}
