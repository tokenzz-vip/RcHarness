import AppKit

enum MenuBarIcon {
    // Draw at menu-bar scale: a remote controlling an AI prompt bubble.
    // Template rendering follows the menu bar's light, dark and selected states.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 12, width: 13, height: 10), xRadius: 3, yRadius: 3).fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 11, y: 14))
            tail.line(to: NSPoint(x: 10, y: 10))
            tail.line(to: NSPoint(x: 15, y: 14))
            tail.close()
            tail.fill()

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: 14, y: 19))
            prompt.line(to: NSPoint(x: 16, y: 17))
            prompt.line(to: NSPoint(x: 14, y: 15))
            prompt.move(to: NSPoint(x: 18.5, y: 15))
            prompt.line(to: NSPoint(x: 20.5, y: 15))
            prompt.lineWidth = 1.4
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.stroke()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 8, yBy: 9)
            transform.rotate(byDegrees: -24)
            transform.concat()
            let remote = NSBezierPath(roundedRect: NSRect(x: -3.8, y: -8, width: 7.6, height: 16), xRadius: 3.8, yRadius: 3.8)
            NSGraphicsContext.current?.compositingOperation = .clear
            remote.lineWidth = 1.8
            remote.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            remote.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: -2.3, y: 1.2, width: 4.6, height: 4.6)).fill()
            for y in [-2.0, -5.0] {
                NSBezierPath(roundedRect: NSRect(x: -1.4, y: y, width: 2.8, height: 1.2), xRadius: 0.6, yRadius: 0.6).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: -0.7, y: 2.8, width: 1.4, height: 1.4)).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.black.setStroke()
            let signal = NSBezierPath()
            signal.move(to: NSPoint(x: 3, y: 20))
            signal.curve(to: NSPoint(x: 8, y: 18.5), controlPoint1: NSPoint(x: 5, y: 20.5), controlPoint2: NSPoint(x: 7, y: 19.5))
            signal.lineWidth = 1.4
            signal.lineCapStyle = .round
            signal.stroke()
            return true
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
