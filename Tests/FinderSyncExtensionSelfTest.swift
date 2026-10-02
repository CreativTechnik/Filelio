import AppKit
import FinderSync
import Foundation

@main
enum FinderSyncExtensionSelfTest {
    static func main() {
        let finderExtension = FinderSyncExtension()
        let menu = finderExtension.menu(for: .toolbarItemMenu)
        let actionItems = menu.items.filter { !$0.isSeparatorItem }
        let titles = actionItems.map(\.title)
        let expected = [
            "Filelio öffnen",
            "Auswahl zur Umbenennung prüfen",
            "Neue Dateinamen vorschauen",
            "Diesen Ordner einmalig organisieren …",
            "Diesen Ordner dauerhaft überwachen …"
        ]
        let toolbarIcon = finderExtension.toolbarItemImage
        guard finderExtension.toolbarItemName == "Filelio",
              toolbarIcon.size.width > 0,
              toolbarIcon.isTemplate,
              actionItems.allSatisfy({ $0.image?.isTemplate == true }),
              titles == expected else {
            fputs("FINDER_SYNC_EXTENSION_SELF_TEST_FAIL titles=\(titles)\n", stderr)
            exit(1)
        }
        print("FINDER_SYNC_EXTENSION_SELF_TEST_PASS toolbar=true adaptiveIcons=true actions=\(titles.count)")
    }
}
