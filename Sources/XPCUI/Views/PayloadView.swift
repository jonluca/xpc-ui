import AppKit
import SwiftUI

struct PayloadView: View {
    let event: CaptureEventEnvelope?
    let blobStore: BlobStore
    var onDraftInterceptionRule: ((CaptureEventEnvelope) -> Void)?

    var body: some View {
        Group {
            if let event {
                List {
                    Section("Actions") {
                        Button("Copy Event JSON", systemImage: "doc.on.doc") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(
                                (try? event.prettyPrintedJSONString()) ?? "",
                                forType: .string
                            )
                        }
                        if
                            InterceptionRule.prepared(from: event) != nil,
                            let onDraftInterceptionRule
                        {
                            Button("Draft Interception Rule", systemImage: "bolt.badge.plus") {
                                onDraftInterceptionRule(event)
                            }
                        }
                    }
                    Section("Event") {
                        LabeledContent("Operation", value: event.operation)
                        LabeledContent("PID", value: String(event.pid))
                        LabeledContent("Parent PID", value: String(event.parentPID))
                        LabeledContent("Direction", value: event.direction)
                        LabeledContent("Source", value: event.source)
                        LabeledContent("Thread", value: String(event.threadID))
                        if let serviceName = event.serviceName {
                            LabeledContent("Service", value: serviceName)
                        }
                    }
                    if !event.appliedInterceptionRuleIDs.isEmpty {
                        Section("Applied Interception Rules") {
                            ForEach(event.appliedInterceptionRuleIDs, id: \.self, content: Text.init)
                        }
                    }
                    if let payload = event.payload {
                        Section("Payload") {
                            PayloadRootView(value: payload, blobStore: blobStore)
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
    let blobStore: BlobStore
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
                            blobStore.loadLazyPayload(value)
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
