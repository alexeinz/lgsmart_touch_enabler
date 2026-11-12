import Foundation

/// Thread-safe in-memory ring buffer of recent events, mirrored to `~/Library/Logs/Touchd/touchd.log`
/// (rotated at 512 KB). The settings app shows it live in the Logs tab.
public final class LogStore: @unchecked Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case info, warn, error, gesture
        var tag: String { rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0) }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: Int
        public let date: Date
        public let level: Level
        public let message: String

        public var line: String { "\(LogStore.timeFormatter.string(from: date)) \(level.tag) \(message)" }
    }

    public static let shared = LogStore()
    public static let defaultFileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Touchd/touchd.log")

    nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public let fileURL: URL?
    public let capacity: Int
    /// Called on the logging thread for every new entry.
    public var onAppend: (@Sendable (Entry) -> Void)? {
        get { lock.withLock { _onAppend } }
        set { lock.withLock { _onAppend = newValue } }
    }

    private let lock = NSLock()
    private let fileQueue = DispatchQueue(label: "touchd.log.file")
    private var _onAppend: (@Sendable (Entry) -> Void)?
    private var entries: [Entry] = []
    private var nextID = 0
    private let maxFileBytes = 512 * 1024

    public init(fileURL: URL? = LogStore.defaultFileURL, capacity: Int = 1000) {
        self.fileURL = fileURL
        self.capacity = capacity
    }

    public var snapshot: [Entry] { lock.withLock { entries } }

    public func log(_ message: String, _ level: Level = .info) {
        let entry: Entry
        let callback: (@Sendable (Entry) -> Void)?
        lock.lock()
        entry = Entry(id: nextID, date: Date(), level: level, message: message)
        nextID += 1
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        callback = _onAppend
        lock.unlock()

        callback?(entry)
        writeToFile(entry.line)
    }

    public func clear() {
        lock.withLock { entries.removeAll() }
    }

    public func exportText() -> String {
        snapshot.map(\.line).joined(separator: "\n")
    }

    private func writeToFile(_ line: String) {
        guard let url = fileURL else { return }
        fileQueue.async { [maxFileBytes] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxFileBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let data = Data((line + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
