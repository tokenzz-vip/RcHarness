import AppKit
import SwiftUI

/// Own pointer routing once for the whole pad. The four visual sector buttons
/// overlap in their rectangular bounds; native hit testing must use their paths.
@MainActor
struct PhrasePadInputSurface: NSViewRepresentable {
    let onSelect: (ControllerInput) -> Void
    let onHover: (ControllerInput?) -> Void
    let onPress: (ControllerInput?) -> Void

    func makeNSView(context: Context) -> PhrasePadInputView {
        let view = PhrasePadInputView()
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PhrasePadInputView, context: Context) {
        view.onSelect = onSelect
        view.onHover = onHover
        view.onPress = onPress
    }
}

@MainActor
final class PhrasePadInputView: NSView {
    var onSelect: ((ControllerInput) -> Void)?
    var onHover: ((ControllerInput?) -> Void)?
    var onPress: ((ControllerInput?) -> Void)?
    private var downInput: ControllerInput?
    private var padTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, PhrasePadLayout.input(at: convert(point, from: superview), in: bounds) != nil else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let padTrackingArea { removeTrackingArea(padTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        padTrackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        downInput = input(for: event)
        onPress?(downInput)
    }

    override func mouseDragged(with event: NSEvent) {
        onPress?(input(for: event) == downInput ? downInput : nil)
    }

    override func mouseUp(with event: NSEvent) {
        let selected = downInput
        downInput = nil
        onPress?(nil)
        guard let selected, selected == input(for: event) else { return }
        onSelect?(selected)
    }

    override func mouseEntered(with event: NSEvent) { onHover?(input(for: event)) }
    override func mouseMoved(with event: NSEvent) { onHover?(input(for: event)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { downInput = nil }
    }

    private func input(for event: NSEvent) -> ControllerInput? {
        PhrasePadLayout.input(at: convert(event.locationInWindow, from: nil), in: bounds)
    }
}
