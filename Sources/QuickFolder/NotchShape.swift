import SwiftUI

/// A notch that grows out of the top edge of the screen: concave "ears" at the
/// top corners and soft convex corners at the bottom.
struct NotchShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set {
            earRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - ear * 2) / 2, rect.height - ear))

        // Control-point distance for a circular-ish cubic corner, pushed a bit
        // further out for the smoother "continuous" look Apple uses.
        let k: CGFloat = 0.62

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Left ear.
        path.addCurve(
            to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
            control1: CGPoint(x: rect.minX + ear * k, y: rect.minY),
            control2: CGPoint(x: rect.minX + ear, y: rect.minY + ear * (1 - k))
        )
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom))

        // Bottom-left corner.
        path.addCurve(
            to: CGPoint(x: rect.minX + ear + bottom, y: rect.maxY),
            control1: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom * (1 - k)),
            control2: CGPoint(x: rect.minX + ear + bottom * (1 - k), y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - ear - bottom, y: rect.maxY))

        // Bottom-right corner.
        path.addCurve(
            to: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom),
            control1: CGPoint(x: rect.maxX - ear - bottom * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom * (1 - k))
        )
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))

        // Right ear.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - ear, y: rect.minY + ear * (1 - k)),
            control2: CGPoint(x: rect.maxX - ear * k, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
