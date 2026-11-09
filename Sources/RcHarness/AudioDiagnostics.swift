import Foundation

/// Bounded metadata only: never stores PCM or recognized speech.
///
/// Called for every voice control packet and status change, so the file
/// handle, timestamp formatter and current size are kept between writes
/// instead of being recreated per line.
enum AudioDiagnostics {
    private static let queue = DispatchQueue(label: "vip.tokenzz.rcharness.audio-diagnostics")
    private static let maximumBytes = 512 * 1024
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RcHarness/audio.log")

    // Only touched on `queue`.
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var size = 0
    nonisolated(unsafe) private static var formatter = ISO8601DateFormatter()
    private static let prefix: String = {
        let process = ProcessInfo.processInfo
        return "[\(process.processName) pid=\(process.processIdentifier)]"
    }()

    static func log(_ message: String) {
        Log.audio.info("\(message, privacy: .public)")
        let date = Date()
        queue.async {
            do {
                let line = Data("\(formatter.string(from: date)) \(prefix) \(message)\n".utf8)
                if size + line.count > maximumBytes { try rotate() }
                let handle = try openHandle()
                try handle.write(contentsOf: line)
                size += line.count
            } catch {
                // Diagnostics must not interrupt a voice session; retry opening next time.
                try? handle?.close()
                handle = nil
            }
        }
    }

    private static func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
        let opened = try FileHandle(forWritingTo: fileURL)
        size = Int(try opened.seekToEnd())
        handle = opened
        return opened
    }

    private static func rotate() throws {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        let previous = fileURL.appendingPathExtension("previous")
        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
        if manager.fileExists(atPath: fileURL.path) { try manager.moveItem(at: fileURL, to: previous) }
        size = 0
    }
}
