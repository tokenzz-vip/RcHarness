import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class PhraseAssignmentTests: XCTestCase {
    func testDirectionIconsOpenPopoversInTheRealDashboardWindow() async throws {
        _ = NSApplication.shared
        let suite = "RcHarness.PhraseDashboardTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.phrases = DefaultPhrases.all
        model.phraseAssignments = DefaultPhrases.assignments(for: model.phrases)
        model.page = .phrases
        let controller = DashboardWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        await flushUI()
        let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        for point in [NSPoint(x: 256, y: 315), NSPoint(x: 188, y: 383), NSPoint(x: 324, y: 383),
                      NSPoint(x: 256, y: 451), NSPoint(x: 256, y: 383)] {
            try click(point, in: host, window: window)
            await flushUI()
            let popup = NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) }
            XCTAssertNotNil(popup, "Direction icon at \(point) must open a popover in the real window; bounds=\(host.bounds)")
            if let popup {
                let anchor = window.convertPoint(toScreen: host.convert(point, to: nil))
                XCTAssertGreaterThan(popup.frame.midX, anchor.x, "The picker should open to the right when there is room")
                try click(NSPoint(x: 100, y: 103), in: XCTUnwrap(popup.contentView), window: popup)
                await flushUI()
            }
        }
    }

    func testEveryAssignmentPopoverSearchesAndUpdatesOnlyItsOwnSlot() async throws {
        _ = NSApplication.shared
        let suite = "RcHarness.PhraseAssignmentTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.phrases = [SavedPhrase(title: "其他常用语", text: "不要选择"),
                         SavedPhrase(title: "选择这一条", text: "测试内容"),
                         SavedPhrase(title: "更多内容", text: "另一个条目")]
        model.phraseAssignments = PhraseAssignments()
        let host = NSHostingView(rootView: PhrasesPage(model: model).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RC_HARNESS_UI_DARK"] == "1" ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        await flushUI()
        let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        var expected = PhraseAssignments()
        for input in PhraseAssignments.inputs {
            // The 212-point wheel starts at (20, 163) in this fixed-size page fixture.
            let position = PhrasePadLayout.position(for: input)
            try click(NSPoint(x: 20 + position.x, y: 163 + position.y), in: host, window: window)
            await flushUI()
            let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existingWindows.contains($0.windowNumber) },
                                     "Clicking \(input.label) must open the phrase selection popover")
            let editor = try XCTUnwrap(popup.firstResponder as? NSTextView, "The search field must receive keyboard focus")
            XCTAssertEqual(editor.string, "", "Opening another key must reset the previous query")
            editor.insertText("选条", replacementRange: NSRange(location: NSNotFound, length: 0))
            await flushUI()
            try snapshot(window: window, popup: popup, name: input.rawValue)
            let content = try XCTUnwrap(popup.contentView)
            try click(NSPoint(x: 100, y: 193), in: content, window: popup)
            await flushUI()
            expected[input] = model.phrases[1].id
            XCTAssertEqual(model.phraseAssignments, expected, "Search result must update only \(input.label)")
            try assertListMatchesModel(model, in: host)
        }
        let up = PhrasePadLayout.position(for: .dpadUp)
        try click(NSPoint(x: 20 + up.x, y: 163 + up.y), in: host, window: window)
        await flushUI()
        let replacementPopup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existingWindows.contains($0.windowNumber) })
        let replacementEditor = try XCTUnwrap(replacementPopup.firstResponder as? NSTextView)
        replacementEditor.insertText("其他", replacementRange: NSRange(location: NSNotFound, length: 0))
        await flushUI()
        try click(NSPoint(x: 100, y: 193), in: XCTUnwrap(replacementPopup.contentView), window: replacementPopup)
        await flushUI()
        expected[.dpadUp] = model.phrases[0].id
        XCTAssertEqual(model.phraseAssignments, expected)
        try assertListMatchesModel(model, in: host)
        let right = PhrasePadLayout.position(for: .dpadRight)
        try click(NSPoint(x: 20 + right.x, y: 163 + right.y), in: host, window: window)
        await flushUI()
        let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existingWindows.contains($0.windowNumber) })
        let editor = try XCTUnwrap(popup.firstResponder as? NSTextView)
        editor.insertText("没有匹配的关键词", replacementRange: NSRange(location: NSNotFound, length: 0))
        await flushUI()
        try snapshot(window: window, popup: popup, name: "empty-search")
        try click(NSPoint(x: 100, y: 103), in: XCTUnwrap(popup.contentView), window: popup)
        await flushUI()
        expected[.dpadRight] = nil
        XCTAssertEqual(model.phraseAssignments, expected, "Unassign must remain available when search has no matches")
        try assertListMatchesModel(model, in: host)
        for input in PhraseAssignments.inputs where expected[input] != nil {
            let position = PhrasePadLayout.position(for: input)
            try click(NSPoint(x: 20 + position.x, y: 163 + position.y), in: host, window: window)
            await flushUI()
            let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existingWindows.contains($0.windowNumber) })
            try click(NSPoint(x: 100, y: 103), in: XCTUnwrap(popup.contentView), window: popup)
            await flushUI()
            expected[input] = nil
            XCTAssertEqual(model.phraseAssignments, expected)
            try assertListMatchesModel(model, in: host)
        }
    }

    private func assertListMatchesModel(_ model: RemoteDashboardModel, in host: NSView) throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, model.orderedPhrases.count)
        for (row, phrase) in model.orderedPhrases.enumerated() {
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            XCTAssertEqual(cell.textField?.stringValue, phrase.displayTitle,
                           "Visible phrase order must update as soon as the picker selection returns")
            let bindings = PhraseAssignments.inputs.filter { model.phraseAssignments[$0] == phrase.id }
            let images = descendants(cell).compactMap { $0 as? NSImageView }
            let expectedLabels = bindings.isEmpty ? ["拖动调整顺序"] : bindings.map { "已绑定" + $0.label }
            XCTAssertEqual(images.compactMap { $0.image?.accessibilityDescription }, expectedLabels,
                           "Visible binding symbols must refresh with the assignment")
            XCTAssertEqual(descendants(cell).contains { $0.identifier?.rawValue.hasPrefix("phrase-drag-handle:") == true },
                           bindings.isEmpty, "A newly bound row must immediately lose its drag handle")
        }
    }

    func testNativeMouseTargetsRecognizeDirectionIconsAndLabels() async throws {
        _ = NSApplication.shared
        var selections: [ControllerInput] = []
        let titles: [ControllerInput: String] = [.dpadUp: "继续执行", .dpadLeft: "解释一下", .dpadRight: "修复问题",
                                                .dpadDown: "检查结果", .buttonA: "确认方案"]
        let host = NSHostingView(rootView: PhrasePadView(title: { titles[$0] ?? "" }, isAssigned: { _ in true }) { selections.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 212, height: 212),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        await flushUI()
        for (input, point): (ControllerInput, NSPoint) in [
            (.dpadUp, NSPoint(x: 106, y: 38)),
            (.dpadUp, NSPoint(x: 106, y: 26)),
            (.dpadUp, NSPoint(x: 106, y: 46)),
            (.dpadUp, NSPoint(x: 90, y: 46)),
            (.dpadUp, NSPoint(x: 122, y: 46)),
            (.dpadLeft, NSPoint(x: 38, y: 106)),
            (.dpadLeft, NSPoint(x: 38, y: 94)),
            (.dpadLeft, NSPoint(x: 38, y: 114)),
            (.dpadLeft, NSPoint(x: 24, y: 114)),
            (.dpadLeft, NSPoint(x: 52, y: 114)),
            (.dpadRight, NSPoint(x: 174, y: 106)),
            (.dpadRight, NSPoint(x: 174, y: 94)),
            (.dpadRight, NSPoint(x: 174, y: 114)),
            (.dpadRight, NSPoint(x: 160, y: 114)),
            (.dpadRight, NSPoint(x: 188, y: 114)),
            (.dpadDown, NSPoint(x: 106, y: 174)),
            (.buttonA, NSPoint(x: 106, y: 106)),
        ] {
            selections.removeAll()
            let location = host.convert(point, to: nil)
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0)))
            await flushUI()
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                let target = try XCTUnwrap(host.hitTest(point))
                XCTAssertTrue(target is PhrasePadInputView, "The native pointer target must own the sector hit test")
                if type == .leftMouseDown { target.mouseDown(with: event) }
                else { target.mouseUp(with: event) }
            }
            await flushUI()
            XCTAssertEqual(selections, [input], "Clicking \(input.label) at \(point) must select that pad position")
        }
    }

    func testPadGapsDoNotInterceptClicksAndCrossSectorDragsDoNotSelect() throws {
        let view = PhrasePadInputView(frame: NSRect(x: 0, y: 0, width: 212, height: 212))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var selections: [ControllerInput] = []
        var presses: [ControllerInput?] = []
        view.onSelect = { selections.append($0) }
        view.onPress = { presses.append($0) }
        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 211, y: 0), NSPoint(x: 20, y: 20),
                      NSPoint(x: 130, y: 130), NSPoint(x: 141, y: 106)] {
            XCTAssertNil(view.hitTest(point), "Empty pad area must not intercept the click at \(point)")
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 106, y: 26)))
        view.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 174, y: 94)))
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 174, y: 94)))
        XCTAssertTrue(selections.isEmpty, "Dragging from one sector to another must not reassign either key")
        XCTAssertEqual(presses, [.dpadUp, nil, nil])
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 106, y: 26)))
        XCTAssertTrue(selections.isEmpty, "A release without a matching press must not select a key")
    }

    private func click(_ point: NSPoint, in view: NSView, window: NSWindow) throws {
        let adjusted = NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let location = view.convert(adjusted, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    private func snapshot(window: NSWindow, popup: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["RC_HARNESS_UI_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windows = [window, popup]
        let views = [window.contentView!, popup.contentView!.superview ?? popup.contentView!]
        let frames = zip(windows, views).map { window, view in window.convertToScreen(view.convert(view.bounds, to: nil)) }
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        for (view, frame) in zip(views, frames) {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let part = NSImage(size: view.bounds.size)
            part.addRepresentation(bitmap)
            part.draw(in: frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func flushUI() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

}
