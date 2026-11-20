import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class MacrosEditorInteractionTests: XCTestCase {
    func testLocalClickPreservesPointerViewAboveNativeButton() throws {
        let fixture = try Fixture(stepCount: 1)
        defer { fixture.close() }
        let content = NSView(frame: fixture.host.bounds)
        let counter = ClickCounter()
        let button = NSButton(title: "Covered button", target: counter, action: #selector(ClickCounter.clicked))
        button.frame = content.bounds
        let pointer = ClickPointerView(frame: content.bounds)
        content.addSubview(button)
        content.addSubview(pointer)
        fixture.window.contentView = content

        try fixture.click(NSPoint(x: pointer.bounds.midX, y: pointer.bounds.midY), in: pointer)

        XCTAssertEqual(pointer.count, 1)
        XCTAssertEqual(counter.count, 0, "A button below the pointer surface must not steal the click")
    }

    @MainActor
    private final class ClickPointerView: NSView {
        var count = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { count += 1 }
    }

    func testLocalClickActivatesButtonCellControlExactlyOnce() throws {
        let fixture = try Fixture(stepCount: 1)
        defer { fixture.close() }
        let counter = ClickCounter()
        let control = NSControl()
        control.cell = NSButtonCell(textCell: "Native cell tracking")
        control.target = counter
        control.action = #selector(ClickCounter.clicked)
        fixture.window.contentView = control

        try fixture.click(NSPoint(x: control.bounds.midX, y: control.bounds.midY), in: control)

        XCTAssertEqual(counter.count, 1)
    }

    func testLocalClickActivatesNativeButtonExactlyOnce() throws {
        let fixture = try Fixture(stepCount: 1)
        defer { fixture.close() }
        let counter = ClickCounter()
        let button = NSButton(title: "Native tracking", target: counter, action: #selector(ClickCounter.clicked))
        button.setButtonType(.momentaryPushIn)
        fixture.window.contentView = button

        try fixture.click(NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)

        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    private final class ClickCounter: NSObject {
        var count = 0
        @objc func clicked() { count += 1 }
    }

    func testNarrowDarkEditorHandlesOneHundredMixedHeightSteps() async throws {
        let fixture = try Fixture(stepCount: 100, mixedHeights: true)
        defer { fixture.close() }
        fixture.window.appearance = NSAppearance(named: .darkAqua)
        fixture.window.setContentSize(NSSize(width: SettingsStyle.minimumWindowSize.width - SettingsStyle.sidebarWidth
                                            - 1 - SettingsStyle.pagePadding * 2,
                                            height: SettingsStyle.minimumWindowSize.height - SettingsStyle.pageHeaderHeight
                                            - SettingsStyle.pagePadding * 2))
        await fixture.settle()
        try await fixture.scrollToEnd()
        try fixture.clickAddStep()
        await fixture.settle()
        XCTAssertEqual(fixture.steps.count, 101)
        try fixture.assertLastStepVisible()
        let nameFrame = try fixture.nameField.convert(fixture.nameField.bounds, to: fixture.host)
        XCTAssertTrue(fixture.host.bounds.contains(nameFrame), "The fixed editor header must stay inside the narrow window")
        try fixture.snapshot("narrow-dark-long-editor")
    }

    func testSwitchingActionsDuringRecordingCancelsWithoutChangingEitherAction() async throws {
        let fixture = try Fixture(stepCount: 50)
        defer { fixture.close() }
        var steps = fixture.steps
        steps[0].mapping = ButtonMapping(action: .recordedShortcut)
        fixture.model.updateMacroSteps(steps, for: fixture.macroID)
        await fixture.settle()
        let other = fixture.model.macros[1]
        let field = try await fixture.startRecordingFirstStep()
        try fixture.send(field.session, .keyDown, code: 40, flags: .maskCommand)
        try fixture.clickMacroRow(1)
        await fixture.settle()
        XCTAssertFalse(field.session.isRecording)
        XCTAssertEqual(fixture.steps, steps)
        XCTAssertEqual(fixture.model.macros[1], other)
        XCTAssertEqual(try fixture.nameField.stringValue, other.name)
    }

    func testRecordingStopsWhenItsRowScrollsAwayAndCanRestart() async throws {
        #if arch(x86_64)
        // Temporarily quarantine this UI lifecycle test: the Intel CI runner
        // fails to realize CaptureField after scrolling (CI run 44001847886).
        // Keep the test enabled on ARM until the Intel runner failure is resolved.
        try XCTSkipIf(true, "Temporarily skipped on Intel: shortcut capture field is missing after scrolling")
        #endif
        let fixture = try Fixture(stepCount: 50)
        defer { fixture.close() }
        let original = RecordedShortcut(keyCode: 0, modifiers: 0, label: "A")
        var steps = fixture.steps
        steps[0].mapping = ButtonMapping(action: .recordedShortcut, shortcut: original)
        fixture.model.updateMacroSteps(steps, for: fixture.macroID)
        await fixture.settle()
        let field = try await fixture.startRecordingFirstStep()
        try fixture.send(field.session, .keyDown, code: 40, flags: .maskCommand)
        try await fixture.scrollToEnd()
        XCTAssertFalse(field.session.isRecording, "Scrolling away must cancel a partial recording")
        XCTAssertEqual(fixture.steps[0].mapping.shortcut, original)
        XCTAssertFalse(try fixture.send(field.session, .keyUp, code: 40), "Late releases must not revive a detached recording")
        try await fixture.scrollToStart()
        let next = try await fixture.startRecordingFirstStep()
        try fixture.send(next.session, .keyDown, code: 40, flags: .maskCommand)
        try fixture.send(next.session, .keyUp, code: 40, flags: .maskCommand)
        try fixture.send(next.session, .flagsChanged, code: 55)
        await fixture.settle()
        XCTAssertEqual(fixture.steps[0].mapping.shortcut?.keyCode, 40)
        XCTAssertEqual(fixture.steps[0].mapping.shortcut?.modifiers, CGEventFlags.maskCommand.rawValue)
        XCTAssertFalse(next.session.isRecording)
        XCTAssertEqual(Array(fixture.steps.dropFirst()), Array(steps.dropFirst()))
    }

    func testRemovingRecordingStepDiscardsItsQueuedCompletion() async throws {
        let fixture = try Fixture(stepCount: 50)
        defer { fixture.close() }
        var steps = fixture.steps
        steps[0].mapping = ButtonMapping(action: .recordedShortcut)
        fixture.model.updateMacroSteps(steps, for: fixture.macroID)
        await fixture.settle()
        let field = try await fixture.startRecordingFirstStep()
        try fixture.send(field.session, .keyDown, code: 40, flags: .maskCommand)
        try fixture.send(field.session, .keyUp, code: 40, flags: .maskCommand)
        try fixture.send(field.session, .flagsChanged, code: 55)
        // Complete the native recording, then remove its row before the deferred callback is delivered.
        fixture.model.updateMacroSteps(Array(steps.dropFirst()), for: fixture.macroID)
        fixture.host.layoutSubtreeIfNeeded()
        await fixture.settle()
        XCTAssertFalse(field.session.isRecording)
        XCTAssertEqual(fixture.steps, Array(steps.dropFirst()), "A queued capture must not overwrite the next row's binding")
    }

    func testMixedHeightRowsKeepTheirBindingsAfterOffscreenAndVisibleDeletions() async throws {
        let fixture = try Fixture(stepCount: 50, mixedHeights: true)
        defer { fixture.close() }
        let original = fixture.steps
        try await fixture.scrollToEnd()
        fixture.model.updateMacroSteps(Array(original.dropFirst()), for: fixture.macroID)
        await fixture.settle()
        try await fixture.scrollToEnd()
        try await fixture.disableLastVisibleStep()
        XCTAssertEqual(fixture.steps.last?.id, original.last?.id)
        XCTAssertEqual(fixture.steps.last?.mapping.action, .disabled)
        XCTAssertEqual(Array(fixture.steps.dropLast()), Array(original.dropFirst().dropLast()),
                       "Editing after an offscreen deletion must preserve every other step")
        try await fixture.scrollToEnd()
        try fixture.clickRemoveLastStep()
        await fixture.settle()
        XCTAssertEqual(fixture.steps, Array(original.dropFirst().dropLast()))
        try await fixture.scrollToEnd()
        try fixture.clickAddStep()
        await fixture.settle()
        XCTAssertEqual(fixture.steps.count, original.count - 1)
        XCTAssertEqual(fixture.steps.last?.mapping.action, .enter)
        try fixture.assertLastStepVisible()
        fixture.model.flushPendingWrites()
        XCTAssertEqual(SettingsStorage.load([SavedMacro].self, SettingsKeys.Stored.macros, defaults: fixture.defaults),
                       fixture.model.macros, "The edited visible rows must persist against their original IDs")
        try fixture.snapshot("mixed-height-after-edits")
    }

    func testSwitchingActionsResetsScrollAndRemovingAllStepsAllowsAddingAgain() async throws {
        let fixture = try Fixture(stepCount: 50)
        defer { fixture.close() }
        try await fixture.scrollToEnd()
        try fixture.clickMacroRow(1)
        await fixture.settle()
        XCTAssertEqual(try fixture.nameField.stringValue, fixture.model.macros[1].name)
        XCTAssertEqual(try fixture.editor.contentView.bounds.minY, 0, accuracy: 1)
        try fixture.clickMacroRow(0)
        await fixture.settle()
        XCTAssertEqual(try fixture.nameField.stringValue, fixture.model.macros[0].name)
        XCTAssertEqual(try fixture.editor.contentView.bounds.minY, 0, accuracy: 1)
        fixture.model.updateMacroSteps([], for: fixture.macroID)
        await fixture.settle()
        XCTAssertTrue(try fixture.visibleActionControls.isEmpty)
        try fixture.clickAddStep()
        await fixture.settle()
        XCTAssertEqual(fixture.steps.count, 1)
        XCTAssertEqual(try fixture.visibleActionControls.count, 1)
        fixture.model.deleteMacro(fixture.macroID)
        await fixture.settle()
        XCTAssertEqual(try fixture.nameField.stringValue, fixture.model.macros[0].name)
        XCTAssertEqual(try fixture.editor.contentView.bounds.minY, 0, accuracy: 1)
    }

    func testConsecutiveAdditionsKeepTheLastStepAndAddButtonVisible() async throws {
        let fixture = try Fixture(stepCount: 50)
        defer { fixture.close() }
        try await fixture.scrollToEnd()
        for _ in 0..<3 {
            let count = fixture.steps.count
            try fixture.clickAddStep()
            await fixture.settle()
            XCTAssertEqual(fixture.steps.count, count + 1)
            try fixture.assertLastStepVisible()
        }
    }

    func testLongEditorOnlyCreatesNearbyActionControls() throws {
        let fixture = try Fixture(stepCount: 50)
        defer { fixture.close() }
        let controls = fixture.actionControls
        XCTAssertFalse(controls.isEmpty)
        XCTAssertLessThan(controls.count, 25,
                          "Opening a long action must not create native controls for every offscreen step")
    }

    func testAddedStepStaysVisibleWhenEditorHeightChanges() async throws {
        let fixture = try Fixture(stepCount: 50, mixedHeights: true)
        defer { fixture.close() }
        try await fixture.scrollToEnd()
        try fixture.clickAddStep()
        await fixture.settle()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: NSScrollView())
        let originalViewportHeight = try fixture.editor.contentView.bounds.height
        fixture.window.setContentSize(NSSize(width: 960, height: 490))
        await fixture.settle()
        XCTAssertEqual(fixture.steps.count, 51)
        // The footer is eager, but SwiftUI can realize the last row in a later layout pass.
        let lastStepVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard let editor = try? fixture.editor, editor.contentView.bounds.height < originalViewportHeight,
                      let controls = try? fixture.visibleActionControls else { return false }
                return controls.contains { $0.accessibilityValue() as? String == RemoteAction.enter.label }
            }
        }, object: nil)
        lastStepVisible.expectationDescription = "The newly added Enter step is visible in the resized editor"
        await fulfillment(of: [lastStepVisible], timeout: 2)
        try fixture.assertLastStepVisible()
        try fixture.snapshot("added-step-after-resize")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                        object: try fixture.editor)
        try await fixture.scrollToStart()
        XCTAssertEqual(try fixture.editor.contentView.bounds.minY, 0, accuracy: 1,
                       "Manual scrolling must release the bottom anchor")
        try await fixture.scrollToEnd()
        try fixture.clickAddStep()
        await fixture.settle()
        XCTAssertEqual(fixture.steps.count, 52)
        try fixture.assertLastStepVisible()
    }

    @MainActor
    private final class TestWindow: NSWindow {
        var localRecordingFocus = false
        override var isKeyWindow: Bool { localRecordingFocus || super.isKeyWindow }
    }

    @MainActor
    private final class Fixture {
        let suite = "RcHarness.MacrosEditorInteraction." + UUID().uuidString
        let defaults: UserDefaults
        let model: RemoteDashboardModel
        let macroID: UUID
        let host: NSHostingView<MacrosPage>
        let window: TestWindow
        private var focusMethod: Method?
        private var originalFocusImplementation: IMP?
        private var localFocusImplementation: IMP?

        init(stepCount: Int, mixedHeights: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            macroID = try XCTUnwrap(model.macros.first?.id)
            let childID = model.macros[1].id
            model.updateMacroSteps((0..<stepCount).map { index in
                var step = MacroStep()
                if mixedHeights {
                    switch index % 5 {
                    case 1: step.mapping = ButtonMapping(action: .rapidDelete)
                    case 2: step.mapping = ButtonMapping(action: .recordedShortcut,
                        shortcut: RecordedShortcut(keyCode: 40, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘K"))
                    case 3: step.mapping = ButtonMapping(action: .macro, referenceID: childID.uuidString)
                    case 4: step.mapping = ButtonMapping(action: .openApplication, applicationPath: "/Applications/Utilities/Terminal.app")
                    default: step.mapping = ButtonMapping(action: .escape)
                    }
                }
                return step
            }, for: macroID)
            model.flushPendingWrites()
            host = NSHostingView(rootView: MacrosPage(model: model, actionFilter: .constant(.all)))
            window = TestWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
        }

        var actionControls: [NSButton] {
            testViewHierarchy(host).compactMap { $0 as? NSButton }.filter {
                $0.identifier?.rawValue == "mapping-action-picker"
            }
        }

        var steps: [MacroStep] { model.macros.first { $0.id == macroID }?.steps ?? [] }

        var visibleActionControls: [NSButton] {
            get throws {
                let scroll = try editor
                return actionControls.filter {
                    !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds)
                }
            }
        }

        var nameField: NSTextField {
            get throws {
                try XCTUnwrap(testViewHierarchy(host).compactMap { $0 as? NSTextField }.first {
                    $0.placeholderString == "组合动作名称"
                })
            }
        }

        var editor: NSScrollView {
            get throws {
                try XCTUnwrap(testViewHierarchy(host).compactMap { $0 as? NSScrollView }.max {
                    $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
                })
            }
        }

        func settle() async {
            for _ in 0..<6 {
                // Process local AppKit events alongside the SwiftUI transactions.
                while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await drainMainQueue()
            }
            host.layoutSubtreeIfNeeded()
        }

        func scrollToEnd() async throws {
            let scroll = try editor
            // Lazy content refines its estimated height as the last rows are realized.
            for _ in 0..<3 {
                let document = try XCTUnwrap(scroll.documentView)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.maxY - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                await settle()
            }
        }

        func scrollToStart() async throws {
            let scroll = try editor
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle()
        }

        func startRecordingFirstStep() async throws -> ShortcutCapture.CaptureField {
            // These tests exercise real SwiftUI row/capture lifetimes with injected foreground state.
            // They must not depend on taking focus from the developer's active application.
            if originalFocusImplementation == nil {
                let method = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)))
                let focused: @convention(block) (AnyObject) -> Bool = { _ in true }
                let implementation = imp_implementationWithBlock(focused)
                focusMethod = method
                localFocusImplementation = implementation
                originalFocusImplementation = method_setImplementation(method, implementation)
            }
            window.localRecordingFocus = true
            await settle()
            let control = try XCTUnwrap(visibleActionControls.min {
                $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY
            })
            let frame = control.convert(control.bounds, to: host)
            if let recordButton = testViewHierarchy(host).compactMap({ $0 as? NSButton }).first(where: {
                $0.title == "录制快捷键" && !$0.isHiddenOrHasHiddenAncestor
            }) {
                // SwiftUI may place the native button a few points differently
                // on Intel after lazy row realization. Invoke the same AppKit
                // action on the discovered control instead of relying on a
                // coordinate offset from the action picker.
                recordButton.performClick(nil)
            } else {
                try click(NSPoint(x: frame.maxX - 54, y: host.isFlipped ? frame.maxY + 24 : frame.minY - 24), in: host)
            }
            // SwiftUI may need several layout turns to realize the native capture
            // field after the row's action changes state. Intel runners are slower
            // here than Apple Silicon, so wait for the actual view instead of using
            // one fixed settle window.
            var field: ShortcutCapture.CaptureField?
            for _ in 0..<8 {
                await settle()
                field = testViewHierarchy(host).compactMap { $0 as? ShortcutCapture.CaptureField }.first
                if field != nil { break }
            }
            let capturedField = try XCTUnwrap(field,
                                              "active=\(NSApp.isActive), key=\(window.isKeyWindow), control=\(frame), flipped=\(host.isFlipped)")
            XCTAssertTrue(capturedField.session.isRecording)
            return capturedField
        }

        @discardableResult
        func send(_ session: ShortcutRecordingSession, _ type: CGEventType, code: UInt16, flags: CGEventFlags = []) throws -> Bool {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown))
            event.type = type
            event.flags = flags
            // Deliver only to the local test session; never post synthetic keyboard events.
            return session.handle(type, event: event)
        }

        func assertLastStepVisible(file: StaticString = #filePath, line: UInt = #line) throws {
            let scroll = try editor
            let controls = actionControls.filter {
                $0.convert($0.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds)
            }
            XCTAssertFalse(controls.isEmpty, file: file, line: line)
            let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
            let button = try addStepFrame
            XCTAssertTrue(viewport.insetBy(dx: -2, dy: -2).contains(button),
                          "Add button \(button) must stay inside viewport \(viewport)", file: file, line: line)
        }

        func clickAddStep() throws {
            let frame = try addStepFrame
            let scroll = try editor
            let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: host)
            _ = try XCTUnwrap(!frame.isEmpty && viewport.insetBy(dx: -2, dy: -2).contains(frame) ? frame : nil,
                              "Add button \(frame) must be visible inside viewport \(viewport) before clicking")
            try click(NSPoint(x: frame.midX, y: frame.midY), in: host)
        }

        var addStepFrame: NSRect {
            get throws {
                let anchor = try XCTUnwrap(testViewHierarchy(host).first {
                    $0.identifier?.rawValue == "macro-add-step"
                })
                return anchor.convert(anchor.bounds, to: host)
            }
        }

        func clickRemoveLastStep() throws {
            let control = try lastVisibleActionControl()
            let frame = control.convert(control.bounds, to: host)
            try click(NSPoint(x: frame.maxX - 7, y: host.isFlipped ? frame.minY - 20 : frame.maxY + 20), in: host)
        }

        func lastVisibleActionControl() throws -> NSButton {
            let scroll = try editor
            return try XCTUnwrap(actionControls.filter {
                $0.convert($0.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds)
            }.max { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY })
        }

        func disableLastVisibleStep() async throws {
            let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            try lastVisibleActionControl().performClick(nil)
            await settle()
            let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) })
            let content = try XCTUnwrap(popup.contentView)
            // Disabled is the first row of every action category.
            let point = NSPoint(x: 70, y: content.isFlipped ? 18 : content.bounds.height - 18)
            try click(point, in: content)
            await settle()
            XCTAssertFalse(popup.isVisible)
        }

        func clickMacroRow(_ index: Int) throws {
            let list = try XCTUnwrap(testViewHierarchy(host).compactMap { $0 as? NSScrollView }.min {
                $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
            })
            let clip = list.contentView
            try click(NSPoint(x: clip.bounds.minX + 36,
                              y: clip.isFlipped ? clip.bounds.minY + 30 + CGFloat(index) * 64
                                                : clip.bounds.maxY - 30 - CGFloat(index) * 64), in: clip)
        }

        func snapshot(_ name: String) throws {
            guard let folder = ProcessInfo.processInfo.environment["RC_HARNESS_UI_SNAPSHOTS"] else { return }
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.lockFocus()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.controlBackgroundColor.setFill()
                NSRect(origin: .zero, size: host.bounds.size).fill()
            }
            NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size).draw(in: NSRect(origin: .zero, size: host.bounds.size))
            image.unlockFocus()
            let rendered = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }

        func click(_ point: NSPoint, in view: NSView) throws {
            try clickInTestWindow(point, in: view)
        }

        func close() {
            window.close()
            if let focusMethod, let originalFocusImplementation {
                method_setImplementation(focusMethod, originalFocusImplementation)
            }
            if let localFocusImplementation { imp_removeBlock(localFocusImplementation) }
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
