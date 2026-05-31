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
        didSet {
            guard selectedCategory != oldValue else { return }
            guard !isApplyingPreset else { return }
            selectedPreset = .all
            rebuildVisibleEvents()
        }
    }
    @Published var selectedProcessID: Int32? {
        didSet {
            guard selectedProcessID != oldValue else { return }
            rebuildVisibleEvents()
        }
    }
    @Published var paused = false
    @Published private(set) var droppedEventCount: UInt64 = 0
    @Published private(set) var appDroppedEventCount: UInt64 = 0
    @Published private(set) var journalDroppedEventCount: UInt64 = 0
    @Published private(set) var tracerDroppedEventCount: UInt64 = 0
    @Published private(set) var snapshot: ProcessTreeSnapshot?
    @Published private(set) var resourceDeltas: [Int32: ProcessResourceDelta] = [:]
    @Published private(set) var xpcServicesByPID: [Int32: Set<String>] = [:]
    @Published private(set) var categories = ["all"]
    @Published private(set) var timelineProcesses: [TimelineProcessOption] = []
    @Published private(set) var selectedPreset = TimelinePreset.all
    @Published private(set) var totalCapturedEventCount = 0
    @Published private(set) var offlineCaptureName: String?
    @Published private(set) var offlineCaptureManifest: CaptureExportService.Manifest?
    @Published private(set) var isOpeningCapture = false

    let sessionController: SessionController

    private let pending = PendingEvents()
    private nonisolated let blobStore = BlobStore()
    private nonisolated let eventJournal = EventJournal()
    private var drainTimer: Timer?
    private let decoder = JSONDecoder()
    private let maxRetainedEvents = 200_000
    private let retainedEventsAfterTrim = 180_000
    private var categorySet = Set<String>()
    private var collectorDropCounts: [CollectorID: UInt64] = [:]
    private var observedProcessIDs = Set<Int32>()
    private var processNamesByPID: [Int32: String] = [:]
    private var launchTargetPID: Int32?
    private var isApplyingPreset = false

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

    var timelineTitle: String {
        offlineCaptureName.map { "Offline Capture: \($0)" } ?? "Live Timeline"
    }

    nonisolated func ingest(frame: Data) {
        do {
            var event = try JSONDecoder().decode(CaptureEventEnvelope.self, from: frame)
            event.payload = blobStore.externalize(event.payload)
            eventJournal.append(event)
            pending.append(event)
        } catch {
            pending.incrementDecodeFailures()
        }
    }

    nonisolated var payloadBlobStore: BlobStore { blobStore }

    func reset() {
        events.removeAll(keepingCapacity: true)
        visibleEvents.removeAll(keepingCapacity: true)
        timelineGeneration += 1
        selectedEventID = nil
        droppedEventCount = 0
        appDroppedEventCount = 0
        journalDroppedEventCount = 0
        tracerDroppedEventCount = 0
        snapshot = nil
        resourceDeltas.removeAll(keepingCapacity: true)
        xpcServicesByPID.removeAll(keepingCapacity: true)
        categorySet.removeAll(keepingCapacity: true)
        categories = ["all"]
        timelineProcesses.removeAll(keepingCapacity: true)
        collectorDropCounts.removeAll(keepingCapacity: true)
        observedProcessIDs.removeAll(keepingCapacity: true)
        processNamesByPID.removeAll(keepingCapacity: true)
        launchTargetPID = nil
        totalCapturedEventCount = 0
        offlineCaptureName = nil
        offlineCaptureManifest = nil
        selectedProcessID = nil
        paused = false
        pending.reset()
        eventJournal.reset()
    }

    func begin(session: TraceSession) throws {
        reset()
        blobStore.configure(blobsURL: session.blobsURL)
        try eventJournal.configure(directoryURL: session.directoryURL)
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
            eventJournal: eventJournal,
            snapshot: snapshot,
            droppedEventCount: droppedEventCount,
            dropCounters: exportDropCounters,
            capabilityResults: sessionController.exportCapabilityResults,
            targetPID: sessionController.capturedTargetPID,
            targetPath: sessionController.capturedTargetPath,
            to: destination
        )
    }

    func openCapture(at bundleURL: URL) async throws {
        isOpeningCapture = true
        defer { isOpeningCapture = false }
        let capture = try await Task.detached(priority: .userInitiated) {
            try CaptureImportService.read(from: bundleURL)
        }.value
        sessionController.stop()
        reset()
        blobStore.configure(blobsURL: capture.blobsURL)
        events = capture.events
        totalCapturedEventCount = capture.parsedEventCount
        offlineCaptureName = bundleURL.lastPathComponent
        offlineCaptureManifest = capture.manifest
        categorySet = capture.categories
        categories = ["all"] + categorySet.sorted()
        observedProcessIDs = capture.observedProcessIDs
        xpcServicesByPID = capture.xpcServicesByPID
        if let snapshot = capture.snapshot {
            update(snapshot: snapshot)
        } else {
            launchTargetPID = capture.manifest.targetPID
            publishTimelineProcesses()
        }
        let dropCounters = capture.manifest.dropCounters
        appDroppedEventCount = dropCounters?.uiBuffer ?? 0
        journalDroppedEventCount = dropCounters?.journal ?? 0
        collectorDropCounts = Dictionary(
            uniqueKeysWithValues: (dropCounters?.collectors ?? []).map {
                (
                    CollectorID(source: $0.source, pid: $0.pid),
                    $0.droppedEventCount
                )
            }
        )
        tracerDroppedEventCount = collectorDropCounts.values.reduce(0, +)
        droppedEventCount = capture.manifest.droppedEventCount
        sessionController.presentOfflineCapture(
            bundleURL: bundleURL,
            manifest: capture.manifest,
            trackedPIDs: observedProcessIDs
        )
        rebuildVisibleEvents()
    }

    func update(snapshot: ProcessTreeSnapshot) {
        let previousByPID = Dictionary(uniqueKeysWithValues: self.snapshot?.processes.map { ($0.pid, $0) } ?? [])
        resourceDeltas = Dictionary(
            uniqueKeysWithValues: snapshot.processes.compactMap { process in
                guard let previous = previousByPID[process.pid] else { return nil }
                return (process.pid, ProcessResourceDelta.between(previous: previous, current: process))
            }
        )
        self.snapshot = snapshot
        launchTargetPID = snapshot.rootPID
        observedProcessIDs.formUnion(snapshot.processIDs)
        for process in snapshot.processes {
            if let name = process.name, !name.isEmpty {
                processNamesByPID[process.pid] = name
            }
        }
        publishTimelineProcesses()
    }

    func apply(preset: TimelinePreset) {
        isApplyingPreset = true
        selectedPreset = preset
        selectedCategory = "all"
        isApplyingPreset = false
        rebuildVisibleEvents()
    }

    private func drainPendingEvents() {
        guard !paused else { return }
        let batch = pending.drain()
        guard !batch.events.isEmpty || batch.decodeFailures > 0 || batch.overflowDrops > 0 else { return }
        let filter = currentFilter
        events.append(contentsOf: batch.events)
        totalCapturedEventCount += batch.events.count
        visibleEvents.append(contentsOf: batch.events.filter(filter.matches))
        let previousProcessCount = observedProcessIDs.count
        observedProcessIDs.formUnion(batch.events.map(\.pid))
        if observedProcessIDs.count != previousProcessCount {
            publishTimelineProcesses()
        }
        let previousCategories = categorySet.count
        categorySet.formUnion(batch.events.map(\.category))
        if categorySet.count != previousCategories {
            categories = ["all"] + categorySet.sorted()
        }
        for event in batch.events where event.category == "xpc" {
            if let serviceName = event.serviceName, !serviceName.isEmpty {
                xpcServicesByPID[event.pid, default: []].insert(serviceName)
            }
        }
        for event in batch.events where event.droppedEventCount > 0 {
            let collector = CollectorID(source: event.source, pid: event.pid)
            collectorDropCounts[collector] = max(
                collectorDropCounts[collector, default: 0],
                event.droppedEventCount
            )
        }
        appDroppedEventCount += batch.decodeFailures + batch.overflowDrops
        journalDroppedEventCount = eventJournal.droppedEventCount
        tracerDroppedEventCount = collectorDropCounts.values.reduce(0, +)
        droppedEventCount = appDroppedEventCount + journalDroppedEventCount + tracerDroppedEventCount
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
        visibleEvents = events.filter(currentFilter.matches)
        if let selectedEventID, !visibleEvents.contains(where: { $0.id == selectedEventID }) {
            self.selectedEventID = nil
        }
        timelineGeneration += 1
    }

    private var currentFilter: TimelineFilter {
        TimelineFilter(
            searchText: searchText,
            category: selectedCategory,
            processID: selectedProcessID,
            preset: selectedPreset
        )
    }

    private func publishTimelineProcesses() {
        let nextProcesses = observedProcessIDs.sorted().map { pid in
            TimelineProcessOption(
                pid: pid,
                name: processNamesByPID[pid],
                isLaunchTarget: pid == launchTargetPID
            )
        }
        if nextProcesses != timelineProcesses {
            timelineProcesses = nextProcesses
        }
    }

    private var exportDropCounters: CaptureExportService.DropCounters {
        CaptureExportService.DropCounters(
            total: droppedEventCount,
            uiBuffer: appDroppedEventCount,
            journal: journalDroppedEventCount,
            collectors: collectorDropCounts
                .map {
                    CaptureExportService.CollectorDropCounter(
                        source: $0.key.source,
                        pid: $0.key.pid,
                        droppedEventCount: $0.value
                    )
                }
                .sorted {
                    ($0.source, $0.pid) < ($1.source, $1.pid)
                }
        )
    }
}

struct TimelineProcessOption: Equatable, Identifiable, Sendable {
    let pid: Int32
    let name: String?
    let isLaunchTarget: Bool

    var id: Int32 { pid }

    var title: String {
        guard let name, !name.isEmpty else {
            return isLaunchTarget ? "PID \(pid) (target)" : "PID \(pid)"
        }
        return isLaunchTarget ? "\(name) (\(pid), target)" : "\(name) (\(pid))"
    }
}

enum TimelinePreset: String, CaseIterable, Identifiable, Sendable {
    case all
    case ipcFirst
    case xpcPayloads
    case intercepted
    case kernelDeep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Traffic"
        case .ipcFirst: "IPC First"
        case .xpcPayloads: "XPC Payloads"
        case .intercepted: "Intercepted"
        case .kernelDeep: "Kernel Deep"
        }
    }

    var icon: String {
        switch self {
        case .all: "list.bullet"
        case .ipcFirst: "arrow.left.arrow.right"
        case .xpcPayloads: "bubble.left.and.bubble.right"
        case .intercepted: "bolt.fill"
        case .kernelDeep: "waveform.path.ecg"
        }
    }
}

struct TimelineFilter: Sendable {
    let searchText: String
    let category: String
    let processID: Int32?
    let preset: TimelinePreset

    func matches(_ event: CaptureEventEnvelope) -> Bool {
        let matchesPreset: Bool
        switch preset {
        case .all:
            matchesPreset = true
        case .ipcFirst:
            matchesPreset = event.category == "xpc" || event.category == "mach_trap"
        case .xpcPayloads:
            matchesPreset = event.category == "xpc"
        case .intercepted:
            matchesPreset = event.isIntercepted
        case .kernelDeep:
            matchesPreset = event.category == "syscall" || event.category == "mach_trap"
        }
        let matchesCategory = category == "all" || event.category == category
        let matchesProcess = processID == nil || event.pid == processID
        let matchesSearch = searchText.isEmpty
            || event.summary.localizedCaseInsensitiveContains(searchText)
            || event.operation.localizedCaseInsensitiveContains(searchText)
            || (event.serviceName?.localizedCaseInsensitiveContains(searchText) ?? false)
        return matchesPreset && matchesCategory && matchesProcess && matchesSearch
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
