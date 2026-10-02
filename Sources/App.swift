import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

private func adaptiveSymbol(_ name: String, description: String? = nil) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    image?.isTemplate = true
    return image
}

private struct PendingFileObservation {
    let snapshot: FileStabilitySnapshot
    let observedAt: Date
}

private struct ScanEnumerationResult {
    var state: PersistentState
    var candidates: [(RenameCandidate, URL)]
    var logMessages: [String]
    var lastError: String?
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fileManager = FileManager.default
    private let paths = AppPaths()
    private lazy var store = JSONStore(paths: paths, fileManager: fileManager)
    private let engine = RenameEngine()
    private var configuration: AppConfiguration?
    private var persistentState = PersistentState()
    private var rootURLs: [String: URL] = [:]
    private var scopedRootIDs = Set<String>()
    private var monitors: [String: DirectoryMonitor] = [:]
    private var pendingScanLocationIDs = Set<String>()
    private var pendingChangesByLocation: [String: DirectoryChange] = [:]
    private var fileObservations: [String: PendingFileObservation] = [:]
    private var pendingStabilityURLsByLocation: [String: Set<URL>] = [:]
    private var renameQueue: [QueuedRenameItem] = []
    private var renameQueueVisible = false
    private var stabilityRetryWorkItem: DispatchWorkItem?
    private var firstLaunchWizardVisible = false
    private var fallbackTimer: Timer?
	private var isScanning = false
	private var scanGeneration = 0
	private let testMode = ProcessInfo.processInfo.arguments.contains("--test-mode")
	private let headlessSmokeTest = ProcessInfo.processInfo.arguments.contains("--headless-smoke-test")
	private let uiSmokeTest = ProcessInfo.processInfo.arguments.contains("--ui-smoke-test")
	private let uiPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
	private let backgroundScanSmokeTest = ProcessInfo.processInfo.arguments.contains("--background-scan-smoke-test")
	private let finderServicesSmokeTest = ProcessInfo.processInfo.arguments.contains("--finder-services-smoke-test")
	private let finderSyncSmokeTest = ProcessInfo.processInfo.arguments.contains("--finder-sync-smoke-test")

    private var statusItem: NSStatusItem!
    private var statusPanel: NSPanel?
    private var previewWindow: NSWindow?
    private lazy var finderAutomationCoordinator = FinderAutomationCoordinator(baseURL: paths.baseURL) { [weak self] message in
        self?.store.appendLog(message)
    }
    private lazy var finderToolsController = FinderToolsController(
        coordinator: finderAutomationCoordinator,
        appActions: ControlCenterActions(
            status: { [weak self] in self?.controlCenterStatus() ?? ControlCenterStatus(headline: "Nicht verfügbar", isMonitoring: false, structures: "–", folders: "–", pending: 0, lastScan: "–", error: "Status nicht verfügbar") },
            toggleMonitoring: { [weak self] in self?.toggleMonitoring() },
            scan: { [weak self] in self?.scanNow() },
            manageStructures: { [weak self] in self?.changeSetup() },
            openQueue: { [weak self] in self?.openRenameQueue() },
            openHistory: { [weak self] in self?.showRenameHistory() },
            openRoot: { [weak self] in self?.openRootFolder() },
            exportConfiguration: { [weak self] in self?.exportConfiguration() },
            importConfiguration: { [weak self] in self?.importConfiguration() },
            openLog: { [weak self] in self?.openLog() },
            configureAutostart: { [weak self] in self?.configureAutostart() }
        )
    )
    private let overallDot = NSTextField(labelWithString: "●")
    private let overallValue = NSTextField(labelWithString: "Nicht eingerichtet")
    private let rootValue = NSTextField(wrappingLabelWithString: "–")
    private let folderValue = NSTextField(labelWithString: "–")
    private let prefixValue = NSTextField(wrappingLabelWithString: "–")
    private let filesValue = NSTextField(labelWithString: "–")
    private let scanValue = NSTextField(labelWithString: "–")
    private let watcherValue = NSTextField(labelWithString: "–")
    private let loginValue = NSTextField(labelWithString: "–")
    private let errorValue = NSTextField(wrappingLabelWithString: "Keine Fehler.")
    private lazy var startStopButton = makeButton("Überwachung starten", action: #selector(toggleMonitoring))
    private lazy var queueButton = makeButton("Warteschlange", action: #selector(openRenameQueue))
    private lazy var autostartButton = makeButton("Autostart einrichten", action: #selector(configureAutostart))

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self

        do { try paths.ensureDirectories(fileManager: fileManager) }
        catch { presentError("Der Datenordner konnte nicht erstellt werden.", error) }

		setupStatusItem()
		setupStatusPanel()
		if uiPreview {
			runUIPreview()
			return
		}
		if backgroundScanSmokeTest {
			runBackgroundScanSmokeTest()
			return
		}
		if finderServicesSmokeTest {
			runFinderServicesSmokeTest()
			return
		}
		if finderSyncSmokeTest {
			runFinderSyncSmokeTest()
			return
		}
		if uiSmokeTest {
			runUISmokeTest()
			return
		}
		if headlessSmokeTest {
			print("HEADLESS_SMOKE_TEST_PASS bundle=\(Bundle.main.bundleIdentifier ?? "unknown") sandboxData=\(paths.baseURL.path)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
			return
		}
		loadPersistentData()
		finderAutomationCoordinator.start()
		registerLoginItemIfPossible()
        refreshStatus()

        if configuration == nil {
            DispatchQueue.main.async { [weak self] in self?.runFirstLaunchWizard() }
        } else if let configuration, rootURLs.count != configuration.locations.count {
            DispatchQueue.main.async { [weak self] in self?.presentUnavailableLocations() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !headlessSmokeTest, !uiSmokeTest else { return true }
        DispatchQueue.main.async { [weak self] in self?.presentMainInterface() }
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !headlessSmokeTest, !uiSmokeTest else { return true }
        DispatchQueue.main.async { [weak self] in self?.presentMainInterface() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "filelio" {
            handleFinderBridgeURL(url)
        }
    }

    private var displayVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private func presentMainInterface() {
        guard configuration != nil else {
            runFirstLaunchWizard()
            return
        }
        showStatusPanel()
    }

    private func presentUnavailableLocations() {
        guard let configuration else { return }
        let missing = configuration.locations.filter { rootURLs[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let names = missing.map { URL(fileURLWithPath: $0.rootPath).lastPathComponent }.joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stammordner nicht verfügbar"
        alert.informativeText = "Folgende Struktur muss neu ausgewählt oder entfernt werden: \(names)"
        alert.addButton(withTitle: "Strukturen verwalten")
        alert.addButton(withTitle: "Später")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { runConfigurationManager() }
    }

    private func runUISmokeTest() {
        let samplePaths = ["Privat/Auto/Kfz", "Privat/Auto/Versicherung", "Arbeit/Projekte"]
        configuration = AppConfiguration(locations: [
            WatchedLocation(id: "ui-a", rootPath: "/tmp/Beispiel A", folderPaths: samplePaths),
            WatchedLocation(id: "ui-b", rootPath: "/tmp/Beispiel B", folderPaths: ["Fotos/Archiv"])
        ])
        refreshStatus()
        showStatusPanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        statusPanel?.orderOut(nil)

        let structureEditor = StructureEditorController(folderPaths: samplePaths, rootName: "Beispiel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.stopModal() }
        _ = structureEditor.runModal()

        let sampleLocations = [
            WatchedLocation(id: "ui-a", rootPath: "/tmp/Beispiel A", folderPaths: samplePaths),
            WatchedLocation(id: "ui-b", rootPath: "/tmp/Beispiel B", folderPaths: ["Fotos/Archiv"])
        ]
        let manager = LocationManagerController(locations: sampleLocations)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.stopModal() }
        _ = manager.runModal()

        let sampleCandidate = RenameCandidate(
            url: URL(fileURLWithPath: "/tmp/Beleg mit Leerzeichen.pdf"),
            relativeKey: "ui-a::Privat/Auto/Kfz/Beleg mit Leerzeichen.pdf",
            relativePath: "Privat/Auto/Kfz/Beleg mit Leerzeichen.pdf",
            prefix: "Privat_Auto_Kfz",
            locationID: "ui-a",
            separator: "_",
            includeDate: true,
            dateFormat: "yyyy-MM-dd",
            namingTemplate: "{prefix}{separator}{title}{separator}{date}"
        )
        let queue = RenameQueueController(items: [QueuedRenameItem(candidate: sampleCandidate, rootURL: URL(fileURLWithPath: "/tmp"))], configuration: configuration!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.stopModal() }
        _ = queue.runModal()
        let rules = LocationOptionsController(rootName: "Beispiel", options: LocationOptions())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.stopModal() }
        _ = rules.runModal()
        let history = RenameHistoryController(entries: [RenameHistoryEntry(locationID: "ui-a", originalRelativePath: "Alt.pdf", renamedRelativePath: "Neu.pdf")])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.stopModal() }
        _ = history.runModal()
        finderToolsController.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let controlCenterVisible = finderToolsController.validateAllAppearancesForSmokeTest()
        NSApp.windows.first(where: { $0.title == "Filelio" })?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        finderToolsController.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let controlCenterReopens = finderToolsController.validateAllPagesForSmokeTest()
        NSApp.windows.first(where: { $0.title == "Filelio" })?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard controlCenterVisible, controlCenterReopens else {
            print("UI_SMOKE_TEST_FAIL controlCenterPagesVisible=\(controlCenterVisible) reopens=\(controlCenterReopens)")
            NSApp.terminate(nil)
            return
        }
        print("UI_SMOKE_TEST_PASS structures=2 graphicalTree=true statusPanel=true controlCenterPages=5 appearanceModes=2 closeReopen=true customIcon=\(bundledImage(named: "AppIcon-master", extension: "png") != nil)")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func runUIPreview() {
        configuration = AppConfiguration(locations: [
            WatchedLocation(id: "preview-a", rootPath: "/Users/Beispiel/Dokumente", folderPaths: ["Privat/Auto/Kfz", "Privat/Auto/Versicherung"]),
            WatchedLocation(id: "preview-b", rootPath: "/Users/Beispiel/Arbeit", folderPaths: ["Projekte/2026"])
        ])
        persistentState.lastScan = Date()
        persistentState.lastScanReason = "Gezielte Prüfung"
        refreshStatus()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 455),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Filelio – Menüvorschau"
        window.contentView = buildPopoverView()
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.captureUIPreview() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { NSApp.terminate(nil) }
    }

    private func runBackgroundScanSmokeTest() {
        do {
            let root = paths.baseURL.appendingPathComponent("BackgroundScanSmoke", isDirectory: true)
            let watchedFolder = root.appendingPathComponent("Privat/Auto/Kfz", isDirectory: true)
            try fileManager.createDirectory(at: watchedFolder, withIntermediateDirectories: true)
            let existingFile = watchedFolder.appendingPathComponent("Altbestand.txt")
            try Data("baseline".utf8).write(to: existingFile, options: .atomic)
            let location = WatchedLocation(id: "background-smoke", rootPath: root.path, folderPaths: ["Privat/Auto/Kfz"])
            let smokeConfiguration = AppConfiguration(locations: [location], monitoringEnabled: false)
            configuration = smokeConfiguration
            rootURLs[location.id] = root
            persistentState = PersistentState()
            try engine.registerExistingFiles(rootURL: root, location: location, state: &persistentState)
            performScan(reason: "Hintergrund-Selbsttest", allowWhenStopped: true)
            DispatchQueue.main.async { print("BACKGROUND_SCAN_MAIN_THREAD_RESPONSIVE") }
            waitForBackgroundSmokeTest(deadline: Date().addingTimeInterval(8))
        } catch {
            print("BACKGROUND_SCAN_SMOKE_TEST_FAIL \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func runFinderServicesSmokeTest() {
        do {
            let root = paths.baseURL.appendingPathComponent("FinderServicesSmoke/Root", isDirectory: true)
            let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
            let selectedFile = inbox.appendingPathComponent("Finder Testdatei.txt")
            try Data("Finder-Dienst".utf8).write(to: selectedFile, options: .atomic)

            let location = WatchedLocation(
                id: "finder-services-smoke",
                rootPath: root.path,
                folderPaths: ["Inbox"]
            )
            let smokeConfiguration = AppConfiguration(locations: [location], monitoringEnabled: false)
            configuration = smokeConfiguration
            rootURLs[location.id] = root
            persistentState = PersistentState()
            var directState = PersistentState()
            let directCandidates = try engine.candidates(
                rootURL: root,
                location: location,
                configuration: smokeConfiguration,
                state: &directState,
                changedURLs: Set([selectedFile])
            )
            guard directCandidates.count == 1 else {
                print("FINDER_SERVICES_SMOKE_FAIL coreCandidates=\(directCandidates.count)")
                NSApp.terminate(nil)
                return
            }

            let copyPasteboard = NSPasteboard.withUniqueName()
            copyPasteboard.writeObjects([selectedFile as NSURL])
            var copyError: NSString?
            copyFilePaths(copyPasteboard, userData: "", error: &copyError)
            let copiedValue = copyPasteboard.string(forType: .string)
            let generalValue = NSPasteboard.general.string(forType: .string)
            guard copyError == nil, copiedValue == selectedFile.path, generalValue == selectedFile.path else {
                print("FINDER_SERVICES_SMOKE_FAIL copy=\(copyError?.description ?? "falscher Inhalt")")
                NSApp.terminate(nil)
                return
            }

            let inspectPasteboard = NSPasteboard.withUniqueName()
            inspectPasteboard.writeObjects([selectedFile as NSURL])
            var inspectError: NSString?
            inspectFilesInFilelio(inspectPasteboard, userData: "", error: &inspectError)
            guard inspectError == nil else {
                print("FINDER_SERVICES_SMOKE_FAIL inspect=\(inspectError!)")
                NSApp.terminate(nil)
                return
            }
            waitForFinderServicesSmokeTest(deadline: Date().addingTimeInterval(8))
        } catch {
            print("FINDER_SERVICES_SMOKE_FAIL setup=\(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func runFinderSyncSmokeTest() {
        do {
            let root = paths.baseURL.appendingPathComponent("FinderSyncSmoke/Root", isDirectory: true)
            let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
            let selectedFile = inbox.appendingPathComponent("Finder Sync Testdatei.txt")
            try Data("Finder-Symbolleiste".utf8).write(to: selectedFile, options: .atomic)
            let location = WatchedLocation(id: "finder-sync-smoke", rootPath: root.path, folderPaths: ["Inbox"])
            configuration = AppConfiguration(locations: [location], monitoringEnabled: false)
            rootURLs[location.id] = root
            persistentState = PersistentState()

            var components = URLComponents()
            components.scheme = "filelio"
            components.host = "finder"
            components.path = "/preview"
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("de.creativtechnik.Filelio.finder-smoke.\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects([selectedFile as NSURL])
            components.queryItems = [URLQueryItem(name: "pasteboard", value: pasteboard.name.rawValue)]
            guard let commandURL = components.url else { throw RenameEngineError.invalidRoot }
            handleFinderBridgeURL(commandURL)
            waitForFinderSyncSmokeTest(deadline: Date().addingTimeInterval(8))
        } catch {
            print("FINDER_SYNC_SMOKE_FAIL setup=\(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func waitForFinderSyncSmokeTest(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.renameQueue.count == 1 {
                print("FINDER_SYNC_SMOKE_PASS urlDispatch=true preview=true selected=1 pending=1")
                NSApp.terminate(nil)
            } else if Date() >= deadline {
                print("FINDER_SYNC_SMOKE_FAIL timeout pending=\(self.renameQueue.count) reason=\(self.persistentState.lastScanReason ?? "nil")")
                NSApp.terminate(nil)
            } else {
                self.waitForFinderSyncSmokeTest(deadline: deadline)
            }
        }
    }

    private func waitForFinderServicesSmokeTest(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.renameQueue.count == 1 {
                print("FINDER_SERVICES_SMOKE_PASS pathsCopied=true generalClipboard=true inspected=1 pending=1")
                NSApp.terminate(nil)
            } else if Date() >= deadline {
                print("FINDER_SERVICES_SMOKE_FAIL timeout pending=\(self.renameQueue.count) reason=\(self.persistentState.lastScanReason ?? "nil")")
                NSApp.terminate(nil)
            } else {
                self.waitForFinderServicesSmokeTest(deadline: deadline)
            }
        }
    }

    private func waitForBackgroundSmokeTest(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if !self.isScanning {
                print("BACKGROUND_SCAN_SMOKE_TEST_PASS")
                NSApp.terminate(nil)
            } else if Date() >= deadline {
                print("BACKGROUND_SCAN_SMOKE_TEST_TIMEOUT")
                NSApp.terminate(nil)
            } else {
                self.waitForBackgroundSmokeTest(deadline: deadline)
            }
        }
    }

    private func captureUIPreview() {
        guard let view = previewWindow?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        let destination = paths.baseURL.appendingPathComponent("Filelio-menu-preview.png")
        try? data.write(to: destination, options: .atomic)
        print("UI_PREVIEW_CAPTURED \(destination.path)")
        guard uiPreview else { return }
        previewWindow?.orderOut(nil)
        finderToolsController.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.captureControlCenterPreview()
        }
    }

    private func captureControlCenterPreview() {
        guard let window = NSApp.windows.first(where: { $0.title == "Filelio" }), let view = window.contentView else {
            NSApp.terminate(nil)
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSApp.terminate(nil)
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        if let data = representation.representation(using: .png, properties: [:]) {
            let destination = paths.baseURL.appendingPathComponent("Filelio-control-center-preview.png")
            try? data.write(to: destination, options: .atomic)
            print("CONTROL_CENTER_PREVIEW_CAPTURED \(destination.path)")
        }
        finderToolsController.showAutomationsForPreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureAutomationsPreview(window: window)
        }
    }

    private func captureAutomationsPreview(window: NSWindow) {
        guard let view = window.contentView else { NSApp.terminate(nil); return }
        view.layoutSubtreeIfNeeded()
        if let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: representation)
            if let data = representation.representation(using: .png, properties: [:]) {
                let destination = paths.baseURL.appendingPathComponent("Filelio-automations-preview.png")
                try? data.write(to: destination, options: .atomic)
                print("AUTOMATIONS_PREVIEW_CAPTURED \(destination.path)")
            }
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAllMonitors()
        fallbackTimer?.invalidate()
        stabilityRetryWorkItem?.cancel()
        finderAutomationCoordinator.stop()
        stopAllSecurityScopes()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = uiPreview
            ? "de.creativtechnik.Filelio.statusItem.preview"
            : "de.creativtechnik.Filelio.statusItem"
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        if let icon = bundledImage(named: "MenuBarIcon", extension: "png") {
            let ratio = icon.size.width / max(icon.size.height, 1)
            icon.isTemplate = true
            icon.size = NSSize(width: 20 * ratio, height: 20)
            button.image = icon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
        } else {
            button.title = "U↻"
            button.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        button.toolTip = "Filelio"
        button.target = self
        button.action = #selector(toggleStatusPanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupStatusPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 455),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.contentView = buildPopoverView()
        statusPanel = panel
    }

    private func buildPopoverView() -> NSView {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 455))

        let title = NSTextField(labelWithString: "Filelio")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Schnellstatus")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let appIcon = NSImageView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        appIcon.image = bundledImage(named: "AppIcon-master", extension: "png")
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 40),
            appIcon.heightAnchor.constraint(equalToConstant: 40)
        ])
        let header = NSStackView(views: [appIcon, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 11

        overallDot.font = .systemFont(ofSize: 15, weight: .bold)
        overallValue.font = .systemFont(ofSize: 15, weight: .semibold)
        let overallRow = NSStackView(views: [overallDot, overallValue])
        overallRow.orientation = .horizontal
        overallRow.alignment = .centerY
        overallRow.spacing = 8

        rootValue.maximumNumberOfLines = 1
        rootValue.lineBreakMode = .byTruncatingMiddle

        let statusGrid = NSGridView(views: [
            [caption("Strukturen"), rootValue],
            [caption("Dateien"), filesValue],
            [caption("Letzte Prüfung"), scanValue]
        ])
        statusGrid.rowSpacing = 6
        statusGrid.columnSpacing = 12
        statusGrid.column(at: 0).xPlacement = .trailing
        statusGrid.column(at: 0).width = 90
        statusGrid.column(at: 1).xPlacement = .leading
        let statusCard = card(views: [overallRow, statusGrid])

        startStopButton.image = adaptiveSymbol("pause.circle.fill")
        startStopButton.imagePosition = .imageLeading
        startStopButton.bezelColor = .controlAccentColor
        let scanButton = makeButton("Jetzt prüfen", action: #selector(scanNow), symbol: "arrow.clockwise")
        let manageButton = makeButton("Strukturen", action: #selector(changeSetup), symbol: "folder.badge.gearshape")
        let openCenter = makeButton("Kontrollzentrum & Finder-Werkzeuge öffnen", action: #selector(openFinderTools), symbol: "rectangle.grid.1x2.fill")
        openCenter.controlSize = .large
        openCenter.bezelColor = .controlAccentColor
        let primaryRow = NSStackView(views: [startStopButton, scanButton])
        primaryRow.orientation = .horizontal
        primaryRow.distribution = .fillEqually
        primaryRow.spacing = 8

        queueButton.image = adaptiveSymbol("tray.full.fill")
        queueButton.imagePosition = .imageLeading
        let secondaryRow = NSStackView(views: [queueButton, manageButton])
        secondaryRow.orientation = .horizontal
        secondaryRow.distribution = .fillEqually
        secondaryRow.spacing = 8
        let controlsCard = card(views: [openCenter, primaryRow, secondaryRow])

        errorValue.font = .systemFont(ofSize: 11)
        errorValue.textColor = .secondaryLabelColor
        errorValue.maximumNumberOfLines = 2
        watcherValue.font = .systemFont(ofSize: 10)
        watcherValue.textColor = .tertiaryLabelColor
        let systemStatus = NSStackView(views: [errorValue, watcherValue])
        systemStatus.orientation = .vertical
        systemStatus.alignment = .leading
        systemStatus.spacing = 3

        let quit = makeButton("App beenden", action: #selector(quitApplication), symbol: "power")
        quit.isBordered = false
        quit.image = nil
        quit.contentTintColor = .secondaryLabelColor

        let footer = NSTextField(labelWithString: "Version \(displayVersion) · CreativTechnik")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center

        let stack = NSStackView(views: [
            header, statusCard, controlsCard, systemStatus, quit, footer
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stack)

        for view in [header, statusCard, controlsCard, systemStatus, quit, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 17),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -14)
        ])
        return rootView
    }

    @objc private func toggleStatusPanel() {
        if statusPanel?.isVisible == true {
            statusPanel?.orderOut(nil)
        } else {
            showStatusPanel()
        }
    }

    private func showStatusPanel() {
        guard let button = statusItem?.button, let panel = statusPanel else { return }
        refreshStatus()
        if let buttonWindow = button.window {
            let windowRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(windowRect)
            let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let width = panel.frame.width
            let height = panel.frame.height
            let x = min(
                max(screenRect.midX - width / 2, visibleFrame.minX + 8),
                visibleFrame.maxX - width - 8
            )
            let y = max(visibleFrame.minY + 8, screenRect.minY - height - 6)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadPersistentData() {
        do {
            configuration = try store.loadConfiguration()
            persistentState = try store.loadState()
            guard let configuration else { return }
            resolveConfiguredRoots(configuration.locations)
            if rootURLs.count != configuration.locations.count {
                persistentState.lastError = "Mindestens ein gespeicherter Stammordner muss erneut ausgewählt werden."
            }
            if let refreshedConfiguration = self.configuration {
                try? store.saveConfiguration(refreshedConfiguration)
            }
            if configuration.monitoringEnabled { startMonitoring(runInitialScan: true) }
        } catch {
            persistentState.lastError = error.localizedDescription
            store.appendLog("START-FEHLER: \(error.localizedDescription)")
        }
    }

    private func resolveConfiguredRoots(_ locations: [WatchedLocation]) {
        stopAllSecurityScopes()
        rootURLs.removeAll()
        var refreshedLocations = locations
        var bookmarksChanged = false

        for index in refreshedLocations.indices {
            let location = refreshedLocations[index]
            var resolvedURL: URL?
            if let bookmark = location.rootBookmark {
                do {
                    var stale = false
                    let url = try URL(
                        resolvingBookmarkData: bookmark,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    )
                    if url.startAccessingSecurityScopedResource() {
                        scopedRootIDs.insert(location.id)
                    }
                    if fileManager.fileExists(atPath: url.path) {
                        resolvedURL = url
                        if stale || url.standardizedFileURL.path != location.rootPath {
                            refreshedLocations[index].rootPath = url.standardizedFileURL.path
                            refreshedLocations[index].rootBookmark = try? url.bookmarkData(
                                options: [.withSecurityScope],
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                            bookmarksChanged = true
                            store.appendLog("ORDNERZUGRIFF ERNEUERT: \(url.path)")
                        }
                    }
                } catch {
                    store.appendLog("BOOKMARK-FEHLER [\(location.rootPath)]: \(error.localizedDescription)")
                }
            }

            if resolvedURL == nil {
                let fallback = URL(fileURLWithPath: location.rootPath, isDirectory: true)
                if fileManager.fileExists(atPath: fallback.path) { resolvedURL = fallback }
            }
            if let resolvedURL { rootURLs[location.id] = resolvedURL }
        }

        if bookmarksChanged, var refreshedConfiguration = configuration {
            let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedLocations.map { ($0.id, $0) })
            refreshedConfiguration.locations = refreshedConfiguration.locations.map { refreshedByID[$0.id] ?? $0 }
            configuration = refreshedConfiguration
            try? store.saveConfiguration(refreshedConfiguration)
        }
    }

    private func stopAllSecurityScopes() {
        for locationID in scopedRootIDs {
            rootURLs[locationID]?.stopAccessingSecurityScopedResource()
        }
        scopedRootIDs.removeAll()
    }

    private func runFirstLaunchWizard() {
        guard !firstLaunchWizardVisible else { return }
        firstLaunchWizardVisible = true
        defer { firstLaunchWizardVisible = false }
        let welcome = NSAlert()
        welcome.messageText = "Willkommen bei Filelio"
        welcome.informativeText = "Du kannst mehrere unabhängige Stammordner überwachen. Für jeden Stammordner baust du die Struktur bequem als grafischen Ordnerbaum auf – ganz ohne Pfade in ein Textfeld einzugeben."
        welcome.addButton(withTitle: "Einrichten")
        welcome.addButton(withTitle: "Später")
        NSApp.activate(ignoringOtherApps: true)
        guard welcome.runModal() == .alertFirstButtonReturn else { return }
        runConfigurationManager()
    }

    private func runConfigurationManager(seedLocations: [WatchedLocation]? = nil) {
        let manager = LocationManagerController(locations: seedLocations ?? configuration?.locations ?? [])
        guard let editedLocations = manager.runModal() else { return }
        do {
            let normalizedLocations = try editedLocations.map { location -> WatchedLocation in
                var normalized = location
                normalized.folderPaths = try engine.normalizeFolderPaths(location.folderPaths)
                guard !normalized.folderPaths.isEmpty else {
                    throw RenameEngineError.invalidFolderPath("Keine Ordner in \(location.rootPath)")
                }
                return normalized
            }
            try engine.validateIndependentRoots(normalizedLocations)
            let newConfiguration = AppConfiguration(
                locations: normalizedLocations,
                separator: configuration?.separator ?? "_",
                includeDate: configuration?.includeDate ?? true,
                monitoringEnabled: true
            )

            let previousConfiguration = configuration
            let previousState = persistentState
            stopAllMonitors()
            fallbackTimer?.invalidate()
            do {
                configuration = newConfiguration
                resolveConfiguredRoots(normalizedLocations)
                guard rootURLs.count == normalizedLocations.count else {
                    throw RenameEngineError.invalidRoot
                }

                // Keep known/ignored files and history when editing a structure. Resetting
                // this state would make unchanged OneDrive and temporary files appear new.
                persistentState = previousState
                for location in normalizedLocations {
                    guard let rootURL = rootURLs[location.id] else { throw RenameEngineError.invalidRoot }
                    try engine.createConfiguredFolders(rootURL: rootURL, folderPaths: location.folderPaths)
                    try engine.registerExistingFiles(rootURL: rootURL, location: location, state: &persistentState)
                }
                try store.saveConfiguration(self.configuration ?? newConfiguration)
                try store.saveState(persistentState)
                let validLocationIDs = Set(normalizedLocations.map(\.id))
                renameQueue.removeAll { !validLocationIDs.contains($0.candidate.locationID) || !fileManager.fileExists(atPath: $0.candidate.url.path) }
            } catch {
                configuration = previousConfiguration
                persistentState = previousState
                if let previousConfiguration {
                    resolveConfiguredRoots(previousConfiguration.locations)
                    if previousConfiguration.monitoringEnabled { startMonitoring(runInitialScan: false) }
                } else {
                    stopAllSecurityScopes()
                    rootURLs.removeAll()
                }
                throw error
            }
            store.appendLog("Eingerichtet: \(normalizedLocations.count) Strukturen | \(normalizedLocations.reduce(0) { $0 + $1.folderPaths.count }) Endpfade")
            startMonitoring(runInitialScan: false)
            refreshStatus()

            let complete = NSAlert()
            complete.messageText = "Einrichtung abgeschlossen"
            let totalPaths = normalizedLocations.reduce(0) { $0 + $1.folderPaths.count }
            complete.informativeText = "\(normalizedLocations.count) Stammordner mit insgesamt \(totalPaths) Endpfaden werden jetzt ressourcenschonend überwacht."
            complete.addButton(withTitle: "OK")
            complete.runModal()
        } catch {
            presentError("Die Ordnerstrukturen konnten nicht gespeichert werden.", error)
        }
    }

    private func startMonitoring(runInitialScan: Bool) {
        guard var configuration, !configuration.locations.isEmpty else { return }
        configuration.monitoringEnabled = true
        self.configuration = configuration
        try? store.saveConfiguration(configuration)
        stopAllMonitors()

        for location in configuration.locations {
            guard !location.effectiveOptions.isPaused else { continue }
            guard let rootURL = rootURLs[location.id] else { continue }
            do {
                let scope = try engine.directoryScope(folderPaths: location.folderPaths)
                let locationID = location.id
                let monitor = DirectoryMonitor { [weak self] change in
                    self?.handleDirectoryChange(locationID: locationID, change: change)
                }
                monitor.start(
                    recursiveRootURLs: scope.recursivePaths.map { rootURL.appendingPathComponent($0, isDirectory: true) },
                    shallowRootURLs: scope.shallowPaths.map { rootURL.appendingPathComponent($0, isDirectory: true) }
                )
                monitors[location.id] = monitor
            } catch {
                persistentState.lastError = "Ordnerüberwachung konnte nicht gestartet werden: \(error.localizedDescription)"
                store.appendLog("WÄCHTER-FEHLER [\(location.rootPath)]: \(error.localizedDescription)")
            }
        }
        fallbackTimer?.invalidate()
        let safetyTimer = Timer(timeInterval: 1_800, target: self, selector: #selector(fallbackScan), userInfo: nil, repeats: true)
        safetyTimer.tolerance = 300
        RunLoop.main.add(safetyTimer, forMode: .common)
        fallbackTimer = safetyTimer
        if runInitialScan {
            DispatchQueue.main.async { [weak self] in self?.performScan(reason: "Startprüfung") }
        }
        refreshStatus()
    }

    private func stopMonitoring() {
        stopAllMonitors()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        if var configuration {
            configuration.monitoringEnabled = false
            self.configuration = configuration
            try? store.saveConfiguration(configuration)
        }
        store.appendLog("Überwachung gestoppt.")
        refreshStatus()
    }

    private func stopAllMonitors() {
        monitors.values.forEach { $0.stop() }
        monitors.removeAll()
        pendingScanLocationIDs.removeAll()
        pendingChangesByLocation.removeAll()
        pendingStabilityURLsByLocation.removeAll()
        stabilityRetryWorkItem?.cancel()
        stabilityRetryWorkItem = nil
        if isScanning {
            scanGeneration += 1
            isScanning = false
        }
    }

    private func handleDirectoryChange(locationID: String, change: DirectoryChange) {
        guard configuration?.monitoringEnabled == true else { return }
        if change.rootChanged, let configuration {
            store.appendLog("WÄCHTER: Stammordneränderung erkannt, Zugriff wird erneuert.")
            resolveConfiguredRoots(configuration.locations)
            startMonitoring(runInitialScan: false)
        }
        if isScanning {
            pendingScanLocationIDs.insert(locationID)
            mergePendingChange(change, locationID: locationID)
            return
        }
        performScan(
            reason: change.requiresFullScan ? "Ordneränderung · Vollprüfung" : "Gezielte Ordneränderung",
            locationIDs: Set([locationID]),
            changesByLocation: [locationID: change]
        )
    }

    @objc private func fallbackScan() {
        guard configuration?.monitoringEnabled == true else { return }
        performScan(reason: "Sicherheitsprüfung")
    }

    @objc private func scanNow() {
        performScan(reason: "Manuelle Prüfung", allowWhenStopped: true)
    }

    private func performScan(
        reason: String,
        allowWhenStopped: Bool = false,
        locationIDs: Set<String>? = nil,
        changesByLocation: [String: DirectoryChange] = [:]
    ) {
        guard !isScanning, let configuration else { return }
        guard allowWhenStopped || configuration.monitoringEnabled else { return }
        isScanning = true
        scanGeneration += 1
        let generation = scanGeneration
        refreshStatus()

        let selectedLocations = configuration.locations.filter { locationIDs?.contains($0.id) ?? true }
        let roots = rootURLs
        let initialState = persistentState
        DispatchQueue.global(qos: .utility).async {
            let scanEngine = RenameEngine()
            var result = ScanEnumerationResult(
                state: initialState,
                candidates: [],
                logMessages: [],
                lastError: nil
            )

            for location in selectedLocations {
                guard let rootURL = roots[location.id] else {
                    result.lastError = "Nicht verfügbar: \(location.rootPath)"
                    continue
                }
                do {
                    let changedURLs: Set<URL>?
                    if let change = changesByLocation[location.id], !change.requiresFullScan {
                        changedURLs = change.changedURLs
                    } else {
                        changedURLs = nil
                    }
                    let candidates = try scanEngine.candidates(
                        rootURL: rootURL,
                        location: location,
                        configuration: configuration,
                        state: &result.state,
                        changedURLs: changedURLs
                    )
                    result.candidates.append(contentsOf: candidates.map { ($0, rootURL) })
                } catch {
                    result.lastError = "\(location.rootPath): \(error.localizedDescription)"
                    result.logMessages.append("SCAN-FEHLER [\(location.rootPath)]: \(error.localizedDescription)")
                }
            }
            result.candidates.sort { $0.0.url.path.localizedStandardCompare($1.0.url.path) == .orderedAscending }
            let completedResult = result

            DispatchQueue.main.async { [weak self] in
                self?.finishScan(
                    completedResult,
                    generation: generation,
                    reason: reason,
                    configuration: configuration
                )
            }
        }
    }

    private func finishScan(
        _ result: ScanEnumerationResult,
        generation: Int,
        reason: String,
        configuration: AppConfiguration
    ) {
        guard isScanning, generation == scanGeneration else { return }
        persistentState = result.state
        result.logMessages.forEach(store.appendLog)
        let scanError = result.lastError
        let stabilityResult = stableCandidates(from: result.candidates)
        scheduleStabilityRetry(stabilityResult.retryURLsByLocation)

        let existingIDs = Set(renameQueue.map(\.id))
        let newItems = stabilityResult.ready
            .map { QueuedRenameItem(candidate: $0.0, rootURL: $0.1) }
            .filter { !existingIDs.contains($0.id) }
        renameQueue.append(contentsOf: newItems)
        if !newItems.isEmpty {
            store.appendLog("WARTESCHLANGE: \(newItems.count) neue Datei(en) zur Prüfung.")
        }

        persistentState.lastScan = Date()
        persistentState.lastScanReason = reason
        persistentState.lastError = scanError
        try? store.saveState(persistentState)
        isScanning = false
        refreshStatus()

        if !newItems.isEmpty, !testMode, NSApp.modalWindow == nil {
            DispatchQueue.main.async { [weak self] in self?.openRenameQueue() }
        }

        let deferredLocationIDs = pendingScanLocationIDs
        let deferredChanges = pendingChangesByLocation
        pendingScanLocationIDs.removeAll()
        pendingChangesByLocation.removeAll()
        if !deferredLocationIDs.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.performScan(
                    reason: "Nachgeholte Ordneränderung",
                    locationIDs: deferredLocationIDs,
                    changesByLocation: deferredChanges
                )
            }
        }
    }

    private func mergePendingChange(_ change: DirectoryChange, locationID: String) {
        if let existing = pendingChangesByLocation[locationID] {
            pendingChangesByLocation[locationID] = DirectoryChange(
                changedURLs: existing.changedURLs.union(change.changedURLs),
                requiresFullScan: existing.requiresFullScan || change.requiresFullScan,
                rootChanged: existing.rootChanged || change.rootChanged
            )
        } else {
            pendingChangesByLocation[locationID] = change
        }
    }

    private func stableCandidates(
        from candidates: [(RenameCandidate, URL)]
    ) -> (ready: [(RenameCandidate, URL)], retryURLsByLocation: [String: Set<URL>]) {
        let now = Date()
        var ready: [(RenameCandidate, URL)] = []
        var retryURLsByLocation: [String: Set<URL>] = [:]

        for item in candidates {
            let candidate = item.0
            guard let snapshot = engine.fileStabilitySnapshot(for: candidate.url) else {
                fileObservations.removeValue(forKey: candidate.relativeKey)
                continue
            }
            guard snapshot.cloudDownloadIsCurrent else {
                fileObservations.removeValue(forKey: candidate.relativeKey)
                continue
            }
            if
                let previous = fileObservations[candidate.relativeKey],
                previous.snapshot == snapshot,
                now.timeIntervalSince(previous.observedAt) >= 1.5
            {
                fileObservations.removeValue(forKey: candidate.relativeKey)
                ready.append(item)
            } else {
                fileObservations[candidate.relativeKey] = PendingFileObservation(snapshot: snapshot, observedAt: now)
                retryURLsByLocation[candidate.locationID, default: []].insert(candidate.url)
            }
        }
        return (ready, retryURLsByLocation)
    }

    private func scheduleStabilityRetry(_ retryURLsByLocation: [String: Set<URL>]) {
        guard !retryURLsByLocation.isEmpty else { return }
        for (locationID, urls) in retryURLsByLocation {
            pendingStabilityURLsByLocation[locationID, default: []].formUnion(urls)
        }
        guard stabilityRetryWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stabilityRetryWorkItem = nil
            let pending = self.pendingStabilityURLsByLocation
            self.pendingStabilityURLsByLocation.removeAll()
            let changes = pending.mapValues {
                DirectoryChange(changedURLs: $0, requiresFullScan: false, rootChanged: false)
            }
            let locationIDs = Set(pending.keys)
            guard !locationIDs.isEmpty else { return }
            if self.isScanning {
                for (locationID, change) in changes {
                    self.pendingScanLocationIDs.insert(locationID)
                    self.mergePendingChange(change, locationID: locationID)
                }
            } else {
                self.performScan(
                    reason: "Datei vollständig übertragen",
                    allowWhenStopped: true,
                    locationIDs: locationIDs,
                    changesByLocation: changes
                )
            }
        }
        stabilityRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    @objc private func toggleMonitoring() {
        guard configuration != nil else {
            runFirstLaunchWizard()
            return
        }
        if configuration?.monitoringEnabled == true {
            stopMonitoring()
        } else {
            startMonitoring(runInitialScan: true)
            store.appendLog("Überwachung gestartet.")
        }
    }

    @objc private func restartMonitoring() {
        guard configuration != nil else { runFirstLaunchWizard(); return }
        stopAllMonitors()
        fallbackTimer?.invalidate()
        startMonitoring(runInitialScan: true)
        store.appendLog("Überwachung neu gestartet.")
    }

    @objc private func changeSetup() {
        runConfigurationManager()
    }

    @objc private func openRenameQueue() {
        guard !renameQueueVisible, NSApp.modalWindow == nil else { return }
        renameQueue.removeAll { !fileManager.fileExists(atPath: $0.candidate.url.path) }
        guard let configuration else { runFirstLaunchWizard(); return }
        guard !renameQueue.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Keine Dateien warten"
            alert.informativeText = "Sobald eine neue relevante Datei erkannt wird, erscheint sie hier mit ihrem vollständigen Zielnamen."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        renameQueueVisible = true
        defer { renameQueueVisible = false }
        let controller = RenameQueueController(items: renameQueue, configuration: configuration)
        let decisions = controller.runModal()
        guard !decisions.isEmpty else { return }
        let itemsByID = Dictionary(uniqueKeysWithValues: renameQueue.map { ($0.id, $0) })
        var completedIDs = Set<String>()

        for decision in decisions {
            guard let item = itemsByID[decision.itemID] else { continue }
            switch decision.action {
            case .keep:
                engine.markKept(item.candidate, state: &persistentState)
                completedIDs.insert(item.id)
                store.appendLog("Behalten: \(item.candidate.relativeKey)")
            case .rename:
                do {
                    let title = decision.title ?? engine.suggestedTitle(for: item.candidate.url)
                    let destination = try engine.targetURL(for: item.candidate, title: title, configuration: configuration)
                    try engine.rename(item.candidate, to: destination, rootURL: item.rootURL, state: &persistentState)
                    completedIDs.insert(item.id)
                    store.appendLog("Umbenannt: \(item.candidate.url.lastPathComponent) -> \(destination.lastPathComponent)")
                } catch {
                    persistentState.lastError = "Umbenennen fehlgeschlagen: \(error.localizedDescription)"
                    store.appendLog("UMBENENN-FEHLER: \(error.localizedDescription) | \(item.candidate.url.path)")
                    presentError("Die Datei konnte nicht umbenannt werden.", error)
                }
            }
        }
        renameQueue.removeAll { completedIDs.contains($0.id) }
        try? store.saveState(persistentState)
        refreshStatus()
    }

    @objc private func openFinderTools() {
        statusPanel?.orderOut(nil)
        finderToolsController.show()
    }

    private func handleFinderBridgeURL(_ url: URL) {
        guard url.scheme?.lowercased() == "filelio", url.host?.lowercased() == "finder" else { return }
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var selectedURLs = queryItems
            .filter { $0.name == "path" }
            .compactMap(\.value)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        if let pasteboardName = queryItems.first(where: { $0.name == "pasteboard" })?.value {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
            let pastedURLs = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            selectedURLs.append(contentsOf: pastedURLs.map(\.standardizedFileURL))
            pasteboard.clearContents()
        }
        selectedURLs = Array(Dictionary(grouping: selectedURLs, by: \.path).compactMap(\.value.first))

        switch action {
        case "open":
            openFinderTools()
        case "inspect", "preview":
            guard !selectedURLs.isEmpty else {
                showFinderBridgeMessage("Keine Finder-Auswahl", "Wähle im Finder mindestens eine Datei oder einen Ordner aus.")
                return
            }
            if let message = inspectFinderURLs(selectedURLs, reason: action == "preview" ? "Finder-Namensvorschau" : "Finder-Symbolleiste") {
                showFinderBridgeMessage("Auswahl kann nicht geprüft werden", message)
            }
        case "organize", "monitor":
            let source = selectedURLs.first.map { url -> URL in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    ? url
                    : url.deletingLastPathComponent()
            }
            finderToolsController.showFinderAutomationSetup(sourceURL: source, preferMonitoring: action == "monitor")
        default:
            showFinderBridgeMessage("Unbekannte Finder-Aktion", "Die Finder-Erweiterung und die Haupt-App haben möglicherweise unterschiedliche Versionen. Installiere Filelio erneut.")
        }
    }

    private func showFinderBridgeMessage(_ title: String, _ message: String) {
        guard !testMode else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func inspectFinderURLs(_ urls: [URL], reason: String) -> String? {
        guard let configuration else { return "Filelio ist noch nicht eingerichtet." }
        var changes: [String: DirectoryChange] = [:]
        for location in configuration.locations {
            guard let root = rootURLs[location.id] else { continue }
            let rootPath = root.standardizedFileURL.path
            let matching = Set(urls.filter {
                let path = $0.standardizedFileURL.path
                return path == rootPath || path.hasPrefix(rootPath + "/")
            })
            if !matching.isEmpty {
                changes[location.id] = DirectoryChange(changedURLs: matching, requiresFullScan: false, rootChanged: false)
            }
        }
        guard !changes.isEmpty else { return "Die Auswahl liegt in keiner eingerichteten Struktur." }
        performScan(
            reason: reason,
            allowWhenStopped: true,
            locationIDs: Set(changes.keys),
            changesByLocation: changes
        )
        return nil
    }

    @objc func copyFilePaths(
        _ pasteboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            errorPointer.pointee = "Keine Finder-Dateien empfangen." as NSString
            return
        }
        let copiedPaths = urls.map(\.path).joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(copiedPaths, forType: .string)
        if pasteboard.name != .general {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copiedPaths, forType: .string)
        }
    }

    @objc func inspectFilesInFilelio(
        _ pasteboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let message = inspectFinderURLs(urls, reason: "Finder-Dienst") {
            errorPointer.pointee = message as NSString
        }
    }

    @objc private func showRenameHistory() {
        guard !persistentState.renameHistory.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Der Verlauf ist noch leer"
            alert.informativeText = "Erfolgreiche Umbenennungen werden hier protokolliert und können sicher zurückgenommen werden."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let controller = RenameHistoryController(entries: persistentState.renameHistory)
        guard let entry = controller.runModal(), let rootURL = rootURLs[entry.locationID] else { return }
        do {
            let restored = try engine.undoRename(entry, rootURL: rootURL, state: &persistentState)
            try store.saveState(persistentState)
            store.appendLog("RÜCKGÄNGIG: \(entry.renamedRelativePath) -> \(entry.originalRelativePath)")
            let alert = NSAlert()
            alert.messageText = "Umbenennung rückgängig gemacht"
            alert.informativeText = restored.lastPathComponent
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            presentError("Die Umbenennung konnte nicht rückgängig gemacht werden.", error)
        }
        refreshStatus()
    }

    @objc private func exportConfiguration() {
        guard var export = configuration else { return }
        export.locations = export.locations.map {
            var location = $0
            location.rootBookmark = nil
            return location
        }
        let panel = NSSavePanel()
        panel.title = "Konfiguration exportieren"
        panel.nameFieldStringValue = "Filelio-Konfiguration.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(export).write(to: url, options: .atomic)
            store.appendLog("Konfiguration exportiert: \(url.path)")
        } catch {
            presentError("Die Konfiguration konnte nicht exportiert werden.", error)
        }
    }

    @objc private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Konfiguration importieren"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
            let portableLocations = imported.locations.map {
                var location = $0
                location.rootBookmark = nil
                return location
            }
            guard !portableLocations.isEmpty else { throw RenameEngineError.invalidRoot }
            store.appendLog("Konfiguration importiert: \(url.path)")
            runConfigurationManager(seedLocations: portableLocations)
        } catch {
            presentError("Die Konfiguration konnte nicht importiert werden.", error)
        }
    }

    @objc private func openRootFolder() {
        guard let location = chooseLocation(title: "Stammordner öffnen"), let rootURL = rootURLs[location.id] else {
            if configuration == nil { runFirstLaunchWizard() }
            return
        }
        NSWorkspace.shared.open(rootURL)
    }

    @objc private func openLog() {
        if !fileManager.fileExists(atPath: paths.logURL.path) {
            fileManager.createFile(atPath: paths.logURL.path, contents: Data())
        }
        NSWorkspace.shared.open(paths.logURL)
    }

    @objc private func showInformation() {
        let alert = NSAlert()
        alert.messageText = "Filelio"
        alert.informativeText = "Version \(displayVersion)\nAutor: CreativTechnik\n\nDateiorganisation, automatische Umbenennung und praktische Finder-Werkzeuge für macOS.\n\nBundle-ID: de.creativtechnik.Filelio\nDaten: \(paths.baseURL.path)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func chooseLocation(title: String) -> WatchedLocation? {
        guard let configuration, !configuration.locations.isEmpty else { return nil }
        if configuration.locations.count == 1 { return configuration.locations[0] }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Wähle die gewünschte Ordnerstruktur."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 28))
        for location in configuration.locations {
            popup.addItem(withTitle: "\(URL(fileURLWithPath: location.rootPath).lastPathComponent) — \(location.rootPath)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Öffnen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0 else { return nil }
        return configuration.locations[popup.indexOfSelectedItem]
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func configureAutostart() {
        guard !testMode else { return }
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                    try SMAppService.mainApp.register()
                }
                if SMAppService.mainApp.status != .enabled {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                persistentState.lastError = "Autostart: \(error.localizedDescription)"
                store.appendLog("AUTOSTART-FEHLER: \(error.localizedDescription)")
            }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        defer { finderToolsController.refresh() }
        guard let configuration else {
            overallDot.textColor = .systemOrange
            overallValue.stringValue = "Einrichtung erforderlich"
            rootValue.stringValue = "Noch nicht ausgewählt"
            folderValue.stringValue = "0"
            prefixValue.stringValue = "–"
            filesValue.stringValue = "0 bekannt · 0 behalten · \(renameQueue.count) wartend"
            watcherValue.stringValue = "0 aktiv"
            scanValue.stringValue = "Noch nicht ausgeführt"
            loginValue.stringValue = loginItemDescription()
            errorValue.stringValue = persistentState.lastError ?? "Bitte die Ersteinrichtung starten."
            startStopButton.title = "Überwachung starten"
            autostartButton.title = "Autostart einrichten"
            return
        }

        if isScanning {
            overallDot.textColor = .systemBlue
            overallValue.stringValue = "Dateien werden geprüft …"
        } else if configuration.monitoringEnabled {
            overallDot.textColor = .systemGreen
            overallValue.stringValue = "Überwachung aktiv"
        } else {
            overallDot.textColor = .systemRed
            overallValue.stringValue = "Überwachung gestoppt"
        }

        let activeLocations = configuration.locations.filter { !$0.effectiveOptions.isPaused }
        let rootNames = configuration.locations.map {
            let name = URL(fileURLWithPath: $0.rootPath).lastPathComponent
            return $0.effectiveOptions.isPaused ? "\(name) (pausiert)" : name
        }
        rootValue.stringValue = rootNames.joined(separator: ", ")
        let folderCount = configuration.locations.reduce(0) { $0 + $1.folderPaths.count }
        folderValue.stringValue = "\(folderCount) konfiguriert"
        if let firstLocation = activeLocations.first, let first = firstLocation.folderPaths.first {
            let options = firstLocation.effectiveOptions
            let separator = options.separator ?? configuration.separator
            let prefix = options.customPrefix.isEmpty ? engine.previewPrefix(for: first, separator: separator) : options.customPrefix
            prefixValue.stringValue = prefix + separator + "Dokument" + ((options.includeDate ?? configuration.includeDate) ? separator + todayText() : "")
        } else {
            prefixValue.stringValue = "Alle Unterordner bestimmen den Präfix"
        }
        filesValue.stringValue = "\(persistentState.knownFiles.count) bekannt · \(persistentState.keptFiles.count) behalten · \(renameQueue.count) wartend"
        watcherValue.stringValue = "\(monitors.values.reduce(0) { $0 + $1.eventStreamCount }) aktive Wächter · \(monitors.values.reduce(0) { $0 + $1.watchedDirectoryCount }) überwachte Zweige"
        scanValue.stringValue = formattedLastScan()
        loginValue.stringValue = loginItemDescription()
        errorValue.stringValue = persistentState.lastError ?? "Keine aktuellen Fehler."
        startStopButton.title = configuration.monitoringEnabled ? "Überwachung stoppen" : "Überwachung starten"
        autostartButton.title = loginItemDescription() == "Aktiv" ? "Autostart aktiv" : "Autostart einrichten"
        queueButton.title = renameQueue.isEmpty ? "Warteschlange" : "Warteschlange (\(renameQueue.count))"
        if let button = statusItem.button {
            button.title = renameQueue.isEmpty ? "" : " \(renameQueue.count)"
            button.imagePosition = renameQueue.isEmpty ? .imageOnly : .imageLeading
            button.toolTip = "Filelio – \(overallValue.stringValue) · \(renameQueue.count) wartend"
        }
    }

    private func registerLoginItemIfPossible() {
        guard !testMode else { return }
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                    try SMAppService.mainApp.register()
                }
            } catch {
                store.appendLog("AUTOSTART-HINWEIS: \(error.localizedDescription)")
            }
            store.appendLog("AUTOSTART-STATUS: \(loginItemDescription())")
        }
    }

    private func loginItemDescription() -> String {
        guard !testMode else { return "Testmodus"
        }
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "Aktiv"
            case .requiresApproval: return "Bestätigung in Systemeinstellungen nötig"
            case .notRegistered: return "Nicht registriert"
            case .notFound: return "Registrierung wird erneuert"
            @unknown default: return "Unbekannt"
            }
        }
        return "Nicht unterstützt"
    }

    private func controlCenterStatus() -> ControlCenterStatus {
        guard let configuration else {
            return ControlCenterStatus(
                headline: "Einrichtung erforderlich",
                isMonitoring: false,
                structures: "Noch keine Struktur eingerichtet",
                folders: "0 Ordnerpfade",
                pending: renameQueue.count,
                lastScan: formattedLastScan(),
                error: persistentState.lastError ?? "Bitte zuerst eine Ordnerstruktur einrichten."
            )
        }
        let activeCount = configuration.locations.filter { !$0.effectiveOptions.isPaused }.count
        let folderCount = configuration.locations.reduce(0) { $0 + $1.folderPaths.count }
        let headline = isScanning
            ? "Dateien werden geprüft …"
            : (configuration.monitoringEnabled ? "Überwachung aktiv" : "Überwachung gestoppt")
        return ControlCenterStatus(
            headline: headline,
            isMonitoring: configuration.monitoringEnabled,
            structures: "\(configuration.locations.count) eingerichtet · \(activeCount) aktiv",
            folders: "\(folderCount) konfigurierte Pfade",
            pending: renameQueue.count,
            lastScan: formattedLastScan(),
            error: persistentState.lastError ?? "Keine aktuellen Fehler."
        )
    }

    private func formattedLastScan() -> String {
        guard let date = persistentState.lastScan else { return "Noch nicht ausgeführt" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        if let reason = persistentState.lastScanReason {
            return "\(formatter.string(from: date)) · \(reason)"
        }
        return formatter.string(from: date)
    }

    private func todayText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func sectionCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeButton(_ title: String, action: Selector, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let symbol, let image = adaptiveSymbol(symbol) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func card(views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 11
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        box.contentViewMargins = NSSize(width: 14, height: 12)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView = box.contentView else { return box }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    private func bundledImage(named name: String, extension fileExtension: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
