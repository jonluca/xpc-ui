import SwiftUI

struct InterceptionRulesView: View {
    @ObservedObject var store: InterceptionRuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingRule: InterceptionRule?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Lab-only active mutation", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Enabled rules run inside the launched target and can change selected XPC arguments or responses before forwarding. Keep rules narrowly scoped and use them only on authorized lab targets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Toggle("Enable interception for the next launch", isOn: $store.enabled)
            List {
                ForEach(store.rules) { rule in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: rule.enabled ? "bolt.fill" : "bolt.slash")
                            .foregroundStyle(rule.enabled ? .orange : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name).fontWeight(.medium)
                            Text(rule.summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("\(rule.replacementKey) = \(rule.replacementType.rawValue)(\(rule.replacementValue))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") {
                            editingRule = rule
                        }
                    }
                    .contextMenu {
                        Button("Edit") {
                            editingRule = rule
                        }
                        Button("Delete", role: .destructive) {
                            store.remove(id: rule.id)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.remove(id: store.rules[index].id)
                    }
                }
            }
            .overlay {
                if store.rules.isEmpty {
                    ContentUnavailableView(
                        "No interception rules",
                        systemImage: "bolt.slash",
                        description: Text("Add a narrowly scoped rule to modify selected XPC calls.")
                    )
                }
            }
            HStack {
                Text("\(store.enabledRuleCount)/\(InterceptionRule.maximumRuleCount) enabled rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Rule") {
                    editingRule = InterceptionRule()
                }
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $editingRule) { rule in
            InterceptionRuleEditor(rule: rule) { savedRule in
                do {
                    if store.rules.contains(where: { $0.id == savedRule.id }) {
                        try store.update(savedRule)
                    } else {
                        try store.add(savedRule)
                    }
                    editingRule = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Unable to save interception rule", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

struct InterceptionRuleEditor: View {
    @State var rule: InterceptionRule
    let onSave: (InterceptionRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Interception Rule")
                .font(.title2.weight(.semibold))
            Text("Rules apply to the next launched target. Review the exact call match and replacement before saving.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                Toggle("Enabled", isOn: $rule.enabled)
                TextField("Name", text: $rule.name)
                TextField("Exact service", text: $rule.serviceName)
                Picker("Direction", selection: $rule.direction) {
                    ForEach(InterceptionRule.Direction.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                TextField("Exact operation", text: $rule.operation)
                Section("Optional dictionary string predicate") {
                    TextField("Predicate key path", text: $rule.matchKey)
                    TextField("Expected string value", text: $rule.matchStringValue)
                }
                Section("Dictionary scalar replacement") {
                    TextField("Replacement key path", text: $rule.replacementKey)
                    Picker("Replacement type", selection: $rule.replacementType) {
                        ForEach(InterceptionRule.ReplacementType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    TextField("Replacement value", text: $rule.replacementValue)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    onSave(rule)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 460)
    }
}
