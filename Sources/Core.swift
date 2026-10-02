import Foundation

struct LocationOptions: Codable, Equatable {
    var isPaused: Bool = false
    var customPrefix: String = ""
    var namingTemplate: String = "{prefix}{separator}{title}{separator}{date}"
    var separator: String?
    var includeDate: Bool?
    var dateFormat: String = "yyyy-MM-dd"
    var excludedFolderNames: [String] = []
    var excludedFilePatterns: [String] = []
    var excludedExtensions: [String] = []
}

struct WatchedLocation: Codable, Equatable, Identifiable {
    var id: String
    var rootBookmark: Data?
    var rootPath: String
    var folderPaths: [String]
    var options: LocationOptions?

    init(
        id: String = UUID().uuidString,
        rootBookmark: Data? = nil,
        rootPath: String,
        folderPaths: [String],
        options: LocationOptions? = nil
    ) {
        self.id = id
        self.rootBookmark = rootBookmark
        self.rootPath = rootPath
        self.folderPaths = folderPaths
        self.options = options
    }

    var effectiveOptions: LocationOptions { options ?? LocationOptions() }
}

struct AppConfiguration: Codable, Equatable {
    var locations: [WatchedLocation]
    var separator: String
    var includeDate: Bool
    var monitoringEnabled: Bool

    init(
        locations: [WatchedLocation],
        separator: String = "_",
        includeDate: Bool = true,
        monitoringEnabled: Bool = true
    ) {
        self.locations = locations
        self.separator = separator
        self.includeDate = includeDate
        self.monitoringEnabled = monitoringEnabled
    }

    init(
        rootBookmark: Data? = nil,
        rootPath: String,
        folderPaths: [String],
        separator: String = "_",
        includeDate: Bool = true,
        monitoringEnabled: Bool = true
    ) {
        self.init(
            locations: [WatchedLocation(id: "primary", rootBookmark: rootBookmark, rootPath: rootPath, folderPaths: folderPaths)],
            separator: separator,
            includeDate: includeDate,
            monitoringEnabled: monitoringEnabled
        )
    }

    private enum CodingKeys: String, CodingKey {
        case locations, separator, includeDate, monitoringEnabled
        case rootBookmark, rootPath, folderPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        separator = try container.decodeIfPresent(String.self, forKey: .separator) ?? "_"
        includeDate = try container.decodeIfPresent(Bool.self, forKey: .includeDate) ?? true
        monitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? true

        if let decodedLocations = try container.decodeIfPresent([WatchedLocation].self, forKey: .locations) {
            locations = decodedLocations
        } else {
            let rootPath = try container.decode(String.self, forKey: .rootPath)
            locations = [WatchedLocation(
                id: "legacy-primary",
                rootBookmark: try container.decodeIfPresent(Data.self, forKey: .rootBookmark),
                rootPath: rootPath,
                folderPaths: try container.decodeIfPresent([String].self, forKey: .folderPaths) ?? []
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(locations, forKey: .locations)
        try container.encode(separator, forKey: .separator)
        try container.encode(includeDate, forKey: .includeDate)
        try container.encode(monitoringEnabled, forKey: .monitoringEnabled)
    }
}

struct RenameHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let locationID: String
    let originalRelativePath: String
    let renamedRelativePath: String
    let renamedAt: Date
    var undoneAt: Date?

    init(
        id: String = UUID().uuidString,
        locationID: String,
        originalRelativePath: String,
        renamedRelativePath: String,
        renamedAt: Date = Date(),
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.locationID = locationID
        self.originalRelativePath = originalRelativePath
        self.renamedRelativePath = renamedRelativePath
        self.renamedAt = renamedAt
        self.undoneAt = undoneAt
    }
}

struct PersistentState: Codable, Equatable {
    var knownFiles: Set<String> = []
    var keptFiles: Set<String> = []
    var lastScan: Date?
    var lastScanReason: String?
    var lastError: String?
    var renameHistory: [RenameHistoryEntry] = []

    private enum CodingKeys: String, CodingKey {
        case knownFiles, keptFiles, lastScan, lastScanReason, lastError, renameHistory
    }

    init(
        knownFiles: Set<String> = [],
        keptFiles: Set<String> = [],
        lastScan: Date? = nil,
        lastScanReason: String? = nil,
        lastError: String? = nil,
        renameHistory: [RenameHistoryEntry] = []
    ) {
        self.knownFiles = knownFiles
        self.keptFiles = keptFiles
        self.lastScan = lastScan
        self.lastScanReason = lastScanReason
        self.lastError = lastError
        self.renameHistory = renameHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        knownFiles = try container.decodeIfPresent(Set<String>.self, forKey: .knownFiles) ?? []
        keptFiles = try container.decodeIfPresent(Set<String>.self, forKey: .keptFiles) ?? []
        lastScan = try container.decodeIfPresent(Date.self, forKey: .lastScan)
        lastScanReason = try container.decodeIfPresent(String.self, forKey: .lastScanReason)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        renameHistory = try container.decodeIfPresent([RenameHistoryEntry].self, forKey: .renameHistory) ?? []
    }
}

struct RenameCandidate: Equatable {
    let url: URL
    let relativeKey: String
    let relativePath: String
    let prefix: String
    let locationID: String
    let separator: String
    let includeDate: Bool
    let dateFormat: String
    let namingTemplate: String
}

struct DirectoryScope: Equatable {
    let recursivePaths: [String]
    let shallowPaths: [String]
}

struct FileStabilitySnapshot: Equatable {
    let size: Int64
    let modificationDate: Date
    let cloudDownloadIsCurrent: Bool
}

enum RenameEngineError: LocalizedError {
    case invalidRoot
    case invalidFolderPath(String)
    case fileOutsideRoot
    case emptyPrefix
    case emptyTitle
    case structureTooLarge(Int)
    case overlappingRoots(String, String)
    case invalidHistoryEntry

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "Der ausgewählte Stammordner ist nicht verfügbar."
        case .invalidFolderPath(let path):
            return "Der Unterordnerpfad ist ungültig: \(path)"
        case .fileOutsideRoot:
            return "Die Datei liegt nicht innerhalb des Stammordners."
        case .emptyPrefix:
            return "Für Dateien direkt im Stammordner kann kein Präfix gebildet werden."
        case .emptyTitle:
            return "Der Dokumenttitel darf nicht leer sein."
        case .structureTooLarge(let maximum):
            return "Die Ordnerstruktur enthält mehr als \(maximum) Verzeichnisse. Wähle einen kleineren Stammordner."
        case .overlappingRoots(let first, let second):
            return "Die Stammordner „\(first)“ und „\(second)“ liegen ineinander. Wähle voneinander unabhängige Stammordner, damit Dateien nicht doppelt verarbeitet werden."
        case .invalidHistoryEntry:
            return "Die Umbenennung kann nicht rückgängig gemacht werden, weil eine beteiligte Datei fehlt oder der ursprüngliche Name bereits vergeben ist."
        }
    }
}

struct AppPaths {
    let baseURL: URL
    let configurationURL: URL
    let stateURL: URL
    let logURL: URL

    init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        let resolvedBase: URL
        if let baseURL {
            resolvedBase = baseURL
        } else if let override = ProcessInfo.processInfo.environment["FILELIO_DATA_DIR"], !override.isEmpty {
            resolvedBase = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            resolvedBase = applicationSupport.appendingPathComponent("Filelio", isDirectory: true)
        }

        self.baseURL = resolvedBase
        self.configurationURL = resolvedBase.appendingPathComponent("configuration.json")
        self.stateURL = resolvedBase.appendingPathComponent("state.json")
        self.logURL = resolvedBase.appendingPathComponent("Filelio.log")
    }

    func ensureDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
}

final class JSONStore {
    private let paths: AppPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadConfiguration() throws -> AppConfiguration? {
        guard fileManager.fileExists(atPath: paths.configurationURL.path) else { return nil }
        return try decoder.decode(AppConfiguration.self, from: Data(contentsOf: paths.configurationURL))
    }

    func saveConfiguration(_ configuration: AppConfiguration) throws {
        try paths.ensureDirectories(fileManager: fileManager)
        try encoder.encode(configuration).write(to: paths.configurationURL, options: .atomic)
    }

    func loadState() throws -> PersistentState {
        guard fileManager.fileExists(atPath: paths.stateURL.path) else { return PersistentState() }
        return try decoder.decode(PersistentState.self, from: Data(contentsOf: paths.stateURL))
    }

    func saveState(_ state: PersistentState) throws {
        try paths.ensureDirectories(fileManager: fileManager)
        try encoder.encode(state).write(to: paths.stateURL, options: .atomic)
    }

    func appendLog(_ message: String) {
        do {
            try paths.ensureDirectories(fileManager: fileManager)
            rotateLogIfNeeded()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            let data = Data(line.utf8)
            if fileManager.fileExists(atPath: paths.logURL.path), let handle = try? FileHandle(forWritingTo: paths.logURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: paths.logURL, options: .atomic)
            }
        } catch {
            // Logging must never stop file processing.
        }
    }

    private func rotateLogIfNeeded() {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: paths.logURL.path),
            let size = attributes[.size] as? NSNumber,
            size.intValue > 1_048_576
        else { return }

        let rotated = paths.logURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: rotated)
        try? fileManager.moveItem(at: paths.logURL, to: rotated)
    }
}

final class RenameEngine {
    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func normalizeFolderPaths(_ rawPaths: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for rawPath in rawPaths {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
                throw RenameEngineError.invalidFolderPath(rawPath)
            }

            let components = trimmed
                .split(separator: "/", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else {
                throw RenameEngineError.invalidFolderPath(rawPath)
            }

            let normalized = components.joined(separator: "/")
            if seen.insert(normalized).inserted { result.append(normalized) }
        }

        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func createConfiguredFolders(rootURL: URL, folderPaths: [String]) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RenameEngineError.invalidRoot
        }

        for folderPath in try normalizeFolderPaths(folderPaths) {
            let destination = rootURL.appendingPathComponent(folderPath, isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
    }

    func validateIndependentRoots(_ locations: [WatchedLocation]) throws {
        let roots = locations.map { location in
            (location, URL(fileURLWithPath: location.rootPath, isDirectory: true).standardizedFileURL)
        }
        for firstIndex in roots.indices {
            for secondIndex in roots.indices where secondIndex > firstIndex {
                let first = roots[firstIndex]
                let second = roots[secondIndex]
                if isSameOrDescendant(second.1, of: first.1) || isSameOrDescendant(first.1, of: second.1) {
                    throw RenameEngineError.overlappingRoots(
                        first.1.lastPathComponent,
                        second.1.lastPathComponent
                    )
                }
            }
        }
    }

    /// Liest eine vorhandene Struktur ohne Dateiinhalte zu öffnen. Zurückgegeben
    /// werden nur Endpfade; ihre Zwischenebenen ergeben sich automatisch.
    func discoverExistingFolderPaths(rootURL: URL, maximumDirectories: Int = 5_000) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RenameEngineError.invalidRoot
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var directoryPaths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isPackage == true || values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true, let relative = relativePath(for: url, rootURL: rootURL), !relative.isEmpty else {
                continue
            }
            directoryPaths.append(relative)
            if directoryPaths.count > maximumDirectories {
                throw RenameEngineError.structureTooLarge(maximumDirectories)
            }
        }

        return directoryPaths.filter { candidate in
            !directoryPaths.contains { possibleChild in
                candidate != possibleChild && possibleChild.hasPrefix(candidate + "/")
            }
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func registerExistingFiles(rootURL: URL, configuration: AppConfiguration, state: inout PersistentState) throws {
        guard let location = configuration.locations.first else { return }
        try registerExistingFiles(rootURL: rootURL, location: location, state: &state)
    }

    func registerExistingFiles(rootURL: URL, location: WatchedLocation, state: inout PersistentState) throws {
        for fileURL in try relevantFiles(rootURL: rootURL, location: location) {
            if let relativePath = relativeKey(for: fileURL, rootURL: rootURL) {
                state.knownFiles.insert(stateKey(locationID: location.id, relativePath: relativePath))
            }
        }
        state.lastScan = Date()
        state.lastScanReason = "Initialbestand registriert"
    }

    func candidates(rootURL: URL, configuration: AppConfiguration, state: inout PersistentState) throws -> [RenameCandidate] {
        guard let location = configuration.locations.first else { return [] }
        return try candidates(rootURL: rootURL, location: location, configuration: configuration, state: &state)
    }

    func candidates(rootURL: URL, location: WatchedLocation, configuration: AppConfiguration, state: inout PersistentState) throws -> [RenameCandidate] {
        try candidates(
            rootURL: rootURL,
            location: location,
            configuration: configuration,
            state: &state,
            changedURLs: nil
        )
    }

    func candidates(
        rootURL: URL,
        location: WatchedLocation,
        configuration: AppConfiguration,
        state: inout PersistentState,
        changedURLs: Set<URL>?
    ) throws -> [RenameCandidate] {
        guard !location.effectiveOptions.isPaused else { return [] }
        var candidates: [RenameCandidate] = []
        let options = location.effectiveOptions
        let separator = normalizedSeparator(options.separator ?? configuration.separator)
        let includeDate = options.includeDate ?? configuration.includeDate

        for fileURL in try relevantFiles(
            rootURL: rootURL,
            location: location,
            changedURLs: changedURLs
        ) {
            guard let relativePath = relativeKey(for: fileURL, rootURL: rootURL) else { continue }
            let key = stateKey(locationID: location.id, relativePath: relativePath)
            let parentRelative = relativeParentPath(for: fileURL, rootURL: rootURL)
            let automaticPrefix = prefixForRelativeFolder(parentRelative, separator: separator)
            let configuredPrefix = sanitizePrefixComponent(options.customPrefix, separator: separator)
            let prefix = configuredPrefix.isEmpty ? automaticPrefix : configuredPrefix
            guard !prefix.isEmpty else { continue }

            if options.namingTemplate.hasPrefix("{prefix}") && fileURL.lastPathComponent.hasPrefix(prefix + separator) {
                state.knownFiles.insert(key)
                continue
            }

            if isPersistentlyKnown(key: key, legacyRelativePath: relativePath, location: location, state: state) { continue }
            candidates.append(RenameCandidate(
                url: fileURL,
                relativeKey: key,
                relativePath: relativePath,
                prefix: prefix,
                locationID: location.id,
                separator: separator,
                includeDate: includeDate,
                dateFormat: validatedDateFormat(options.dateFormat),
                namingTemplate: options.namingTemplate.isEmpty
                    ? "{prefix}{separator}{title}{separator}{date}"
                    : options.namingTemplate
            ))
        }

        candidates.sort { $0.relativeKey.localizedStandardCompare($1.relativeKey) == .orderedAscending }
        return candidates
    }

    func fileStabilitySnapshot(for fileURL: URL) -> FileStabilitySnapshot? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard
            let values = try? fileURL.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            let size = values.fileSize,
            let modificationDate = values.contentModificationDate
        else { return nil }

        let cloudDownloadIsCurrent = values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
        return FileStabilitySnapshot(
            size: Int64(size),
            modificationDate: modificationDate,
            cloudDownloadIsCurrent: cloudDownloadIsCurrent
        )
    }

    func markKept(_ candidate: RenameCandidate, state: inout PersistentState) {
        state.knownFiles.insert(candidate.relativeKey)
        state.keptFiles.insert(candidate.relativeKey)
    }

    func markKnown(_ url: URL, rootURL: URL, locationID: String, state: inout PersistentState) {
        if let relativePath = relativeKey(for: url, rootURL: rootURL) {
            state.knownFiles.insert(stateKey(locationID: locationID, relativePath: relativePath))
        }
    }

    func suggestedTitle(for fileURL: URL) -> String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    func targetURL(
        for candidate: RenameCandidate,
        title rawTitle: String,
        configuration: AppConfiguration,
        date: Date = Date()
    ) throws -> URL {
        var title = sanitizeTitle(rawTitle, separator: candidate.separator)
        guard !title.isEmpty else { throw RenameEngineError.emptyTitle }

        let dateText: String
        if candidate.includeDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = candidate.dateFormat
            dateText = formatter.string(from: date)
        } else {
            dateText = ""
        }

        let fileExtension = candidate.url.pathExtension
        let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let fixedParts = [candidate.prefix, dateText].filter { !$0.isEmpty }
        let fixedName = fixedParts.joined(separator: candidate.separator)
        let reservedBytes = filesystemUTF8Count(fixedName) + filesystemUTF8Count(extensionSuffix) + filesystemUTF8Count(candidate.separator)
        title = truncateToUTF8Bytes(title, maximumBytes: max(1, 240 - reservedBytes))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RenameEngineError.emptyTitle }

        var baseName = candidate.namingTemplate
            .replacingOccurrences(of: "{prefix}", with: candidate.prefix)
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{date}", with: dateText)
            .replacingOccurrences(of: "{separator}", with: candidate.separator)
        baseName = sanitizeGeneratedBaseName(baseName, separator: candidate.separator)
        baseName = truncateToUTF8Bytes(baseName, maximumBytes: max(1, 240 - filesystemUTF8Count(extensionSuffix)))
        guard !baseName.isEmpty else { throw RenameEngineError.emptyTitle }
        let parent = candidate.url.deletingLastPathComponent()
        var destination = parent.appendingPathComponent(baseName + extensionSuffix)
        var counter = 2

        while fileManager.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent(baseName + candidate.separator + String(counter) + extensionSuffix)
            counter += 1
        }
        return destination
    }

    @discardableResult
    func rename(_ candidate: RenameCandidate, to destination: URL, rootURL: URL, state: inout PersistentState) throws -> URL {
        let originalRelativePath = candidate.relativePath
        try fileManager.moveItem(at: candidate.url, to: destination)
        state.knownFiles.remove(candidate.relativeKey)
        markKnown(destination, rootURL: rootURL, locationID: candidate.locationID, state: &state)
        if let renamedRelativePath = relativeKey(for: destination, rootURL: rootURL) {
            state.renameHistory.append(RenameHistoryEntry(
                locationID: candidate.locationID,
                originalRelativePath: originalRelativePath,
                renamedRelativePath: renamedRelativePath
            ))
            if state.renameHistory.count > 500 {
                state.renameHistory.removeFirst(state.renameHistory.count - 500)
            }
        }
        return destination
    }

    @discardableResult
    func undoRename(_ entry: RenameHistoryEntry, rootURL: URL, state: inout PersistentState) throws -> URL {
        guard entry.undoneAt == nil else { throw RenameEngineError.invalidHistoryEntry }
        let source = rootURL.appendingPathComponent(entry.renamedRelativePath)
        let destination = rootURL.appendingPathComponent(entry.originalRelativePath)
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else {
            throw RenameEngineError.invalidHistoryEntry
        }
        try fileManager.moveItem(at: source, to: destination)
        if let index = state.renameHistory.firstIndex(where: { $0.id == entry.id }) {
            state.renameHistory[index].undoneAt = Date()
        }
        state.knownFiles.remove(stateKey(locationID: entry.locationID, relativePath: entry.renamedRelativePath))
        state.knownFiles.insert(stateKey(locationID: entry.locationID, relativePath: entry.originalRelativePath))
        return destination
    }

    func previewPrefix(for folderPath: String, separator: String = "_") -> String {
        prefixForRelativeFolder(folderPath, separator: separator)
    }

    /// Endordner werden rekursiv verarbeitet. Ihre übergeordneten, im Pfad
    /// enthaltenen Ordner werden nur direkt geprüft. So reagieren Zwischenebenen,
    /// ohne dass fremde Seitenzweige unnötig gescannt werden.
    func directoryScope(folderPaths: [String]) throws -> DirectoryScope {
        let normalizedPaths = try normalizeFolderPaths(folderPaths)
        let recursivePaths = minimalConfiguredPaths(normalizedPaths)
        var shallowPaths = Set<String>()

        for path in recursivePaths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for componentCount in 1..<components.count {
                shallowPaths.insert(components.prefix(componentCount).joined(separator: "/"))
            }
        }

        return DirectoryScope(
            recursivePaths: recursivePaths,
            shallowPaths: shallowPaths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    func shouldIgnoreFileName(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        if fileName.hasPrefix(".") || fileName.hasPrefix("~$") || fileName.hasSuffix("~") { return true }
        let ignoredSuffixes = [
            ".tmp", ".part", ".partial", ".download", ".crdownload",
            ".opdownload", ".icloud", ".sync", ".syncthing"
        ]
        return ignoredSuffixes.contains(where: { lowercased.hasSuffix($0) })
    }

    func relativeKey(for fileURL: URL, rootURL: URL) -> String? {
        relativePath(for: fileURL, rootURL: rootURL)
    }

    private func relevantFiles(
        rootURL: URL,
        location: WatchedLocation,
        changedURLs: Set<URL>? = nil
    ) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RenameEngineError.invalidRoot
        }

        let scope = try directoryScope(folderPaths: location.folderPaths)
        if let changedURLs {
            return targetedRelevantFiles(rootURL: rootURL, location: location, scope: scope, changedURLs: changedURLs)
        }
        var files: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .nameKey]

        for shallowPath in scope.shallowPaths {
            let directory = rootURL.appendingPathComponent(shallowPath, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in children {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isPackage != true else { continue }
                guard !shouldIgnoreFileName(url.lastPathComponent) else { continue }
                guard !isExcluded(url, rootURL: rootURL, location: location) else { continue }
                files.append(url)
            }
        }

        for configuredPath in scope.recursivePaths {
            let scanRoot = rootURL.appendingPathComponent(configuredPath, isDirectory: true)
            var scanRootIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: scanRoot.path, isDirectory: &scanRootIsDirectory), scanRootIsDirectory.boolValue else {
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if isExcluded(url, rootURL: rootURL, location: location) { enumerator.skipDescendants() }
                    continue
                }
                if values?.isPackage == true { continue }
                guard values?.isRegularFile == true else { continue }
                guard !shouldIgnoreFileName(url.lastPathComponent) else { continue }
                guard !isExcluded(url, rootURL: rootURL, location: location) else { continue }
                files.append(url)
            }
        }
        return files
    }

    private func targetedRelevantFiles(
        rootURL: URL,
        location: WatchedLocation,
        scope: DirectoryScope,
        changedURLs: Set<URL>
    ) -> [URL] {
        let recursiveRoots = scope.recursivePaths.map { rootURL.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
        let shallowRoots = scope.shallowPaths.map { rootURL.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
        var result = Set<URL>()

        func addFileIfRelevant(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard !shouldIgnoreFileName(standardized.lastPathComponent) else { return }
            guard !isExcluded(standardized, rootURL: rootURL, location: location) else { return }
            guard let values = try? standardized.resourceValues(forKeys: keys), values.isRegularFile == true, values.isPackage != true else { return }
            let inRecursiveScope = recursiveRoots.contains { isSameOrDescendant(standardized, of: $0) }
            let inShallowScope = shallowRoots.contains { standardized.deletingLastPathComponent() == $0 }
            if inRecursiveScope || inShallowScope { result.insert(standardized) }
        }

        for changedURL in changedURLs {
            let url = changedURL.standardizedFileURL
            guard isSameOrDescendant(url, of: rootURL.standardizedFileURL) else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                addFileIfRelevant(url)
                continue
            }
            guard values?.isDirectory == true, values?.isPackage != true else { continue }
            guard !isExcluded(url, rootURL: rootURL, location: location) else { continue }

            if shallowRoots.contains(url) {
                let children = (try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )) ?? []
                children.forEach(addFileIfRelevant)
            }

            guard recursiveRoots.contains(where: { isSameOrDescendant(url, of: $0) }) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let child as URL in enumerator { addFileIfRelevant(child) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func stateKey(locationID: String, relativePath: String) -> String {
        locationID + "::" + relativePath
    }

    private func isPersistentlyKnown(
        key: String,
        legacyRelativePath: String,
        location: WatchedLocation,
        state: PersistentState
    ) -> Bool {
        if state.knownFiles.contains(key) || state.keptFiles.contains(key) { return true }
        guard location.id == "legacy-primary" || location.id == "primary" else { return false }
        return state.knownFiles.contains(legacyRelativePath) || state.keptFiles.contains(legacyRelativePath)
    }

    private func minimalConfiguredPaths(_ folderPaths: [String]) -> [String] {
        folderPaths.filter { candidate in
            !folderPaths.contains { possibleParent in
                candidate != possibleParent && candidate.hasPrefix(possibleParent + "/")
            }
        }
    }

    private func relativeParentPath(for fileURL: URL, rootURL: URL) -> String {
        relativePath(for: fileURL.deletingLastPathComponent(), rootURL: rootURL) ?? ""
    }

    private func relativePath(for url: URL, rootURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.count >= rootComponents.count else { return nil }
        guard Array(targetComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func isSameOrDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= parentComponents.count &&
            Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
    }

    private func truncateToUTF8Bytes(_ value: String, maximumBytes: Int) -> String {
        guard filesystemUTF8Count(value) > maximumBytes else { return value }
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = filesystemUTF8Count(String(character))
            guard byteCount + characterBytes <= maximumBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private func filesystemUTF8Count(_ value: String) -> Int {
        value.decomposedStringWithCanonicalMapping.utf8.count
    }

    private func normalizedSeparator(_ rawSeparator: String) -> String {
        var separator = rawSeparator.trimmingCharacters(in: .whitespacesAndNewlines)
        separator = separator.replacingOccurrences(of: "/", with: "-")
        separator = separator.replacingOccurrences(of: ":", with: "-")
        if separator.isEmpty { return "_" }
        return String(separator.prefix(3))
    }

    private func validatedDateFormat(_ rawFormat: String) -> String {
        let trimmed = rawFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "yyyy-MM-dd" }
        let allowed = CharacterSet(charactersIn: "yYMdDEeHhmsSaZzXx-_. /:")
        return trimmed.unicodeScalars.allSatisfy(allowed.contains) ? String(trimmed.prefix(40)) : "yyyy-MM-dd"
    }

    private func sanitizeGeneratedBaseName(_ rawName: String, separator: String) -> String {
        var value = rawName.precomposedStringWithCanonicalMapping
        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\n", with: " ")
        value = value.replacingOccurrences(of: "\r", with: " ")
        while value.contains(separator + separator) {
            value = value.replacingOccurrences(of: separator + separator, with: separator)
        }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: separator))
        return value.trimmingCharacters(in: trimSet)
    }

    private func isExcluded(_ url: URL, rootURL: URL, location: WatchedLocation) -> Bool {
        let options = location.effectiveOptions
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let excludedFolders = Set(options.excludedFolderNames.map { $0.lowercased() })
        if !excludedFolders.isEmpty, let relative = relativePath(for: url, rootURL: rootURL) {
            var components = relative.split(separator: "/").map { String($0).lowercased() }
            if !isDirectory, !components.isEmpty { components.removeLast() }
            if components.contains(where: excludedFolders.contains) { return true }
        }

        guard !isDirectory else { return false }
        let fileExtension = url.pathExtension.lowercased()
        let excludedExtensions = Set(options.excludedExtensions.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        })
        if !fileExtension.isEmpty, excludedExtensions.contains(fileExtension) { return true }
        return options.excludedFilePatterns.contains { wildcardMatch(url.lastPathComponent, pattern: $0) }
    }

    private func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var regexPattern = NSRegularExpression.escapedPattern(for: trimmed)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = regexPattern.replacingOccurrences(of: "\\?", with: ".")
        guard let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$", options: [.caseInsensitive]) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    private func prefixForRelativeFolder(_ relativeFolder: String, separator: String) -> String {
        relativeFolder
            .split(separator: "/")
            .map { sanitizePrefixComponent(String($0), separator: separator) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    private func sanitizePrefixComponent(_ component: String, separator: String) -> String {
        var value = component.precomposedStringWithCanonicalMapping
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: "\n", with: " ")
        value = value.replacingOccurrences(of: "\r", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains(separator + separator) {
            value = value.replacingOccurrences(of: separator + separator, with: separator)
        }
        return value
    }

    private func sanitizeTitle(_ title: String, separator: String) -> String {
        var value = title.precomposedStringWithCanonicalMapping
        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\n", with: " ")
        value = value.replacingOccurrences(of: "\r", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains(separator + separator) {
            value = value.replacingOccurrences(of: separator + separator, with: separator)
        }
        return value
    }
}
