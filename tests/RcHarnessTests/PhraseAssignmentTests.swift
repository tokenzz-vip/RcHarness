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
        for input in PhraseAssignments.inputs {
            let shown = try await openPopover(input, in: host)
            XCTAssertGreaterThan(shown.window.frame.midX, shown.anchor.x,
                                 "The picker should open to the right when there is room")
            try await selectOption(at: NSPoint(x: 100, y: 103), in: shown)
        }
    }

    func testEveryAssignmentPopoverSearchesAndUpdatesOnlyItsOwnSlot() async throws {
        try await checkAssignmentPopovers(height: 650)
    }

    func testTallerWindowAssignmentPopoversFollowThePad() async throws {
        try await checkAssignmentPopovers(height: 850)
    }

    private func checkAssignmentPopovers(height: CGFloat) async throws {
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
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RC_HARNESS_UI_DARK"] == "1" ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        await flushUI()
        var expected = PhraseAssignments()
        for input in PhraseAssignments.inputs {
            let shown = try await openPopover(input, in: host)
            let popup = shown.window
            let editor = try XCTUnwrap(popup.firstResponder as? NSTextView, "The search field must receive keyboard focus")
            XCTAssertEqual(editor.string, "", "Opening another key must reset the previous query")
            editor.insertText("选条", replacementRange: NSRange(location: NSNotFound, length: 0))
            await flushUI()
            try snapshot(window: window, popup: popup, name: input.rawValue)
            try await selectOption(at: NSPoint(x: 100, y: 193), in: shown)
            expected[input] = model.phrases[1].id
            XCTAssertEqual(model.phraseAssignments, expected, "Search result must update only \(input.label)")
            try assertListMatchesModel(model, in: host)
        }
        let replacement = try await openPopover(.dpadUp, in: host)
        let replacementPopup = replacement.window
        let replacementEditor = try XCTUnwrap(replacementPopup.firstResponder as? NSTextView)
        replacementEditor.insertText("其他", replacementRange: NSRange(location: NSNotFound, length: 0))
        await flushUI()
        try await selectOption(at: NSPoint(x: 100, y: 193), in: replacement)
        expected[.dpadUp] = model.phrases[0].id
        XCTAssertEqual(model.phraseAssignments, expected)
        try assertListMatchesModel(model, in: host)
        let emptySearch = try await openPopover(.dpadRight, in: host)
        let popup = emptySearch.window
        let editor = try XCTUnwrap(popup.firstResponder as? NSTextView)
        editor.insertText("没有匹配的关键词", replacementRange: NSRange(location: NSNotFound, length: 0))
        await flushUI()
        try snapshot(window: window, popup: popup, name: "empty-search")
        try await selectOption(at: NSPoint(x: 100, y: 103), in: emptySearch)
        expected[.dpadRight] = nil
        XCTAssertEqual(model.phraseAssignments, expected, "Unassign must remain available when search has no matches")
        try assertListMatchesModel(model, in: host)
        for input in PhraseAssignments.inputs where expected[input] != nil {
            let shown = try await openPopover(input, in: host)
            try await selectOption(at: NSPoint(x: 100, y: 103), in: shown)
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

    private struct ShownPopover {
        let popover: NSPopover
        let window: NSWindow
        let anchor: NSPoint
    }

    @MainActor
    private final class PopoverPresentation {
        var popover: NSPopover?
    }

    /// Queue turns do not imply completed SwiftUI/AppKit presentation updates.
    /// Observe the actual lifecycle and retain exactly the picker that opened.
    private func openPopover(_ input: ControllerInput, in host: NSView) async throws -> ShownPopover {
        let presented = PopoverPresentation()
        let shown = expectation(forNotification: NSPopover.didShowNotification, object: nil) { notification in
            guard let popover = notification.object as? NSPopover else { return false }
            MainActor.assumeIsolated {
                presented.popover = popover
            }
            return true
        }
        let anchor = try clickPad(input, in: host)
        await fulfillment(of: [shown], timeout: 2)
        await flushUI()
        let popover = try XCTUnwrap(presented.popover, "Clicking \(input.label) must present the phrase selection popover")
        let popup = try XCTUnwrap(popover.contentViewController?.view.window)
        XCTAssertTrue(popover.isShown)
        return ShownPopover(popover: popover, window: popup, anchor: anchor)
    }

    private func selectOption(at point: NSPoint, in shown: ShownPopover) async throws {
        let closed = expectation(forNotification: NSPopover.didCloseNotification, object: shown.popover)
        try click(point, in: XCTUnwrap(shown.window.contentView), window: shown.window)
        await fulfillment(of: [closed], timeout: 2)
        await flushUI()
        XCTAssertFalse(shown.popover.isShown, "The picker must finish closing before another key is selected")
        XCTAssertFalse(shown.window.isVisible)
    }

    /// SwiftUI distributes the panel's spacers differently across window sizes
    /// and AppKit versions. Route through the laid-out native pointer surface.
    @discardableResult
    private func clickPad(_ input: ControllerInput, in host: NSView) throws -> NSPoint {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        let pad = try XCTUnwrap(descendants(host).compactMap { $0 as? PhrasePadInputView }.first)
        let window = try XCTUnwrap(pad.window)
        let position = PhrasePadLayout.position(for: input)
        let point = NSPoint(x: pad.bounds.minX + position.x * pad.bounds.width / 212,
                            y: pad.bounds.minY + position.y * pad.bounds.height / 212)
        let content = try XCTUnwrap(window.contentView)
        let hit = content.hitTest(pad.convert(point, to: content.superview))
        _ = try XCTUnwrap(hit === pad ? hit : nil,
                          "\(input.label) at \(point) must hit the actual pad; frame=\(pad.convert(pad.bounds, to: content))")
        let anchor = window.convertPoint(toScreen: pad.convert(point, to: nil))
        try clickInTestWindow(point, in: pad)
        return anchor
    }

    private func click(_ point: NSPoint, in view: NSView, window: NSWindow) throws {
        let adjusted = NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        XCTAssertTrue(view.window === window)
        try clickInTestWindow(adjusted, in: view)
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
