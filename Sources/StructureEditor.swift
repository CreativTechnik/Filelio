import AppKit
import Foundation

private func adaptiveSymbol(_ name: String, description: String? = nil) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    image?.isTemplate = true
    return image
}

private struct ExistingStructureImportResult: Sendable {
    let rootURL: URL
    let folderPaths: [String]
    let errorDescription: String?
}

private final class ExistingStructureImportBox: @unchecked Sendable {
    var results: [ExistingStructureImportResult] = []
}

@MainActor
private final class FolderNode: NSObject {
    var name: String
    weak var parent: FolderNode?
    var children: [FolderNode] = []

    init(name: String, parent: FolderNode? = nil) {
        self.name = name
        self.parent = parent
    }
}

@MainActor
final class StructureEditorController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    private var rootNodes: [FolderNode] = []
    private let outlineView = NSOutlineView()
    private var window: NSWindow!
    private var accepted = false
    private let subtitle: String
    private let selectionInfo = NSTextField(wrappingLabelWithString: "Noch kein Ordner ausgewählt.")
    private let summaryValue = NSTextField(labelWithString: "0 Ordner")

    init(folderPaths: [String], rootName: String) {
        subtitle = "Ordnerstruktur für „\(rootName)“"
        super.init()
        rootNodes = Self.nodes(from: folderPaths)
    }

    func runModal() -> [String]? {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return accepted ? leafPaths() : nil
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ordnerbaum bearbeiten"
        window.delegate = self

        let title = NSTextField(labelWithString: subtitle)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "Lege Ordner und Unterordner mit den Schaltflächen an. Dateien direkt in Zwischenordnern werden ebenfalls erkannt; der Präfix richtet sich nach der tatsächlichen Ebene.")
        help.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "Ordner"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 25
        outlineView.indentationPerLevel = 22
        outlineView.selectionHighlightStyle = .regular
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.doubleAction = #selector(renameFolder)
        outlineView.target = self

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        selectionInfo.font = .systemFont(ofSize: 12)
        selectionInfo.textColor = .secondaryLabelColor
        selectionInfo.maximumNumberOfLines = 12
        summaryValue.font = .systemFont(ofSize: 12, weight: .semibold)
        let detailHelp = NSTextField(wrappingLabelWithString: "Endordner werden rekursiv überwacht. Bei Zwischenordnern werden Dateien erkannt, die direkt darin liegen.")
        detailHelp.font = .systemFont(ofSize: 11)
        detailHelp.textColor = .tertiaryLabelColor
        let detailStack = NSStackView(views: [summaryValue, separator(), selectionInfo, detailHelp])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 10
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        let detailBox = NSBox()
        detailBox.title = "Übersicht"
        detailBox.contentView?.addSubview(detailStack)
        for view in [summaryValue, selectionInfo, detailHelp] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailBox.contentView!.leadingAnchor, constant: 12),
            detailStack.trailingAnchor.constraint(equalTo: detailBox.contentView!.trailingAnchor, constant: -12),
            detailStack.topAnchor.constraint(equalTo: detailBox.contentView!.topAnchor, constant: 12),
            detailStack.bottomAnchor.constraint(lessThanOrEqualTo: detailBox.contentView!.bottomAnchor, constant: -12)
        ])

        let contentRow = NSStackView(views: [scroll, detailBox])
        contentRow.orientation = .horizontal
        contentRow.alignment = .top
        contentRow.spacing = 12
        scroll.widthAnchor.constraint(equalToConstant: 510).isActive = true
        detailBox.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let addFolder = button("Hauptordner", #selector(addRootFolder), symbol: "folder.badge.plus")
        let addChild = button("Unterordner", #selector(addSubfolder), symbol: "arrow.turn.down.right")
        let rename = button("Umbenennen", #selector(renameFolder), symbol: "pencil")
        let remove = button("Entfernen", #selector(removeFolder), symbol: "trash")
        let tools = NSStackView(views: [addFolder, addChild, rename, remove])
        tools.orientation = .horizontal
        tools.spacing = 8

        let cancel = button("Abbrechen", #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = button("Übernehmen", #selector(accept))
        done.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), cancel, done])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, help, contentRow, tools, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)

        for view in [title, help, contentRow, tools, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        contentRow.heightAnchor.constraint(equalToConstant: 410).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)
        ])

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        refreshEditorInfo()
    }

    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let symbol, let image = adaptiveSymbol(symbol) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func addRootFolder() {
        guard let name = requestName(title: "Neuen Ordner anlegen", initialValue: "") else { return }
        guard !rootNodes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            showWarning("Ein gleichnamiger Ordner existiert auf dieser Ebene bereits.")
            return
        }
        let node = FolderNode(name: name)
        rootNodes.append(node)
        reload(select: node)
    }

    @objc private func addSubfolder() {
        guard let parent = selectedNode else {
            showWarning("Wähle zuerst den Ordner aus, unter dem der neue Unterordner entstehen soll.")
            return
        }
        guard let name = requestName(title: "Neuen Unterordner anlegen", initialValue: "") else { return }
        guard !parent.children.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            showWarning("Ein gleichnamiger Unterordner existiert bereits.")
            return
        }
        let child = FolderNode(name: name, parent: parent)
        parent.children.append(child)
        reload(select: child)
    }

    @objc private func renameFolder() {
        guard let node = selectedNode else {
            showWarning("Wähle zuerst einen Ordner aus.")
            return
        }
        guard let name = requestName(title: "Ordner umbenennen", initialValue: node.name) else { return }
        let siblings = node.parent?.children ?? rootNodes
        guard !siblings.contains(where: { $0 !== node && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            showWarning("Ein gleichnamiger Ordner existiert auf dieser Ebene bereits.")
            return
        }
        node.name = name
        reload(select: node)
    }

    @objc private func removeFolder() {
        guard let node = selectedNode else {
            showWarning("Wähle zuerst einen Ordner aus.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "„\(node.name)“ entfernen?"
        alert.informativeText = node.children.isEmpty
            ? "Der Ordner wird aus der Konfiguration entfernt. Vorhandene Dateien werden nicht gelöscht."
            : "Auch alle darunter angezeigten Unterordner werden aus der Konfiguration entfernt. Vorhandene Dateien werden nicht gelöscht."
        alert.addButton(withTitle: "Entfernen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let parent = node.parent {
            parent.children.removeAll { $0 === node }
        } else {
            rootNodes.removeAll { $0 === node }
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        refreshEditorInfo()
    }

    @objc private func accept() {
        guard !leafPaths().isEmpty else {
            showWarning("Lege mindestens einen Ordner an.")
            return
        }
        accepted = true
        NSApp.stopModal()
    }

    @objc private func cancel() {
        accepted = false
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window {
            accepted = false
            NSApp.stopModal()
        }
    }

    private var selectedNode: FolderNode? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.selectedRow) as? FolderNode
    }

    private func reload(select node: FolderNode) {
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        refreshEditorInfo()
    }

    private func requestName(title: String, initialValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Verwende einen normalen macOS-Ordnernamen ohne „/“ oder „:“ ."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        input.stringValue = initialValue
        alert.accessoryView = input
        alert.addButton(withTitle: "Übernehmen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains(":") else {
            showWarning("Dieser Ordnername ist ungültig.")
            return nil
        }
        return value
    }

    private func showWarning(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderNode)?.children.count ?? rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderNode)?.children[index] ?? rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? FolderNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FolderCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let icon = NSImageView()
            icon.image = adaptiveSymbol("folder.fill")
            icon.contentTintColor = .systemBlue
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 17),
                icon.heightAnchor.constraint(equalToConstant: 17),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.name
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshEditorInfo()
    }

    private func refreshEditorInfo() {
        let paths = allFolderPaths()
        let maximumDepth = paths.map { $0.split(separator: "/").count }.max() ?? 0
        summaryValue.stringValue = "\(paths.count) Ordner\n\(leafPaths().count) Endpfade\n\(maximumDepth) Ebenen"
        guard let node = selectedNode else {
            selectionInfo.stringValue = "Wähle links einen Ordner aus. Danach kannst du einen Unterordner anlegen, ihn umbenennen oder entfernen."
            return
        }
        let path = path(for: node)
        let mode = node.children.isEmpty
            ? "Rekursiv überwacht – auch spätere Unterordner werden erfasst."
            : "Zwischenebene – Dateien direkt in diesem Ordner werden erfasst."
        selectionInfo.stringValue = "PFAD\n\(path)\n\nÜBERWACHUNG\n\(mode)"
    }

    private func path(for node: FolderNode) -> String {
        var components = [node.name]
        var parent = node.parent
        while let current = parent {
            components.insert(current.name, at: 0)
            parent = current.parent
        }
        return components.joined(separator: "/")
    }

    private func allFolderPaths() -> [String] {
        var paths: [String] = []
        func visit(_ node: FolderNode, parents: [String]) {
            let current = parents + [node.name]
            paths.append(current.joined(separator: "/"))
            node.children.forEach { visit($0, parents: current) }
        }
        rootNodes.forEach { visit($0, parents: []) }
        return paths
    }

    private func leafPaths() -> [String] {
        var paths: [String] = []
        func visit(_ node: FolderNode, parents: [String]) {
            let current = parents + [node.name]
            if node.children.isEmpty {
                paths.append(current.joined(separator: "/"))
            } else {
                node.children.forEach { visit($0, parents: current) }
            }
        }
        rootNodes.forEach { visit($0, parents: []) }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func nodes(from paths: [String]) -> [FolderNode] {
        var roots: [FolderNode] = []
        for path in paths {
            var siblings = roots
            var parent: FolderNode?
            for component in path.split(separator: "/").map(String.init) {
                let node: FolderNode
                if let existing = siblings.first(where: { $0.name == component }) {
                    node = existing
                } else {
                    node = FolderNode(name: component, parent: parent)
                    if let parent { parent.children.append(node) } else { roots.append(node) }
                }
                parent = node
                siblings = node.children
            }
        }
        return roots
    }
}

@MainActor
final class LocationManagerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var locations: [WatchedLocation]
    private let engine = RenameEngine()
    private let tableView = NSTableView()
    private let statusValue = NSTextField(labelWithString: "0 Stammordner")
    private var window: NSWindow!
    private var accepted = false

    init(locations: [WatchedLocation]) {
        self.locations = locations
    }

    func runModal() -> [WatchedLocation]? {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return accepted ? locations : nil
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Überwachte Ordnerstrukturen"
        window.delegate = self

        let title = NSTextField(labelWithString: "Ordnerstrukturen verwalten")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "Du kannst mehrere voneinander unabhängige Stammordner hinzufügen. Jede Struktur besitzt ihren eigenen grafischen Ordnerbaum und wird nur bei tatsächlichen Änderungen geprüft.")
        help.textColor = .secondaryLabelColor
        statusValue.font = .systemFont(ofSize: 12, weight: .semibold)
        statusValue.textColor = .secondaryLabelColor

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Stammordner"
        nameColumn.width = 190
        let countColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("count"))
        countColumn.title = "Endpfade"
        countColumn.width = 75
        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Speicherort"
        pathColumn.width = 510
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(countColumn)
        tableView.addTableColumn(pathColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(editStructure)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder

        let add = button("Neue Struktur erstellen", #selector(addLocation), symbol: "folder.badge.plus")
        let importExisting = button("Bestehende Struktur übernehmen", #selector(importExistingLocations), symbol: "square.and.arrow.down")
        let firstToolRow = NSStackView(views: [add, importExisting])
        firstToolRow.orientation = .horizontal
        firstToolRow.spacing = 8

        let edit = button("Ordnerbaum bearbeiten", #selector(editStructure), symbol: "list.bullet.indent")
        let editRules = button("Regeln bearbeiten", #selector(editRules), symbol: "slider.horizontal.3")
        let changeRoot = button("Stammordner ändern", #selector(changeRootFolder), symbol: "arrow.triangle.2.circlepath")
        let remove = button("Struktur entfernen", #selector(removeLocation), symbol: "trash")
        let secondToolRow = NSStackView(views: [edit, editRules, changeRoot, remove])
        secondToolRow.orientation = .horizontal
        secondToolRow.spacing = 8
        let tools = NSStackView(views: [firstToolRow, secondToolRow])
        tools.orientation = .vertical
        tools.alignment = .leading
        tools.spacing = 8

        let cancel = button("Abbrechen", #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = button("Speichern", #selector(accept))
        done.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), cancel, done])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, help, statusValue, scroll, tools, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        for view in [title, help, statusValue, scroll, tools, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)
        ])
        refreshManagerStatus()
    }

    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let symbol, let image = adaptiveSymbol(symbol) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    @objc private func addLocation() {
        let panel = NSOpenPanel()
        panel.title = "Stammordner auswählen oder erstellen"
        panel.message = "Dieser Ordner bildet die oberste Ebene einer eigenständigen überwachten Struktur."
        panel.prompt = "Auswählen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let rootURL = panel.url else { return }
        guard conflictingLocation(for: rootURL) == nil else {
            showWarning("Dieser Stammordner überschneidet sich mit einer bestehenden Struktur. Stammordner müssen voneinander unabhängig sein.")
            return
        }

        let editor = StructureEditorController(folderPaths: [], rootName: rootURL.lastPathComponent)
        guard let folderPaths = editor.runModal() else { return }
        let bookmark = try? rootURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        locations.append(WatchedLocation(rootBookmark: bookmark, rootPath: rootURL.path, folderPaths: folderPaths))
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: locations.count - 1), byExtendingSelection: false)
        refreshManagerStatus()
    }

    @objc private func importExistingLocations() {
        let panel = NSOpenPanel()
        panel.title = "Bestehende Ordnerstrukturen auswählen"
        panel.message = "Wähle einen oder mehrere bestehende Stammordner. Die vorhandenen Unterordner werden automatisch eingelesen; Dateien werden nicht geöffnet oder verändert."
        panel.prompt = "Strukturen übernehmen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        let progressAlert = NSAlert()
        progressAlert.messageText = "Ordnerstrukturen werden eingelesen"
        progressAlert.informativeText = "Die Verzeichnisse werden im Hintergrund geprüft. Dateien werden nicht geöffnet."
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 360, height: 18))
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        progressAlert.accessoryView = progress
        let resultBox = ExistingStructureImportBox()
        let selectedURLs = panel.urls
        DispatchQueue.global(qos: .utility).async {
            let importEngine = RenameEngine()
            resultBox.results = selectedURLs.map { rootURL in
                do {
                    return ExistingStructureImportResult(
                        rootURL: rootURL,
                        folderPaths: try importEngine.discoverExistingFolderPaths(rootURL: rootURL),
                        errorDescription: nil
                    )
                } catch {
                    return ExistingStructureImportResult(
                        rootURL: rootURL,
                        folderPaths: [],
                        errorDescription: error.localizedDescription
                    )
                }
            }
            DispatchQueue.main.async { NSApp.stopModal(withCode: .OK) }
        }
        progressAlert.window.center()
        NSApp.runModal(for: progressAlert.window)
        progressAlert.window.orderOut(nil)

        var importedIndices: [Int] = []
        var skipped: [String] = []
        for result in resultBox.results {
            let rootURL = result.rootURL
            if conflictingLocation(for: rootURL) != nil {
                skipped.append("\(rootURL.lastPathComponent): überschneidet sich mit einer vorhandenen Struktur")
                continue
            }
            if let errorDescription = result.errorDescription {
                skipped.append("\(rootURL.lastPathComponent): \(errorDescription)")
            } else {
                let folderPaths = result.folderPaths
                guard !folderPaths.isEmpty else {
                    skipped.append("\(rootURL.lastPathComponent): keine Unterordner")
                    continue
                }
                let bookmark = try? rootURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                locations.append(WatchedLocation(rootBookmark: bookmark, rootPath: rootURL.path, folderPaths: folderPaths))
                importedIndices.append(locations.count - 1)
            }
        }

        tableView.reloadData()
        refreshManagerStatus()
        if let lastIndex = importedIndices.last {
            tableView.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
        }

        let alert = NSAlert()
        alert.messageText = importedIndices.isEmpty ? "Keine Struktur übernommen" : "\(importedIndices.count) Struktur(en) übernommen"
        var details = importedIndices.isEmpty
            ? "Wähle einen Stammordner, der mindestens einen Unterordner enthält."
            : "Die vorhandenen Unterordner wurden eingelesen. Vorhandene Dateien werden beim Speichern als Altbestand registriert."
        if !skipped.isEmpty { details += "\n\nNicht übernommen:\n" + skipped.joined(separator: "\n") }
        alert.informativeText = details
        if importedIndices.count == 1 { alert.addButton(withTitle: "Ordnerbaum prüfen") }
        alert.addButton(withTitle: "Fertig")
        if importedIndices.count == 1, alert.runModal() == .alertFirstButtonReturn {
            editStructure()
        } else if importedIndices.count != 1 {
            alert.runModal()
        }
    }

    @objc private func editStructure() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < locations.count else {
            showWarning("Wähle zuerst eine Ordnerstruktur aus.")
            return
        }
        let index = tableView.selectedRow
        let location = locations[index]
        let editor = StructureEditorController(
            folderPaths: location.folderPaths,
            rootName: URL(fileURLWithPath: location.rootPath).lastPathComponent
        )
        guard let folderPaths = editor.runModal() else { return }
        locations[index].folderPaths = folderPaths
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        refreshManagerStatus()
    }

    @objc private func editRules() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < locations.count else {
            showWarning("Wähle zuerst eine Ordnerstruktur aus.")
            return
        }
        let index = tableView.selectedRow
        let location = locations[index]
        let controller = LocationOptionsController(
            rootName: URL(fileURLWithPath: location.rootPath).lastPathComponent,
            options: location.effectiveOptions
        )
        guard let options = controller.runModal() else { return }
        locations[index].options = options
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        refreshManagerStatus()
    }

    @objc private func changeRootFolder() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < locations.count else {
            showWarning("Wähle zuerst eine Ordnerstruktur aus.")
            return
        }
        let index = tableView.selectedRow
        let panel = NSOpenPanel()
        panel.title = "Neuen Stammordner auswählen oder erstellen"
        panel.prompt = "Übernehmen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let rootURL = panel.url else { return }
        guard conflictingLocation(for: rootURL, excluding: index) == nil else {
            showWarning("Dieser Stammordner überschneidet sich mit einer bestehenden Struktur. Stammordner müssen voneinander unabhängig sein.")
            return
        }
        locations[index].rootPath = rootURL.path
        locations[index].rootBookmark = try? rootURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        refreshManagerStatus()
    }

    @objc private func removeLocation() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < locations.count else {
            showWarning("Wähle zuerst eine Ordnerstruktur aus.")
            return
        }
        let index = tableView.selectedRow
        let location = locations[index]
        let alert = NSAlert()
        alert.messageText = "„\(URL(fileURLWithPath: location.rootPath).lastPathComponent)“ nicht mehr überwachen?"
        alert.informativeText = "Die Konfiguration wird entfernt. Ordner und Dateien auf dem Laufwerk werden nicht gelöscht."
        alert.addButton(withTitle: "Entfernen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        locations.remove(at: index)
        tableView.reloadData()
        refreshManagerStatus()
    }

    @objc private func accept() {
        guard !locations.isEmpty else {
            showWarning("Füge mindestens eine Ordnerstruktur hinzu.")
            return
        }
        do {
            try engine.validateIndependentRoots(locations)
        } catch {
            showWarning(error.localizedDescription)
            return
        }
        accepted = true
        NSApp.stopModal()
    }

    @objc private func cancel() {
        accepted = false
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window {
            accepted = false
            NSApp.stopModal()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { locations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let location = locations[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = URL(fileURLWithPath: location.rootPath).lastPathComponent
        case "count": value = location.effectiveOptions.isPaused ? "Pausiert" : String(location.folderPaths.count)
        default: value = location.rootPath
        }
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = value
        return cell
    }

    private func conflictingLocation(for rootURL: URL, excluding excludedIndex: Int? = nil) -> WatchedLocation? {
        let candidateComponents = rootURL.standardizedFileURL.pathComponents
        return locations.enumerated().first { index, location in
            guard index != excludedIndex else { return false }
            let existingComponents = URL(fileURLWithPath: location.rootPath, isDirectory: true)
                .standardizedFileURL.pathComponents
            let sharedCount = min(candidateComponents.count, existingComponents.count)
            return Array(candidateComponents.prefix(sharedCount)) == Array(existingComponents.prefix(sharedCount))
        }?.element
    }

    private func refreshManagerStatus() {
        let pathCount = locations.reduce(0) { $0 + $1.folderPaths.count }
        statusValue.stringValue = "\(locations.count) Stammordner · \(pathCount) überwachte Endpfade"
    }

    private func showWarning(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
