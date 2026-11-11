import AppKit
import Darwin

// The guard only manages HID mappings and stdin. Run it before creating
// NSApplication so it never registers as a second Dock application.
if CommandLine.arguments.contains("--restore-shortcut-keys") {
    exit(RemoteVolumeGuardWorker(recoverRetiredShortcuts: true).run() ? 0 : 1)
}
if CommandLine.arguments.contains("--remote-volume-guard") {
    let profiles: [RemoteProfile]
    if let flag = CommandLine.arguments.firstIndex(of: "--remote-profiles") {
        let ids = Set(CommandLine.arguments.dropFirst(flag + 1))
        profiles = RemoteProfiles.all.filter { ids.contains($0.id) }
    } else {
        profiles = RemoteProfiles.all
    }
    exit(RemoteVolumeGuardWorker(profiles: profiles).run() ? 0 : 1)
}

// SwiftPM executables do not automatically enter the AppKit delegate lifecycle
// when the delegate is only declared as a type. Install the delegate explicitly
// before starting the run loop so applicationDidFinishLaunching is guaranteed to
// configure the dashboard, status item, and remote listeners.
let application = NSApplication.shared
let isUtilityProcess = CommandLine.arguments.contains("--render-settings")
let instanceLock: SingleInstanceLock?
if isUtilityProcess {
    instanceLock = nil
} else {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RcHarness")
    do {
        instanceLock = try SingleInstanceLock(path: directory.appendingPathComponent("application.lock").path)
    } catch SingleInstanceLock.Failure.alreadyRunning {
        DistributedNotificationCenter.default().postNotificationName(
            .rcHarnessShowDashboard, object: String(getuid()), userInfo: nil, deliverImmediately: true
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("RcHarness 无法取得应用实例锁：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
// Top-level code runs on the main thread before the run loop starts.
MainActor.assumeIsolated {
    if !isUtilityProcess { RetiredShortcutProtection.recoverIfNeeded() }
    let delegate = RcHarnessApp()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    // NSApplication.delegate is weak. Keep the delegate alive for the complete
    // lifetime of the run loop; otherwise startup callbacks silently never fire.
    withExtendedLifetime((delegate, instanceLock)) {
        application.run()
    }
}
