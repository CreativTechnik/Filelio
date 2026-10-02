import AppKit
import CryptoKit
import Foundation
import PDFKit

enum FinderAutomationKind: String, Codable, CaseIterable, Sendable {
    case downloads
    case screenshots
    case desktop
    case customMove

    var title: String {
        switch self {
        case .downloads: return "Downloads sortieren"
        case .screenshots: return "Screenshots organisieren"
        case .desktop: return "Schreibtisch aufräumen"
        case .customMove: return "Regelbasiert verschieben"
        }
    }
}

struct FinderAutomationJob: Codable, Identifiable, Equatable {
    var id: String
    var kind: FinderAutomationKind
    var sourcePath: String
    var sourceBookmark: Data?
    var targetPath: String?
    var targetBookmark: Data?
    var extensions: [String]
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        kind: FinderAutomationKind,
        sourceURL: URL,
        sourceBookmark: Data?,
        targetURL: URL? = nil,
        targetBookmark: Data? = nil,
        extensions: [String] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.sourcePath = sourceURL.path
        self.sourceBookmark = sourceBookmark
        self.targetPath = targetURL?.path
        self.targetBookmark = targetBookmark
        self.extensions = extensions
        self.enabled = enabled
    }
}

struct FinderToolkitSettings: Codable, Equatable {
    var jobs: [FinderAutomationJob] = []
}

struct FileMovePlan: Identifiable, Equatable, Sendable {
    let id: String
    let source: URL
    let destination: URL
    let reason: String

    init(source: URL, destination: URL, reason: String) {
        self.id = source.standardizedFileURL.path
        self.source = source
        self.destination = destination
        self.reason = reason
    }
}

struct LargeFileFinding: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let size: Int64

    init(url: URL, size: Int64) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.size = size
    }
}

struct DuplicateFileGroup: Identifiable, Equatable, Sendable {
    let id: String
    let size: Int64
    let urls: [URL]
}

enum FinderToolkitError: LocalizedError {
    case noFiles
    case invalidRule
    case invalidImage
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .noFiles: return "Es wurden keine passenden Dateien gefunden."
        case .invalidRule: return "Die Regel benötigt mindestens eine Dateiendung und einen Zielordner."
        case .invalidImage: return "Mindestens ein Bild konnte nicht gelesen oder konvertiert werden."
        case .pdfCreationFailed: return "Die PDF-Datei konnte nicht erstellt werden."
        }
    }
}

final class FinderToolkitStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL) {
        url = baseURL.appendingPathComponent("finder-tools.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> FinderToolkitSettings {
        guard let data = try? Data(contentsOf: url) else { return FinderToolkitSettings() }
        return (try? decoder.decode(FinderToolkitSettings.self, from: data)) ?? FinderToolkitSettings()
    }

    func save(_ settings: FinderToolkitSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

final class FinderToolkitEngine: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func automationPlan(
        kind: FinderAutomationKind,
        source: URL,
        target: URL? = nil,
        extensions: [String] = []
    ) throws -> [FileMovePlan] {
        switch kind {
        case .downloads:
            return downloadsPlan(in: source)
        case .screenshots:
            return screenshotPlan(in: source)
        case .desktop:
            return desktopPlan(in: source)
        case .customMove:
            guard let target else { throw FinderToolkitError.invalidRule }
            return try customMovePlan(in: source, target: target, extensions: extensions)
        }
    }

    func downloadsPlan(in source: URL) -> [FileMovePlan] {
        immediateFiles(in: source).compactMap { file in
            guard let category = downloadCategory(for: file) else { return nil }
            return FileMovePlan(
                source: file,
                destination: source.appendingPathComponent(category, isDirectory: true).appendingPathComponent(file.lastPathComponent),
                reason: category
            )
        }
    }

    func screenshotPlan(in source: URL) -> [FileMovePlan] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return immediateFiles(in: source).compactMap { file in
            let lower = file.deletingPathExtension().lastPathComponent.lowercased()
            guard lower.contains("screenshot") || lower.contains("bildschirmfoto") || lower.contains("bildschirmaufnahme") else { return nil }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let month = formatter.string(from: values?.contentModificationDate ?? Date())
            let destination = source
                .appendingPathComponent("Screenshots", isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
                .appendingPathComponent(file.lastPathComponent)
            return FileMovePlan(source: file, destination: destination, reason: "Screenshots / \(month)")
        }
    }

    func desktopPlan(in source: URL) -> [FileMovePlan] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return immediateFiles(in: source).map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let month = formatter.string(from: values?.contentModificationDate ?? Date())
            let category = downloadCategory(for: file) ?? "Sonstiges"
            let destination = source
                .appendingPathComponent("Schreibtisch-Archiv", isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
                .appendingPathComponent(category, isDirectory: true)
                .appendingPathComponent(file.lastPathComponent)
            return FileMovePlan(source: file, destination: destination, reason: "Archiv / \(month) / \(category)")
        }
    }

    func customMovePlan(in source: URL, target: URL, extensions: [String]) throws -> [FileMovePlan] {
        let normalized = Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty })
        guard !normalized.isEmpty else { throw FinderToolkitError.invalidRule }
        return immediateFiles(in: source).compactMap { file in
            guard normalized.contains(file.pathExtension.lowercased()) else { return nil }
            return FileMovePlan(source: file, destination: target.appendingPathComponent(file.lastPathComponent), reason: "Regel: .\(file.pathExtension.lowercased())")
        }
    }

    @discardableResult
    func execute(_ plans: [FileMovePlan]) throws -> [URL] {
        var moved: [URL] = []
        for plan in plans where fileManager.fileExists(atPath: plan.source.path) {
            try autoreleasepool {
                try fileManager.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let destination = availableURL(for: plan.destination)
                try fileManager.moveItem(at: plan.source, to: destination)
                moved.append(destination)
            }
        }
        return moved
    }

    func largeFiles(in root: URL, minimumBytes: Int64) throws -> [LargeFileFinding] {
        try recursiveFiles(in: root).compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            return size >= minimumBytes ? LargeFileFinding(url: url, size: size) : nil
        }.sorted { $0.size > $1.size }
    }

    func duplicateGroups(in root: URL) throws -> [DuplicateFileGroup] {
        var bySize: [Int64: [URL]] = [:]
        for url in try recursiveFiles(in: root) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            if size > 0 { bySize[size, default: []].append(url) }
        }
        var groups: [DuplicateFileGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for url in urls {
                if let digest = sha256(url) { byHash[digest, default: []].append(url) }
            }
            for (digest, matches) in byHash where matches.count > 1 {
                groups.append(DuplicateFileGroup(id: digest, size: size, urls: matches.sorted { $0.path < $1.path }))
            }
        }
        return groups.sorted { ($0.size * Int64($0.urls.count - 1)) > ($1.size * Int64($1.urls.count - 1)) }
    }

    func externalVolumes() -> [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeNameKey]
        return (fileManager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            return values?.volumeIsEjectable == true || (values?.volumeIsRemovable == true && values?.volumeIsInternal != true)
        }
    }

    func mergePDFs(_ inputs: [URL], to destination: URL) throws {
        guard !inputs.isEmpty else { throw FinderToolkitError.noFiles }
        let output = PDFDocument()
        var index = 0
        for url in inputs {
            guard let document = PDFDocument(url: url) else { continue }
            for pageIndex in 0..<document.pageCount {
                if let page = document.page(at: pageIndex) {
                    output.insert(page, at: index)
                    index += 1
                }
            }
        }
        guard index > 0, output.write(to: destination) else { throw FinderToolkitError.pdfCreationFailed }
    }

    func convertImages(_ inputs: [URL], outputDirectory: URL, maximumWidth: CGFloat, format: NSBitmapImageRep.FileType) throws -> [URL] {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for input in inputs {
            guard let image = NSImage(contentsOf: input) else { continue }
            let original = image.size
            let scale = maximumWidth > 0 && original.width > maximumWidth ? maximumWidth / original.width : 1
            let size = NSSize(width: max(1, floor(original.width * scale)), height: max(1, floor(original.height * scale)))
            let rendered = NSImage(size: size)
            rendered.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
            rendered.unlockFocus()
            guard let tiff = rendered.tiffRepresentation, let representation = NSBitmapImageRep(data: tiff) else { continue }
            let ext = format == .png ? "png" : "jpg"
            let proposed = outputDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
            let destination = availableURL(for: proposed)
            let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg ? [.compressionFactor: 0.84] : [:]
            guard let data = representation.representation(using: format, properties: properties) else { continue }
            try data.write(to: destination, options: .atomic)
            outputs.append(destination)
        }
        guard !outputs.isEmpty else { throw FinderToolkitError.invalidImage }
        return outputs
    }

    private func immediateFiles(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isPackageKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        return (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]))?.filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            let cloudIsReady = values?.isUbiquitousItem != true || values?.ubiquitousItemDownloadingStatus == .current
            return values?.isRegularFile == true && values?.isPackage != true && cloudIsReady && !isIncomplete(url)
        } ?? []
    }

    private func recursiveFiles(in root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isRegularFile == true && values?.isPackage != true && !isIncomplete(url) { files.append(url) }
        }
        return files
    }

    private func downloadCategory(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ["pdf"].contains(ext) { return "PDF" }
        if ["doc", "docx", "odt", "pages", "rtf", "txt", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key"].contains(ext) { return "Dokumente" }
        if ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "svg"].contains(ext) { return "Bilder" }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) { return "Videos" }
        if ["mp3", "m4a", "wav", "aac", "flac"].contains(ext) { return "Audio" }
        if ["zip", "rar", "7z", "tar", "gz", "dmg", "pkg"].contains(ext) { return "Archive & Installer" }
        if ["swift", "js", "ts", "py", "html", "css", "json", "xml", "md"].contains(ext) { return "Code" }
        return ext.isEmpty ? nil : "Sonstiges"
    }

    private func isIncomplete(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".download", ".part", ".partial", ".crdownload", ".opdownload", ".icloud", ".tmp", ".sync", ".syncthing"].contains { name.hasSuffix($0) }
    }

    private func availableURL(for proposed: URL) -> URL {
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let parent = proposed.deletingLastPathComponent()
        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        var counter = 2
        while true {
            let suffix = " \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = parent.appendingPathComponent(base + suffix)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func sha256(_ url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1_048_576)
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class FinderAutomationCoordinator {
    private let store: FinderToolkitStore
    private let log: (String) -> Void
    private var monitors: [String: DirectoryMonitor] = [:]
    private var scopedURLs: [URL] = []
    private var resolvedSources: [String: URL] = [:]
    private var resolvedTargets: [String: URL] = [:]
    private var processingJobIDs = Set<String>()
    private var pendingJobIDs = Set<String>()
    private var monitorGeneration = 0
    private let processingQueue = DispatchQueue(
        label: "de.creativtechnik.Filelio.finder-automation",
        qos: .utility
    )
    private(set) var settings: FinderToolkitSettings

    var activeMonitorCount: Int { monitors.count }
    var activeJobCount: Int { settings.jobs.filter(\.enabled).count }

    init(baseURL: URL, log: @escaping (String) -> Void) {
        store = FinderToolkitStore(baseURL: baseURL)
        settings = store.load()
        self.log = log
    }

    func start() { rebuildMonitors() }

    func stop() {
        monitorGeneration += 1
        monitors.values.forEach { $0.stop() }
        monitors.removeAll()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        resolvedSources.removeAll()
        resolvedTargets.removeAll()
        processingJobIDs.removeAll()
        pendingJobIDs.removeAll()
    }

    func jobs(for kind: FinderAutomationKind) -> [FinderAutomationJob] {
        settings.jobs.filter { $0.kind == kind }
    }

    func configure(kind: FinderAutomationKind, source: URL, target: URL? = nil, extensions: [String] = []) throws {
        let sourceBookmark = try? source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let targetBookmark = try? target?.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        settings.jobs.removeAll { $0.kind == kind }
        let configuredJob = FinderAutomationJob(
            kind: kind,
            sourceURL: source,
            sourceBookmark: sourceBookmark,
            targetURL: target,
            targetBookmark: targetBookmark,
            extensions: extensions
        )
        settings.jobs.append(configuredJob)
        try store.save(settings)
        rebuildMonitors()
        // Nur die gerade eingerichtete Regel verarbeitet den Anfangsbestand.
        // Andere Ordner werden beim Hinzufügen einer Automatik nicht erneut gescannt.
        process(configuredJob)
    }

    func disable(kind: FinderAutomationKind) throws {
        for index in settings.jobs.indices where settings.jobs[index].kind == kind { settings.jobs[index].enabled = false }
        try store.save(settings)
        rebuildMonitors()
    }

    func processNow(kind: FinderAutomationKind) {
        for job in jobs(for: kind).filter(\.enabled) { process(job) }
    }

    private func rebuildMonitors() {
        stop()
        let enabledJobs = settings.jobs.filter(\.enabled)
        var jobsBySourcePath: [String: [FinderAutomationJob]] = [:]
        var sourceCache: [String: URL] = [:]
        var targetCache: [String: URL] = [:]

        for job in enabledJobs {
            let source: URL
            if let cached = sourceCache[job.sourcePath] {
                source = cached
            } else {
                guard let resolved = resolve(path: job.sourcePath, bookmark: job.sourceBookmark) else { continue }
                sourceCache[job.sourcePath] = resolved
                source = resolved
            }
            resolvedSources[job.id] = source
            jobsBySourcePath[source.standardizedFileURL.path, default: []].append(job)

            if let targetPath = job.targetPath {
                let target = targetCache[targetPath] ?? resolve(path: targetPath, bookmark: job.targetBookmark)
                if let target {
                    targetCache[targetPath] = target
                    resolvedTargets[job.id] = target
                }
            }
        }

        for (sourcePath, jobs) in jobsBySourcePath {
            guard let source = jobs.first.flatMap({ resolvedSources[$0.id] }) else { continue }
            let monitor = DirectoryMonitor { [weak self] _ in
                guard let self else { return }
                for job in jobs { self.process(job) }
            }
            monitor.start(rootURL: source)
            monitors[sourcePath] = monitor
        }

    }

    private func resolve(path: String, bookmark: Data?) -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                return url
            }
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func process(_ job: FinderAutomationJob) {
        guard job.enabled, let source = resolvedSources[job.id] else { return }
        if processingJobIDs.contains(job.id) {
            // Viele Kopierereignisse werden zu genau einem Nachlauf gebündelt.
            // So geht keine spät eingetroffene Datei verloren und es entstehen
            // gleichzeitig keine parallelen Vollscans desselben Ordners.
            pendingJobIDs.insert(job.id)
            return
        }
        processingJobIDs.insert(job.id)
        let target = resolvedTargets[job.id]
        let generation = monitorGeneration
        processingQueue.async { [weak self] in
            guard let self else { return }
            let message: String?
            do {
                let engine = FinderToolkitEngine()
                let plans = try engine.automationPlan(
                    kind: job.kind,
                    source: source,
                    target: target,
                    extensions: job.extensions
                )
                let moved = try engine.execute(plans)
                message = moved.isEmpty ? nil : "FINDER-AUTOMATIK [\(job.kind.title)]: \(moved.count) Datei(en) verschoben."
            } catch {
                message = "FINDER-AUTOMATIK-FEHLER [\(job.kind.title)]: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.monitorGeneration == generation else { return }
                self.processingJobIDs.remove(job.id)
                if let message { self.log(message) }
                if self.pendingJobIDs.remove(job.id) != nil,
                   let currentJob = self.settings.jobs.first(where: { $0.id == job.id && $0.enabled }) {
                    self.process(currentJob)
                }
            }
        }
    }
}
