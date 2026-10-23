import SwiftUI

// Why the next two are settings and not automatic: on macOS 27 the menu bar is one Window Server window
// and there are no per-item status windows any more, so the free space beside the notch can't be
// measured without extra permissions. The apps never move or hide other apps' menu bar items and ask
// for no Accessibility or Screen Recording permission (a product decision), so the user picks.

/// How the pill looks when the notch is ours (no neighbor) and it shows something below the notch.
/// Raw values are stored in the apps' preferences: never rename them.
public enum NotchPillShape: String, Codable, CaseIterable, Sendable {
    /// One wide black shape from the top edge, content-wide all the way up through the menu bar.
    case grow
    /// "Keep the menu bar clear": notch-wide inside the menu bar, flaring out to content width below it,
    /// so nothing in the menu bar is covered.
    case clearMenuBar
}

/// Where the quiet indicator goes when the notch is ours. Raw values are stored in the apps' preferences.
public enum NotchIndicatorPosition: String, Codable, CaseIterable, Sendable {
    /// A status dot and a level meter on either side of the notch.
    case besideNotch
    /// A slim glowing line just under the notch.
    case underNotch
}

/// A shape that hangs from the top of the screen like the notch: small outward flares where it
/// meets the bezel, rounded corners at the bottom.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        NotchOutline(topRadius: topRadius, bottomRadius: bottomRadius, neckWidth: rect.width, neckDepth: 0).path(in: rect)
    }
}

/// The pill attached to the notch. With a neck narrower than the shape, the top `neckDepth` points stay
/// exactly `neckWidth` wide and centred (the notch), then smooth shoulders flare out to the full width:
/// "Keep the menu bar clear". With a neck as wide as the shape it's the plain notch shape.
public struct NotchOutline: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    public var neckWidth: CGFloat
    public var neckDepth: CGFloat
    /// The concave curve where the neck meets the body.
    public static let shoulder: CGFloat = 10
    /// The body's rounded top corners.
    public static let corner: CGFloat = 14

    public init(topRadius: CGFloat, bottomRadius: CGFloat, neckWidth: CGFloat, neckDepth: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.neckWidth = neckWidth
        self.neckDepth = neckDepth
    }

    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), AnimatablePair(neckWidth, neckDepth)) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            neckWidth = newValue.second.first
            neckDepth = newValue.second.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let inset = (rect.width - neckWidth) / 2
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        var path = Path()
        guard inset > 0.5, neckDepth > 0 else {
            // The plain notch shape: flares at the top, straight sides, rounded bottom.
            let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
            path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
            path.closeSubpath()
            return path
        }
        let depth = min(neckDepth, rect.height)
        let s = min(Self.shoulder, inset / 2, max(0, rect.height - depth))
        let shoulderY = rect.minY + depth + s
        let r = min(Self.corner, inset - s, max(0, rect.maxY - shoulderY) / 2)
        let b = max(0, min(bottomRadius, rect.width / 2, rect.maxY - shoulderY - r))
        let left = rect.minX + inset, right = rect.maxX - inset
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + depth))
        path.addQuadCurve(to: CGPoint(x: left - s, y: shoulderY), control: CGPoint(x: left, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: shoulderY + r), control: CGPoint(x: rect.minX, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + b, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - b), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulderY + r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: shoulderY), control: CGPoint(x: rect.maxX, y: shoulderY))
        path.addLine(to: CGPoint(x: right + s, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + depth), control: CGPoint(x: right, y: shoulderY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
