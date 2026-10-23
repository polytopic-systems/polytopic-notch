import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// "Grow from the notch" vs "Keep the menu bar clear", and the quiet indicator's position.
@MainActor
struct NotchShapeTests {
    func model(_ notch: (CGFloat, CGFloat, CGFloat, CGFloat), shape: NotchPillShape = .clearMenuBar,
               indicator: NotchIndicatorPosition = .besideNotch) -> NotchViewModel {
        let content = NotchContent()
        content.showing = NotchBody(height: 46) { Color.clear }
        return .test(TestScreens.geometry(notch), settings: NotchSettings(pillShape: shape, indicator: indicator), content: content)
    }

    @Test func clearMenuBarKeepsTheNeckExactlyNotchWideInsideTheBar() {
        for notch in TestScreens.notches {
            let model = model(notch)
            let notchWidth = notch.1
            let depth = max(notch.2, notch.3)
            for mode in [NotchMode.showing, .expanded, .asking] {
                let size = model.size(for: mode)
                let path = model.attachedShape(for: mode).path(in: CGRect(origin: .zero, size: size))
                let left = (size.width - notchWidth) / 2
                let right = left + notchWidth
                // Every row inside the menu bar: black exactly between the notch's edges, nothing beside it.
                for y in stride(from: CGFloat(0.5), to: depth, by: 1) {
                    #expect(path.contains(CGPoint(x: left + 0.5, y: y)), "\(notch) \(mode) y \(y)")
                    #expect(path.contains(CGPoint(x: right - 0.5, y: y)))
                    #expect(!path.contains(CGPoint(x: left - 0.5, y: y)), "covers the menu bar at \(notch) \(mode) y \(y)")
                    #expect(!path.contains(CGPoint(x: right + 0.5, y: y)))
                }
                // Below the bar and its shoulders it's the full width.
                let body = depth + NotchOutline.shoulder + NotchOutline.corner + 1
                #expect(path.contains(CGPoint(x: 1, y: body)) && path.contains(CGPoint(x: size.width - 1, y: body)))
                // The content starts below the bar.
                #expect(model.notchTop(for: mode) == depth + NotchOutline.shoulder)
                #expect(model.keepsMenuBarClear(mode))
            }
            // Quiet and hidden are the notch itself (and ears, beside the notch, when that's chosen).
            #expect(!model.keepsMenuBarClear(.quiet) && !model.keepsMenuBarClear(.hidden))
        }
    }

    @Test func growFromTheNotchIsThePlainShape() {
        for notch in TestScreens.notches {
            let model = model(notch, shape: .grow)
            let size = model.size(for: .showing)
            let path = model.attachedShape(for: .showing).path(in: CGRect(origin: .zero, size: size))
            // Full width right up through the menu bar (inside the small flares at the bezel).
            #expect(path.contains(CGPoint(x: 8, y: 8)) && path.contains(CGPoint(x: size.width - 8, y: 8)))
            #expect(model.notchTop(for: .showing) == notch.2)
            #expect(size.height == notch.2 + 46)
            // Same outline as the plain NotchShape.
            let plain = NotchShape(topRadius: 6, bottomRadius: 20).path(in: CGRect(origin: .zero, size: size))
            #expect(path.boundingRect == plain.boundingRect)
        }
    }

    @Test func hoverLeavesTheMenuBarBesideTheNotchAlone() {
        let clear = model(TestScreens.notches[2])
        clear.previewMode = .expanded
        clear.isHovering = true
        let notch = clear.geometry.notchRect
        let besideInBar = CGPoint(x: notch.maxX + 60, y: notch.midY)
        let belowBar = CGPoint(x: notch.maxX + 60, y: notch.minY - 40)
        #expect(!clear.hoverContains(besideInBar), "a menu beside the notch must stay clickable")
        #expect(clear.hoverContains(belowBar) && clear.hoverContains(CGPoint(x: notch.midX, y: notch.midY)))
        // Growing from the notch covers the menu bar beside it while open.
        let grow = model(TestScreens.notches[2], shape: .grow)
        grow.previewMode = .expanded
        grow.isHovering = true
        #expect(grow.hoverContains(besideInBar))
    }

    @Test func quietIndicatorUnderTheNotch() {
        let under = model(TestScreens.notches[2], shape: .grow, indicator: .underNotch)
        #expect(under.indicatorUnderNotch)
        #expect(under.size(for: .quiet) == CGSize(width: 220, height: 38 + NotchGeometry.sharedGap + 5))
        let beside = model(TestScreens.notches[2], shape: .grow)
        #expect(beside.size(for: .quiet) == CGSize(width: 220 + 2 * NotchMetrics.standard.ear, height: 38))
        // Sharing the notch: both settings step aside for the below-the-notch look.
        under.geometry = under.geometry.sharingNotch(true)
        #expect(!under.indicatorUnderNotch && !under.keepsMenuBarClear(.showing))
        #expect(under.size(for: .quiet) == CGSize(width: 84, height: 5))
    }

    @Test func busyMakesTheQuietLineBigger() {
        let under = model(TestScreens.notches[2], shape: .grow, indicator: .underNotch)
        under.content.busy = true
        #expect(under.size(for: .quiet) == CGSize(width: 220, height: 38 + NotchGeometry.sharedGap + 7))
        under.geometry = under.geometry.sharingNotch(true)
        #expect(under.size(for: .quiet) == CGSize(width: 180, height: 7))
    }

    @Test func aBodyMaySetItsOwnBottomCorner() {
        let model = model(TestScreens.notches[0], shape: .grow)
        #expect(model.attachedShape(for: .showing).bottomRadius == 20)
        model.content.showing?.bottomRadius = 18
        #expect(model.attachedShape(for: .showing).bottomRadius == 18)
        #expect(model.attachedShape(for: .hidden).bottomRadius == 8 && model.attachedShape(for: .quiet).bottomRadius == 10)
        #expect(model.attachedShape(for: .expanded).bottomRadius == 26 && model.attachedShape(for: .asking).bottomRadius == 26)
    }
}
