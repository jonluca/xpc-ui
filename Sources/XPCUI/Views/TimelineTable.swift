import AppKit
import SwiftUI

struct TimelineTable: NSViewRepresentable {
    let events: [CaptureEventEnvelope]
    let generation: Int
    @Binding var selection: CaptureEventEnvelope.ID?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.headerView = NSTableHeaderView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        addColumn("time", title: "Time", width: 92, to: table)
        addColumn("pid", title: "PID", width: 58, to: table)
        addColumn("category", title: "Kind", width: 86, to: table)
        addColumn("operation", title: "Operation", width: 155, to: table)
        addColumn("service", title: "Service", width: 220, to: table)
        addColumn("summary", title: "Summary", width: 420, to: table)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = table
        context.coordinator.tableView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.update(events: events, generation: generation)
        if let selection, let row = events.firstIndex(where: { $0.id == selection }) {
            context.coordinator.tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat, to table: NSTableView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        table.addTableColumn(column)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var events: [CaptureEventEnvelope] = []
        var generation = 0
        var selection: Binding<CaptureEventEnvelope.ID?>
        weak var tableView: NSTableView?

        init(selection: Binding<CaptureEventEnvelope.ID?>) {
            self.selection = selection
        }

        func update(events nextEvents: [CaptureEventEnvelope], generation nextGeneration: Int) {
            let strategy = TimelineTable.updateStrategy(
                previousCount: events.count,
                nextCount: nextEvents.count,
                previousGeneration: generation,
                nextGeneration: nextGeneration
            )
            events = nextEvents
            generation = nextGeneration
            guard let tableView else { return }
            switch strategy {
            case .noChanges:
                break
            case let .insertRows(rows):
                tableView.beginUpdates()
                tableView.insertRows(at: IndexSet(integersIn: rows), withAnimation: [])
                tableView.endUpdates()
            case .reload:
                tableView.reloadData()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            events.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < events.count, let identifier = tableColumn?.identifier else { return nil }
            let event = events[row]
            let text: String
            switch identifier.rawValue {
            case "time": text = event.timestampText
            case "pid": text = String(event.pid)
            case "category": text = event.category
            case "operation": text = event.operation
            case "service": text = event.serviceName ?? ""
            default: text = event.summary
            }
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? NSTableCellView()
            view.identifier = identifier
            if view.textField == nil {
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(field)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                view.textField = field
            }
            view.textField?.stringValue = text
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let row = tableView?.selectedRow, row >= 0, row < events.count else {
                selection.wrappedValue = nil
                return
            }
            selection.wrappedValue = events[row].id
        }
    }
}

extension TimelineTable {
    enum UpdateStrategy: Equatable {
        case noChanges
        case insertRows(Range<Int>)
        case reload
    }

    static func updateStrategy(
        previousCount: Int,
        nextCount: Int,
        previousGeneration: Int,
        nextGeneration: Int
    ) -> UpdateStrategy {
        guard previousGeneration == nextGeneration, nextCount >= previousCount else {
            return .reload
        }
        guard nextCount > previousCount else {
            return .noChanges
        }
        return .insertRows(previousCount ..< nextCount)
    }
}
