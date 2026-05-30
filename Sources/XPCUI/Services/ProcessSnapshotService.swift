import Foundation

enum ProcessSnapshotService {
    static func snapshot(pid: Int32) async -> ProcessSnapshot {
        let directSnapshot = await Task.detached(priority: .utility) {
            snapshotDirectly(pid: pid)
        }.value
        guard directSnapshot.error != nil else { return directSnapshot }
        return await CaptureHelperClient.shared.snapshot(pid: pid) ?? directSnapshot
    }

    static func snapshotDirectly(pid: Int32) -> ProcessSnapshot {
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
