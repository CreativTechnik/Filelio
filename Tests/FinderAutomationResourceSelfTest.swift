import AppKit
import Foundation

private enum FinderAutomationResourceFailure: LocalizedError {
    case assertion(String)

    var errorDescription: String? {
        if case .assertion(let message) = self { return message }
        return nil
    }
}

@main
@MainActor
struct FinderAutomationResourceSelfTest {
    static func main() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("Filelio-FinderAutomationScale-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let oneTimeSource = base.appendingPathComponent("Einmalig", isDirectory: true)
        try fileManager.createDirectory(at: oneTimeSource, withIntermediateDirectories: true)

        let oneTimeCount = 1_500
        for index in 0..<oneTimeCount {
            try Data("Datei \(index)".utf8).write(
                to: oneTimeSource.appendingPathComponent(String(format: "Dokument-%04d.txt", index))
            )
        }

        let engine = FinderToolkitEngine(fileManager: fileManager)
        let plans = try engine.automationPlan(kind: .downloads, source: oneTimeSource)
        try expect(plans.count == oneTimeCount, "Einmaliger Plan enthält \(plans.count) statt \(oneTimeCount) Dateien.")
        let movedOnce = try engine.execute(plans)
        try expect(movedOnce.count == oneTimeCount, "Einmalige Sortierung hat nicht alle Dateien verarbeitet.")
        try expect(
            !fileManager.fileExists(atPath: base.appendingPathComponent("finder-tools.json").path),
            "Die einmalige Sortierung hat fälschlich eine dauerhafte Konfiguration angelegt."
        )

        let watchedSource = base.appendingPathComponent("Überwacht", isDirectory: true)
        try fileManager.createDirectory(at: watchedSource, withIntermediateDirectories: true)
        let coordinator = FinderAutomationCoordinator(baseURL: base) { _ in }
        try coordinator.configure(kind: .downloads, source: watchedSource)
        try coordinator.configure(kind: .screenshots, source: watchedSource)
        try expect(coordinator.activeJobCount == 2, "Es sollten zwei Automationen aktiv sein.")
        try expect(
            coordinator.activeMonitorCount == 1,
            "Automationen desselben Quellordners verwenden \(coordinator.activeMonitorCount) statt eines gemeinsamen Wächters."
        )

        // Den FSEvents-Strom anlaufen lassen, dann viele Dateien in zwei Wellen
        // erzeugen. Die Verarbeitung muss alle Dateien erreichen, ohne pro Datei
        // einen eigenen Wächter oder parallelen Ordnerscan zu starten.
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        let watchedCount = 600
        for index in 0..<watchedCount {
            try Data("Ereignis \(index)".utf8).write(
                to: watchedSource.appendingPathComponent(String(format: "Neu-%04d.txt", index))
            )
            if index == watchedCount / 2 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }
        }

        let destination = watchedSource.appendingPathComponent("Dokumente", isDirectory: true)
        let deadline = Date().addingTimeInterval(12)
        var sortedCount = 0
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            sortedCount = (try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).count) ?? 0
        } while sortedCount < watchedCount && Date() < deadline

        try expect(sortedCount == watchedCount, "Unter Last wurden nur \(sortedCount) von \(watchedCount) Dateien sortiert.")
        try expect(coordinator.activeMonitorCount == 1, "Unter Last wurden zusätzliche Wächter erzeugt.")
        coordinator.stop()
        try expect(coordinator.activeMonitorCount == 0, "Der Dateiwächter wurde nicht vollständig beendet.")

        print(
            "FINDER_AUTOMATION_RESOURCE_PASS oneTime=\(oneTimeCount) watched=\(watchedCount) " +
            "sharedStreams=1 persistedOneTime=false sandbox=\(base.path)"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FinderAutomationResourceFailure.assertion(message) }
    }
}
