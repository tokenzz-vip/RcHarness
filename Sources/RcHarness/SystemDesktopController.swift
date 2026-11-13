import CoreFoundation
import Darwin
import Foundation

/// The Dock notification used by macOS to toggle Show Desktop.
///
/// This is an undocumented Dock entry point. It is loaded dynamically so the
/// app remains launchable when a future macOS release removes or renames it.
protocol DesktopController: AnyObject {
    var isSupported: Bool { get }
    func toggle()
}

final class SystemDesktopController: DesktopController {
    static let shared = SystemDesktopController()

    private static let dockPath = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    private static let notificationName = "com.apple.showdesktop.awake"
    private typealias NotificationSender = @convention(c) (CFString) -> Void

    private let dockHandle: UnsafeMutableRawPointer?
    private let notificationSender: ((CFString) -> Void)?

    /// Loads the private Dock symbol. The symbol lookup is the non-destructive
    /// runtime probe used by the settings UI to decide whether to offer this
    /// action.
    init() {
        let handle = dlopen(Self.dockPath, RTLD_LAZY)
        dockHandle = handle
        if let handle, let symbol = dlsym(handle, "CoreDockSendNotification") {
            let function = unsafeBitCast(symbol, to: NotificationSender.self)
            notificationSender = { value in function(value) }
            Log.hid.info("Show Desktop Dock notification is available")
        } else {
            notificationSender = nil
            Log.hid.info("Show Desktop Dock notification is unavailable")
        }
    }

    /// Test-only initializer that exercises the same send path without
    /// loading the real Dock process.
    init(notificationSender: @escaping (CFString) -> Void) {
        dockHandle = nil
        self.notificationSender = notificationSender
    }

    deinit {
        if let dockHandle { dlclose(dockHandle) }
    }

    var isSupported: Bool { notificationSender != nil }

    func toggle() {
        guard let notificationSender else {
            Log.hid.error("Show Desktop is unavailable on this macOS version")
            return
        }
        notificationSender(Self.notificationName as CFString)
    }
}
