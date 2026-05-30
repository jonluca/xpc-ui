import XCTest
@testable import XPC_UI

final class EventStorePerformanceTests: XCTestCase {
    func testEventJournalBurstRemainsBoundedAndAccountsForDrops() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let export = directory.appendingPathComponent("export.ndjson")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = EventJournal(maxPendingCount: 8)
        try journal.configure(directoryURL: directory)
        defer { journal.reset() }
        let event = syntheticEvent()
        let submittedEventCount = 10_000

        for _ in 0 ..< submittedEventCount {
            journal.append(event)
        }
        let result = try journal.copyEvents(to: export)

        XCTAssertEqual(UInt64(result.eventCount) + result.droppedEventCount, UInt64(submittedEventCount))
        XCTAssertLessThanOrEqual(result.maximumBufferedEventCount, 8)
    }

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

    func testIPCPresetKeepsXPCAndMachTrapEvents() {
        let filter = TimelineFilter(searchText: "", category: "all", processID: nil, preset: .ipcFirst)

        XCTAssertTrue(filter.matches(syntheticEvent(category: "xpc")))
        XCTAssertTrue(filter.matches(syntheticEvent(category: "mach_trap")))
        XCTAssertFalse(filter.matches(syntheticEvent(category: "syscall")))
    }

    func testTimelineFilterIntersectsProcessCategoryAndSearch() {
        let filter = TimelineFilter(searchText: "lookup", category: "xpc", processID: 42, preset: .all)

        XCTAssertTrue(filter.matches(syntheticEvent(pid: 42, category: "xpc", summary: "lookup request")))
        XCTAssertFalse(filter.matches(syntheticEvent(pid: 43, category: "xpc", summary: "lookup request")))
        XCTAssertFalse(filter.matches(syntheticEvent(pid: 42, category: "syscall", summary: "lookup request")))
        XCTAssertFalse(filter.matches(syntheticEvent(pid: 42, category: "xpc", summary: "unrelated")))
    }

    private func syntheticEvent(
        pid: Int32 = 2,
        category: String = "xpc",
        summary: String = "synthetic event"
    ) -> CaptureEventEnvelope {
        CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: "stress",
            sequence: 1,
            monotonicTimestamp: 1,
            pid: pid,
            parentPID: 1,
            threadID: 3,
            source: "synthetic",
            category: category,
            direction: "outgoing",
            operation: "send",
            serviceName: "com.example.synthetic",
            summary: summary,
            payload: nil,
            diagnostics: [],
            droppedEventCount: 0
        )
    }
}
