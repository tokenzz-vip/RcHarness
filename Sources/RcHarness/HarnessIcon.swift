import SwiftUI

/// Shared with JoyHarness: three tiles and a sparkle on a 24-point grid.
struct HarnessIcon: View {
    var size: CGFloat = 24

    var body: some View {
        HarnessIconShape()
            .stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct HarnessIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for origin in [CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 14), CGPoint(x: 14, y: 14)] {
            path.addRoundedRect(in: CGRect(origin: origin, size: CGSize(width: 8, height: 8)),
                                cornerSize: CGSize(width: 2, height: 2))
        }
        path.move(to: CGPoint(x: 18, y: 2))
        path.addCurve(to: CGPoint(x: 23, y: 7), control1: CGPoint(x: 19, y: 5), control2: CGPoint(x: 20, y: 6))
        path.addCurve(to: CGPoint(x: 18, y: 12), control1: CGPoint(x: 20, y: 8), control2: CGPoint(x: 19, y: 9))
        path.addCurve(to: CGPoint(x: 13, y: 7), control1: CGPoint(x: 17, y: 9), control2: CGPoint(x: 16, y: 8))
        path.addCurve(to: CGPoint(x: 18, y: 2), control1: CGPoint(x: 16, y: 6), control2: CGPoint(x: 17, y: 5))
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 24, b: 0, c: 0, d: rect.height / 24,
                                             tx: rect.minX, ty: rect.minY))
    }
}
