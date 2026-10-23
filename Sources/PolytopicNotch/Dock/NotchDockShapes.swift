import SwiftUI

// Outlines for the docked parts. Each app draws only its own part, in its own window; the parts meet on the device
// pixel grid (`NotchDockLayout` snaps every rect), black on black, so they read as one shape.
//
// - Merged top: `NotchShape(topRadius: flare, bottomRadius: 0)`, the attached pill with square bottom corners.
// - Merged middle and bottom: `NotchLowerPartShape`, square on top (tucked under the parts above), rounded at the
//   bottom only for the lowest.
// - Split wings: `NotchWingShape`, an ear of the band, its neck and its body as one outline.

/// A Merged part below the top one: square top corners (they sit under the part above), rounded bottom corners for
/// the lowest part, square for a middle one.
public struct NotchLowerPartShape: Shape {
    public var bottomRadius: CGFloat

    public init(bottomRadius: CGFloat) {
        self.bottomRadius = bottomRadius
    }

    public var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        let b = max(0, min(bottomRadius, rect.width / 2, rect.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - b, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - b), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// One Split wing in its panel's coordinates (y down from the top of the screen): an ear of the band beside the
/// notch, and, while the app shows something, a neck down from the ear to its body with concave shoulders.
///
/// The wing's inner edge sits inside the notch (or against the next app's ear), so it's straight. The outermost ear
/// flares into the top edge like the notch pill does and, while quiet, rounds its bottom outer corner (its straight
/// neck stops `earCornerRadius` above the ear's bottom, so the ear covers no more of the menu bar than today's quiet
/// ears).
public struct NotchWingShape: Shape {
    /// The band segment (top of the screen down to the ear's bottom).
    public var band: CGRect
    /// The body, including the shoulder at its top. Zero height: no body.
    public var body: CGRect
    public var isLeft: Bool
    /// Outermost on its side: top flare and, while quiet, a rounded bottom outer corner.
    public var isOutermost: Bool
    /// How deep the quiet ear's straight outer side reaches before its rounded corner.
    public var neckDepth: CGFloat
    public var flare: CGFloat
    public var shoulder: CGFloat
    public var bodyBottomRadius: CGFloat
    /// The body's convex top corners, away from the neck.
    public static let bodyCorner: CGFloat = 14

    public init(band: CGRect, body: CGRect?, isLeft: Bool, isOutermost: Bool, neckDepth: CGFloat, flare: CGFloat,
                shoulder: CGFloat, bodyBottomRadius: CGFloat) {
        self.band = band
        // No body: a zero-height one at the band's bottom, so a body that appears grows out of the ear.
        self.body = body ?? CGRect(x: band.minX, y: band.maxY, width: band.width, height: 0)
        self.isLeft = isLeft
        self.isOutermost = isOutermost
        self.neckDepth = neckDepth
        self.flare = flare
        self.shoulder = shoulder
        self.bodyBottomRadius = bodyBottomRadius
    }

    public var animatableData: AnimatablePair<CGRect.AnimatableData, AnimatablePair<CGRect.AnimatableData, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(band.animatableData, AnimatablePair(body.animatableData, AnimatablePair(neckDepth, bodyBottomRadius))) }
        set {
            band.animatableData = newValue.first
            body.animatableData = newValue.second.first
            neckDepth = newValue.second.second.first
            bodyBottomRadius = newValue.second.second.second
        }
    }

    public var hasBody: Bool { body.height > shoulder + 0.5 && body.width > 1 }

    public func path(in _: CGRect) -> Path {
        let dir: CGFloat = isLeft ? -1 : 1                 // from the inner edge outwards
        let inner = isLeft ? band.maxX : band.minX
        let outer = isLeft ? band.minX : band.maxX
        let t = isOutermost ? max(0, min(flare, band.width / 2, band.height / 2)) : 0
        let straight = outer - dir * t                     // the ear's straight outer side
        let bodyTop = body.minY + shoulder
        let showsBody = hasBody
        let depth = showsBody ? max(band.maxY, bodyTop) : band.maxY
        let corner = !showsBody && isOutermost ? max(0, min(band.height - neckDepth, abs(straight - inner))) : 0

        var ear = Path()
        ear.move(to: CGPoint(x: inner, y: band.minY))
        ear.addLine(to: CGPoint(x: outer, y: band.minY))
        if t > 0 { ear.addQuadCurve(to: CGPoint(x: straight, y: band.minY + t), control: CGPoint(x: straight, y: band.minY)) }
        ear.addLine(to: CGPoint(x: straight, y: depth - corner))
        if corner > 0 {
            ear.addQuadCurve(to: CGPoint(x: straight - dir * corner, y: depth), control: CGPoint(x: straight, y: depth))
        }
        ear.addLine(to: CGPoint(x: inner, y: depth))
        ear.closeSubpath()
        guard showsBody else { return ear }

        // The body, with its top corners rounded only where it reaches past the neck, and concave shoulders there.
        let neckMin = min(inner, straight), neckMax = max(inner, straight)
        let s = shoulder
        let reachLeft = neckMin - body.minX, reachRight = body.maxX - neckMax
        let topLeft = reachLeft >= 1 ? min(Self.bodyCorner, max(0, reachLeft - s)) : 0
        let topRight = reachRight >= 1 ? min(Self.bodyCorner, max(0, reachRight - s)) : 0
        let box = CGRect(x: body.minX, y: bodyTop, width: body.width, height: max(0, body.maxY - bodyTop))
        let b = max(0, min(bodyBottomRadius, box.width / 2, box.height / 2))
        let bodyPath = UnevenRoundedRectangle(cornerRadii: .init(topLeading: topLeft, bottomLeading: b, bottomTrailing: b,
                                                                 topTrailing: topRight), style: .continuous).path(in: box)
        var shape = ear.union(bodyPath)
        if reachLeft >= s {
            var fillet = Path()
            fillet.move(to: CGPoint(x: neckMin, y: bodyTop - s))
            fillet.addQuadCurve(to: CGPoint(x: neckMin - s, y: bodyTop), control: CGPoint(x: neckMin, y: bodyTop))
            fillet.addLine(to: CGPoint(x: neckMin, y: bodyTop))
            fillet.closeSubpath()
            shape = shape.union(fillet)
        }
        if reachRight >= s {
            var fillet = Path()
            fillet.move(to: CGPoint(x: neckMax, y: bodyTop - s))
            fillet.addQuadCurve(to: CGPoint(x: neckMax + s, y: bodyTop), control: CGPoint(x: neckMax, y: bodyTop))
            fillet.addLine(to: CGPoint(x: neckMax, y: bodyTop))
            fillet.closeSubpath()
            shape = shape.union(fillet)
        }
        return shape
    }
}
