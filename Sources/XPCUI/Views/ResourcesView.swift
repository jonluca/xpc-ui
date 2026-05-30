import SwiftUI

struct ResourcesView: View {
    let snapshot: ProcessTreeSnapshot?
    let deltas: [Int32: ProcessResourceDelta]
    let xpcServicesByPID: [Int32: Set<String>]
    @State private var selectedPID: Int32?

    var body: some View {
        if let snapshot {
            HSplitView {
                processList(snapshot)
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
                resourceList(selectedSnapshot(in: snapshot))
                    .frame(minWidth: 520)
            }
            .navigationTitle("Tracked Resources")
            .onAppear {
                selectDefaultProcess(in: snapshot)
            }
            .onChange(of: snapshot.processes.map(\.pid)) { _, _ in
                selectDefaultProcess(in: snapshot)
            }
        } else {
            ContentUnavailableView(
                "No process snapshot",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Launch a target to inspect its open resources.")
            )
        }
    }

    private func processList(_ snapshot: ProcessTreeSnapshot) -> some View {
        List(snapshot.processes, selection: $selectedPID) { process in
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name?.isEmpty == false ? process.name! : "Process \(process.pid)")
                    .fontWeight(process.pid == snapshot.rootPID ? .semibold : .regular)
                Text(process.pid == snapshot.rootPID ? "PID \(process.pid) • launch target" : "PID \(process.pid) • child of \(process.parentPID ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(process.pid)
        }
    }

    @ViewBuilder
    private func resourceList(_ snapshot: ProcessSnapshot?) -> some View {
        if let snapshot {
            let delta = deltas[snapshot.pid]
            List {
                if let path = snapshot.path, !path.isEmpty {
                    Section("Executable") {
                        Text(path)
                            .textSelection(.enabled)
                    }
                }
                if let error = snapshot.error {
                    Section("Capability note") {
                        Text(error)
                            .foregroundStyle(.orange)
                    }
                }
                if let delta, !delta.isEmpty {
                    Section("Changes since previous snapshot") {
                        DeltaSummaryRow(
                            title: "Files and folders",
                            added: delta.addedFileIDs.count,
                            removed: delta.removedFileIDs.count
                        )
                        DeltaSummaryRow(
                            title: "Sockets",
                            added: delta.addedSocketIDs.count,
                            removed: delta.removedSocketIDs.count
                        )
                        DeltaSummaryRow(
                            title: "Mach ports",
                            added: delta.addedMachPortNames.count,
                            removed: delta.removedMachPortNames.count
                        )
                    }
                }
                if let machPortSpace = snapshot.machPortSpace {
                    Section("Mach namespace") {
                        LabeledContent("Table capacity", value: machPortSpace.tableSize.formatted())
                        LabeledContent("Table entries", value: machPortSpace.tableEntryCount.formatted())
                        LabeledContent("Tree entries", value: machPortSpace.treeEntryCount.formatted())
                        Text("Mach names are process-local opaque identifiers. Rights are decoded without assigning speculative service names.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let services = xpcServicesByPID[snapshot.pid], !services.isEmpty {
                    Section("Observed XPC services (\(services.count))") {
                        ForEach(services.sorted(), id: \.self) { service in
                            Label(service, systemImage: "arrow.left.arrow.right")
                                .textSelection(.enabled)
                        }
                        Text("These are services observed for this PID, not guessed labels for individual Mach ports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Open files and folders (\(snapshot.files.count))") {
                    ForEach(snapshot.files) { file in
                        HStack {
                            Label(file.path, systemImage: file.isDirectory ? "folder" : "doc")
                                .textSelection(.enabled)
                            if delta?.addedFileIDs.contains(file.id) == true {
                                AddedBadge()
                            }
                        }
                    }
                }
                Section("Sockets (\(snapshot.sockets.count))") {
                    ForEach(snapshot.sockets) { socket in
                        VStack(alignment: .leading) {
                            Text(socket.localEndpoint ?? "fd \(socket.fd)")
                            if let remote = socket.remoteEndpoint {
                                Text("to \(remote)").font(.caption).foregroundStyle(.secondary)
                            }
                            if delta?.addedSocketIDs.contains(socket.id) == true {
                                AddedBadge()
                            }
                        }
                    }
                }
                Section("Mach ports (\(snapshot.machPorts.count))") {
                    ForEach(snapshot.machPorts) { port in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("0x\(String(port.name, radix: 16))")
                                Text(portDetail(port))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if delta?.addedMachPortNames.contains(port.name) == true {
                                AddedBadge()
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a process",
                systemImage: "list.bullet.rectangle",
                description: Text("Choose the launch target or one of its descendants.")
            )
        }
    }

    private func selectedSnapshot(in snapshot: ProcessTreeSnapshot) -> ProcessSnapshot? {
        snapshot.processes.first { $0.pid == selectedPID }
    }

    private func selectDefaultProcess(in snapshot: ProcessTreeSnapshot) {
        guard !snapshot.processes.contains(where: { $0.pid == selectedPID }) else { return }
        selectedPID = snapshot.processes.first(where: { $0.pid == snapshot.rootPID })?.pid
            ?? snapshot.processes.first?.pid
    }

    private func portDetail(_ port: ProcessSnapshot.MachPort) -> String {
        var detail = "\(port.rightsText) • bits 0x\(String(port.typeBits, radix: 16))"
        if let userReferences = port.userReferences {
            detail += " • \(userReferences) refs"
        }
        return detail
    }
}

private struct DeltaSummaryRow: View {
    let title: String
    let added: Int
    let removed: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("+\(added.formatted())")
                .foregroundStyle(.green)
            Text("−\(removed.formatted())")
                .foregroundStyle(.red)
        }
    }
}

private struct AddedBadge: View {
    var body: some View {
        Text("NEW")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
    }
}
