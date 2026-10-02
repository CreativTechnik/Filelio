import AppKit
import FinderSync
import Foundation

@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
    private enum Command: String {
        case open
        case inspect
        case preview
        case organize
        case monitor
    }

    override init() {
        super.init()

        // Finder Sync verlangt mindestens einen Zuständigkeitsbereich, damit die
        // Schaltfläche angezeigt wird. Die Erweiterung liest oder überwacht hier
        // keine Dateien; alle echte Arbeit bleibt in der Haupt-App.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var directories = Set([home])
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        directories.insert(volumes)
        FIFinderSyncController.default().directoryURLs = directories
    }

    override var toolbarItemName: String { "Filelio" }

    override var toolbarItemToolTip: String {
        "Auswahl prüfen, Namen vorschauen oder den aktuellen Ordner organisieren"
    }

    override var toolbarItemImage: NSImage {
        if let iconURL = Bundle(for: FinderSyncExtension.self).url(forResource: "MenuBarIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            let ratio = icon.size.width / max(icon.size.height, 1)
            icon.size = NSSize(width: 18 * ratio, height: 18)
            icon.isTemplate = true
            icon.accessibilityDescription = "Filelio"
            return icon
        }
        let fallback = adaptiveSymbol("tray.full.fill", description: "Filelio")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "Filelio")
        addItem("Filelio öffnen", symbol: "rectangle.grid.1x2", action: #selector(openApplication), to: menu)
        menu.addItem(.separator())
        addItem("Auswahl zur Umbenennung prüfen", symbol: "checkmark.circle", action: #selector(inspectSelection), to: menu)
        addItem("Neue Dateinamen vorschauen", symbol: "eye", action: #selector(previewSelection), to: menu)
        menu.addItem(.separator())
        addItem("Diesen Ordner einmalig organisieren …", symbol: "folder.badge.gearshape", action: #selector(organizeFolder), to: menu)
        addItem("Diesen Ordner dauerhaft überwachen …", symbol: "bolt.badge.clock", action: #selector(monitorFolder), to: menu)
        return menu
    }

    @objc private func openApplication() { send(.open, urls: []) }
    @objc private func inspectSelection() { send(.inspect, urls: selectionOrTarget()) }
    @objc private func previewSelection() { send(.preview, urls: selectionOrTarget()) }
    @objc private func organizeFolder() { send(.organize, urls: currentFolder().map { [$0] } ?? []) }
    @objc private func monitorFolder() { send(.monitor, urls: currentFolder().map { [$0] } ?? []) }

    private func addItem(_ title: String, symbol: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = adaptiveSymbol(symbol)
        menu.addItem(item)
    }

    private func adaptiveSymbol(_ name: String, description: String? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    private func selectionOrTarget() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty { return selected }
        return controller.targetedURL().map { [$0] } ?? []
    }

    private func currentFolder() -> URL? {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), selected.count == 1, let first = selected.first {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return first
            }
        }
        return controller.targetedURL()
    }

    private func send(_ command: Command, urls: [URL]) {
        var components = URLComponents()
        components.scheme = "filelio"
        components.host = "finder"
        components.path = "/\(command.rawValue)"
        if !urls.isEmpty {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("de.creativtechnik.Filelio.finder.\(UUID().uuidString)"))
            pasteboard.clearContents()
            if pasteboard.writeObjects(urls.prefix(1_000).map { $0 as NSURL }) {
                components.queryItems = [URLQueryItem(name: "pasteboard", value: pasteboard.name.rawValue)]
            } else {
                components.queryItems = urls.prefix(20).map { URLQueryItem(name: "path", value: $0.path) }
            }
        }
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
