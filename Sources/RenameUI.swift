import AppKit
import Foundation

private func adaptiveSymbol(_ name: String, description: String? = nil) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    image?.isTemplate = true
    return image
}

struct QueuedRenameItem: Identifiable, Equatable {
    let id: String
    let candidate: RenameCandidate
    let rootURL: URL

    init(candidate: RenameCandidate, rootURL: URL) {
        self.id = candidate.relativeKey
        self.candidate = candidate
        self.rootURL = rootURL
    }
}

enum QueueDecisionAction {
    case rename
    case keep
}

struct QueueDecision {
    let itemID: String
    let action: QueueDecisionAction
    let title: String?
}

@MainActor
final class RenameQueueController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let items: [QueuedRenameItem]
    private let configuration: AppConfiguration
    private let engine = RenameEngine()
    private let tableView = NSTableView()
    private let titleField = NSTextField()
    private let previewValue = NSTextField(wrappingLabelWithString: "Wähle eine Datei aus.")
    private var window: NSWindow!
    private var result: [QueueDecision] = []
    private var accepted = false

    init(items: [QueuedRenameItem], configuration: AppConfiguration) {
        self.items = items
        self.configuration = configuration
    }

    func runModal() -> [QueueDecision] {
        guard !items.isEmpty else { return [] }
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateSelectionDetails()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return accepted ? result : []
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wartende Dateien prüfen"
        window.minSize = NSSize(width: 820, height: 540)
        window.delegate = self

        let title = NSTextField(labelWithString: "Umbenennungen prüfen")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "Alle neuen Dateien werden gesammelt. Prüfe die Vorschau und bearbeite eine oder mehrere Dateien gemeinsam.")
        subtitle.textColor = .secondaryLabelColor

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fileColumn.title = "Aktueller Name"
        fileColumn.width = 225
        let folderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folderColumn.title = "Ordner"
        folderColumn.width = 220
        let previewColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        previewColumn.title = "Vorschau"
        previewColumn.width = 420
        [fileColumn, folderColumn, previewColumn].forEach(tableView.addTableColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let titleLabel = NSTextField(labelWithString: "Titel für die ausgewählte Datei")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.placeholderString = "Dokumenttitel"
        titleField.delegate = self
        previewValue.textColor = .secondaryLabelColor
        previewValue.maximumNumberOfLines = 2
        let editStack = NSStackView(views: [titleLabel, titleField, previewValue])
        editStack.orientation = .vertical
        editStack.alignment = .leading
        editStack.spacing = 7
        for view in [titleField, previewValue] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: editStack.widthAnchor).isActive = true
        }

        let renameSelected = button("Ausgewählte umbenennen", #selector(renameSelected), symbol: "checkmark.circle.fill")
        renameSelected.keyEquivalent = "\r"
        let keepSelected = button("Ausgewählte behalten", #selector(keepSelected), symbol: "hand.raised.fill")
        let renameAll = button("Alle automatisch umbenennen", #selector(renameAll), symbol: "checkmark.rectangle.stack.fill")
        let keepAll = button("Alle behalten", #selector(keepAll), symbol: "tray.full.fill")
        let later = button("Später", #selector(cancel), symbol: "clock")
        later.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [renameSelected, keepSelected, renameAll, keepAll, NSView(), later])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, subtitle, scroll, editStack, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        for view in [title, subtitle, scroll, editStack, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }

    private func button(_ title: String, _ action: Selector, symbol: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.image = adaptiveSymbol(symbol)
        button.imagePosition = .imageLeading
        return button
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "file": value = item.candidate.url.lastPathComponent
        case "folder": value = item.candidate.url.deletingLastPathComponent().lastPathComponent
        default: value = previewName(for: item, customTitle: nil)
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelectionDetails() }
    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    private func updateSelectionDetails() {
        let rows = tableView.selectedRowIndexes
        titleField.isEnabled = rows.count == 1
        if let row = rows.first, rows.count == 1 {
            titleField.stringValue = engine.suggestedTitle(for: items[row].candidate.url)
        } else {
            titleField.stringValue = ""
        }
        updatePreview()
    }

    private func updatePreview() {
        let rows = tableView.selectedRowIndexes
        if let row = rows.first, rows.count == 1 {
            previewValue.stringValue = "Vorschau: " + previewName(for: items[row], customTitle: titleField.stringValue)
        } else if rows.count > 1 {
            previewValue.stringValue = "\(rows.count) Dateien ausgewählt · vorhandene Titel werden übernommen"
        } else {
            previewValue.stringValue = "Wähle mindestens eine Datei aus."
        }
    }

    private func previewName(for item: QueuedRenameItem, customTitle: String?) -> String {
        let title = customTitle ?? engine.suggestedTitle(for: item.candidate.url)
        return (try? engine.targetURL(for: item.candidate, title: title, configuration: configuration).lastPathComponent) ?? "Vorschau nicht verfügbar"
    }

    @objc private func renameSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { NSSound.beep(); return }
        result = rows.map { row in
            let item = items[row]
            let customTitle = rows.count == 1 ? titleField.stringValue : engine.suggestedTitle(for: item.candidate.url)
            return QueueDecision(itemID: item.id, action: .rename, title: customTitle)
        }
        finish()
    }

    @objc private func keepSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { NSSound.beep(); return }
        result = rows.map { QueueDecision(itemID: items[$0].id, action: .keep, title: nil) }
        finish()
    }

    @objc private func renameAll() {
        result = items.map {
            QueueDecision(itemID: $0.id, action: .rename, title: engine.suggestedTitle(for: $0.candidate.url))
        }
        finish()
    }

    @objc private func keepAll() {
        result = items.map { QueueDecision(itemID: $0.id, action: .keep, title: nil) }
        finish()
    }

    @objc private func cancel() {
        accepted = false
        NSApp.stopModal()
    }

    private func finish() {
        accepted = true
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window { cancel() }
    }
}

@MainActor
final class LocationOptionsController: NSObject, NSWindowDelegate {
    private let rootName: String
    private var options: LocationOptions
    private var window: NSWindow!
    private var accepted = false
    private let pauseCheck = NSButton(checkboxWithTitle: "Diese Struktur pausieren", target: nil, action: nil)
    private let prefixField = NSTextField()
    private let templateField = NSTextField()
    private let separatorField = NSTextField()
    private let dateCheck = NSButton(checkboxWithTitle: "Datum ergänzen", target: nil, action: nil)
    private let dateFormatField = NSTextField()
    private let foldersField = NSTextField()
    private let patternsField = NSTextField()
    private let extensionsField = NSTextField()

    init(rootName: String, options: LocationOptions) {
        self.rootName = rootName
        self.options = options
    }

    func runModal() -> LocationOptions? {
        buildWindow()
        populate()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return accepted ? options : nil
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 610),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Regeln für \(rootName)"
        window.delegate = self

        let title = NSTextField(labelWithString: "Individuelle Umbenennungsregeln")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let help = NSTextField(wrappingLabelWithString: "Verfügbare Platzhalter: {prefix}, {title}, {date} und {separator}. Kommagetrennte Ausschlüsse gelten nur für diese Struktur.")
        help.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label("Eigener Präfix"), prefixField],
            [label("Namensschema"), templateField],
            [label("Trennzeichen"), separatorField],
            [label("Datumsformat"), dateFormatField],
            [label("Ordner ignorieren"), foldersField],
            [label("Dateimuster ignorieren"), patternsField],
            [label("Endungen ignorieren"), extensionsField]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 160
        grid.column(at: 1).width = 420

        prefixField.placeholderString = "Leer = automatisch aus dem Ordner"
        templateField.placeholderString = "{prefix}{separator}{title}{separator}{date}"
        separatorField.placeholderString = "_"
        dateFormatField.placeholderString = "yyyy-MM-dd"
        foldersField.placeholderString = "Archiv, Cache"
        patternsField.placeholderString = "*.tmp, Entwurf*"
        extensionsField.placeholderString = "part, download"

        let checks = NSStackView(views: [pauseCheck, dateCheck])
        checks.orientation = .horizontal
        checks.spacing = 24
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Regeln speichern", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), cancel, save])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, help, checks, grid, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        for view in [title, help, checks, grid, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text + ":")
        field.textColor = .secondaryLabelColor
        return field
    }

    private func populate() {
        pauseCheck.state = options.isPaused ? .on : .off
        prefixField.stringValue = options.customPrefix
        templateField.stringValue = options.namingTemplate
        separatorField.stringValue = options.separator ?? "_"
        dateCheck.state = (options.includeDate ?? true) ? .on : .off
        dateFormatField.stringValue = options.dateFormat
        foldersField.stringValue = options.excludedFolderNames.joined(separator: ", ")
        patternsField.stringValue = options.excludedFilePatterns.joined(separator: ", ")
        extensionsField.stringValue = options.excludedExtensions.joined(separator: ", ")
    }

    private func values(_ field: NSTextField) -> [String] {
        field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    @objc private func save() {
        let template = templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty && !template.contains("{title}") {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Namensschema benötigt {title}"
            alert.informativeText = "Der Platzhalter verhindert, dass verschiedene Dateien denselben Namen erhalten."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        options.isPaused = pauseCheck.state == .on
        options.customPrefix = prefixField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        options.namingTemplate = template
        options.separator = separatorField.stringValue
        options.includeDate = dateCheck.state == .on
        options.dateFormat = dateFormatField.stringValue
        options.excludedFolderNames = values(foldersField)
        options.excludedFilePatterns = values(patternsField)
        options.excludedExtensions = values(extensionsField)
        accepted = true
        NSApp.stopModal()
    }

    @objc private func cancel() {
        accepted = false
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window { cancel() }
    }
}

@MainActor
final class RenameHistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let entries: [RenameHistoryEntry]
    private let tableView = NSTableView()
    private var window: NSWindow!
    private var selectedEntry: RenameHistoryEntry?

    init(entries: [RenameHistoryEntry]) {
        self.entries = entries.sorted { $0.renamedAt > $1.renamedAt }
    }

    func runModal() -> RenameHistoryEntry? {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return selectedEntry
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Umbenennungsverlauf"
        window.delegate = self
        let title = NSTextField(labelWithString: "Umbenennungsverlauf")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Nur verfügbare, noch nicht zurückgenommene Änderungen können rückgängig gemacht werden.")
        subtitle.textColor = .secondaryLabelColor

        for (id, heading, width) in [("date", "Zeitpunkt", 150.0), ("old", "Ursprünglicher Name", 320.0), ("new", "Neuer Name", 360.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = heading
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let undo = NSButton(title: "Ausgewählte Umbenennung rückgängig", target: self, action: #selector(undo))
        undo.image = adaptiveSymbol("arrow.uturn.backward.circle")
        undo.imagePosition = .imageLeading
        let close = NSButton(title: "Schließen", target: self, action: #selector(close))
        let actions = NSStackView(views: [undo, NSView(), close])
        actions.orientation = .horizontal
        let stack = NSStackView(views: [title, subtitle, scroll, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        for view in [title, subtitle, scroll, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 330)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "date": value = entry.renamedAt.formatted(date: .abbreviated, time: .shortened) + (entry.undoneAt == nil ? "" : " · rückgängig")
        case "old": value = entry.originalRelativePath
        default: value = entry.renamedRelativePath
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.textColor = entry.undoneAt == nil ? .labelColor : .tertiaryLabelColor
        return field
    }

    @objc private func undo() {
        guard tableView.selectedRow >= 0 else { NSSound.beep(); return }
        let entry = entries[tableView.selectedRow]
        guard entry.undoneAt == nil else { NSSound.beep(); return }
        selectedEntry = entry
        NSApp.stopModal()
    }

    @objc private func close() {
        selectedEntry = nil
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window { close() }
    }
}
