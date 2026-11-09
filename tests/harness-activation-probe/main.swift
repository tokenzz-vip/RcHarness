// Opt-in GUI integration probe. Only its own fixture process receives events.
import AppKit

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    let root: URL
    let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 300, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    var reopens = 0
    var timer: Timer?
    init(root: URL) { self.root = root; super.init(); window.isReleasedWhenClosed = false }
    func state() {
        try! "\(window.isVisible ? 1 : 0),\(reopens)".write(to: root.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        state()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                let url = root.appendingPathComponent("command")
                guard let command = try? String(contentsOf: url, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: url)
                if command == "close" { window.performClose(nil); state() }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopens += 1
        window.makeKeyAndOrderFront(nil)
        state()
        return true
    }
}

@main
struct Probe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        if CommandLine.arguments[1] == "--fixture" {
            app.setActivationPolicy(.regular)
            let fixture = Fixture(root: root)
            app.delegate = fixture
            withExtendedLifetime(fixture) { app.run() }
            return
        }
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("state"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--fixture", root.path]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        func awaitState(_ expected: String) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            repeat {
                if (try? String(contentsOf: root.appendingPathComponent("state"), encoding: .utf8)) == expected { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
            return false
        }
        guard awaitState("1,0") else { fatalError("Fixture did not show initial window") }
        let pid = process.processIdentifier
        func activate() -> HarnessApplicationActivation.Result {
            HarnessApplicationActivation.perform(processID: pid, isAvailable: {
                NSRunningApplication(processIdentifier: pid)?.isTerminated == false
            })
        }
        // An existing window must still switch successfully.
        guard activate() == .activated, awaitState("1,1") else {
            fatalError("Could not activate fixture with an existing window")
        }
        for count in 1...2 {
            try "close".write(to: root.appendingPathComponent("command"), atomically: true, encoding: .utf8)
            guard awaitState("0,\(count)") else { fatalError("Fixture did not close window") }
            let result = activate()
            let restored = awaitState("1,\(count + 1)")
            print("cycle=\(count) activation_result=\(result) window_restored=\(restored)")
            guard result == .activated, restored else { exit(1) }
        }
    }
}
