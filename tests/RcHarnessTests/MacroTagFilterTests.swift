import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class MacroTagFilterTests: XCTestCase {
    func testDropdownOpensBelowAndSupportsConsecutiveSelectionsAndClear() async throws {
        _ = NSApplication.shared
        let suite = "RcHarness.MacroTagFilterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.page = .macros
        let controller = DashboardWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RC_HARNESS_UI_DARK"] == "1" ? .darkAqua : .aqua)
        window.setContentSize(SettingsStyle.minimumWindowSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        await flushUI()
        let button = try XCTUnwrap(testViewHierarchy(host).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "macro-tag-filter"
        })
        let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        button.performClick(nil)
        await flushUI()
        let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
        defer { button.performClick(nil) }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        XCTAssertLessThanOrEqual(popup.frame.maxY, anchor.minY + 2)
        XCTAssertEqual(popup.frame.midX, anchor.midX, accuracy: 2,
                       "popup=\(popup.frame), anchor=\(anchor), screen=\(window.screen?.visibleFrame ?? .zero)")
        let content = try XCTUnwrap(popup.contentView)

        // 4 pt inset, 28 pt reset row, 9 pt separator, then uniform 28 pt tag rows.
        try click(NSPoint(x: 60, y: 83), in: content, window: popup) // ChatGPT
        await flushUI()
        XCTAssertTrue(popup.isVisible)
        XCTAssertEqual(button.accessibilityValue() as? String, "ChatGPT")
        try click(NSPoint(x: 60, y: 139), in: content, window: popup) // Cursor
        await flushUI()
        XCTAssertTrue(popup.isVisible)
        XCTAssertEqual(button.accessibilityValue() as? String, "ChatGPT、Cursor")
        try snapshot(window: window, popup: popup)

        try click(NSPoint(x: 60, y: 83), in: content, window: popup)
        await flushUI()
        XCTAssertEqual(button.accessibilityValue() as? String, "Cursor")
        try click(NSPoint(x: 60, y: 18), in: content, window: popup)
        await flushUI()
        XCTAssertEqual(button.accessibilityValue() as? String, "全部标签")
        XCTAssertTrue(popup.isVisible)
    }

    func testKeyboardPickerStaysCenteredInTheMappingWindowAndKeepsItsDraft() async throws {
        #if arch(x86_64)
        try XCTSkipIf(true, "Intel CI crashes in the SwiftUI keyboard picker renderer (MTLLoader assertion)")
        #endif
        let suite = "RcHarness.KeyboardPickerSheetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let original = RecordedShortcut(keyCode: 40, modifiers: 0x0010_0000, label: "⌘K")
        model.update(ButtonMapping(action: .recordedShortcut, shortcut: original), for: .buttonY, trigger: .long)
        let controller = DashboardWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(SettingsStyle.minimumWindowSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        model.openButtonEditor(.buttonY, trigger: .long)
        await flushUI()

        let host = try XCTUnwrap(window.contentView)
        let action = try XCTUnwrap(testViewHierarchy(host).first { $0.identifier?.rawValue == "mapping-action-picker" })
        let frame = action.convert(action.bounds, to: host)
        let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        let scrollViewsBefore = Set(testViewHierarchy(host).compactMap { $0 as? NSScrollView })
        let windowFrame = window.frame
        try click(NSPoint(x: frame.maxX - 129, y: host.isFlipped ? frame.maxY + 24 : host.bounds.height - frame.minY + 24),
                  in: host, window: window)
        await flushUI()

        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), windowsBefore)
        XCTAssertEqual(window.frame, windowFrame)
        XCTAssertNil(window.attachedSheet)
        try snapshot(window: window, name: "shortcut-keyboard-in-mapping-window")
        XCTAssertTrue(testViewHierarchy(host).compactMap { $0 as? NSScrollView }.allSatisfy(scrollViewsBefore.contains))
        XCTAssertFalse(testViewHierarchy(host).contains { $0.identifier?.rawValue == "mapping-action-picker" })
        let verticalCenter = host.bounds.midY + (host.safeAreaInsets.top - host.safeAreaInsets.bottom) / 2
        try click(NSPoint(x: host.bounds.midX + ShortcutKeyboardPicker.preferredWidth / 2 - 55,
                          y: verticalCenter + ShortcutKeyboardPicker.preferredHeight / 2 - 22), in: host, window: window)
        await flushUI()
        XCTAssertTrue(model.editorVisible)
        XCTAssertTrue(testViewHierarchy(host).contains { $0.identifier?.rawValue == "mapping-action-picker" })
        XCTAssertEqual(model.effectiveMapping[.buttonY, .long].shortcut, original)
    }

    func testMappingMacroPickerOpensBelowScrollsAndClosesAfterSingleSelection() async throws {
        _ = NSApplication.shared
        let suite = "RcHarness.MappingMacroPopoverTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.openButtonEditor(.buttonY, trigger: .long)
        let original = try XCTUnwrap(model.macros.first)
        model.update(ButtonMapping(action: .macro, referenceID: original.id.uuidString), for: .buttonY, trigger: .long)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RC_HARNESS_UI_DARK"] == "1" ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: MappingEditorSheet(model: model, actionFilter: .constant(.all)).id(UUID()))
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        await flushUI()
        let buttons = testViewHierarchy(host).compactMap { $0 as? NSButton }
        let tagButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "macro-tag-filter" })
        let macroButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "macro-reference-picker" })
        let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        tagButton.performClick(nil)
        await flushUI()
        let tags = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
        let tagContent = try XCTUnwrap(tags.contentView)
        try click(NSPoint(x: 60, y: 83), in: tagContent, window: tags)
        await flushUI()
        try click(NSPoint(x: 60, y: 139), in: tagContent, window: tags)
        await flushUI()
        XCTAssertTrue(tags.isVisible)
        XCTAssertEqual(tagButton.accessibilityValue() as? String, "ChatGPT、Cursor")
        XCTAssertEqual(model.effectiveMapping[.buttonY, .long].referenceID, original.id.uuidString)
        tagButton.performClick(nil)
        await flushUI()

        macroButton.performClick(nil)
        await flushUI()
        let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
        let anchor = window.convertToScreen(macroButton.convert(macroButton.bounds, to: nil))
        XCTAssertLessThanOrEqual(popup.frame.maxY, anchor.minY + 2)
        XCTAssertEqual(popup.frame.midX, anchor.midX, accuracy: 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(popup.contentView).bounds.height, 320,
                                 "Long macro lists must scroll inside the popover")
        try capturePopup(popup, filename: "mapping-macro-picker-window.png")
        let content = try XCTUnwrap(popup.contentView)
        let expected = model.macros.filter { !$0.tagIDs.isDisjoint(with: ["chatgpt", "cursor"]) }[1]
        try click(NSPoint(x: 90, y: 83), in: content, window: popup)
        await flushUI()
        XCTAssertFalse(popup.isVisible)
        XCTAssertEqual(model.effectiveMapping[.buttonY, .long].referenceID, original.id.uuidString,
                       "Selecting a macro only changes the draft")
        XCTAssertEqual(macroButton.accessibilityValue() as? String, expected.name)
        XCTAssertEqual(tagButton.accessibilityValue() as? String, "ChatGPT、Cursor")

        try clickEditorButton("mapping-editor-cancel", in: host)
        await flushUI()
        XCTAssertFalse(model.editorVisible)
        XCTAssertEqual(model.effectiveMapping[.buttonY, .long].referenceID, original.id.uuidString)
        let last = try XCTUnwrap(model.macros.last { !$0.tagIDs.isDisjoint(with: ["chatgpt", "cursor"]) })
        model.update(ButtonMapping(action: .macro, referenceID: last.id.uuidString), for: .buttonY, trigger: .long)
        host.rootView = MappingEditorSheet(model: model, actionFilter: .constant(.all)).id(UUID())
        await flushUI()
        let lastMacroButton = try XCTUnwrap(testViewHierarchy(host).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "macro-reference-picker"
        })
        lastMacroButton.performClick(nil)
        await flushUI()
        let reopened = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
        let reopenedContent = try XCTUnwrap(reopened.contentView)
        try click(NSPoint(x: 90, y: reopenedContent.bounds.height - 18), in: reopenedContent, window: reopened)
        await flushUI()
        XCTAssertFalse(reopened.isVisible)
        XCTAssertEqual(model.effectiveMapping[.buttonY, .long].referenceID, last.id.uuidString,
                       "Reopening must scroll the current selection into view, including the last action")
    }

    func testActionDropdownOpensBelowForLongAndShortCategoriesAndPreservesExistingConfiguration() async throws {
        _ = NSApplication.shared
        let suite = "RcHarness.ActionPopoverTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.selectedInput = .buttonY
        model.selectedTrigger = .long
        let original = ButtonMapping(action: .openApplication, applicationPath: "/Applications/Dictionary.app")
        var heights: [CGFloat] = []
        for filter in [ActionFilter.all, .system, .custom] {
            model.openButtonEditor(.buttonY, trigger: .long)
            model.update(original, for: .buttonY, trigger: .long)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RC_HARNESS_UI_DARK"] == "1" ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: MappingEditorSheet(model: model, actionFilter: .constant(filter)))
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            await flushUI()
            let button = try XCTUnwrap(testViewHierarchy(host).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "mapping-action-picker"
            })
            let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            button.performClick(nil)
            await flushUI()
            let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
            let content = try XCTUnwrap(popup.contentView)
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            XCTAssertLessThanOrEqual(popup.frame.maxY, anchor.minY + 2)
            XCTAssertEqual(popup.frame.midX, anchor.midX, accuracy: 2)
            XCTAssertEqual(content.bounds.width, anchor.width, accuracy: 1)
            XCTAssertLessThanOrEqual(content.bounds.height, 320)
            heights.append(content.bounds.height)
            let category = filter == .system ? "system" : filter == .custom ? "custom" : "all"
            try capturePopup(popup, filename: "mapping-action-\(category)-window.png")

            // Disabled stays first, including when the current action is outside the category.
            let currentRow = filter == .system ? 1 : 2
            try click(NSPoint(x: 90, y: CGFloat(18 + currentRow * 28)), in: content, window: popup)
            await flushUI()
            XCTAssertFalse(popup.isVisible)
            XCTAssertEqual(model.effectiveMapping[.buttonY, .long], original,
                           "Choosing the current action must preserve its application path")
            button.performClick(nil)
            await flushUI()
            let reopened = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
            let nextRow = filter == .system ? 2 : filter == .custom ? 4 : 1
            try click(NSPoint(x: 90, y: CGFloat(18 + nextRow * 28)),
                      in: XCTUnwrap(reopened.contentView), window: reopened)
            await flushUI()
            XCTAssertFalse(reopened.isVisible)
            XCTAssertEqual(model.effectiveMapping[.buttonY, .long], original,
                           "Changing the action must not update the live configuration before Save")
            button.performClick(nil)
            await flushUI()
            let reset = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
            try click(NSPoint(x: 90, y: 18), in: XCTUnwrap(reset.contentView), window: reset)
            await flushUI()
            XCTAssertFalse(reset.isVisible)
            XCTAssertEqual(model.effectiveMapping[.buttonY, .long], original)
            try clickEditorButton("mapping-editor-save", in: host)
            await flushUI()
            XCTAssertFalse(model.editorVisible)
            XCTAssertEqual(model.effectiveMapping[.buttonY, .long].action, .disabled,
                           "Save commits the draft; Disabled is the first option in every category")
            XCTAssertNil(model.effectiveMapping[.buttonY, .long].applicationPath)
            XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults)
                .effectiveMapping[.buttonY, .long].action, .disabled)
        }
        XCTAssertGreaterThan(heights[0], try XCTUnwrap(heights.last), "Long lists scroll while short lists use their natural height")
    }

    private func clickEditorButton(_ identifier: String, in host: NSView) throws {
        let window = try XCTUnwrap(host.window)
        let trailingInset: CGFloat = identifier == "mapping-editor-save" ? 46 : 112
        try click(NSPoint(x: host.bounds.width - trailingInset, y: host.bounds.height - 26),
                  in: host, window: window)
    }

    private func capturePopup(_ popup: NSWindow, filename: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["RC_HARNESS_UI_SNAPSHOTS"],
              ProcessInfo.processInfo.environment["RC_HARNESS_UI_CAPTURE_WINDOW"] == "1" else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(popup.windowNumber),
                             directory.appendingPathComponent(filename).path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }

    private func click(_ point: NSPoint, in view: NSView, window: NSWindow) throws {
        let adjusted = NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        XCTAssertTrue(view.window === window)
        try clickInTestWindow(adjusted, in: view)
    }

    private func snapshot(window: NSWindow, popup: NSWindow? = nil, name: String = "macro-tag-filter") throws {
        guard let folder = ProcessInfo.processInfo.environment["RC_HARNESS_UI_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["RC_HARNESS_UI_CAPTURE_WINDOW"] == "1" {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String((popup ?? window).windowNumber),
                                 directory.appendingPathComponent("\(name)-window.png").path]
            try capture.run()
            capture.waitUntilExit()
        }
        let windows = [window] + [popup].compactMap { $0 }
        let views = windows.map { $0.contentView! }
        let frames = zip(windows, views).map { window, view in
            window.convertToScreen(view.convert(view.bounds, to: nil))
        }
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
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
