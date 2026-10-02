import Foundation

private enum MonitorTestFailure: LocalizedError {
	case incorrectCallbackCount(Int)
	case incorrectWatcherCount(Int)
	case unexpectedIdleCallback(Int)

	var errorDescription: String? {
		switch self {
		case .incorrectCallbackCount(let count):
			return "Der native Ordnerwächter lieferte \(count) statt genau eines gebündelten Ereignisses."
		case .incorrectWatcherCount(let count):
			return "Der native Ereignisstrom verwendete \(count) statt drei gezielten Pfadfiltern."
		case .unexpectedIdleCallback(let count):
			return "Im Leerlauf wurden unerwartet \(count) Dateisystemereignisse ausgelöst."
		}
	}
}

@main
struct MonitorSelfTest {
	static func main() throws {
		let fileManager = FileManager.default
		let root = fileManager.temporaryDirectory
			.appendingPathComponent("Filelio-Monitor-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))", isDirectory: true)
		defer { try? fileManager.removeItem(at: root) }
		let auto = root.appendingPathComponent("Privat/Auto", isDirectory: true)
		let kfz = auto.appendingPathComponent("Kfz", isDirectory: true)
		let versicherung = auto.appendingPathComponent("Versicherung", isDirectory: true)
		try fileManager.createDirectory(at: kfz.appendingPathComponent("Archiv", isDirectory: true), withIntermediateDirectories: true)
		try fileManager.createDirectory(at: versicherung, withIntermediateDirectories: true)
		try fileManager.createDirectory(at: root.appendingPathComponent("NichtKonfiguriert/GrosserBaum", isDirectory: true), withIntermediateDirectories: true)

		var callbackCount = 0
		var changedPaths = Set<String>()
		let monitor = DirectoryMonitor { change in
			callbackCount += 1
			changedPaths.formUnion(change.changedURLs.map(\.path))
		}
		monitor.start(recursiveRootURLs: [kfz, versicherung], shallowRootURLs: [auto])
		guard monitor.watchedDirectoryCount == 3, monitor.eventStreamCount == 1 else {
			throw MonitorTestFailure.incorrectWatcherCount(monitor.watchedDirectoryCount)
		}
		RunLoop.main.run(until: Date().addingTimeInterval(1.5))
		guard callbackCount == 0 else {
			throw MonitorTestFailure.unexpectedIdleCallback(callbackCount)
		}

		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
			try? Data("parent event".utf8).write(to: auto.appendingPathComponent("DirektInAuto.txt"))
			try? Data("leaf event".utf8).write(to: kfz.appendingPathComponent("NewFile.txt"))
		}

		let timeout = Date().addingTimeInterval(6)
		while callbackCount == 0 && RunLoop.main.run(mode: .default, before: timeout) && Date() < timeout {}
		monitor.stop()

		guard callbackCount == 1 else { throw MonitorTestFailure.incorrectCallbackCount(callbackCount) }
		guard changedPaths.contains(where: { $0.hasSuffix("DirektInAuto.txt") }) && changedPaths.contains(where: { $0.hasSuffix("NewFile.txt") }) else {
			throw MonitorTestFailure.incorrectCallbackCount(callbackCount)
		}
		print("MONITOR_SELF_TEST_PASS idleCallbacks=0 callbacks=\(callbackCount) targetedPaths=\(changedPaths.count) eventStreams=1 pathFilters=3 sandbox=\(root.path)")
	}
}
