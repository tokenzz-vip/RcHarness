import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class MacrosLayoutTests: XCTestCase {
    func testLongMacroListScrollsWithoutMovingTheEditor() throws {
        let suite = "RcHarness.MacrosLayoutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let macro = try XCTUnwrap(model.macros.first)
        model.updateMacroSteps((0..<12).map { _ in MacroStep() }, for: macro.id)
        model.page = .macros
        let hostingView = NSHostingView(rootView: RemoteDashboardView(model: model))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsStyle.minimumWindowSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()

        let panes = scrollViews(in: hostingView).filter {
            $0.convert($0.bounds, to: hostingView).minX > SettingsStyle.sidebarWidth
        }.sorted { $0.convert($0.bounds, to: hostingView).minX < $1.convert($1.bounds, to: hostingView).minX }
        XCTAssertEqual(panes.count, 2, "The macro list and editor must have independent scroll areas")
        guard panes.count == 2 else { return }
        let list = panes[0]
        let editor = panes[1]
        let document = try XCTUnwrap(list.documentView)
        XCTAssertGreaterThan(document.bounds.height, list.contentView.bounds.height)
        let editorFrame = editor.convert(editor.bounds, to: hostingView)
        XCTAssertLessThanOrEqual(editorFrame.maxY, hostingView.bounds.maxY)
        XCTAssertGreaterThanOrEqual(editorFrame.minY, hostingView.bounds.minY)

        list.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - list.contentView.bounds.height))
        list.reflectScrolledClipView(list.contentView)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(list.contentView.bounds.minY, 0)
        XCTAssertEqual(editor.convert(editor.bounds, to: hostingView), editorFrame,
                       "Scrolling to the last macro must keep the editor visible")

        let editorDocument = try XCTUnwrap(editor.documentView)
        XCTAssertGreaterThan(editorDocument.bounds.height, editor.contentView.bounds.height)
        let listPosition = list.contentView.bounds.origin
        editor.contentView.scroll(to: CGPoint(x: 0, y: editorDocument.bounds.height - editor.contentView.bounds.height))
        editor.reflectScrolledClipView(editor.contentView)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.contentView.bounds.minY, 0)
        XCTAssertEqual(list.contentView.bounds.origin, listPosition,
                       "Scrolling a long action must not move the macro list")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
