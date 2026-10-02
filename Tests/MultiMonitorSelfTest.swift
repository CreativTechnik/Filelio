import Foundation

private enum MultiMonitorFailure: LocalizedError {
    case unexpectedCounts(Int, Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedCounts(let first, let second):
            return "Änderung in Struktur A erzeugte A=\(first), B=\(second) Rückrufe."
        }
    }
}

@main
struct MultiMonitorSelfTest {
    static func main() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("Filelio-MultiMonitor-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let firstRoot = base.appendingPathComponent("Struktur-A/Privat/Auto", isDirectory: true)
        let secondRoot = base.appendingPathComponent("Struktur-B/Privat/Auto", isDirectory: true)
        try fileManager.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondRoot, withIntermediateDirectories: true)

        var firstCallbacks = 0
        var secondCallbacks = 0
		let firstMonitor = DirectoryMonitor { _ in firstCallbacks += 1 }
		let secondMonitor = DirectoryMonitor { _ in secondCallbacks += 1 }
        firstMonitor.start(rootURL: firstRoot)
        secondMonitor.start(rootURL: secondRoot)

        // Frisch erzeugte APFS-Verzeichnisse können noch ein verzögertes
        // FSEvents-Startsignal liefern. Gemessen wird der stabile Betrieb danach.
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        firstCallbacks = 0
        secondCallbacks = 0
        try Data("only A changed".utf8).write(to: firstRoot.appendingPathComponent("Beleg.pdf"))
        let timeout = Date().addingTimeInterval(5)
        while firstCallbacks == 0 && RunLoop.main.run(mode: .default, before: timeout) && Date() < timeout {}

        firstMonitor.stop()
        secondMonitor.stop()
        guard firstCallbacks == 1, secondCallbacks == 0 else {
            throw MultiMonitorFailure.unexpectedCounts(firstCallbacks, secondCallbacks)
        }
        print("MULTI_MONITOR_PASS changedRootCallbacks=1 unchangedRootCallbacks=0 sandbox=\(base.path)")
    }
}
