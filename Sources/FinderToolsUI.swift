import AppKit
import FinderSync
import Foundation
import UniformTypeIdentifiers

private func adaptiveSymbol(_ name: String, description: String? = nil) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: description)
    image?.isTemplate = true
    return image
}

struct ControlCenterStatus {
    let headline: String
    let isMonitoring: Bool
    let structures: String
    let folders: String
    let pending: Int
    let lastScan: String
    let error: String
}

struct ControlCenterActions {
    let status: () -> ControlCenterStatus
    let toggleMonitoring: () -> Void
    let scan: () -> Void
    let manageStructures: () -> Void
    let openQueue: () -> Void
    let openHistory: () -> Void
    let openRoot: () -> Void
    let exportConfiguration: () -> Void
    let importConfiguration: () -> Void
    let openLog: () -> Void
    let configureAutostart: () -> Void
}

private final class ThreadSafeResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

@MainActor
final class FinderToolsController: NSObject, NSWindowDelegate {
    private enum Page: Int {
        case overview
        case automations
        case storage
        case media
        case settings
    }

    private let coordinator: FinderAutomationCoordinator
    private let appActions: ControlCenterActions
    private let engine = FinderToolkitEngine()
    private var window: NSWindow?
    private let automationStatus = NSTextField(wrappingLabelWithString: "")
    private var resultControllers: [FileAnalysisResultsController] = []
    private let contentHost = NSView()
    private var sidebarButtons: [NSButton] = []
    private var selectedPage: Page = .overview
    private var automationFeedback: String?

    private enum AutomationRunMode {
        case once
        case monitored
    }

    init(coordinator: FinderAutomationCoordinator, appActions: ControlCenterActions) {
        self.coordinator = coordinator
        self.appActions = appActions
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            showPage(selectedPage)
            return
        }
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.title = "Filelio"
        created.minSize = NSSize(width: 940, height: 650)
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.contentView = buildView()
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
        showPage(.overview)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Das Kontrollzentrum wird während der App-Laufzeit wiederverwendet. Ein
    // sofortiges Freigeben kann mit der AppKit-Schließanimation kollidieren.
    func windowWillClose(_ notification: Notification) {}

    func refresh() {
        guard window != nil else { return }
        showPage(selectedPage)
    }

    func showAutomationsForPreview() {
        guard window != nil else { return }
        showPage(.automations)
    }

    func showFinderAutomationSetup(sourceURL: URL?, preferMonitoring: Bool) {
        show()
        showPage(.automations)
        DispatchQueue.main.async { [weak self] in
            self?.presentFinderAutomationSetup(sourceURL: sourceURL, preferMonitoring: preferMonitoring)
        }
    }

    func prepareForTermination() {
        window?.orderOut(nil)
        resultControllers.forEach { $0.prepareForTermination() }
    }

    func validateAllPagesForSmokeTest() -> Bool {
        guard let window else { return false }
        let expectedIcons: [(Page, Int)] = [
            (.overview, 5),
            (.automations, 5),
            (.storage, 4),
            (.media, 3),
            (.settings, 4)
        ]
        let visible = expectedIcons.allSatisfy { page, minimumIconCount in
            showPage(page)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let content = contentHost.subviews.first else { return false }
            let icons = imageViews(in: content)
            let validIcons = icons.filter { imageView in
                guard let image = imageView.image else { return false }
                return image.size.width > 0 && image.size.height > 0 && image.isTemplate
            }
            return contentHost.bounds.width > 500
                && content.frame.width > 500
                && content.frame.height > 120
                && validIcons.count >= minimumIconCount
        }
        showPage(.overview)
        return visible
    }

    func validateAllAppearancesForSmokeTest() -> Bool {
        guard let window else { return false }
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance }
        let appearances = [NSAppearance.Name.aqua, .darkAqua].compactMap(NSAppearance.init(named:))
        return appearances.count == 2 && appearances.allSatisfy { appearance in
            window.appearance = appearance
            window.contentView?.needsDisplay = true
            window.contentView?.layoutSubtreeIfNeeded()
            return validateAllPagesForSmokeTest()
        }
    }

    private func imageViews(in view: NSView) -> [NSImageView] {
        var result = view.subviews.compactMap { $0 as? NSImageView }
        for child in view.subviews { result.append(contentsOf: imageViews(in: child)) }
        return result
    }

    private func buildView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 720))
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "AppIcon-master", withExtension: "png") {
            icon.image = NSImage(contentsOf: url)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44)
        ])
        let title = NSTextField(labelWithString: "Filelio")
        title.font = .systemFont(ofSize: 21, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Kontrollzentrum · CreativTechnik")
        subtitle.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        let header = NSStackView(views: [icon, texts])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)

        let navigation: [(String, String, Page)] = [
            ("Übersicht", "gauge.with.dots.needle.67percent", .overview),
            ("Automationen", "bolt.badge.clock.fill", .automations),
            ("Speicher prüfen", "doc.text.magnifyingglass", .storage),
            ("PDF & Bilder", "photo.on.rectangle.angled", .media),
            ("Einstellungen", "gearshape.fill", .settings)
        ]
        sidebarButtons = navigation.map { title, symbol, page in
            let item = NSButton(title: title, target: self, action: #selector(selectPage(_:)))
            item.tag = page.rawValue
            item.bezelStyle = .recessed
            item.setButtonType(.pushOnPushOff)
            item.alignment = .left
            item.font = .systemFont(ofSize: 13, weight: .medium)
            item.image = adaptiveSymbol(symbol)
            item.imagePosition = .imageLeading
            item.contentTintColor = .labelColor
            item.translatesAutoresizingMaskIntoConstraints = false
            item.heightAnchor.constraint(equalToConstant: 38).isActive = true
            return item
        }
        let navStack = NSStackView(views: sidebarButtons)
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 5
        navStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navStack)
        for item in sidebarButtons { item.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true }

        let explanation = NSTextField(wrappingLabelWithString: "Automationen laufen ereignisbasiert. Analysewerkzeuge starten nur, wenn du sie anklickst.")
        explanation.font = .systemFont(ofSize: 10)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 4
        explanation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(explanation)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentHost)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 15),
            header.heightAnchor.constraint(equalToConstant: 48),

            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),

            navStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            navStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            navStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            explanation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            explanation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            explanation.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),

            contentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: sidebar.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func selectPage(_ sender: NSButton) {
        guard let page = Page(rawValue: sender.tag) else { return }
        showPage(page)
    }

    private func showPage(_ page: Page) {
        selectedPage = page
        sidebarButtons.forEach { $0.state = $0.tag == page.rawValue ? .on : .off }
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch page {
        case .overview: content = overviewPage()
        case .automations: content = automationsPage()
        case .storage: content = storagePage()
        case .media: content = mediaPage()
        case .settings: content = settingsPage()
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 26),
            content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -26),
            content.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: contentHost.bottomAnchor, constant: -22)
        ])
    }

    private func overviewPage() -> NSView {
        let status = appActions.status()
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 16, weight: .bold)
        dot.textColor = status.isMonitoring ? .systemGreen : .systemRed
        let state = NSTextField(labelWithString: status.headline)
        state.font = .systemFont(ofSize: 17, weight: .semibold)
        let stateRow = NSStackView(views: [dot, state])
        stateRow.orientation = .horizontal
        stateRow.spacing = 8
        let grid = NSGridView(views: [
            [smallCaption("Strukturen"), value(status.structures)],
            [smallCaption("Ordnerpfade"), value(status.folders)],
            [smallCaption("Warteschlange"), value(status.pending == 0 ? "Keine Datei wartet" : "\(status.pending) Datei(en) warten")],
            [smallCaption("Letzte Prüfung"), value(status.lastScan)]
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        grid.column(at: 0).width = 112
        grid.column(at: 0).xPlacement = .trailing
        let statusCard = simpleCard([stateRow, grid])
        let cards = cardGrid([
            moduleCard(symbol: "power.circle.fill", title: "Überwachung", description: "Startet oder stoppt die automatische Dateierkennung für alle aktiven Strukturen.", primary: (status.isMonitoring ? "Überwachung stoppen" : "Überwachung starten", #selector(performToggleMonitoring)), secondary: ("Jetzt prüfen", #selector(performScan))),
            moduleCard(symbol: "folder.badge.gearshape", title: "Ordnerstrukturen", description: "Stammordner hinzufügen, vorhandene Strukturen übernehmen und Namensregeln bearbeiten.", primary: ("Strukturen verwalten", #selector(performManageStructures))),
            moduleCard(symbol: "tray.full.fill", title: "Wartende Dateien", description: "Zeigt den vollständigen neuen Dateinamen vor dem Umbenennen und unterstützt Mehrfachauswahl.", primary: (status.pending == 0 ? "Warteschlange öffnen" : "\(status.pending) Datei(en) prüfen", #selector(performOpenQueue))),
            moduleCard(symbol: "clock.arrow.circlepath", title: "Verlauf & Rückgängig", description: "Zeigt ausgeführte Umbenennungen und stellt einen früheren Namen sicher wieder her.", primary: ("Verlauf öffnen", #selector(performOpenHistory)))
        ])
        return pageStack(
            title: "Übersicht",
            subtitle: "Die wichtigsten Funktionen und der aktuelle Zustand an einem Ort.",
            views: [statusCard, infoBanner(status.error, symbol: status.error == "Keine aktuellen Fehler." ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"), cards]
        )
    }

    private func automationsPage() -> NSView {
        refreshStatusLabel()
        let downloadsJob = activeAutomationJob(.downloads)
        let screenshotsJob = activeAutomationJob(.screenshots)
        let customMoveJob = activeAutomationJob(.customMove)
        let desktopJob = activeAutomationJob(.desktop)
        let cards = cardGrid([
            moduleCard(symbol: "arrow.down.doc.fill", title: "Downloads sortieren", description: "Sortiert nach PDF, Dokumenten, Bildern, Medien, Archiven und Code.", primary: (downloadsJob == nil ? "Einrichten" : "Ordner oder Modus ändern", #selector(configureDownloads)), secondary: downloadsJob == nil ? nil : ("Stoppen", #selector(disableDownloads)), status: automationBadge(downloadsJob), metadata: automationPath(downloadsJob)),
            moduleCard(symbol: "camera.viewfinder", title: "Screenshots organisieren", description: "Verschiebt Screenshots automatisch in Monatsordner.", primary: (screenshotsJob == nil ? "Einrichten" : "Ordner oder Modus ändern", #selector(configureScreenshots)), secondary: screenshotsJob == nil ? nil : ("Stoppen", #selector(disableScreenshots)), status: automationBadge(screenshotsJob), metadata: automationPath(screenshotsJob)),
            moduleCard(symbol: "folder.badge.gearshape", title: "Nach Dateityp verschieben", description: "Verschiebt ausgewählte Dateitypen von einer Quelle in ein Ziel.", primary: (customMoveJob == nil ? "Regel einrichten" : "Regel oder Modus ändern", #selector(configureCustomMove)), secondary: customMoveJob == nil ? nil : ("Stoppen", #selector(disableCustomMove)), status: automationBadge(customMoveJob), metadata: automationPath(customMoveJob)),
            moduleCard(symbol: "desktopcomputer", title: "Schreibtisch aufräumen", description: "Archiviert Dateien übersichtlich nach Monat und Kategorie.", primary: (desktopJob == nil ? "Einrichten" : "Ordner oder Modus ändern", #selector(configureDesktop)), secondary: desktopJob == nil ? nil : ("Stoppen", #selector(disableDesktop)), status: automationBadge(desktopJob), metadata: automationPath(desktopJob))
        ])
        return pageStack(
            title: "Automationen",
            subtitle: "Ordner einmalig aufräumen oder bei künftigen Änderungen automatisch sortieren.",
            views: [infoBanner("Nach der Vorschau entscheidest du: „Nur einmal aufräumen“ erzeugt keinen Hintergrundwächter. „Dauerhaft überwachen“ reagiert energiesparend auf künftige Änderungen.", symbol: "lightbulb.fill"), automationStatus, cards]
        )
    }

    private func storagePage() -> NSView {
        let cards = cardGrid([
            moduleCard(symbol: "doc.text.magnifyingglass", title: "Große Dateien suchen", description: "Du wählst Ordner und Mindestgröße. Die Treffer werden nur angezeigt und können im Finder geöffnet werden.", primary: ("Suche starten", #selector(findLargeFiles))),
            moduleCard(symbol: "square.on.square", title: "Duplikate finden", description: "Vergleicht erst Größe und dann den vollständigen SHA-256-Inhalt. Es wird niemals automatisch gelöscht.", primary: ("Vergleich starten", #selector(findDuplicates))),
            moduleCard(symbol: "eject.fill", title: "Laufwerk sicher auswerfen", description: "Zeigt nur externe, von macOS als auswerfbar gemeldete Datenträger und führt das sichere Auswerfen aus.", primary: ("Laufwerk auswählen", #selector(ejectDrive)))
        ])
        return pageStack(
            title: "Speicher prüfen",
            subtitle: "Speicher analysieren und externe Datenträger sicher verwalten.",
            views: [infoBanner("Diese Werkzeuge laufen ausschließlich nach einem Klick. Suchergebnisse verändern keine Datei.", symbol: "hand.raised.fill"), cards]
        )
    }

    private func mediaPage() -> NSView {
        let cards = cardGrid([
            moduleCard(symbol: "doc.on.doc.fill", title: "PDF-Dateien zusammenfügen", description: "Wähle mindestens zwei PDFs. Die Reihenfolge im Auswahldialog wird übernommen und als neue PDF gespeichert.", primary: ("PDFs auswählen", #selector(mergePDFs))),
            moduleCard(symbol: "photo.stack.fill", title: "Bilder verkleinern & konvertieren", description: "Erstellt neue JPEG- oder PNG-Kopien mit gewünschter Maximalbreite. Originalbilder bleiben erhalten.", primary: ("Bilder auswählen", #selector(convertImages)))
        ])
        return pageStack(
            title: "PDF & Bilder",
            subtitle: "Dokumente und Bilder bearbeiten, ohne die Originale zu überschreiben.",
            views: [infoBanner("Alle Ausgaben werden an einem von dir gewählten Ort gespeichert. Gleichnamige Dateien werden automatisch nummeriert.", symbol: "doc.badge.plus"), cards]
        )
    }

    private func settingsPage() -> NSView {
        let finderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        let cards = cardGrid([
            moduleCard(symbol: "cursorarrow.click.2", title: "Finder-Integration", description: "Schaltfläche in der Finder-Symbolleiste sowie zwei Dienste für ausgewählte Dateien.", primary: ("Status & Anleitung", #selector(showFinderServices)), status: (finderExtensionEnabled ? "AKTIV" : "AKTIVIEREN", finderExtensionEnabled), metadata: "Finder-Symbolleiste und Rechtsklick → Dienste"),
            moduleCard(symbol: "folder", title: "Überwachten Ordner öffnen", description: "Öffnet einen konfigurierten Stammordner direkt im Finder.", primary: ("Ordner öffnen", #selector(performOpenRoot))),
            moduleCard(symbol: "square.and.arrow.up.on.square", title: "Konfiguration sichern", description: "Exportiert oder importiert Strukturen und Regeln. macOS-Ordnerberechtigungen werden nicht weitergegeben.", primary: ("Exportieren", #selector(performExportConfiguration)), secondary: ("Importieren", #selector(performImportConfiguration))),
            moduleCard(symbol: "gearshape.2.fill", title: "System & Diagnose", description: "Autostart einrichten oder das Protokoll öffnen, falls eine Funktion nicht wie erwartet arbeitet.", primary: ("Autostart", #selector(performConfigureAutostart)), secondary: ("Protokoll", #selector(performOpenLog)))
        ])
        return pageStack(
            title: "Einstellungen",
            subtitle: "Finder-Integration, Datensicherung, Autostart und Diagnose.",
            views: [cards]
        )
    }

    private func pageStack(title: String, subtitle: String, views: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 25, weight: .bold)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let header = NSStackView(views: [heading, detail])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        let stack = NSStackView(views: [header] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        for view in [header] + views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func cardGrid(_ cards: [NSView]) -> NSView {
        var rows: [NSView] = []
        for index in stride(from: 0, to: cards.count, by: 2) {
            let left = cards[index]
            let right = index + 1 < cards.count ? cards[index + 1] : NSView()
            let row = NSStackView(views: [left, right])
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = 12
            rows.append(row)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func simpleCard(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 12
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.contentViewMargins = NSSize(width: 16, height: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor)
        ])
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return box
    }

    private func infoBanner(_ text: String, symbol: String) -> NSView {
        let image = NSImageView(image: adaptiveSymbol(symbol) ?? NSImage())
        image.contentTintColor = .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        image.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [image, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func smallCaption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text + ":")
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        return field
    }

    private func value(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    @objc private func performToggleMonitoring() { appActions.toggleMonitoring(); showPage(.overview) }
    @objc private func performScan() { appActions.scan(); showPage(.overview) }
    @objc private func performManageStructures() { appActions.manageStructures(); showPage(.overview) }
    @objc private func performOpenQueue() { appActions.openQueue(); showPage(.overview) }
    @objc private func performOpenHistory() { appActions.openHistory(); showPage(.overview) }
    @objc private func performOpenRoot() { appActions.openRoot() }
    @objc private func performExportConfiguration() { appActions.exportConfiguration() }
    @objc private func performImportConfiguration() { appActions.importConfiguration(); showPage(.overview) }
    @objc private func performOpenLog() { appActions.openLog() }
    @objc private func performConfigureAutostart() { appActions.configureAutostart(); showPage(.settings) }

    private func moduleCard(
        symbol: String,
        title: String,
        description: String,
        primary: (String, Selector),
        secondary: (String, Selector)? = nil,
        status: (String, Bool)? = nil,
        metadata: String? = nil
    ) -> NSView {
        let icon = NSImageView(image: adaptiveSymbol(symbol) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        var headingViews: [NSView] = [heading, NSView()]
        if let status {
            let badge = NSTextField(labelWithString: "  \(status.0)  ")
            badge.font = .systemFont(ofSize: 9, weight: .bold)
            badge.textColor = status.1 ? .systemGreen : .secondaryLabelColor
            badge.drawsBackground = true
            badge.backgroundColor = (status.1 ? NSColor.systemGreen : NSColor.secondaryLabelColor).withAlphaComponent(0.12)
            badge.isBezeled = false
            badge.isEditable = false
            badge.isSelectable = false
            headingViews.append(badge)
        }
        let headingRow = NSStackView(views: headingViews)
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = 6
        let detail = NSTextField(wrappingLabelWithString: description)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 3
        var textViews: [NSView] = [headingRow, detail]
        if let metadata {
            let meta = NSTextField(labelWithString: metadata)
            meta.font = .systemFont(ofSize: 10, weight: .medium)
            meta.textColor = .tertiaryLabelColor
            meta.lineBreakMode = .byTruncatingMiddle
            meta.toolTip = metadata
            textViews.append(meta)
        }
        let text = NSStackView(views: textViews)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        for view in textViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        let top = NSStackView(views: [icon, text])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 11
        let primaryButton = button(primary.0, primary.1)
        var actionViews: [NSView] = [primaryButton]
        if let secondary { actionViews.append(button(secondary.0, secondary.1)) }
        actionViews.append(NSView())
        let actions = NSStackView(views: actionViews)
        actions.orientation = .horizontal
        actions.spacing = 7
        let stack = NSStackView(views: [top, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
        card.fillColor = .controlBackgroundColor
        card.borderColor = .separatorColor
        card.borderWidth = 1
        card.contentView?.addSubview(stack)
        for view in [top, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor, constant: -14),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 142)
        ])
        return card
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func refreshStatusLabel() {
        if let automationFeedback {
            automationStatus.stringValue = automationFeedback
            automationStatus.textColor = .controlAccentColor
            return
        }
        let active = coordinator.settings.jobs.filter(\.enabled)
        automationStatus.stringValue = active.isEmpty
            ? "Automationen: keine aktiv · Analysewerkzeuge laufen ausschließlich auf Anforderung"
            : "Automationen aktiv: " + active.map { $0.kind.title }.joined(separator: " · ")
        automationStatus.textColor = .secondaryLabelColor
    }

    private func automationIsActive(_ kind: FinderAutomationKind) -> Bool {
        coordinator.jobs(for: kind).contains(where: \.enabled)
    }

    private func activeAutomationJob(_ kind: FinderAutomationKind) -> FinderAutomationJob? {
        coordinator.jobs(for: kind).first(where: \.enabled)
    }

    private func automationBadge(_ job: FinderAutomationJob?) -> (String, Bool) {
        job == nil ? ("NICHT AKTIV", false) : ("ÜBERWACHUNG AKTIV", true)
    }

    private func automationPath(_ job: FinderAutomationJob?) -> String {
        guard let job else { return "Kein Ordner wird dauerhaft überwacht" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = job.sourcePath.hasPrefix(home + "/")
            ? "~" + String(job.sourcePath.dropFirst(home.count))
            : job.sourcePath
        if let target = job.targetPath {
            let targetPath = target.hasPrefix(home + "/") ? "~" + String(target.dropFirst(home.count)) : target
            return "\(path)  →  \(targetPath)"
        }
        return path
    }

    private func chooseDirectory(title: String, initial: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initial
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func configureSimple(_ kind: FinderAutomationKind, initialURL: URL? = nil, preferMonitoring: Bool = false) {
        let initial: URL?
        if let initialURL {
            initial = initialURL
        } else {
            switch kind {
            case .downloads: initial = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            case .desktop, .screenshots: initial = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            case .customMove: initial = nil
            }
        }
        guard let source = chooseDirectory(title: "Ordner für „\(kind.title)“ auswählen", initial: initial) else { return }
        guard let plans = buildAutomationPlan(kind: kind, source: source) else { return }
        presentAutomationRunMode(kind: kind, matchingCount: plans.count, preferMonitoring: preferMonitoring) { [weak self] mode in
            guard let self, let mode else { return }
            self.applyAutomation(kind: kind, source: source, plans: plans, mode: mode)
        }
    }

    @objc private func configureDownloads() { configureSimple(.downloads) }
    @objc private func configureScreenshots() { configureSimple(.screenshots) }
    @objc private func configureDesktop() { configureSimple(.desktop) }

    @objc private func configureCustomMove() { configureCustomMoveFlow(initialURL: nil, preferMonitoring: false) }

    private func configureCustomMoveFlow(initialURL: URL?, preferMonitoring: Bool) {
        guard let source = chooseDirectory(title: "Quellordner auswählen", initial: initialURL) else { return }
        guard let target = chooseDirectory(title: "Zielordner auswählen") else { return }
        let alert = NSAlert()
        alert.messageText = "Dateitypen festlegen"
        alert.informativeText = "Gib Dateiendungen kommagetrennt ein, zum Beispiel: pdf, docx, jpg"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        input.placeholderString = "pdf, docx"
        alert.accessoryView = input
        alert.addButton(withTitle: "Weiter")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let extensions = input.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let plans = buildAutomationPlan(kind: .customMove, source: source, target: target, extensions: extensions) else { return }
        presentAutomationRunMode(kind: .customMove, matchingCount: plans.count, preferMonitoring: preferMonitoring) { [weak self] mode in
            guard let self, let mode else { return }
            self.applyAutomation(kind: .customMove, source: source, target: target, extensions: extensions, plans: plans, mode: mode)
        }
    }

    private func buildAutomationPlan(
        kind: FinderAutomationKind,
        source: URL,
        target: URL? = nil,
        extensions: [String] = []
    ) -> [FileMovePlan]? {
        var planningResult: Result<[FileMovePlan], Error>?
        runBackground(title: "Ordner wird analysiert …") {
            try FinderToolkitEngine().automationPlan(
                kind: kind,
                source: source,
                target: target,
                extensions: extensions
            )
        } completion: { planningResult = $0 }
        switch planningResult {
        case .success(let plans): return plans
        case .failure(let error):
            showError("Der Ordner konnte nicht analysiert werden.", error)
            return nil
        case nil: return nil
        }
    }

    private func presentAutomationRunMode(
        kind: FinderAutomationKind,
        matchingCount: Int,
        preferMonitoring: Bool = false,
        completion: @escaping (AutomationRunMode?) -> Void
    ) {
        let existingNote = automationIsActive(kind)
            ? "Eine bestehende Überwachung bleibt bei einer einmaligen Ausführung unverändert."
            : ""
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Ausführung festlegen"
        alert.informativeText = "\(kind.title) · aktuell \(matchingCount) passende Datei(en). Es wird nichts gelöscht."

        let selector = NSSegmentedControl(
            labels: ["Nur einmal", "Dauerhaft"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        selector.selectedSegment = preferMonitoring ? 1 : 0
        selector.segmentStyle = .rounded
        selector.translatesAutoresizingMaskIntoConstraints = false
        let once = NSTextField(labelWithString: "Nur einmal: jetzt sortieren, ohne Hintergrundüberwachung")
        let watched = NSTextField(labelWithString: "Dauerhaft: jetzt sortieren und künftige Änderungen überwachen")
        let existing = NSTextField(wrappingLabelWithString: existingNote)
        for label in [once, watched, existing] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let labels = [once, watched] + (existingNote.isEmpty ? [] : [existing])
        let stack = NSStackView(views: [selector] + labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: existingNote.isEmpty ? 82 : 104))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            selector.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Ausführen")
        alert.addButton(withTitle: "Abbrechen")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(selector.selectedSegment == 1 ? .monitored : .once)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func presentFinderAutomationSetup(sourceURL: URL?, preferMonitoring: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = preferMonitoring ? "Ordner dauerhaft überwachen" : "Ordner einmalig organisieren"
        alert.informativeText = "Wähle, wie Filelio den aktuellen Finder-Ordner behandeln soll. Vor jeder Änderung folgt eine Vorschau."
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 28))
        choices.addItems(withTitles: [
            "Nach Dateityp sortieren",
            "Screenshots in Monatsordner",
            "Dateien nach eigener Endungsregel verschieben",
            "Nach Monat und Kategorie archivieren"
        ])
        alert.accessoryView = choices
        alert.addButton(withTitle: "Weiter")
        alert.addButton(withTitle: "Abbrechen")

        let continueSetup: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            switch choices.indexOfSelectedItem {
            case 0: self.configureSimple(.downloads, initialURL: sourceURL, preferMonitoring: preferMonitoring)
            case 1: self.configureSimple(.screenshots, initialURL: sourceURL, preferMonitoring: preferMonitoring)
            case 2: self.configureCustomMoveFlow(initialURL: sourceURL, preferMonitoring: preferMonitoring)
            default: self.configureSimple(.desktop, initialURL: sourceURL, preferMonitoring: preferMonitoring)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: continueSetup)
        } else {
            continueSetup(alert.runModal())
        }
    }

    private func applyAutomation(
        kind: FinderAutomationKind,
        source: URL,
        target: URL? = nil,
        extensions: [String] = [],
        plans: [FileMovePlan],
        mode: AutomationRunMode
    ) {
        switch mode {
        case .once:
            runBackground(title: "Ordner wird einmalig aufgeräumt …") {
                try FinderToolkitEngine().execute(plans)
            } completion: { result in
                switch result {
                case .success(let moved):
                    self.automationFeedback = moved.isEmpty
                        ? "Einmalige Ausführung beendet: keine passende Datei gefunden · keine Überwachung angelegt"
                        : "Einmalige Ausführung beendet: \(moved.count) Datei(en) sortiert · keine Überwachung angelegt"
                    self.showPage(.automations)
                case .failure(let error):
                    self.showError("Die einmalige Sortierung ist fehlgeschlagen.", error)
                }
            }
        case .monitored:
            do {
                try coordinator.configure(kind: kind, source: source, target: target, extensions: extensions)
                automationFeedback = "Dauerhafte Überwachung aktiv: \(kind.title) · aktuell \(plans.count) passende Datei(en)"
                showPage(.automations)
            } catch {
                showError("Die Automatik konnte nicht gespeichert werden.", error)
            }
        }
    }

    private func disable(_ kind: FinderAutomationKind) {
        do {
            try coordinator.disable(kind: kind)
            automationFeedback = "Überwachung beendet: \(kind.title)"
            showPage(.automations)
        }
        catch { showError("Die Automatik konnte nicht gestoppt werden.", error) }
    }

    @objc private func disableDownloads() { disable(.downloads) }
    @objc private func disableScreenshots() { disable(.screenshots) }
    @objc private func disableDesktop() { disable(.desktop) }
    @objc private func disableCustomMove() { disable(.customMove) }

    @objc private func findLargeFiles() {
        guard let root = chooseDirectory(title: "Ordner nach großen Dateien durchsuchen") else { return }
        let alert = NSAlert()
        alert.messageText = "Mindestgröße in MB"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        input.stringValue = "500"
        alert.accessoryView = input
        alert.addButton(withTitle: "Suchen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let megabytes = max(1, Int64(input.stringValue) ?? 500)
        runBackground(title: "Große Dateien werden gesucht …") { [engine] in
            try engine.largeFiles(in: root, minimumBytes: megabytes * 1_048_576)
        } completion: { result in
            switch result {
            case .success(let findings):
                let controller = FileAnalysisResultsController(title: "Große Dateien", largeFiles: findings)
                self.resultControllers.append(controller)
                controller.show(attachedTo: self.window)
            case .failure(let error): self.showError("Die Suche ist fehlgeschlagen.", error)
            }
        }
    }

    @objc private func findDuplicates() {
        guard let root = chooseDirectory(title: "Ordner nach Duplikaten durchsuchen") else { return }
        runBackground(title: "Dateiinhalte werden verglichen …") { [engine] in
            try engine.duplicateGroups(in: root)
        } completion: { result in
            switch result {
            case .success(let groups):
                let controller = FileAnalysisResultsController(title: "Gefundene Duplikate", duplicateGroups: groups)
                self.resultControllers.append(controller)
                controller.show(attachedTo: self.window)
            case .failure(let error): self.showError("Die Duplikatsuche ist fehlgeschlagen.", error)
            }
        }
    }

    @objc private func ejectDrive() {
        let volumes = engine.externalVolumes()
        guard !volumes.isEmpty else {
            showMessage("Kein auswerfbares Laufwerk", "macOS meldet aktuell keinen sicher auswerfbaren externen Datenträger.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Externes Laufwerk sicher auswerfen"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        volumes.forEach { popup.addItem(withTitle: $0.lastPathComponent) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Auswerfen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = volumes[max(0, popup.indexOfSelectedItem)]
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: selected)
            showMessage("Laufwerk ausgeworfen", selected.lastPathComponent)
        } catch {
            showError("Das Laufwerk konnte nicht ausgeworfen werden.", error)
        }
    }

    @objc private func mergePDFs() {
        let open = NSOpenPanel()
        open.title = "PDF-Dateien in gewünschter Reihenfolge auswählen"
        open.allowedContentTypes = [.pdf]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        guard open.runModal() == .OK, open.urls.count >= 2 else { return }
        let save = NSSavePanel()
        save.title = "Zusammengeführte PDF speichern"
        save.allowedContentTypes = [.pdf]
        save.nameFieldStringValue = "Zusammengeführt.pdf"
        guard save.runModal() == .OK, let destination = save.url else { return }
        let selectedPDFs = open.urls
        runBackground(title: "PDF-Dateien werden zusammengeführt …") { [engine] in
            try engine.mergePDFs(selectedPDFs, to: destination)
            return destination
        } completion: { result in
            switch result {
            case .success(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error): self.showError("Die PDFs konnten nicht zusammengeführt werden.", error)
            }
        }
    }

    @objc private func convertImages() {
        let open = NSOpenPanel()
        open.title = "Bilder auswählen"
        open.allowedContentTypes = [UTType.png, UTType.jpeg, UTType.heic, UTType.tiff, UTType.gif, UTType(filenameExtension: "webp")].compactMap { $0 }
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let settings = NSAlert()
        settings.messageText = "Bildkopien erstellen"
        settings.informativeText = "Maximale Breite in Pixeln (0 behält die Originalgröße)."
        let width = NSTextField(frame: NSRect(x: 0, y: 34, width: 220, height: 26))
        width.stringValue = "1920"
        let format = NSPopUpButton(frame: NSRect(x: 230, y: 34, width: 150, height: 26))
        format.addItems(withTitles: ["JPEG", "PNG"])
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 64))
        accessory.addSubview(width)
        accessory.addSubview(format)
        settings.accessoryView = accessory
        settings.addButton(withTitle: "Weiter")
        settings.addButton(withTitle: "Abbrechen")
        guard settings.runModal() == .alertFirstButtonReturn else { return }
        guard let output = chooseDirectory(title: "Ausgabeordner auswählen") else { return }
        let maxWidth = CGFloat(Double(width.stringValue) ?? 1920)
        let fileType: NSBitmapImageRep.FileType = format.indexOfSelectedItem == 1 ? .png : .jpeg
        let selectedImages = open.urls
        runBackground(title: "Bilder werden konvertiert …") { [engine] in
            try engine.convertImages(selectedImages, outputDirectory: output, maximumWidth: maxWidth, format: fileType)
        } completion: { result in
            switch result {
            case .success(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
            case .failure(let error): self.showError("Die Bilder konnten nicht konvertiert werden.", error)
            }
        }
    }

    @objc private func showFinderServices() {
        NSUpdateDynamicServices()
        let alert = NSAlert()
        alert.messageText = "Finder-Integration ist installiert"
        alert.informativeText = "Die Finder-Schaltfläche bietet Namensvorschau, Auswahlprüfung sowie einmaliges oder dauerhaftes Organisieren des aktuellen Ordners. Aktiviere „Filelio Finder“ unter Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Finder.\n\nZusätzlich bleiben die Dienste „Dateipfade kopieren“ und „Mit Filelio prüfen“ im Rechtsklick-Menü verfügbar."
        alert.addButton(withTitle: "Verstanden")
        alert.addButton(withTitle: "Finder-Erweiterungen öffnen")
        if alert.runModal() == .alertSecondButtonReturn {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }

    private func runBackground<T: Sendable>(title: String, operation: @escaping @Sendable () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        let progressAlert = NSAlert()
        progressAlert.messageText = title
        progressAlert.informativeText = "Die Arbeit läuft im Hintergrund. Andere App-Bereiche bleiben reaktionsfähig."
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 360, height: 18))
        progress.style = .spinning
        progress.startAnimation(nil)
        progressAlert.accessoryView = progress
        let resultBox = ThreadSafeResultBox<Result<T, Error>>()
        DispatchQueue.global(qos: .utility).async {
            let completed = Result { try operation() }
            resultBox.set(completed)
            DispatchQueue.main.async {
                NSApp.stopModal(withCode: .OK)
            }
        }
        progressAlert.window.center()
        NSApp.runModal(for: progressAlert.window)
        progressAlert.window.orderOut(nil)
        if let result = resultBox.get() { completion(result) }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }

    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
final class FileAnalysisResultsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private struct Row {
        let url: URL
        let size: Int64
        let detail: String
    }
    private let titleText: String
    private let rows: [Row]
    private let table = NSTableView()
    private var window: NSWindow?

    init(title: String, largeFiles: [LargeFileFinding]) {
        titleText = title
        rows = largeFiles.map { Row(url: $0.url, size: $0.size, detail: "Große Datei") }
    }

    init(title: String, duplicateGroups: [DuplicateFileGroup]) {
        titleText = title
        rows = duplicateGroups.enumerated().flatMap { index, group in
            group.urls.map { Row(url: $0, size: group.size, detail: "Duplikatgruppe \(index + 1) · \(group.urls.count) Dateien") }
        }
    }

    func show(attachedTo parentWindow: NSWindow? = nil) {
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        created.title = titleText
        created.isReleasedWhenClosed = false
        created.delegate = self
        let heading = NSTextField(labelWithString: titleText)
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let note = NSTextField(labelWithString: "\(rows.count) Treffer · Es wird nichts automatisch gelöscht.")
        note.textColor = .secondaryLabelColor
        for (id, label, width) in [("name", "Datei", 260.0), ("size", "Größe", 110.0), ("path", "Speicherort / Gruppe", 480.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(reveal)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let reveal = NSButton(title: "Im Finder anzeigen", target: self, action: #selector(reveal))
        let close = NSButton(title: "Schließen", target: self, action: #selector(close))
        let actions = NSStackView(views: [reveal, NSView(), close])
        actions.orientation = .horizontal
        let stack = NSStackView(views: [heading, note, scroll, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        created.contentView?.addSubview(stack)
        for view in [heading, note, scroll, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: created.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: created.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: created.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: created.contentView!.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        window = created
        if let parentWindow {
            parentWindow.beginSheet(created)
        } else {
            created.center()
            created.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func prepareForTermination() {
        window?.orderOut(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = item.url.lastPathComponent
        case "size": value = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        default: value = item.detail + " · " + item.url.deletingLastPathComponent().path
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = item.url.path
        return field
    }

    @objc private func reveal() {
        guard table.selectedRow >= 0 else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([rows[table.selectedRow].url])
    }

    @objc private func close() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        else { window.close() }
    }
    func windowWillClose(_ notification: Notification) {}
}
