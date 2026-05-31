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
            Text("\(store.totalCapturedEventCount.formatted()) events")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.totalCapturedEventCount > store.events.count {
                Text("\(store.events.count.formatted()) in timeline window")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
                if store.journalDroppedEventCount > 0 {
                    Text("\(store.journalDroppedEventCount.formatted()) dropped by session journal")
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
    @State private var preparedInterceptionRule: InterceptionRule?
    @State private var interceptionRuleErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            CaptureToolbar(store: store)
            Divider()
            Group {
                if let selectedEvent = store.selectedEvent {
                    HSplitView {
                        timelineTable
                        PayloadView(
                            event: selectedEvent,
                            blobStore: store.payloadBlobStore,
                            onDraftInterceptionRule: prepareInterceptionRule
                        )
                            .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
                    }
                } else {
                    timelineTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(store.timelineTitle)
        .sheet(item: $preparedInterceptionRule) { rule in
            InterceptionRuleEditor(rule: rule) { savedRule in
                do {
                    try store.sessionController.interceptionRules.add(savedRule)
                    preparedInterceptionRule = nil
                } catch {
                    interceptionRuleErrorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "Unable to save interception rule",
            isPresented: .constant(interceptionRuleErrorMessage != nil)
        ) {
            Button("OK") { interceptionRuleErrorMessage = nil }
        } message: {
            Text(interceptionRuleErrorMessage ?? "")
        }
    }

    private var timelineTable: some View {
        TimelineTable(
            events: store.visibleEvents,
            generation: store.timelineGeneration,
            selection: $store.selectedEventID,
            onPrepareInterceptionRule: prepareInterceptionRule
        )
        .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prepareInterceptionRule(from event: CaptureEventEnvelope) {
        preparedInterceptionRule = InterceptionRule.prepared(from: event)
    }
}

private struct CaptureToolbar: View {
    @ObservedObject var store: EventStore
    @ObservedObject var sessionController: SessionController
    @State private var errorMessage: String?
    @State private var showExportWarning = false
    @State private var showInterceptionRules = false
    @State private var showOfflineCaptureInfo = false
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
                Button(store.isOpeningCapture ? "Opening..." : "Open Capture", systemImage: "folder") {
                    openCapture()
                }
                .disabled(sessionController.targetPID != nil || store.isOpeningCapture)
                Button(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play" : "pause") {
                    store.paused.toggle()
                }
                .disabled(sessionController.targetPID == nil)
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
                    .disabled(preLaunchConfigurationDisabled)
                    .help("Collect filtered DTrace syscall and mach_trap events when available. This starts on when dtrace is installed.")
                Toggle("NSXPC", isOn: $sessionController.optionalNSXPCLifecycleAdapterEnabled)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(preLaunchConfigurationDisabled)
                    .help("Collect NSXPCConnection lifecycle events when the tracer is available. This uses Objective-C swizzling and starts on when bundled.")
                Toggle("ES", isOn: $sessionController.endpointSecurityTelemetryEnabled)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(preLaunchConfigurationDisabled)
                    .help("Collect supported Endpoint Security telemetry when the entitlement-gated system extension is embedded and activated.")
                Menu("Kernel Filters", systemImage: "line.3.horizontal.decrease.circle") {
                    ForEach(KernelTraceService.Category.allCases) { category in
                        Toggle(category.title, isOn: kernelCategoryBinding(category))
                    }
                }
                .disabled(preLaunchConfigurationDisabled || !sessionController.kernelDeepModeEnabled)
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
                Toggle("Intercept", isOn: interceptionEnabledBinding)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(preLaunchConfigurationDisabled)
                    .help("Lab-only opt in. Matching pre-launch rules may modify selected XPC arguments or responses before forwarding.")
                Button("Rules \(sessionController.interceptionRules.enabledRuleCount)") {
                    showInterceptionRules = true
                }
                .help("Review and edit rules for the next target launch.")
                if store.offlineCaptureManifest != nil {
                    Button("Capture Info", systemImage: "info.circle") {
                        showOfflineCaptureInfo = true
                    }
                }
                Spacer()
            }
        }
        .padding(10)
        .alert("Capture action failed", isPresented: .constant(errorMessage != nil)) {
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
            Text("The .xpcapture bundle contains unredacted XPC payloads, binary blobs, and any lab-only interception rules used for the session.")
        }
        .sheet(item: $pendingPreflight) { preflight in
            TargetPreflightView(
                preflight: preflight,
                interceptionRuleCount: sessionController.interceptionRules.enabled
                    ? sessionController.interceptionRules.enabledRuleCount
                    : 0,
                onCancel: { pendingPreflight = nil },
                onLaunch: {
                    pendingPreflight = nil
                    launch(preflight: preflight)
                }
            )
        }
        .sheet(isPresented: $showInterceptionRules) {
            InterceptionRulesView(store: sessionController.interceptionRules)
        }
        .sheet(isPresented: $showOfflineCaptureInfo) {
            if
                let manifest = store.offlineCaptureManifest,
                let bundleURL = sessionController.offlineCaptureURL
            {
                OfflineCaptureInfoView(
                    manifest: manifest,
                    bundleURL: bundleURL,
                    retainedEventCount: store.events.count
                )
            }
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

    private func openCapture() {
        let panel = NSOpenPanel()
        panel.title = "Open Capture"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xpcapture") ?? .package]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.openCapture(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
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

    private var interceptionEnabledBinding: Binding<Bool> {
        Binding(
            get: { sessionController.interceptionRules.enabled },
            set: { sessionController.interceptionRules.enabled = $0 }
        )
    }

    private var preLaunchConfigurationDisabled: Bool {
        sessionController.targetPID != nil || sessionController.offlineCaptureURL != nil
    }
}

private struct OfflineCaptureInfoView: View {
    let manifest: CaptureExportService.Manifest
    let bundleURL: URL
    let retainedEventCount: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Offline Capture")
                    .font(.title2.weight(.semibold))
                Text(bundleURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            List {
                Section("Evidence") {
                    LabeledContent("Session", value: manifest.sessionID)
                    LabeledContent("Exported", value: manifest.exportedAt.formatted())
                    LabeledContent("Events", value: manifest.eventCount.formatted())
                    LabeledContent("Timeline window", value: retainedEventCount.formatted())
                    LabeledContent("Dropped", value: manifest.droppedEventCount.formatted())
                    if let targetPID = manifest.targetPID {
                        LabeledContent("Target PID", value: String(targetPID))
                    }
                    if let targetPath = manifest.targetPath {
                        LabeledContent("Target", value: targetPath)
                    }
                }
                if let counters = manifest.dropCounters {
                    Section("Drop Counters") {
                        LabeledContent("UI buffer", value: counters.uiBuffer.formatted())
                        if let journal = counters.journal {
                            LabeledContent("Journal", value: journal.formatted())
                        }
                        ForEach(counters.collectors, id: \.self) { collector in
                            LabeledContent(
                                "\(collector.source) PID \(collector.pid)",
                                value: collector.droppedEventCount.formatted()
                            )
                        }
                    }
                }
                if let capabilityResults = manifest.capabilityResults, !capabilityResults.isEmpty {
                    Section("Capture Capabilities") {
                        ForEach(capabilityResults, id: \.id) { capability in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(capability.title).fontWeight(.medium)
                                    Spacer()
                                    Text(capability.level)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(capabilityColor(capability.level))
                                }
                                Text(capability.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                Section("Evidence Warnings") {
                    ForEach(manifest.capabilityNotes, id: \.self, content: Text.init)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 540)
    }

    private func capabilityColor(_ level: String) -> Color {
        switch level {
        case "available": .green
        case "limited", "requested": .orange
        default: .secondary
        }
    }
}

private struct TargetPreflightView: View {
    let preflight: TargetPreflight
    let interceptionRuleCount: Int
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
            if interceptionRuleCount > 0 {
                Label(
                    "Lab-only interception is enabled. \(interceptionRuleCount) matching rule\(interceptionRuleCount == 1 ? "" : "s") may modify selected XPC arguments or responses before forwarding.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
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
    @StateObject private var endpointSecurity = EndpointSecurityAdapter.shared
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
            Button("Activate ES") {
                endpointSecurity.activate()
            }
            Button("Deactivate ES") {
                endpointSecurity.deactivate()
            }
            Button("Full Disk Access") {
                endpointSecurity.openFullDiskAccessSettings()
            }
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
        .safeAreaInset(edge: .bottom) {
            Text("Endpoint Security: \(endpointSecurity.activationStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
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
