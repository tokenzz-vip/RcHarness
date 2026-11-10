import AppKit
import SwiftUI
import XCTest
import ObjectiveC
@testable import RcHarness

@MainActor
final class PhraseDraggingTests: XCTestCase {
    func testHandlePrecedesTitleAndBoundRowsCannotStartDragging() throws {
        try withList { model, table in
            model.phraseAssignments[.dpadUp] = model.phrases[1].id
            let view = PhraseListView(model: model, selectedPhraseID: .constant(model.phrases[0].id))
            let coordinator = try XCTUnwrap(table.dataSource as? PhraseListView.Coordinator)
            coordinator.update(parent: view, table: table)
            XCTAssertNil(table.dataSource?.tableView?(table, pasteboardWriterForRow: 0))
            XCTAssertNotNil(table.dataSource?.tableView?(table, pasteboardWriterForRow: 1))
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            let handle = try XCTUnwrap(descendants(cell).first { $0.identifier?.rawValue.hasPrefix("phrase-drag-handle:") == true })
            let title = try XCTUnwrap(cell.textField)
            XCTAssertLessThan(handle.convert(handle.bounds, to: cell).maxX, title.convert(title.bounds, to: cell).minX)
        }
    }

    func testNativeDropMovesBothDirectionsAndKeepsBindingsPinned() throws {
        try withList { model, table in
            let entries = model.phrases
            model.phraseAssignments[.dpadUp] = entries[1].id
            let view = PhraseListView(model: model, selectedPhraseID: .constant(entries[0].id))
            let coordinator = try XCTUnwrap(table.dataSource as? PhraseListView.Coordinator)
            coordinator.update(parent: view, table: table)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let writer = try XCTUnwrap(table.dataSource?.tableView?(table, pasteboardWriterForRow: 1))
            XCTAssertTrue(pasteboard.writeObjects([writer]))
            let info = TestDraggingInfo(source: table, pasteboard: pasteboard)
            XCTAssertEqual(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: 3, proposedDropOperation: .above), .move)
            XCTAssertEqual(table.dataSource?.tableView?(table, acceptDrop: info, row: 3, dropOperation: .above), true)
            XCTAssertEqual(model.orderedPhrases.map(\.id), [entries[1].id, entries[2].id, entries[0].id])
            XCTAssertEqual(model.phraseAssignments[.dpadUp], entries[1].id)
            table.layoutSubtreeIfNeeded()
            let firstTitle = try XCTUnwrap((table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue)
            XCTAssertEqual(firstTitle, entries[1].displayTitle, "The released row must repaint immediately after acceptDrop returns")
            coordinator.update(parent: view, table: table)
            XCTAssertEqual(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .above), .move)
            XCTAssertEqual(table.dataSource?.tableView?(table, acceptDrop: info, row: 1, dropOperation: .above), true)
            XCTAssertEqual(model.orderedPhrases.map(\.id), [entries[1].id, entries[0].id, entries[2].id])
            XCTAssertEqual(table.dataSource?.tableView?(table, acceptDrop: info, row: 0, dropOperation: .above), false)
            info.draggingSource = NSTableView()
            XCTAssertEqual(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .above), [])
            info.draggingSource = table
            pasteboard.clearContents()
            pasteboard.setString(entries[1].id.uuidString, forType: PhraseListView.Coordinator.pasteboardType)
            XCTAssertEqual(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .above), [])
        }
    }

    private func withList(_ body: (RemoteDashboardModel, NSTableView) throws -> Void) throws {
        let suite = "RcHarness.PhraseDraggingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.phrases = (0..<3).map { SavedPhrase(title: "条目\($0)", text: "内容\($0)") }
        let host = NSHostingView(rootView: PhrasesPage(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try body(model, XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first))
    }

    func testDraggingVisibleRowStartsANativeDragSession() throws {
        let suite = "RcHarness.PhraseDraggingInputTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.phrases = [SavedPhrase(title: "第一条", text: "1"), SavedPhrase(title: "第二条", text: "2")]
        let host = NSHostingView(rootView: PhrasesPage(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let rowRect = table.rect(ofRow: 0)
        let point = NSPoint(x: rowRect.minX + 14, y: rowRect.midY)
        let target = try XCTUnwrap(table.hitTest(point))
        let start = table.convert(point, to: nil)
        let method = try XCTUnwrap(class_getInstanceMethod(NSView.self, #selector(NSView.beginDraggingSession(with:event:source:))))
        var sessions = 0
        // Intercept the native session boundary; events stay inside this test window.
        // No global mouse events or real system drag sessions are created.
        let block: @convention(block) (NSView, NSArray, NSEvent, AnyObject) -> NSDraggingSession = { _, _, _, _ in
            sessions += 1
            return NSDraggingSession()
        }
        let replacement = imp_implementationWithBlock(block)
        let original = method_setImplementation(method, replacement)
        defer { method_setImplementation(method, original); imp_removeBlock(replacement) }
        func event(_ type: NSEvent.EventType, _ location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 50)), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, NSPoint(x: start.x, y: start.y - 50)), atStart: false)
        target.mouseDown(with: try event(.leftMouseDown, start))
        XCTAssertEqual(sessions, 1, "Dragging a visible phrase row must start a native drag, not just click its selection button")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(source: NSTableView, pasteboard: NSPasteboard) {
        draggingSource = source
        draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
