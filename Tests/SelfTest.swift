import Foundation

enum SelfTestFailure: LocalizedError {
    case assertion(String)

    var errorDescription: String? {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@main
struct FilelioSelfTest {
    static func main() throws {
        let fileManager = FileManager.default
        let runURL = fileManager.temporaryDirectory
            .appendingPathComponent("Filelio-Core-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fileManager.removeItem(at: runURL) }
        let rootURL = runURL.appendingPathComponent("WatchedFolder", isDirectory: true)
        let dataURL = runURL.appendingPathComponent("AppData", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let engine = RenameEngine(fileManager: fileManager)
        let folderPaths = try engine.normalizeFolderPaths([
            "Mathematik/Q1",
            "Mathematik/Q2",
            "Sprachen/Englisch/Modul A",
            "Mathematik/Q1"
        ])
        try expect(folderPaths.count == 3, "Doppelte Ordnerpfade wurden nicht entfernt.")

        let configuration = AppConfiguration(rootPath: rootURL.path, folderPaths: folderPaths)
        let primaryLocation = configuration.locations[0]
        try engine.createConfiguredFolders(rootURL: rootURL, folderPaths: primaryLocation.folderPaths)

        let scope = try engine.directoryScope(folderPaths: primaryLocation.folderPaths)
        try expect(scope.recursivePaths == folderPaths, "Die rekursiven Endordner wurden falsch berechnet.")
        try expect(
            scope.shallowPaths == ["Mathematik", "Sprachen", "Sprachen/Englisch"],
            "Die überwachten Zwischenordner wurden falsch berechnet: \(scope.shallowPaths)"
        )

        let q1 = rootURL.appendingPathComponent("Mathematik/Q1", isDirectory: true)
        let q2 = rootURL.appendingPathComponent("Mathematik/Q2", isDirectory: true)
        let english = rootURL.appendingPathComponent("Sprachen/Englisch/Modul A", isDirectory: true)
        try Data("baseline".utf8).write(to: q1.appendingPathComponent("Altbestand.pdf"))
        try Data("already named".utf8).write(to: q1.appendingPathComponent("Mathematik_Q1_Fertig_2026-08-23.pdf"))
        try Data("temporary".utf8).write(to: q1.appendingPathComponent("OneDrive.part"))
        try Data("root file".utf8).write(to: rootURL.appendingPathComponent("NichtRelevant.pdf"))

        var state = PersistentState()
        try engine.registerExistingFiles(rootURL: rootURL, configuration: configuration, state: &state)
        try expect(state.knownFiles.count == 2, "Der Initialbestand wurde nicht korrekt begrenzt.")

        let newQ1File = q1.appendingPathComponent("Arbeitsblatt.pdf")
        let parentFile = rootURL.appendingPathComponent("Mathematik/Übersicht.pdf")
        try Data("new".utf8).write(to: newQ1File)
        try Data("parent".utf8).write(to: parentFile)
        try Data("temporary".utf8).write(to: q1.appendingPathComponent("Upload.download"))

        var candidates = try engine.candidates(rootURL: rootURL, configuration: configuration, state: &state)
        try expect(candidates.count == 2, "Erwartet wurden Dateien aus End- und Zwischenordner, gefunden: \(candidates.count).")
        let targetedCandidates = try engine.candidates(
            rootURL: rootURL,
            location: primaryLocation,
            configuration: configuration,
            state: &state,
            changedURLs: Set([newQ1File])
        )
        try expect(
            targetedCandidates.count == 1 && sameFile(targetedCandidates[0].url, newQ1File),
            "Die pfadgenaue Ereignisprüfung hat weitere Ordner gescannt."
        )
        try expect(engine.fileStabilitySnapshot(for: newQ1File) != nil, "Der Dateizustand konnte nicht geprüft werden.")
        guard let parentCandidate = candidates.first(where: { sameFile($0.url, parentFile) }) else {
            throw SelfTestFailure.assertion("Die Datei im Zwischenordner Mathematik wurde nicht erkannt.")
        }
        try expect(parentCandidate.prefix == "Mathematik", "Der Zwischenordner-Präfix ist falsch: \(parentCandidate.prefix)")

        let parentTarget = try engine.targetURL(
            for: parentCandidate,
            title: "Übersicht",
            configuration: configuration,
            date: ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")!
        )
        try expect(parentTarget.lastPathComponent == "Mathematik_Übersicht_2026-08-23.pdf", "Der Zielname im Zwischenordner ist falsch.")
        try engine.rename(parentCandidate, to: parentTarget, rootURL: rootURL, state: &state)

        guard let firstCandidate = candidates.first(where: { sameFile($0.url, newQ1File) }) else {
            throw SelfTestFailure.assertion("Die Datei im Endordner Mathematik/Q1 wurde nicht erkannt.")
        }
        try expect(firstCandidate.prefix == "Mathematik_Q1", "Der dynamische Präfix ist falsch: \(firstCandidate.prefix)")

        let fixedDate = ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")!
        let target = try engine.targetURL(
            for: firstCandidate,
            title: "Arbeitsblatt",
            configuration: configuration,
            date: fixedDate
        )
        try expect(target.lastPathComponent == "Mathematik_Q1_Arbeitsblatt_2026-08-23.pdf", "Der Zielname ist falsch: \(target.lastPathComponent)")
        let unicodeTarget = try engine.targetURL(
            for: firstCandidate,
            title: String(repeating: "📚ä", count: 100),
            configuration: configuration,
            date: fixedDate
        )
        try expect(
            unicodeTarget.lastPathComponent.utf8.count <= 255,
            "Ein Unicode-Dateiname überschreitet mit \(unicodeTarget.lastPathComponent.utf8.count) Bytes das macOS-Limit: \(unicodeTarget.lastPathComponent)"
        )
        try engine.rename(firstCandidate, to: target, rootURL: rootURL, state: &state)

        candidates = try engine.candidates(rootURL: rootURL, configuration: configuration, state: &state)
        try expect(candidates.isEmpty, "Eine umbenannte Datei wurde erneut angeboten.")

        let sameNameOtherFolder = q2.appendingPathComponent("Arbeitsblatt.pdf")
        try Data("different file".utf8).write(to: sameNameOtherFolder)
        candidates = try engine.candidates(rootURL: rootURL, configuration: configuration, state: &state)
        try expect(candidates.count == 1 && candidates[0].prefix == "Mathematik_Q2", "Gleichnamige Dateien in anderen Ordnern wurden verwechselt.")
        engine.markKept(candidates[0], state: &state)

        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: sameNameOtherFolder.path)
        candidates = try engine.candidates(rootURL: rootURL, configuration: configuration, state: &state)
        try expect(candidates.isEmpty, "Eine reine Metadatenänderung führte zu einer erneuten Nachfrage.")

        let nestedFile = english.appendingPathComponent("Lesson.txt")
        try Data("lesson".utf8).write(to: nestedFile)
        candidates = try engine.candidates(rootURL: rootURL, configuration: configuration, state: &state)
        try expect(candidates.count == 1, "Die frei konfigurierbare dritte Ordnerebene wurde nicht erkannt.")
        try expect(candidates[0].prefix == "Sprachen_Englisch_Modul A", "Der mehrstufige Präfix ist falsch: \(candidates[0].prefix)")
        try expect(
            engine.previewPrefix(for: "ESK - 26 27/GK - 12") == "ESK - 26 27_GK - 12",
            "Leerzeichen in Ordnernamen wurden unerwartet durch Bindestriche ersetzt."
        )

        let rulesRoot = runURL.appendingPathComponent("Rules", isDirectory: true)
        let rulesInbox = rulesRoot.appendingPathComponent("Inbox", isDirectory: true)
        try fileManager.createDirectory(at: rulesInbox.appendingPathComponent("Archiv", isDirectory: true), withIntermediateDirectories: true)
        try Data("rename".utf8).write(to: rulesInbox.appendingPathComponent("Mein Dokument.pdf"))
        try Data("excluded".utf8).write(to: rulesInbox.appendingPathComponent("Entwurf 1.docx"))
        try Data("excluded".utf8).write(to: rulesInbox.appendingPathComponent("Sicherung.bak"))
        try Data("excluded".utf8).write(to: rulesInbox.appendingPathComponent("Archiv/Alt.pdf"))
        var ruleOptions = LocationOptions()
        ruleOptions.customPrefix = "Eigener Präfix"
        ruleOptions.namingTemplate = "{prefix}{separator}{title}"
        ruleOptions.separator = "__"
        ruleOptions.includeDate = false
        ruleOptions.excludedFolderNames = ["Archiv"]
        ruleOptions.excludedFilePatterns = ["Entwurf*"]
        ruleOptions.excludedExtensions = ["bak"]
        let rulesLocation = WatchedLocation(id: "rules", rootPath: rulesRoot.path, folderPaths: ["Inbox"], options: ruleOptions)
        let rulesConfiguration = AppConfiguration(locations: [rulesLocation])
        var rulesState = PersistentState()
        let ruleCandidates = try engine.candidates(rootURL: rulesRoot, location: rulesLocation, configuration: rulesConfiguration, state: &rulesState)
        try expect(ruleCandidates.count == 1, "Eigene Ausschlussregeln wurden nicht korrekt angewendet.")
        let ruleTarget = try engine.targetURL(for: ruleCandidates[0], title: "Mein Dokument", configuration: rulesConfiguration, date: fixedDate)
        try expect(ruleTarget.lastPathComponent == "Eigener Präfix__Mein Dokument.pdf", "Das eigene Namensschema ist falsch: \(ruleTarget.lastPathComponent)")
        try engine.rename(ruleCandidates[0], to: ruleTarget, rootURL: rulesRoot, state: &rulesState)
        try expect(rulesState.renameHistory.count == 1, "Die Umbenennung wurde nicht im Verlauf gespeichert.")
        try engine.undoRename(rulesState.renameHistory[0], rootURL: rulesRoot, state: &rulesState)
        try expect(fileManager.fileExists(atPath: rulesInbox.appendingPathComponent("Mein Dokument.pdf").path), "Rückgängig hat den Originalnamen nicht wiederhergestellt.")
        try expect(rulesState.renameHistory[0].undoneAt != nil, "Der Verlauf markiert Rückgängig nicht.")
        var pausedOptions = ruleOptions
        pausedOptions.isPaused = true
        let pausedLocation = WatchedLocation(id: "paused", rootPath: rulesRoot.path, folderPaths: ["Inbox"], options: pausedOptions)
        var pausedState = PersistentState()
        let pausedCandidates = try engine.candidates(rootURL: rulesRoot, location: pausedLocation, configuration: AppConfiguration(locations: [pausedLocation]), state: &pausedState)
        try expect(pausedCandidates.isEmpty, "Eine pausierte Struktur liefert weiterhin Kandidaten.")

        let collisionTarget = try engine.targetURL(for: candidates[0], title: "Lesson", configuration: configuration, date: fixedDate)
        try Data("collision".utf8).write(to: collisionTarget)
        let uniqueTarget = try engine.targetURL(for: candidates[0], title: "Lesson", configuration: configuration, date: fixedDate)
        try expect(uniqueTarget.deletingPathExtension().lastPathComponent.hasSuffix("_2"), "Namenskollisionen werden nicht nummeriert.")

        let overlappingConfiguration = AppConfiguration(
            rootPath: rootURL.path,
            folderPaths: ["Mathematik", "Mathematik/Q1"]
        )
        var overlappingState = PersistentState()
        try engine.registerExistingFiles(rootURL: rootURL, configuration: overlappingConfiguration, state: &overlappingState)
        try Data("overlap".utf8).write(to: q1.appendingPathComponent("NurEinmal.docx"))
        let overlappingCandidates = try engine.candidates(
            rootURL: rootURL,
            configuration: overlappingConfiguration,
            state: &overlappingState
        )
        try expect(overlappingCandidates.count == 1, "Überlappende konfigurierte Ordner erzeugten doppelte Rückfragen.")

        let secondRootURL = runURL.appendingPathComponent("SecondWatchedFolder", isDirectory: true)
        try fileManager.createDirectory(at: secondRootURL, withIntermediateDirectories: true)
        let sharedPaths = ["Privat/Auto/Kfz", "Privat/Auto/Versicherung"]
        let firstMultiLocation = WatchedLocation(id: "location-a", rootPath: rootURL.path, folderPaths: sharedPaths)
        let secondMultiLocation = WatchedLocation(id: "location-b", rootPath: secondRootURL.path, folderPaths: sharedPaths)
        let multiConfiguration = AppConfiguration(locations: [firstMultiLocation, secondMultiLocation])
        try engine.validateIndependentRoots(multiConfiguration.locations)
        do {
            try engine.validateIndependentRoots([
                firstMultiLocation,
                WatchedLocation(rootPath: rootURL.appendingPathComponent("Privat").path, folderPaths: ["Auto"])
            ])
            throw SelfTestFailure.assertion("Verschachtelte Stammordner wurden nicht abgewiesen.")
        } catch RenameEngineError.overlappingRoots {
            // Erwartet: verhindert doppelte Dateidialoge.
        }
        try engine.createConfiguredFolders(rootURL: rootURL, folderPaths: sharedPaths)
        try engine.createConfiguredFolders(rootURL: secondRootURL, folderPaths: sharedPaths)
        var multiState = PersistentState()
        try engine.registerExistingFiles(rootURL: rootURL, location: firstMultiLocation, state: &multiState)
        try engine.registerExistingFiles(rootURL: secondRootURL, location: secondMultiLocation, state: &multiState)

        let firstSharedFile = rootURL.appendingPathComponent("Privat/Auto/Beleg.pdf")
        let secondSharedFile = secondRootURL.appendingPathComponent("Privat/Auto/Beleg.pdf")
        try Data("first root".utf8).write(to: firstSharedFile)
        try Data("second root".utf8).write(to: secondSharedFile)
        var firstRootCandidates = try engine.candidates(
            rootURL: rootURL,
            location: firstMultiLocation,
            configuration: multiConfiguration,
            state: &multiState
        )
        var secondRootCandidates = try engine.candidates(
            rootURL: secondRootURL,
            location: secondMultiLocation,
            configuration: multiConfiguration,
            state: &multiState
        )
        try expect(firstRootCandidates.count == 1 && secondRootCandidates.count == 1, "Mehrere Stammordner wurden nicht unabhängig erkannt.")
        try expect(firstRootCandidates[0].prefix == "Privat_Auto", "Der Präfix im ersten Stammordner ist falsch.")
        try expect(secondRootCandidates[0].prefix == "Privat_Auto", "Der Präfix im zweiten Stammordner ist falsch.")
        engine.markKept(firstRootCandidates[0], state: &multiState)
        firstRootCandidates = try engine.candidates(rootURL: rootURL, location: firstMultiLocation, configuration: multiConfiguration, state: &multiState)
        secondRootCandidates = try engine.candidates(rootURL: secondRootURL, location: secondMultiLocation, configuration: multiConfiguration, state: &multiState)
        try expect(firstRootCandidates.isEmpty, "Die Behalten-Entscheidung im ersten Stammordner wurde nicht gespeichert.")
        try expect(secondRootCandidates.count == 1, "Eine Entscheidung aus dem ersten Stammordner wurde fälschlich auf den zweiten übertragen.")

        let legacyJSON = Data("""
        {"rootPath":"/tmp/legacy","folderPaths":["Alt/Ordner"],"separator":"_","includeDate":true,"monitoringEnabled":true}
        """.utf8)
        let migratedConfiguration = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON)
        try expect(migratedConfiguration.locations.count == 1, "Die 1.1-Konfiguration wurde nicht migriert.")
        try expect(migratedConfiguration.locations[0].id == "legacy-primary", "Die Migration verwendet keine stabile Legacy-Kennung.")

        let existingStructureRoot = runURL.appendingPathComponent("ExistingStructure", isDirectory: true)
        try fileManager.createDirectory(at: existingStructureRoot.appendingPathComponent("Privat/Auto/Kfz", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: existingStructureRoot.appendingPathComponent("Privat/Auto/Versicherung", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: existingStructureRoot.appendingPathComponent("Arbeit/Projekte", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: existingStructureRoot.appendingPathComponent(".Versteckt/NichtImportieren", isDirectory: true), withIntermediateDirectories: true)
        let importedFolderPaths = try engine.discoverExistingFolderPaths(rootURL: existingStructureRoot)
        try expect(
            importedFolderPaths == ["Arbeit/Projekte", "Privat/Auto/Kfz", "Privat/Auto/Versicherung"],
            "Die bestehende Ordnerstruktur wurde falsch importiert: \(importedFolderPaths)"
        )

        state.lastScan = Date()
        state.lastScanReason = "Sandbox-Selbsttest"
        let paths = AppPaths(baseURL: dataURL, fileManager: fileManager)
        let store = JSONStore(paths: paths, fileManager: fileManager)
        try store.saveConfiguration(multiConfiguration)
        try store.saveState(state)
		let loadedConfiguration = try store.loadConfiguration()
		let loadedState = try store.loadState()
		try expect(loadedConfiguration == multiConfiguration, "Die Mehrfach-Konfiguration konnte nicht verlustfrei geladen werden.")
		try expect(loadedState.knownFiles == state.knownFiles, "Bekannte Dateien wurden nicht verlustfrei geladen.")
		try expect(loadedState.keptFiles == state.keptFiles, "Behaltene Dateien wurden nicht verlustfrei geladen.")
		try expect(loadedState.lastScanReason == state.lastScanReason, "Der Scanstatus wurde nicht verlustfrei geladen.")
		let legacyState = try JSONDecoder().decode(PersistentState.self, from: Data("{\"knownFiles\":[],\"keptFiles\":[]}".utf8))
		try expect(legacyState.renameHistory.isEmpty, "Ein älterer Status ohne Verlauf konnte nicht migriert werden.")

        let report: [String: Any] = [
            "result": "PASS",
            "sandbox": runURL.path,
            "configuredFolderPaths": primaryLocation.folderPaths,
            "dynamicPrefixes": ["Mathematik_Q1", "Mathematik_Q2", "Sprachen_Englisch_Modul A"],
            "watchedRoots": multiConfiguration.locations.count,
            "importedExistingPaths": importedFolderPaths,
            "knownFiles": state.knownFiles.count,
            "keptFiles": state.keptFiles.count
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try reportData.write(to: runURL.appendingPathComponent("self-test-report.json"), options: .atomic)
        print(String(decoding: reportData, as: UTF8.self))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SelfTestFailure.assertion(message) }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
