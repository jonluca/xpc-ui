import SwiftUI

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

    var body: some View {
        HStack(spacing: 10) {
            Button("Launch Target", systemImage: "play.fill") {}
                .buttonStyle(.borderedProminent)
            Button(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play" : "pause") {
                store.paused.toggle()
            }
            Button("Stop", systemImage: "stop.fill") {
                store.sessionController.stop()
            }
            .disabled(store.sessionController.targetPID == nil)
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
    }
}

private struct SetupView: View {
    var body: some View {
        ContentUnavailableView(
            "Lab setup diagnostics are coming online",
            systemImage: "wrench.and.screwdriver",
            description: Text("The next checkpoint wires helper registration, SIP status, and capture capabilities.")
        )
    }
}
