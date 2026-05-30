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
                ResourcesView(
                    snapshot: store.snapshot,
                    deltas: store.resourceDeltas,
                    xpcServicesByPID: store.xpcServicesByPID
                )
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
    @ObservedObject var sessionController: SessionController

    init(store: EventStore) {
        self.store = store
        sessionController = store.sessionController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sessionController.status)
                .font(.caption.weight(.semibold))
            Text("\(store.events.count.formatted()) events")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !sessionController.trackedPIDs.isEmpty {
                Text("\(sessionController.trackedPIDs.count.formatted()) tracked process\(sessionController.trackedPIDs.count == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.droppedEventCount > 0 {
                Text("\(store.droppedEventCount.formatted()) dropped")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if store.appDroppedEventCount > 0 {
                    Text("\(store.appDroppedEventCount.formatted()) dropped by UI buffer")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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
                TimelineTable(
                    events: store.visibleEvents,
                    generation: store.timelineGeneration,
                    selection: $store.selectedEventID
                )
                    .frame(minWidth: 580)
                PayloadView(event: store.selectedEvent, loadLazyPayload: store.lazyPayloadLoader)
                    .frame(minWidth: 280, idealWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Live Timeline")
    }
}

private struct CaptureToolbar: View {
    @ObservedObject var store: EventStore
    @ObservedObject var sessionController: SessionController
    @State private var errorMessage: String?
    @State private var showExportWarning = false
    @State private var pendingPreflight: TargetPreflight?

    init(store: EventStore) {
        self.store = store
        sessionController = store.sessionController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Launch Target", systemImage: "play.fill") {
                    selectAndLaunch()
                }
                .buttonStyle(.borderedProminent)
                Button(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play" : "pause") {
                    store.paused.toggle()
                }
                Button("Stop", systemImage: "stop.fill") {
                    sessionController.stop()
                }
                .disabled(sessionController.targetPID == nil)
                Button("Export", systemImage: "square.and.arrow.up") {
                    showExportWarning = true
                }
                .disabled(sessionController.session == nil)
                Divider()
                    .frame(height: 20)
                Toggle("Kernel", isOn: $sessionController.kernelDeepModeEnabled)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(sessionController.targetPID != nil)
                    .help("Opt in to filtered DTrace syscall and mach_trap events before launch.")
                Toggle("NSXPC", isOn: $sessionController.optionalNSXPCLifecycleAdapterEnabled)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(sessionController.targetPID != nil)
                    .help("Opt in to the replaceable NSXPCConnection lifecycle adapter. This uses Objective-C swizzling and is off by default.")
                Menu("Kernel Filters", systemImage: "line.3.horizontal.decrease.circle") {
                    ForEach(KernelTraceService.Category.allCases) { category in
                        Toggle(category.title, isOn: kernelCategoryBinding(category))
                    }
                }
                .disabled(sessionController.targetPID != nil || !sessionController.kernelDeepModeEnabled)
                if sessionController.kernelDeepModeEnabled {
                    Text(sessionController.kernelTraceStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Menu(store.selectedPreset.title, systemImage: store.selectedPreset.icon) {
                    ForEach(TimelinePreset.allCases) { preset in
                        Button {
                            store.apply(preset: preset)
                        } label: {
                            Label(preset.title, systemImage: preset.icon)
                        }
                    }
                }
                Picker("Process", selection: $store.selectedProcessID) {
                    Text("All Processes").tag(Int32?.none)
                    ForEach(store.timelineProcesses) { process in
                        Text(process.title).tag(Optional(process.pid))
                    }
                }
                .frame(width: 200)
                Picker("Category", selection: $store.selectedCategory) {
                    ForEach(store.categories, id: \.self) { category in
                        Text(category.capitalized).tag(category)
                    }
                }
                .frame(width: 140)
                TextField("Search events", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
            }
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
        .sheet(item: $pendingPreflight) { preflight in
            TargetPreflightView(
                preflight: preflight,
                onCancel: { pendingPreflight = nil },
                onLaunch: {
                    pendingPreflight = nil
                    launch(preflight: preflight)
                }
            )
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
            pendingPreflight = await sessionController.preflight(url: url)
        }
    }

    private func launch(preflight: TargetPreflight) {
        Task {
            do {
                try await sessionController.launch(preflight: preflight)
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

    private func kernelCategoryBinding(_ category: KernelTraceService.Category) -> Binding<Bool> {
        Binding(
            get: { sessionController.selectedKernelCategories.contains(category) },
            set: { isEnabled in
                if isEnabled {
                    sessionController.selectedKernelCategories.insert(category)
                } else {
                    sessionController.selectedKernelCategories.remove(category)
                }
            }
        )
    }
}

private struct TargetPreflightView: View {
    let preflight: TargetPreflight
    let onCancel: () -> Void
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Target Preflight")
                    .font(.title2.weight(.semibold))
                Text("\(preflight.targetKind.rawValue): \(preflight.displayName)")
                    .foregroundStyle(.secondary)
                Text(preflight.targetURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            List(preflight.checks) { check in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: check.level.icon)
                        .foregroundStyle(check.level.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title).fontWeight(.medium)
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 260)
            HStack {
                if preflight.hasLimitedCoverage {
                    Text("Launch is allowed, but reported limitations may reduce capture coverage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Launch Capture", action: onLaunch)
                    .buttonStyle(.borderedProminent)
                    .disabled(!preflight.canLaunch)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 430)
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

private extension TargetPreflight.Check.Level {
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
