import SwiftUI

struct PayloadView: View {
    let event: CaptureEventEnvelope?
    let loadLazyPayload: @Sendable (JSONValue) -> JSONValue?

    var body: some View {
        Group {
            if let event {
                List {
                    Section("Event") {
                        LabeledContent("Operation", value: event.operation)
                        LabeledContent("PID", value: String(event.pid))
                        LabeledContent("Direction", value: event.direction)
                        if let serviceName = event.serviceName {
                            LabeledContent("Service", value: serviceName)
                        }
                    }
                    if let payload = event.payload {
                        Section("Payload") {
                            PayloadRootView(value: payload, loadLazyPayload: loadLazyPayload)
                        }
                    }
                    if !event.diagnostics.isEmpty {
                        Section("Diagnostics") {
                            ForEach(event.diagnostics, id: \.self, content: Text.init)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Select an event", systemImage: "sidebar.right")
            }
        }
    }
}

private struct PayloadRootView: View {
    let value: JSONValue
    let loadLazyPayload: @Sendable (JSONValue) -> JSONValue?
    @State private var loadedValue: JSONValue?
    @State private var isLoading = false

    var body: some View {
        if let loadedValue {
            JSONValueView(label: "root", value: loadedValue)
        } else if case let .object(fields) = value, fields["type"] == .string("lazy-json") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Large payload stored as a lazy sidecar.")
                    .foregroundStyle(.secondary)
                if case let .number(length)? = fields["length"] {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(length), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(isLoading ? "Loading..." : "Load Full Payload") {
                    isLoading = true
                    Task {
                        loadedValue = await Task.detached(priority: .userInitiated) {
                            loadLazyPayload(value)
                        }.value
                        isLoading = false
                    }
                }
                .disabled(isLoading)
            }
        } else {
            JSONValueView(label: "root", value: value)
        }
    }
}

private struct JSONValueView: View {
    let label: String
    let value: JSONValue

    var body: some View {
        switch value {
        case let .object(fields):
            DisclosureGroup("\(label)  {\(fields.count)}") {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    if let child = fields[key] {
                        JSONValueView(label: key, value: child)
                    }
                }
            }
        case let .array(items):
            DisclosureGroup("\(label)  [\(items.count)]") {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    JSONValueView(label: "[\(index)]", value: item)
                }
            }
        default:
            LabeledContent(label, value: value.displayText)
        }
    }
}
