import SwiftUI

struct ResourcesView: View {
    let snapshot: ProcessSnapshot?

    var body: some View {
        if let snapshot {
            List {
                if let error = snapshot.error {
                    Section("Capability note") {
                        Text(error)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Open files and folders (\(snapshot.files.count))") {
                    ForEach(snapshot.files) { file in
                        Label(file.path, systemImage: file.isDirectory ? "folder" : "doc")
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
            .navigationTitle("Process \(snapshot.pid)")
        } else {
            ContentUnavailableView(
                "No process snapshot",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Launch a target to inspect its open resources.")
            )
        }
    }
}
