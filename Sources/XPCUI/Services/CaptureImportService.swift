import Foundation

enum CaptureImportService {
    static let defaultTimelineRetentionLimit = 200_000

    struct Capture: Sendable {
        let manifest: CaptureExportService.Manifest
        let events: [CaptureEventEnvelope]
        let snapshot: ProcessTreeSnapshot?
        let blobsURL: URL
        let parsedEventCount: Int
        let categories: Set<String>
        let observedProcessIDs: Set<Int32>
        let xpcServicesByPID: [Int32: Set<String>]
    }

    static func read(
        from bundleURL: URL,
        timelineRetentionLimit: Int = defaultTimelineRetentionLimit
    ) throws -> Capture {
        guard timelineRetentionLimit > 0 else {
            throw ImportError.invalidRetentionLimit
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard
            manager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ImportError.notCaptureBundle
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard manager.fileExists(atPath: manifestURL.path) else {
            throw ImportError.missingFile("manifest.json")
        }
        let manifest = try decoder.decode(
            CaptureExportService.Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let eventsURL = bundleURL.appendingPathComponent("events.ndjson")
        guard manager.fileExists(atPath: eventsURL.path) else {
            throw ImportError.missingFile("events.ndjson")
        }

        var retainedEvents = RingBuffer<CaptureEventEnvelope>(capacity: timelineRetentionLimit)
        var parsedEventCount = 0
        var categories = Set<String>()
        var observedProcessIDs = Set<Int32>()
        var xpcServicesByPID: [Int32: Set<String>] = [:]
        let reader = try NDJSONLineReader(url: eventsURL)
        defer { reader.close() }
        while let line = try reader.nextLine() {
            guard !line.isEmpty else { continue }
            let event = try decoder.decode(CaptureEventEnvelope.self, from: line)
            guard event.sessionID == manifest.sessionID else {
                throw ImportError.sessionMismatch(
                    expected: manifest.sessionID,
                    actual: event.sessionID
                )
            }
            retainedEvents.append(event)
            parsedEventCount += 1
            categories.insert(event.category)
            observedProcessIDs.insert(event.pid)
            if
                event.category == "xpc",
                let serviceName = event.serviceName,
                !serviceName.isEmpty
            {
                xpcServicesByPID[event.pid, default: []].insert(serviceName)
            }
        }
        guard parsedEventCount == manifest.eventCount else {
            throw ImportError.eventCountMismatch(
                expected: manifest.eventCount,
                actual: parsedEventCount
            )
        }

        let snapshotURL = bundleURL.appendingPathComponent("snapshot.json")
        let snapshot = manager.fileExists(atPath: snapshotURL.path)
            ? try decoder.decode(ProcessTreeSnapshot.self, from: Data(contentsOf: snapshotURL))
            : nil
        return Capture(
            manifest: manifest,
            events: retainedEvents.orderedElements,
            snapshot: snapshot,
            blobsURL: bundleURL.appendingPathComponent("blobs", isDirectory: true),
            parsedEventCount: parsedEventCount,
            categories: categories,
            observedProcessIDs: observedProcessIDs,
            xpcServicesByPID: xpcServicesByPID
        )
    }
}

extension CaptureImportService {
    enum ImportError: LocalizedError {
        case invalidRetentionLimit
        case notCaptureBundle
        case missingFile(String)
        case eventLineTooLarge
        case sessionMismatch(expected: String, actual: String)
        case eventCountMismatch(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .invalidRetentionLimit:
                "The offline timeline retention limit must be greater than zero."
            case .notCaptureBundle:
                "Choose an exported .xpcapture bundle."
            case let .missingFile(filename):
                "The capture bundle is missing \(filename)."
            case .eventLineTooLarge:
                "The capture contains an event larger than the supported 16 MiB envelope limit."
            case let .sessionMismatch(expected, actual):
                "The capture contains an event for session \(actual), but its manifest declares \(expected)."
            case let .eventCountMismatch(expected, actual):
                "The capture manifest declares \(expected) events, but \(actual) were found."
            }
        }
    }
}

private struct RingBuffer<Element> {
    private(set) var elements: [Element] = []
    private var overwriteIndex = 0
    private var didWrap = false
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        elements.reserveCapacity(capacity)
    }

    mutating func append(_ element: Element) {
        guard elements.count == capacity else {
            elements.append(element)
            return
        }
        elements[overwriteIndex] = element
        overwriteIndex = (overwriteIndex + 1) % capacity
        didWrap = true
    }

    var orderedElements: [Element] {
        guard didWrap else { return elements }
        return Array(elements[overwriteIndex...] + elements[..<overwriteIndex])
    }
}

private final class NDJSONLineReader {
    private static let readChunkByteCount = 64 * 1024
    private static let maximumLineByteCount = 16 * 1024 * 1024

    private let handle: FileHandle
    private var buffer = Data()
    private var cursor = 0
    private var reachedEOF = false

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    func close() {
        try? handle.close()
    }

    func nextLine() throws -> Data? {
        while true {
            if let newline = buffer[cursor...].firstIndex(of: 0x0a) {
                let line = Data(buffer[cursor..<newline])
                cursor = newline + 1
                guard line.count <= Self.maximumLineByteCount else {
                    throw CaptureImportService.ImportError.eventLineTooLarge
                }
                compactBufferIfNeeded()
                return line
            }
            if reachedEOF {
                guard cursor < buffer.count else { return nil }
                let line = Data(buffer[cursor...])
                cursor = buffer.count
                guard line.count <= Self.maximumLineByteCount else {
                    throw CaptureImportService.ImportError.eventLineTooLarge
                }
                return line
            }
            compactBufferIfNeeded()
            let chunk = try handle.read(upToCount: Self.readChunkByteCount) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                buffer.append(chunk)
                guard buffer.count - cursor <= Self.maximumLineByteCount else {
                    throw CaptureImportService.ImportError.eventLineTooLarge
                }
            }
        }
    }

    private func compactBufferIfNeeded() {
        guard cursor > 0, cursor == buffer.count || cursor >= Self.readChunkByteCount else {
            return
        }
        buffer.removeSubrange(0..<cursor)
        cursor = 0
    }
}
