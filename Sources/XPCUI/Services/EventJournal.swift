import Foundation

final class EventJournal: @unchecked Sendable {
    struct CopyResult {
        let eventCount: Int
        let droppedEventCount: UInt64
        let maximumBufferedEventCount: Int
    }

    private let queue = DispatchQueue(label: "com.jonluca.xpcui.event-journal", qos: .utility)
    private let pendingLock = NSLock()
    private let encoder = JSONEncoder()
    private let maxPendingCount: Int
    private var pendingEvents: [CaptureEventEnvelope] = []
    private var drainScheduled = false
    private var overflowDrops: UInt64 = 0
    private var maximumBufferedEventCountObserved = 0
    private var fileHandle: FileHandle?
    private var journalURL: URL?
    private var eventCount = 0
    private var writeError: Error?

    init(maxPendingCount: Int = 100_000) {
        precondition(maxPendingCount > 0)
        self.maxPendingCount = maxPendingCount
        pendingEvents.reserveCapacity(maxPendingCount)
    }

    func configure(directoryURL: URL) throws {
        try queue.sync {
            try close()
            let journalURL = directoryURL.appendingPathComponent("events.ndjson")
            guard FileManager.default.createFile(
                atPath: journalURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: journalURL.path,
                ])
            }
            fileHandle = try FileHandle(forWritingTo: journalURL)
            self.journalURL = journalURL
            eventCount = 0
            writeError = nil
        }
    }

    func append(_ event: CaptureEventEnvelope) {
        pendingLock.lock()
        if pendingEvents.count < maxPendingCount {
            pendingEvents.append(event)
            maximumBufferedEventCountObserved = max(maximumBufferedEventCountObserved, pendingEvents.count)
        } else {
            overflowDrops += 1
        }
        let shouldScheduleDrain = !drainScheduled && !pendingEvents.isEmpty
        if shouldScheduleDrain {
            drainScheduled = true
        }
        pendingLock.unlock()
        if shouldScheduleDrain {
            queue.async { [self] in
                drainPendingEvents()
            }
        }
    }

    func copyEvents(to destination: URL) throws -> CopyResult {
        try queue.sync {
            if let writeError {
                throw writeError
            }
            guard let journalURL else {
                throw CocoaError(.fileNoSuchFile)
            }
            try fileHandle?.synchronize()
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: journalURL, to: destination)
            return CopyResult(
                eventCount: eventCount,
                droppedEventCount: droppedEventCount,
                maximumBufferedEventCount: maximumBufferedEventCount
            )
        }
    }

    var droppedEventCount: UInt64 {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return overflowDrops
    }

    var maximumBufferedEventCount: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return maximumBufferedEventCountObserved
    }

    func reset() {
        queue.sync {
            try? close()
        }
    }

    private func close() throws {
        try fileHandle?.close()
        fileHandle = nil
        journalURL = nil
        eventCount = 0
        writeError = nil
        pendingLock.lock()
        pendingEvents.removeAll(keepingCapacity: true)
        drainScheduled = false
        overflowDrops = 0
        maximumBufferedEventCountObserved = 0
        pendingLock.unlock()
    }

    private func drainPendingEvents() {
        while true {
            pendingLock.lock()
            guard !pendingEvents.isEmpty else {
                drainScheduled = false
                pendingLock.unlock()
                return
            }
            let batch = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            pendingLock.unlock()

            guard writeError == nil, let fileHandle else {
                incrementDrops(by: batch.count)
                continue
            }
            for (index, event) in batch.enumerated() {
                do {
                    var data = try encoder.encode(event)
                    data.append(0x0a)
                    try fileHandle.write(contentsOf: data)
                    eventCount += 1
                } catch {
                    writeError = error
                    incrementDrops(by: batch.count - index)
                    break
                }
            }
        }
    }

    private func incrementDrops(by count: Int) {
        pendingLock.lock()
        overflowDrops += UInt64(count)
        pendingLock.unlock()
    }
}
