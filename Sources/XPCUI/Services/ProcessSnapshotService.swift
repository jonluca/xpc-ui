import Foundation

enum ProcessSnapshotService {
    static func snapshot(pid: Int32) -> ProcessSnapshot {
        guard let pointer = XPCUICopyProcessSnapshotJSON(pid) else {
            return .unavailable(pid: pid, error: "Native snapshot returned no data")
        }
        defer { XPCUIFreeCString(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        do {
            return try JSONDecoder().decode(ProcessSnapshot.self, from: data)
        } catch {
            return .unavailable(pid: pid, error: "Snapshot decode failed: \(error.localizedDescription)")
        }
    }
}
