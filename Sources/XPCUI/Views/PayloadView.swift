import SwiftUI

struct PayloadView: View {
    let event: CaptureEventEnvelope?

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
                            JSONValueView(label: "root", value: payload)
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
