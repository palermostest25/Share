import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension NSPasteboard.PasteboardType {
    static let shareEntry = NSPasteboard.PasteboardType("dev.denby.share.entry")
}

@MainActor
final class FinderTableView: NSTableView {
    var openSelection: (() -> Void)?
    var previewSelection: (() -> Void)?
    var renameSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36 where !command: renameSelection?()
        case 49 where !command: previewSelection?()
        case 125 where command: openSelection?()
        case 51 where command: deleteSelection?()
        default: super.keyDown(with: event)
        }
    }
}

struct DriveTableView: NSViewRepresentable {
    let path: String
    let entries: [DriveEntry]
    @Binding var selection: Set<DriveEntry.ID>
    let browser: BrowserViewModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FinderTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.rowHeight = 30
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.registerForDraggedTypes([.shareEntry, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.openSelection = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        table.previewSelection = { [weak coordinator = context.coordinator] in coordinator?.previewSelected() }
        table.renameSelection = { [weak coordinator = context.coordinator] in coordinator?.renameSelected() }
        table.deleteSelection = { [weak coordinator = context.coordinator] in coordinator?.deleteSelected() }

        for (id, title, width) in [("name", "Name", 390.0), ("size", "Size", 110.0), ("modified", "Date Modified", 180.0), ("kind", "Kind", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 160 : 80
            table.addTableColumn(column)
        }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? FinderTableView else { return }
        let coordinator = context.coordinator
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        if coordinator.renderedEntries != entries || coordinator.renderedPath != path {
            coordinator.renderedEntries = entries
            coordinator.renderedPath = path
            table.reloadData()
        }
        let indexes = IndexSet(entries.indices.filter { selection.contains(entries[$0].name) })
        if table.selectedRowIndexes != indexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate, NSTextFieldDelegate {
        var parent: DriveTableView
        weak var table: FinderTableView?
        var renderedEntries: [DriveEntry] = []
        var renderedPath = ""
        var isUpdating = false

        init(_ parent: DriveTableView) { self.parent = parent }

        func entry(at row: Int) -> DriveEntry? {
            parent.entries.indices.contains(row) ? parent.entries[row] : nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let entry = entry(at: row), let column else { return nil }
            let identifier = column.identifier.rawValue
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label

            if identifier == "name" {
                let image = NSImageView()
                image.image = entry.isDirectory ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(for: UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
                image.imageScaling = .scaleProportionallyUpOrDown
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                label.stringValue = entry.name
                label.isEditable = true
                label.isSelectable = true
                label.isBordered = false
                label.delegate = self
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 20),
                    image.heightAnchor.constraint(equalToConstant: 20),
                    label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                switch identifier {
                case "size": label.stringValue = entry.isDirectory ? "—" : (entry.size ?? 0).fileSizeText
                case "modified": label.stringValue = DateFormatter.localizedString(from: entry.modified, dateStyle: .medium, timeStyle: .short)
                default:
                    let ext = (entry.name as NSString).pathExtension
                    label.stringValue = entry.isDirectory ? "Folder" : (ext.isEmpty ? "File" : "\(ext.uppercased()) file")
                }
                label.textColor = .secondaryLabelColor
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, !isUpdating else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { entry(at: $0)?.name })
        }

        @objc func doubleClick(_ sender: Any?) {
            guard let table, let entry = entry(at: table.clickedRow) else { return }
            Task { await parent.browser.open(entry) }
        }

        func openSelected() {
            guard let table, let entry = entry(at: table.selectedRow) else { return }
            Task { await parent.browser.open(entry) }
        }

        func previewSelected() {
            guard let table, let entry = entry(at: table.selectedRow) else { return }
            Task { await parent.browser.preview(entry) }
        }

        func renameSelected() {
            guard let table, table.selectedRowIndexes.count == 1, table.selectedRow >= 0 else { return }
            table.editColumn(0, row: table.selectedRow, with: nil, select: true)
        }

        func deleteSelected() {
            guard let table else { return }
            parent.browser.deleteTargets = table.selectedRowIndexes.compactMap { entry(at: $0) }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let cell = field.superview as? NSTableCellView,
                  let table, let entry = entry(at: table.row(for: cell)),
                  field.stringValue != entry.name else { return }
            Task { await parent.browser.rename(entry, to: field.stringValue) }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let entry = entry(at: row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(entry.name, forType: .shareEntry)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let target = entry(at: row), target.isDirectory else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            let pasteboard = info.draggingPasteboard
            if pasteboard.availableType(from: [.shareEntry]) != nil { return .move }
            if pasteboard.availableType(from: [.fileURL]) != nil { return .copy }
            return []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let target = entry(at: row), target.isDirectory else { return false }
            let destination = parent.browser.fullPath(target.name)
            let pasteboard = info.draggingPasteboard
            let names = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .shareEntry) } ?? []
            if !names.isEmpty {
                Task { await parent.browser.move(names, into: destination) }
                return true
            }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return !urls.isEmpty && parent.browser.acceptDrop(urls, into: destination)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let entry = entry(at: table.clickedRow) else { return }
            let row = table.clickedRow
            if !table.isRowSelected(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            menu.addItem(withTitle: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "").target = self
            if !entry.isDirectory { menu.addItem(withTitle: "Quick Look", action: #selector(menuPreview(_:)), keyEquivalent: "").target = self }
            if !entry.isDirectory { menu.addItem(withTitle: "Download…", action: #selector(menuDownload(_:)), keyEquivalent: "").target = self }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename", action: #selector(menuRename(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Move to Folder…", action: #selector(menuMove(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Delete", action: #selector(menuDelete(_:)), keyEquivalent: "").target = self
        }

        @objc private func menuOpen(_ sender: Any?) { openSelected() }
        @objc private func menuPreview(_ sender: Any?) { previewSelected() }
        @objc private func menuRename(_ sender: Any?) { renameSelected() }
        @objc private func menuDelete(_ sender: Any?) { deleteSelected() }
        @objc private func menuDownload(_ sender: Any?) {
            guard let table, let entry = entry(at: table.selectedRow) else { return }
            Task { await parent.browser.download(entry) }
        }
        @objc private func menuMove(_ sender: Any?) {
            guard let table, let entry = entry(at: table.selectedRow) else { return }
            parent.browser.moveWithPrompt(entry)
        }
    }
}
