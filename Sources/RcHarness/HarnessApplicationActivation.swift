import AppKit
import ApplicationServices

/// Coordinates activation and Dock-style reopening of the same running process.
@MainActor
enum HarnessApplicationActivation {
    enum Result: Equatable { case activated, unavailable, failed }

    static func perform(processID: Int32, isAvailable: () -> Bool) -> Result {
        perform(isAvailable: isAvailable, requestActivation: {
            guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated else { return false }
            application.unhide()
            NSApp.yieldActivation(to: application)
            return application.activate(options: [.activateAllWindows]) || application.isActive
        }, makeFrontmost: {
            // HID input does not give a background app an AppKit activation
            // grant. Use the existing Accessibility permission for this PID.
            guard AXIsProcessTrusted() else { return false }
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.5)
            let error = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if error != .success {
                Log.app.error("Harness focus failed pid=\(processID) accessibility_error=\(error.rawValue)")
            }
            return error == .success
        }, requestReopen: {
            reopen(processID: processID)
        })
    }

    static func perform(isAvailable: () -> Bool, requestActivation: () -> Bool,
                        makeFrontmost: () -> Bool, requestReopen: () -> Bool) -> Result {
        guard isAvailable() else { return .unavailable }
        if !requestActivation() {
            // Activation may be refused when our nonactivating switcher belongs
            // to a background app. Revalidate before using the accessibility path.
            guard isAvailable() else { return .unavailable }
            guard makeFrontmost() else { return .failed }
        }
        // Activation succeeds even when the user has closed every window.
        // Dock also sends 'rapp', letting the target restore its own window.
        guard isAvailable() else { return .unavailable }
        return requestReopen() ? .activated : .failed
    }

    private static func reopen(processID: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated else { return false }
        // Address a PID, never an application URL/bundle ID: an app that exits
        // while switching must not be relaunched by this request.
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            _ = try event.sendEvent(options: [.noReply, .canInteract], timeout: 0.5)
            return true
        } catch {
            Log.app.error("Harness reopen failed pid=\(processID) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
