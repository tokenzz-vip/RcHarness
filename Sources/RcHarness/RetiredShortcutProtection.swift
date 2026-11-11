import Foundation

/// One-way migration for interrupted recordings from older builds. New
/// recordings never change HID mappings or start a keyboard guard.
@MainActor
enum RetiredShortcutProtection {
    static func recoverIfNeeded() {
        let journal = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RcHarness/shortcut-function-restore.json")
        guard let data = try? Data(contentsOf: journal),
              let snapshots = try? JSONSerialization.jsonObject(with: data) as? [Any],
              !snapshots.isEmpty,
              let executable = Bundle.main.executableURL else { return }
        let recovery = Process()
        recovery.executableURL = executable
        recovery.arguments = ["--restore-shortcut-keys"]
        recovery.standardInput = FileHandle.nullDevice
        recovery.standardOutput = FileHandle.nullDevice
        do { try recovery.run() }
        catch { Log.settings.error("Legacy shortcut restore could not start: \(error.localizedDescription, privacy: .public)") }
    }
}
