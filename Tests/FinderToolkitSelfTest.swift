import AppKit
import Foundation
import PDFKit

private enum FinderToolkitTestFailure: LocalizedError {
    case assertion(String)
    var errorDescription: String? {
        if case .assertion(let message) = self { return message }
        return nil
    }
}

@main
struct FinderToolkitSelfTest {
    static func main() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("Filelio-FinderTools-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let downloads = base.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: downloads.appendingPathComponent("Bericht.pdf"))
        try Data("image".utf8).write(to: downloads.appendingPathComponent("Foto.jpg"))
        try Data("code".utf8).write(to: downloads.appendingPathComponent("app.swift"))
        try Data("incomplete".utf8).write(to: downloads.appendingPathComponent("Transfer.part"))

        let engine = FinderToolkitEngine(fileManager: fileManager)
        let downloadPlans = engine.downloadsPlan(in: downloads)
        try expect(downloadPlans.count == 3, "Download-Sortierung hat falsche Treffer: \(downloadPlans.count)")
        let moved = try engine.execute(downloadPlans)
        try expect(moved.count == 3, "Nicht alle Download-Pläne wurden ausgeführt.")
        try expect(fileManager.fileExists(atPath: downloads.appendingPathComponent("PDF/Bericht.pdf").path), "PDF-Kategorie fehlt.")
        try expect(fileManager.fileExists(atPath: downloads.appendingPathComponent("Transfer.part").path), "Unvollständige Datei wurde verschoben.")

        try Data("new".utf8).write(to: downloads.appendingPathComponent("Bericht.pdf"))
        let collision = try engine.execute(engine.downloadsPlan(in: downloads))
        try expect(collision.first?.lastPathComponent == "Bericht 2.pdf", "Kollision wurde nicht sicher nummeriert.")

        let desktop = base.appendingPathComponent("Desktop", isDirectory: true)
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data("shot".utf8).write(to: desktop.appendingPathComponent("Bildschirmfoto 2026-08-23.png"))
        try Data("normal".utf8).write(to: desktop.appendingPathComponent("Notiz.txt"))
        try expect(engine.screenshotPlan(in: desktop).count == 1, "Screenshot-Erkennung ist falsch.")
        try expect(engine.desktopPlan(in: desktop).count == 2, "Schreibtisch-Plan ist falsch.")

        let ruleSource = base.appendingPathComponent("RuleSource", isDirectory: true)
        let ruleTarget = base.appendingPathComponent("RuleTarget", isDirectory: true)
        try fileManager.createDirectory(at: ruleSource, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ruleTarget, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: ruleSource.appendingPathComponent("A.foo"))
        try Data("b".utf8).write(to: ruleSource.appendingPathComponent("B.txt"))
        let rulePlans = try engine.customMovePlan(in: ruleSource, target: ruleTarget, extensions: ["foo"])
        try expect(rulePlans.count == 1 && rulePlans[0].source.lastPathComponent == "A.foo", "Dateityp-Regel ist falsch.")

        let analysis = base.appendingPathComponent("Analysis", isDirectory: true)
        try fileManager.createDirectory(at: analysis, withIntermediateDirectories: true)
        let duplicateData = Data(repeating: 42, count: 1_200_000)
        try duplicateData.write(to: analysis.appendingPathComponent("Kopie A.bin"))
        try duplicateData.write(to: analysis.appendingPathComponent("Kopie B.bin"))
        try Data(repeating: 7, count: 1_300_000).write(to: analysis.appendingPathComponent("Einzigartig.bin"))
        let large = try engine.largeFiles(in: analysis, minimumBytes: 1_000_000)
        try expect(large.count == 3, "Große-Dateien-Suche ist falsch.")
        let duplicates = try engine.duplicateGroups(in: analysis)
        try expect(duplicates.count == 1 && duplicates[0].urls.count == 2, "SHA-256-Duplikatsuche ist falsch.")

        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 80)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { throw FinderToolkitTestFailure.assertion("Testbild nicht erzeugt.") }
        let imageSource = base.appendingPathComponent("Source.tiff")
        try tiff.write(to: imageSource)
        let converted = try engine.convertImages([imageSource], outputDirectory: base.appendingPathComponent("Images"), maximumWidth: 60, format: .png)
        try expect(converted.count == 1 && fileManager.fileExists(atPath: converted[0].path), "Bildkonvertierung ist fehlgeschlagen.")

        let firstPDF = PDFDocument()
        let secondPDF = PDFDocument()
        guard let page = PDFPage(image: image), let page2 = PDFPage(image: image) else { throw FinderToolkitTestFailure.assertion("PDF-Testseite nicht erzeugt.") }
        firstPDF.insert(page, at: 0)
        secondPDF.insert(page2, at: 0)
        let firstURL = base.appendingPathComponent("A.pdf")
        let secondURL = base.appendingPathComponent("B.pdf")
        try expect(firstPDF.write(to: firstURL) && secondPDF.write(to: secondURL), "PDF-Testdateien nicht geschrieben.")
        let mergedURL = base.appendingPathComponent("Merged.pdf")
        try engine.mergePDFs([firstURL, secondURL], to: mergedURL)
        try expect(PDFDocument(url: mergedURL)?.pageCount == 2, "PDF-Zusammenführung enthält nicht zwei Seiten.")

        let store = FinderToolkitStore(baseURL: base)
        let job = FinderAutomationJob(kind: .downloads, sourceURL: downloads, sourceBookmark: nil)
        try store.save(FinderToolkitSettings(jobs: [job]))
        try expect(store.load().jobs == [job], "Finder-Automatik-Konfiguration wurde nicht verlustfrei gespeichert.")

        print("FINDER_TOOLKIT_SELF_TEST_PASS downloads=3 duplicates=1 large=3 pdfPages=2 imageCopies=1 sandbox=\(base.path)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FinderToolkitTestFailure.assertion(message) }
    }
}
