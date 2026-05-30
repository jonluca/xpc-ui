import Foundation

final class KernelTraceLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        var consumed = buffer.startIndex
        while let newline = buffer[consumed...].firstIndex(of: 0x0a) {
            let line = buffer[consumed ..< newline]
            if !line.isEmpty {
                lines.append(String(decoding: line, as: UTF8.self))
            }
            consumed = buffer.index(after: newline)
        }
        if consumed > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex ..< consumed)
        }
        return lines
    }

    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll(keepingCapacity: false) }
        return [String(decoding: buffer, as: UTF8.self)]
    }
}
