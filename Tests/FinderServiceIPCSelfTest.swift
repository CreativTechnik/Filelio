import AppKit
import Foundation

private enum FinderServiceIPCFailure: LocalizedError {
    case assertion(String)

    var errorDescription: String? {
        if case .assertion(let message) = self { return message }
        return nil
    }
}

@main
struct FinderServiceIPCSelfTest {
    static func main() throws {
        _ = NSApplication.shared
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Filelio-FinderService-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let selectedFile = base.appendingPathComponent("Ausgewählte Datei.txt")
        try Data("Finder IPC".utf8).write(to: selectedFile)

        let pasteboard = NSPasteboard.withUniqueName()
        guard pasteboard.writeObjects([selectedFile as NSURL]) else {
            throw FinderServiceIPCFailure.assertion("Die Testdatei konnte nicht auf das Dienste-Pasteboard geschrieben werden.")
        }
        guard NSPerformService("Dateipfade kopieren", pasteboard) else {
            throw FinderServiceIPCFailure.assertion("macOS hat den registrierten Dienst nicht angenommen.")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard NSPasteboard.general.string(forType: .string) == selectedFile.path else {
            throw FinderServiceIPCFailure.assertion("Der Pfad wurde nicht in die allgemeine Zwischenablage kopiert.")
        }
        print("FINDER_SERVICE_IPC_PASS registered=true invoked=true clipboard=true")
    }
}
