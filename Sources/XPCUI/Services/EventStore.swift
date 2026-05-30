import Foundation

@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [CaptureEventEnvelope] = []
    @Published var selectedEventID: CaptureEventEnvelope.ID?
    @Published var searchText = ""
    @Published var selectedCategory = "all"
    @Published var paused = false
    @Published private(set) var droppedEventCount: UInt64 = 0
    @Published private(set) var snapshot: ProcessTreeSnapshot?

    let sessionController: SessionController

    private let pending = PendingEvents()
    private nonisolated let blobStore = BlobStore()
    private var drainTimer: Timer?
    private let decoder = JSONDecoder()
    private let maxRetainedEvents = 200_000

    init() {
        sessionController = SessionController()
        sessionController.store = nil
        sessionController.store = self
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainPendingEvents() }
        }
    }

    var visibleEvents: [CaptureEventEnvelope] {
        events.filter { event in
            let matchesCategory = selectedCategory == "all" || event.category == selectedCategory
            let matchesSearch = searchText.isEmpty
                || event.summary.localizedCaseInsensitiveContains(searchText)
                || event.operation.localizedCaseInsensitiveContains(searchText)
                || (event.serviceName?.localizedCaseInsensitiveContains(searchText) ?? false)
            return matchesCategory && matchesSearch
        }
    }

    var selectedEvent: CaptureEventEnvelope? {
        events.first { $0.id == selectedEventID }
    }

    var categories: [String] {
        ["all"] + Array(Set(events.map(\.category))).sorted()
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

    nonisolated func loadLazyPayload(_ value: JSONValue) -> JSONValue? {
        blobStore.loadLazyPayload(value)
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
        selectedEventID = nil
        droppedEventCount = 0
        snapshot = nil
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
        guard !batch.events.isEmpty || batch.decodeFailures > 0 else { return }
        events.append(contentsOf: batch.events)
        droppedEventCount = batch.events.last?.droppedEventCount ?? droppedEventCount
        droppedEventCount += batch.decodeFailures
        if events.count > maxRetainedEvents {
            events.removeFirst(events.count - maxRetainedEvents)
        }
    }
}

private final class PendingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CaptureEventEnvelope] = []
    private var decodeFailures: UInt64 = 0

    func append(_ event: CaptureEventEnvelope) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func incrementDecodeFailures() {
        lock.lock()
        decodeFailures += 1
        lock.unlock()
    }

    func drain() -> (events: [CaptureEventEnvelope], decodeFailures: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let drainedEvents = events
        let drainedFailures = decodeFailures
        events.removeAll(keepingCapacity: true)
        decodeFailures = 0
        return (drainedEvents, drainedFailures)
    }

    func reset() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        decodeFailures = 0
        lock.unlock()
    }
}
