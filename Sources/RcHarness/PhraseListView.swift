import AppKit
import SwiftUI

/// AppKit owns row selection and drag tracking together, so neither a SwiftUI
/// button nor a gesture recognizer can consume the start of a row drag.
@MainActor
struct PhraseListView: NSViewRepresentable {
    @ObservedObject var model: RemoteDashboardModel
    @Binding var selectedPhraseID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("phrase"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.allowsEmptySelection = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([Coordinator.pasteboardType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityLabel("常用语库")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        context.coordinator.update(parent: self, table: table)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let table = view.documentView as? NSTableView else { return }
        context.coordinator.update(parent: self, table: table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType("vip.tokenzz.rcharness.phrase-order")

        struct Row: Equatable {
            let id: UUID
            let title: String
            let preview: String
            let bindings: [ControllerInput]
        }

        private var parent: PhraseListView
        private var rows: [Row] = []
        private var updating = false

        init(parent: PhraseListView) { self.parent = parent }

        func update(parent: PhraseListView, table: NSTableView) {
            self.parent = parent
            updating = true
            defer { updating = false }
            let updated = parent.model.orderedPhrases.map { phrase in
                let source = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? phrase.englishText : phrase.text
                let preview = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return Row(id: phrase.id, title: phrase.displayTitle, preview: preview,
                    bindings: PhraseAssignments.inputs.filter { parent.model.phraseAssignments[$0] == phrase.id })
            }
            if updated != rows {
                rows = updated
                table.reloadData()
            }
            let selection = rows.firstIndex { $0.id == parent.selectedPhraseID }
            if let selection {
                if table.selectedRow != selection { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
            } else {
                table.deselectAll(nil)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = rows[row]
            let cell = NSTableCellView()
            let title = NSTextField(wrappingLabelWithString: item.title)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.maximumNumberOfLines = 1
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.textField = title
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            let leading = NSStackView()
            leading.orientation = .horizontal
            leading.alignment = .centerY
            leading.spacing = 8
            if item.bindings.isEmpty {
                let handle = symbol("line.3.horizontal", label: "拖动调整顺序", color: .tertiaryLabelColor)
                handle.identifier = NSUserInterfaceItemIdentifier("phrase-drag-handle:" + item.id.uuidString)
                leading.addArrangedSubview(handle)
                cell.toolTip = "拖动此行调整顺序"
            }
            let copy = NSStackView()
            copy.orientation = .vertical
            copy.alignment = .leading
            copy.spacing = 3
            copy.addArrangedSubview(title)
            if !item.preview.isEmpty {
                let preview = NSTextField(wrappingLabelWithString: item.preview)
                preview.font = .systemFont(ofSize: 10)
                preview.textColor = .secondaryLabelColor
                preview.maximumNumberOfLines = 1
                preview.lineBreakMode = .byTruncatingTail
                preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                copy.addArrangedSubview(preview)
            }
            leading.addArrangedSubview(copy)
            stack.addArrangedSubview(leading)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(spacer)
            let bindings = NSStackView()
            bindings.orientation = .horizontal
            bindings.alignment = .centerY
            bindings.spacing = 8
            for input in item.bindings {
                bindings.addArrangedSubview(symbol(input.symbol, label: "已绑定" + input.label, color: .controlAccentColor))
            }
            if !item.bindings.isEmpty { stack.addArrangedSubview(bindings) }
            cell.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                stack.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 4),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        }

        private func symbol(_ name: String, label: String, color: NSColor) -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage())
            view.contentTintColor = color
            view.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            view.widthAnchor.constraint(equalToConstant: 12).isActive = true
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView,
                  rows.indices.contains(table.selectedRow) else { return }
            let id = rows[table.selectedRow].id
            if parent.selectedPhraseID != id { parent.selectedPhraseID = id }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard rows.indices.contains(row), rows[row].bindings.isEmpty else { return nil }
            let item = NSPasteboardItem()
            item.setString(rows[row].id.uuidString, forType: Self.pasteboardType)
            return item
        }

        private func draggedIndex(_ info: NSDraggingInfo, table: NSTableView) -> Int? {
            guard (info.draggingSource as? NSTableView) === table,
                  let value = info.draggingPasteboard.string(forType: Self.pasteboardType),
                  let id = UUID(uuidString: value) else { return nil }
            return parent.model.unboundPhrases.firstIndex { $0.id == id }
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard draggedIndex(info, table: tableView) != nil else { return [] }
            // Every destination is an insertion point below the fixed bindings.
            let destination = min(max(row, parent.model.boundPhrases.count), rows.count)
            tableView.setDropRow(destination, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard dropOperation == .above, let source = draggedIndex(info, table: tableView) else { return false }
            let destination = row - parent.model.boundPhrases.count
            guard (0...parent.model.unboundPhrases.count).contains(destination) else { return false }
            parent.model.moveUnboundPhrases(fromOffsets: IndexSet(integer: source), toOffset: destination)
            // NSTableView does not wait for SwiftUI to run the next update
            // pass after accepting a drop. Refresh this same table immediately
            // so the released row never remains visible in its old position.
            update(parent: parent, table: tableView)
            return true
        }
    }
}
