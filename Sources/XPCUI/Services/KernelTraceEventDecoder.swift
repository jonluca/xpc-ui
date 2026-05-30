import Foundation

final class KernelTraceEventDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    func decode(line: String, sessionID: String) -> CaptureEventEnvelope? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard
            fields.count == 6,
            let pid = Int32(fields[3]),
            let parentPID = Int32(fields[4]),
            let threadID = UInt64(fields[5])
        else {
            return nil
        }

        lock.lock()
        sequence += 1
        let nextSequence = sequence
        lock.unlock()

        let category = String(fields[0])
        let direction = String(fields[1])
        let operation = String(fields[2])
        return CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: sessionID,
            sequence: nextSequence,
            monotonicTimestamp: DispatchTime.now().uptimeNanoseconds,
            pid: pid,
            parentPID: parentPID,
            threadID: threadID,
            source: "dtrace",
            category: category,
            direction: direction,
            operation: operation,
            serviceName: nil,
            summary: "\(category) \(operation)",
            payload: .object([
                "provider": .string(category),
                "probe": .string(operation),
            ]),
            diagnostics: [],
            droppedEventCount: 0
        )
    }
}
