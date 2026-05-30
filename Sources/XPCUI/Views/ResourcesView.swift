import SwiftUI

struct ResourcesView: View {
    let snapshot: ProcessTreeSnapshot?
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
                Section("Open files and folders (\(snapshot.files.count))") {
                    ForEach(snapshot.files) { file in
                        Label(file.path, systemImage: file.isDirectory ? "folder" : "doc")
                            .textSelection(.enabled)
                    }
                }
                Section("Sockets (\(snapshot.sockets.count))") {
                    ForEach(snapshot.sockets) { socket in
                        VStack(alignment: .leading) {
                            Text(socket.localEndpoint ?? "fd \(socket.fd)")
                            if let remote = socket.remoteEndpoint {
                                Text("to \(remote)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Mach ports (\(snapshot.machPorts.count))") {
                    ForEach(snapshot.machPorts) { port in
                        LabeledContent("0x\(String(port.name, radix: 16))", value: "rights 0x\(String(port.typeBits, radix: 16))")
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
}
