import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: EventStore
    @State private var selectedSidebarItem: SidebarItem = .timeline

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSidebarItem) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .navigationTitle("XPC UI")
            .safeAreaInset(edge: .bottom) {
                SidebarStatus(store: store)
            }
        } detail: {
            switch selectedSidebarItem {
            case .timeline:
                TimelineScreen(store: store)
            case .resources:
                ResourcesView(snapshot: store.snapshot)
            case .setup:
                SetupView()
            }
        }
    }
}

private enum SidebarItem: String, CaseIterable, Identifiable {
    case timeline
    case resources
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: "Timeline"
        case .resources: "Resources"
        case .setup: "Lab Setup"
        }
    }

    var icon: String {
        switch self {
        case .timeline: "waveform.path.ecg"
        case .resources: "point.3.connected.trianglepath.dotted"
        case .setup: "checklist"
        }
    }
}

private struct SidebarStatus: View {
    @ObservedObject var store: EventStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.sessionController.status)
                .font(.caption.weight(.semibold))
            Text("\(store.events.count.formatted()) events")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.droppedEventCount > 0 {
                Text("\(store.droppedEventCount.formatted()) dropped")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.bar)
    }
}

private struct TimelineScreen: View {
    @ObservedObject var store: EventStore

    var body: some View {
        VStack(spacing: 0) {
            CaptureToolbar(store: store)
            Divider()
            HSplitView {
                TimelineTable(events: store.visibleEvents, selection: $store.selectedEventID)
                    .frame(minWidth: 580)
                PayloadView(event: store.selectedEvent)
                    .frame(minWidth: 280, idealWidth: 360)
            }
        }
        .navigationTitle("Live Timeline")
    }
}

private struct CaptureToolbar: View {
    @ObservedObject var store: EventStore
    @State private var errorMessage: String?
    @State private var showExportWarning = false

    var body: some View {
        HStack(spacing: 10) {
            Button("Launch Target", systemImage: "play.fill") {
                selectAndLaunch()
            }
                .buttonStyle(.borderedProminent)
            Button(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play" : "pause") {
                store.paused.toggle()
            }
            Button("Stop", systemImage: "stop.fill") {
                store.sessionController.stop()
            }
            .disabled(store.sessionController.targetPID == nil)
            Button("Export", systemImage: "square.and.arrow.up") {
                showExportWarning = true
            }
            .disabled(store.sessionController.session == nil)
            Divider()
                .frame(height: 20)
            Picker("Category", selection: $store.selectedCategory) {
                ForEach(store.categories, id: \.self) { category in
                    Text(category.capitalized).tag(category)
                }
            }
            .frame(width: 150)
            TextField("Search events", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
        }
        .padding(10)
        .alert("Unable to launch target", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Export full-fidelity capture?",
            isPresented: $showExportWarning,
            titleVisibility: .visible
        ) {
            Button("Export Sensitive Payloads") { exportCapture() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The .xpcapture bundle contains unredacted XPC payloads and binary blobs.")
        }
    }

    private func selectAndLaunch() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app bundle or executable"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.sessionController.launch(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportCapture() {
        let panel = NSSavePanel()
        panel.title = "Export Capture"
        panel.nameFieldStringValue = "Capture.xpcapture"
        panel.allowedContentTypes = [UTType(filenameExtension: "xpcapture") ?? .package]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SetupView: View {
    @StateObject private var diagnostics = DiagnosticsService()
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("Deep inspection is designed for a dedicated lab Mac. Protected targets can still expose blind spots, so every capability is reported explicitly.")
                    .foregroundStyle(.secondary)
            }
            Section("Capture capabilities") {
                ForEach(diagnostics.capabilities) { capability in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: capability.level.icon)
                            .foregroundStyle(capability.level.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capability.title).fontWeight(.medium)
                            Text(capability.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Lab Setup")
        .toolbar {
            Button("Register Helper") {
                do {
                    try diagnostics.registerHelper()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                diagnostics.refresh()
            }
        }
        .task {
            diagnostics.refresh()
        }
        .alert("Setup action failed", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private extension CapabilityStatus.Level {
    var icon: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .limited: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .available: .green
        case .limited: .orange
        case .unavailable: .secondary
        }
    }
}
