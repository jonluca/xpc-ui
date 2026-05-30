import Foundation

enum ProcessTreeService {
    static func snapshot(rootPID: Int32) async -> ProcessTreeSnapshot {
        let identities = await Task.detached(priority: .utility) {
            discoverDirectly(rootPID: rootPID)
        }.value
        let processes = await withTaskGroup(of: ProcessSnapshot.self) { group in
            for identity in identities {
                group.addTask {
                    await ProcessSnapshotService.snapshot(pid: identity.pid)
                        .identified(as: identity)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        return ProcessTreeSnapshot(
            rootPID: rootPID,
            processes: processes.sorted { lhs, rhs in
                lhs.pid == rootPID || (rhs.pid != rootPID && lhs.pid < rhs.pid)
            }
        )
    }

    static func discoverDirectly(rootPID: Int32) -> [TrackedProcess] {
        guard let pointer = XPCUICopyProcessTreeJSON(rootPID) else {
            return [TrackedProcess(pid: rootPID, parentPID: 0, name: "", path: "")]
        }
        defer { XPCUIFreeCString(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        return (try? JSONDecoder().decode([TrackedProcess].self, from: data))?
            .sorted { lhs, rhs in
                lhs.pid == rootPID || (rhs.pid != rootPID && lhs.pid < rhs.pid)
            }
            ?? [TrackedProcess(pid: rootPID, parentPID: 0, name: "", path: "")]
    }
}
