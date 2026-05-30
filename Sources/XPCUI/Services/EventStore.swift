import Foundation

@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [CaptureEventEnvelope] = []
    @Published private(set) var visibleEvents: [CaptureEventEnvelope] = []
    @Published private(set) var timelineGeneration = 0
    @Published var selectedEventID: CaptureEventEnvelope.ID?
    @Published var searchText = "" {
        didSet { rebuildVisibleEvents() }
    }
    @Published var selectedCategory = "all" {
        didSet { rebuildVisibleEvents() }
    }
    @Published var paused = false
    @Published private(set) var droppedEventCount: UInt64 = 0
    @Published private(set) var appDroppedEventCount: UInt64 = 0
    @Published private(set) var tracerDroppedEventCount: UInt64 = 0
    @Published private(set) var snapshot: ProcessTreeSnapshot?
    @Published private(set) var categories = ["all"]

    let sessionController: SessionController

    private let pending = PendingEvents()
    private nonisolated let blobStore = BlobStore()
    private var drainTimer: Timer?
    private let decoder = JSONDecoder()
    private let maxRetainedEvents = 200_000
    private let retainedEventsAfterTrim = 180_000
    private var categorySet = Set<String>()
    private var collectorDropCounts: [CollectorID: UInt64] = [:]

    init() {
        sessionController = SessionController()
        sessionController.store = nil
        sessionController.store = self
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainPendingEvents() }
        }
    }

    var selectedEvent: CaptureEventEnvelope? {
        events.first { $0.id == selectedEventID }
    }

    nonisolated func ingest(frame: Data) {
        do {
            var event = try JSONDecoder().decode(CaptureEventEnvelope.self, from: frame)
            event.payload = blobStore.externalize(event.payload)
            pending.append(event)
        } catch {
            pending.incrementDecodeFailures()
        }
    }

    nonisolated var lazyPayloadLoader: @Sendable (JSONValue) -> JSONValue? {
        let blobStore = blobStore
        return { value in
            blobStore.loadLazyPayload(value)
        }
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
        visibleEvents.removeAll(keepingCapacity: true)
        timelineGeneration += 1
        selectedEventID = nil
        droppedEventCount = 0
        appDroppedEventCount = 0
        tracerDroppedEventCount = 0
        snapshot = nil
        categorySet.removeAll(keepingCapacity: true)
        categories = ["all"]
        collectorDropCounts.removeAll(keepingCapacity: true)
        pending.reset()
    }

    func begin(session: TraceSession) {
        reset()
        blobStore.configure(blobsURL: session.blobsURL)
    }

    func export(to destination: URL) throws {
        guard let session = sessionController.session else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Launch a capture session before exporting.",
            ])
        }
        try CaptureExportService.write(
            session: session,
            events: events,
            snapshot: snapshot,
            droppedEventCount: droppedEventCount,
            targetPID: sessionController.targetPID,
            targetPath: sessionController.targetPath,
            to: destination
        )
    }

    func update(snapshot: ProcessTreeSnapshot) {
        self.snapshot = snapshot
    }

    private func drainPendingEvents() {
        guard !paused else { return }
        let batch = pending.drain()
        guard !batch.events.isEmpty || batch.decodeFailures > 0 || batch.overflowDrops > 0 else { return }
        events.append(contentsOf: batch.events)
        visibleEvents.append(contentsOf: batch.events.filter(matchesCurrentFilter))
        let previousCategories = categorySet.count
        categorySet.formUnion(batch.events.map(\.category))
        if categorySet.count != previousCategories {
            categories = ["all"] + categorySet.sorted()
        }
        for event in batch.events where event.droppedEventCount > 0 {
            let collector = CollectorID(source: event.source, pid: event.pid)
            collectorDropCounts[collector] = max(
                collectorDropCounts[collector, default: 0],
                event.droppedEventCount
            )
        }
        appDroppedEventCount += batch.decodeFailures + batch.overflowDrops
        tracerDroppedEventCount = collectorDropCounts.values.reduce(0, +)
        droppedEventCount = appDroppedEventCount + tracerDroppedEventCount
        if events.count > maxRetainedEvents {
            let removalCount = events.count - retainedEventsAfterTrim
            let removedIDs = Set(events.prefix(removalCount).map(\.id))
            events.removeFirst(removalCount)
            visibleEvents.removeAll { removedIDs.contains($0.id) }
            if let selectedEventID, removedIDs.contains(selectedEventID) {
                self.selectedEventID = nil
            }
            timelineGeneration += 1
        }
    }

    private func rebuildVisibleEvents() {
        visibleEvents = events.filter(matchesCurrentFilter)
        timelineGeneration += 1
    }

    private func matchesCurrentFilter(_ event: CaptureEventEnvelope) -> Bool {
        let matchesCategory = selectedCategory == "all" || event.category == selectedCategory
        let matchesSearch = searchText.isEmpty
            || event.summary.localizedCaseInsensitiveContains(searchText)
            || event.operation.localizedCaseInsensitiveContains(searchText)
            || (event.serviceName?.localizedCaseInsensitiveContains(searchText) ?? false)
        return matchesCategory && matchesSearch
    }
}

private struct CollectorID: Hashable {
    let source: String
    let pid: Int32
}

struct PendingEventBatch {
    let events: [CaptureEventEnvelope]
    let decodeFailures: UInt64
    let overflowDrops: UInt64
}

final class PendingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let maxCount: Int
    private var events: [CaptureEventEnvelope] = []
    private var decodeFailures: UInt64 = 0
    private var overflowDrops: UInt64 = 0

    init(maxCount: Int = 100_000) {
        precondition(maxCount > 0)
        self.maxCount = maxCount
        events.reserveCapacity(maxCount)
    }

    func append(_ event: CaptureEventEnvelope) {
        lock.lock()
        if events.count < maxCount {
            events.append(event)
        } else {
            overflowDrops += 1
        }
        lock.unlock()
    }

    func incrementDecodeFailures() {
        lock.lock()
        decodeFailures += 1
        lock.unlock()
    }

    func drain() -> PendingEventBatch {
        lock.lock()
        defer { lock.unlock() }
        let batch = PendingEventBatch(
            events: events,
            decodeFailures: decodeFailures,
            overflowDrops: overflowDrops
        )
        events.removeAll(keepingCapacity: true)
        decodeFailures = 0
        overflowDrops = 0
        return batch
    }

    var bufferedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func reset() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        decodeFailures = 0
        overflowDrops = 0
        lock.unlock()
    }
}
