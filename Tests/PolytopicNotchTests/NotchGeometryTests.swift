import CoreGraphics
import Testing
@testable import PolytopicNotch

struct NotchGeometryTests {
    // 14" MacBook Pro at default scaling.
    let notched = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                safeAreaTop: 32,
                                auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
                                auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32),
                                menuBarHeight: 32)

    let external = NotchGeometry(screenFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                 safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil,
                                 menuBarHeight: 25)

    @Test func notchIsMeasuredFromAuxiliaryAreas() {
        #expect(notched.hasNotch)
        #expect(notched.notchSize == CGSize(width: 188, height: 32))
        #expect(notched.centerX == 756)
        #expect(notched.anchorY == 982)
    }

    @Test func pillHangsFromTheNotch() {
        let rect = notched.pillRect(size: CGSize(width: 300, height: 100))
        #expect(rect == CGRect(x: 606, y: 882, width: 300, height: 100))
        #expect(notched.hotZone == CGRect(x: 662, y: 950, width: 188, height: 32))
    }

    @Test func screensWithoutNotchHangBelowTheMenuBar() {
        #expect(!external.hasNotch)
        #expect(external.centerX == CGFloat(1512 + 1280))
        #expect(external.anchorY == 1440 - 25 - NotchGeometry.barGap)
        #expect(external.hotZone == CGRect(x: 1512 + 1280 - 110, y: 1415, width: 220, height: 25))
    }

    @Test func panelIsCentredOnTheNotch() {
        let frame = notched.panelFrame(maxSize: CGSize(width: 680, height: 420))
        #expect(frame.midX == notched.centerX)
        #expect(frame.maxY == 982)
    }
}

struct SharedNotchTests {
    let notched = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), safeAreaTop: 38,
                                auxiliaryTopLeft: CGRect(x: 0, y: 1079, width: 771, height: 38),
                                auxiliaryTopRight: CGRect(x: 957, y: 1079, width: 771, height: 38), menuBarHeight: 38)
    let external = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                 auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 25)

    @Test func sharingMovesThePillBelowTheNotch() {
        #expect(notched.placement == .notch)
        let shared = notched.sharingNotch(true)
        #expect(shared.placement == .belowNotch)
        #expect(shared.notchRect == CGRect(x: 771, y: 1079, width: 186, height: 38))
        // The pill's top edge clears the notch by the gap, centred under it.
        #expect(shared.anchorY == 1117 - 38 - NotchGeometry.sharedGap)
        let pill = shared.pillRect(size: CGSize(width: 500, height: 60))
        #expect(pill.maxY < shared.notchRect.minY && pill.midX == shared.notchRect.midX)
        // The notch itself still opens the panel.
        #expect(shared.hotZone == shared.notchRect)
        #expect(shared.sharingNotch(false).placement == .notch)
    }

    @Test func screensWithoutANotchAreUnaffected() {
        #expect(external.sharingNotch(true).placement == .menuBar)
        #expect(external.notchRect == .zero)
    }

    @Test func sharingPreference() {
        #expect(NotchSharing.automatic.shares(neighborPresent: true))
        #expect(!NotchSharing.automatic.shares(neighborPresent: false))
        #expect(NotchSharing.always.shares(neighborPresent: false))
        #expect(!NotchSharing.never.shares(neighborPresent: true))
    }

    @Test func bartenderTopShelfIsRecognisedByItsTallPanel() {
        typealias Window = NotchNeighborMonitor.WindowInfo
        let menuBarOverlay = Window(ownerPID: 10, layer: 24, bounds: CGRect(x: 0, y: 0, width: 2056, height: 51))
        let topShelf = Window(ownerPID: 10, layer: 25, bounds: CGRect(x: 0, y: 0, width: 2056, height: 500))
        let desktopLevel = Window(ownerPID: 10, layer: -2_147_483_623, bounds: CGRect(x: 0, y: 0, width: 2056, height: 1329))
        let someoneElse = Window(ownerPID: 99, layer: 25, bounds: CGRect(x: 0, y: 0, width: 2056, height: 500))
        // Bartender without Top Shelf: only its menu bar overlay and desktop-level window.
        #expect(!NotchNeighborMonitor.hasNotchPanel([menuBarOverlay, desktopLevel], ownedBy: [10]))
        #expect(NotchNeighborMonitor.hasNotchPanel([menuBarOverlay, desktopLevel, topShelf], ownedBy: [10]))
        #expect(!NotchNeighborMonitor.hasNotchPanel([someoneElse], ownedBy: [10]))
    }

    @Test func bartenderBarIsRecognisedOnlyWhileShowing() {
        typealias Window = NotchNeighborMonitor.WindowInfo
        let screen = NotchNeighborMonitor.ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), menuBarHeight: 38)
        let menuBarOverlay = Window(ownerPID: 10, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1728, height: 51))
        let topShelfCanvas = Window(ownerPID: 10, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1728, height: 500))
        let bar = Window(ownerPID: 10, layer: 25, bounds: CGRect(x: 900, y: 40, width: 420, height: 36))
        let settingsWindow = Window(ownerPID: 10, layer: 0, bounds: CGRect(x: 300, y: 40, width: 800, height: 600))
        let otherApp = Window(ownerPID: 77, layer: 25, bounds: CGRect(x: 900, y: 40, width: 420, height: 36))

        // Bartender 6 idle, or Bartender 7 with Top Shelf: nothing is in the way.
        #expect(NotchNeighborMonitor.barBelowMenuBar([menuBarOverlay, topShelfCanvas, settingsWindow, otherApp],
                                                     ownedBy: [10], screens: [screen]) == nil)
        #expect(NotchNeighborMonitor.barBelowMenuBar([menuBarOverlay, bar], ownedBy: [10], screens: [screen]) == bar.bounds)
        // Bartender 6 has no notch panel of its own.
        #expect(!NotchNeighborMonitor.hasNotchPanel([menuBarOverlay, bar], ownedBy: [10]))
    }

    @Test func pillStepsUnderABarThatIsInItsWay() {
        // The bar in AppKit coordinates: under the 38 pt menu bar, 36 pt tall, overlapping the centre.
        let bar = CGRect(x: 700, y: 1117 - 38 - 2 - 36, width: 420, height: 36)
        let moved = notched.avoiding(bar, reach: 560)
        #expect(moved.placement == .belowNotch)
        #expect(moved.pillRect(size: CGSize(width: 500, height: 60)).maxY == bar.minY - NotchGeometry.sharedGap)

        // A bar far off to the side leaves the pill attached to the notch.
        let aside = CGRect(x: 1400, y: 1041, width: 300, height: 36)
        #expect(notched.avoiding(aside, reach: 560) == notched)
        #expect(notched.avoiding(nil, reach: 560) == notched)

        // On a screen without a notch the bar-style pill just moves further down.
        let externalBar = CGRect(x: 1100, y: 1440 - 25 - 36, width: 400, height: 36)
        let lowered = external.avoiding(externalBar, reach: 560)
        #expect(lowered.placement == .menuBar)
        #expect(lowered.anchorY == externalBar.minY - NotchGeometry.sharedGap)

        // Taking the notch back clears the offset.
        #expect(moved.sharingNotch(false).drop == 0)
    }
}
