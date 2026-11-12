import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class HarnessLayoutTests: XCTestCase {
    func testLightPageLayoutStaysStableWhenForegroundApplicationChanges() async throws {
        try await assertStableLayout(appearance: .aqua)
    }

    func testDarkPageLayoutStaysStableWhenForegroundApplicationChanges() async throws {
        try await assertStableLayout(appearance: .darkAqua)
    }

    private func assertStableLayout(appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        let suite = "RcHarness.HarnessLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let host = NSHostingView(rootView: HarnessSettingsView(model: model)
            .padding(SettingsStyle.pagePadding)
            .frame(width: 900)
            .fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(host)
        let baseline = host.fittingSize.height
        let baselineSwitches = switchFrames(in: host)
        XCTAssertEqual(baselineSwitches.count, model.harnesses.count)
        let targets: [(identifier: String, harnessID: String?)] = [
            ("com.openai.codex", "codex"),
            ("com.todesktop.230313mzl4w4u92", "cursor"),
            ("com.deepseek.dsh", "deepseek"),
            ("other.app", nil),
        ]
        for (identifier, harnessID) in targets {
            window.resignKey()
            model.matchApplication(nil, bundleIdentifier: identifier)
            XCTAssertEqual(model.selectedHarnessID, harnessID)
            await settle(host)
            XCTAssertEqual(host.fittingSize.height, baseline, accuracy: 0.1,
                           "Foreground app \(identifier) must not move the Harness page's rows")
            XCTAssertEqual(switchFrames(in: host), baselineSwitches,
                           "Changing the current Harness must preserve every row's position")
            window.makeKeyAndOrderFront(nil)
            await settle(host)
            XCTAssertEqual(switchFrames(in: host), baselineSwitches,
                           "Restoring window focus must preserve every row's position")
        }
    }

    private func switchFrames(in host: NSView) -> [NSRect] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(host).compactMap { $0 as? NSSwitch }
            .map { host.convert($0.bounds, from: $0) }
            .sorted { $0.minY < $1.minY }
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<3 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
    }
}
