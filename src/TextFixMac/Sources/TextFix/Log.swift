// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A deliberately small rolling log. It records what the agent tried and how the provider
/// answered - never the text being fixed, never a clipboard payload, never an API key. Those are
/// the whole point of the app being local, and a log file is the easiest place to leak them.
enum Log {
    private static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "com.turtlecute33.textfix.log", qos: .utility)

    /// Read from the request task and written from the main thread, so it lives behind a lock
    /// in a reference box rather than being a plain mutable `static var`.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        var current: Bool {
            get { lock.locked { value } }
            set { lock.locked { value = newValue } }
        }
    }

    private static let verboseFlag = Flag()

    static var verbose: Bool {
        get { verboseFlag.current }
        set { verboseFlag.current = newValue }
    }

    /// `~/Library/Logs/TextFix`, which is where Console.app and every macOS support document
    /// already tell people to look.
    static let directory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TextFix", isDirectory: true)

    static let fileURL: URL = directory.appendingPathComponent("textfix.log")

    static func info(_ message: @autoclosure @escaping () -> String) { write("INFO ", message) }

    static func warn(_ message: @autoclosure @escaping () -> String) { write("WARN ", message) }

    static func error(_ message: @autoclosure @escaping () -> String) { write("ERROR", message) }

    /// Autoclosed so that a verbose-only message costs nothing to *not* log: with verbose off the
    /// string is never built, which matters because the hot path formats one per fix.
    static func debug(_ message: @autoclosure @escaping () -> String) {
        guard verbose else { return }
        write("DEBUG", message)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func write(_ level: String, _ message: @escaping () -> String) {
        // Off the caller's thread: a fix must never wait on a disk write, and serialising here is
        // what makes the file safe to append to from the request task and the main thread at once.
        queue.async {
            let line = "\(stamp.string(from: Date())) \(level) \(message())\n"
            guard let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let attributes = try? manager.attributesOfItem(atPath: fileURL.path)
                if let size = attributes?[.size] as? Int, size > maxBytes {
                    // One generation of history is enough to diagnose "it stopped working today".
                    let previous = fileURL.appendingPathExtension("1")
                    try? manager.removeItem(at: previous)
                    try? manager.moveItem(at: fileURL, to: previous)
                }
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                // Logging must never be the reason a fix fails.
            }
        }
    }
}

extension NSLock {
    /// Named `locked` rather than `withLock` so it can never be ambiguous with the one Foundation
    /// added to NSLocking - which exists on some SDKs this is built against and not others.
    @inline(__always)
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
