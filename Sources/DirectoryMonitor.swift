import Foundation
import CoreServices

struct DirectoryChange: Equatable {
    let changedURLs: Set<URL>
    let requiresFullScan: Bool
    let rootChanged: Bool
}

/// Ein nativer FSEvents-Strom pro Stammstruktur. Die Anzahl der Ressourcen
/// bleibt dadurch konstant, auch wenn ein Endordner tausende Unterordner hat.
/// Zwischenordner werden nur direkt, konfigurierte Endordner rekursiv gefiltert.
final class DirectoryMonitor {
    private let callback: (DirectoryChange) -> Void
    private var stream: FSEventStreamRef?
    private var pendingCallback: DispatchWorkItem?
    private var pendingChangedURLs = Set<URL>()
    private var pendingRequiresFullScan = false
    private var pendingRootChanged = false
    private(set) var recursiveRootURLs: [URL] = []
    private(set) var shallowRootURLs: [URL] = []

    var watchedDirectoryCount: Int {
        Set((recursiveRootURLs + shallowRootURLs).map { $0.standardizedFileURL.path }).count
    }

    var eventStreamCount: Int { stream == nil ? 0 : 1 }

    init(fileManager: FileManager = .default, callback: @escaping (DirectoryChange) -> Void) {
        self.callback = callback
    }

    deinit { stop() }

    func start(rootURL: URL) {
        start(recursiveRootURLs: [rootURL], shallowRootURLs: [])
    }

    func start(rootURLs: [URL]) {
        start(recursiveRootURLs: rootURLs, shallowRootURLs: [])
    }

    func start(recursiveRootURLs: [URL], shallowRootURLs: [URL]) {
        stop()
        self.recursiveRootURLs = uniqueExistingDirectories(recursiveRootURLs)
        self.shallowRootURLs = uniqueExistingDirectories(shallowRootURLs)

        let allPaths = Array(Set((self.recursiveRootURLs + self.shallowRootURLs).map { $0.standardizedFileURL.path })).sorted()
        guard !allPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
        )
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            allPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            3.0,
            flags
        ) else { return }

        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, DispatchQueue.main)
        if !FSEventStreamStart(createdStream) {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            stream = nil
        }
    }

    /// FSEvents überwacht neu entstehende Unterordner automatisch. Ein teurer
    /// Neuaufbau nach jedem Scan ist deshalb nicht erforderlich.
    func rebuild() {}

    func stop() {
        pendingCallback?.cancel()
        pendingCallback = nil
        pendingChangedURLs.removeAll()
        pendingRequiresFullScan = false
        pendingRootChanged = false
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        recursiveRootURLs = []
        shallowRootURLs = []
    }

    private func uniqueExistingDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            return seen.insert(path).inserted && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static let eventCallback: FSEventStreamCallback = {
        _, clientInfo, eventCount, eventPaths, eventFlags, _ in
        guard let clientInfo else { return }
        let monitor = Unmanaged<DirectoryMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
        let pathArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let paths = pathArray as? [String] ?? []
        guard eventCount > 0 else { return }
        guard let change = monitor.relevantChange(paths: paths, flags: eventFlags, count: eventCount) else { return }
        monitor.scheduleCoalescedCallback(change)
    }

    private func relevantChange(
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) -> DirectoryChange? {
        let recursivePaths = recursiveRootURLs.map { $0.standardizedFileURL.path }
        let shallowPaths = shallowRootURLs.map { $0.standardizedFileURL.path }
        let safeCount = min(count, paths.count)
        var changedURLs = Set<URL>()
        var requiresFullScan = false
        var rootChanged = false

        for index in 0..<safeCount {
            let eventURL = URL(fileURLWithPath: paths[index]).standardizedFileURL
            let eventPath = eventURL.path
            let eventFlag = FSEventStreamEventFlags(flags[index])
            let isRecursiveEvent = recursivePaths.contains(where: { eventPath == $0 || eventPath.hasPrefix($0 + "/") })
            let parentPath = URL(fileURLWithPath: eventPath).deletingLastPathComponent().standardizedFileURL.path
            let isShallowEvent = shallowPaths.contains(parentPath) || shallowPaths.contains(eventPath)
            let affectsWatchedPath = isRecursiveEvent || isShallowEvent
            guard affectsWatchedPath else { continue }

            changedURLs.insert(eventURL)
            let rescanMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagEventIdsWrapped
            )
            if (eventFlag & rescanMask) != 0 { requiresFullScan = true }
            if (eventFlag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0 {
                rootChanged = true
                requiresFullScan = true
            }
        }
        guard !changedURLs.isEmpty else { return nil }
        return DirectoryChange(
            changedURLs: changedURLs,
            requiresFullScan: requiresFullScan,
            rootChanged: rootChanged
        )
    }

    private func scheduleCoalescedCallback(_ change: DirectoryChange) {
        pendingChangedURLs.formUnion(change.changedURLs)
        pendingRequiresFullScan = pendingRequiresFullScan || change.requiresFullScan
        pendingRootChanged = pendingRootChanged || change.rootChanged
        pendingCallback?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCallback = nil
            let combinedChange = DirectoryChange(
                changedURLs: self.pendingChangedURLs,
                requiresFullScan: self.pendingRequiresFullScan,
                rootChanged: self.pendingRootChanged
            )
            self.pendingChangedURLs.removeAll()
            self.pendingRequiresFullScan = false
            self.pendingRootChanged = false
            self.callback(combinedChange)
        }
        pendingCallback = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}
