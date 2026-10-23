import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// What the pill shows for each content status, the menu hold, and how big it is in every mode and placement.
@MainActor
struct NotchContentTests {
    /// Bodies sized like the apps': a 46 pt showing body, the default expanded panel, a 120 pt question.
    func model(_ geometry: NotchGeometry = TestScreens.geometry(TestScreens.notches[0]), shares: Bool = false) -> NotchViewModel {
        let content = NotchContent()
        content.showing = NotchBody(height: 46) { Color.clear }
        content.prompt = nil
        return .test(geometry.sharingNotch(shares), content: content)
    }

    @Test func statusMapsToModes() {
        #expect(NotchViewModel.mode(for: .off) == .hidden)
        #expect(NotchViewModel.mode(for: .quiet) == .quiet)
        #expect(NotchViewModel.mode(for: .showing) == .showing)
        #expect(NotchViewModel.mode(for: .attention) == .showing)
    }

    @Test func modeFollowsTheContentAndTheHover() {
        let model = model()
        let content = model.content
        #expect(model.mode == .hidden)
        content.status = .quiet
        #expect(model.mode == .quiet)
        content.status = .showing
        #expect(model.mode == .showing && !model.needsAttention)
        content.status = .attention
        #expect(model.mode == .showing && model.needsAttention)
        model.isHovering = true
        #expect(model.mode == .expanded)
        // Option-hover hands the notch to a neighbor: nothing of ours shows.
        model.isYielding = true
        model.isHovering = false
        #expect(model.mode == .hidden)
        content.status = .off
        model.isYielding = false
        #expect(model.mode == .hidden)
        // Hovering the notch opens the pill even with nothing to show.
        model.isHovering = true
        #expect(model.mode == .expanded)
    }

    @Test func aQuestionOverridesHoverWhereThereIsANotch() {
        let model = model()
        model.content.status = .quiet
        model.content.prompt = NotchBody(height: 120) { Text("Allow?") }
        #expect(model.canAsk && model.mode == .asking)
        model.isHovering = true
        #expect(model.mode == .asking, "a question stays in front of the pointer's panel")
        model.isMenuOpen = true
        #expect(model.mode == .asking)
        // Without a notch the floating window asks; the bar below the menu bar never does.
        let bar = self.model(TestScreens.external)
        bar.content.prompt = NotchBody(height: 120) { Text("Allow?") }
        #expect(!bar.canAsk && bar.mode == .hidden)
        // Below a shared notch it still asks in the pill.
        let shared = self.model(shares: true)
        shared.content.prompt = NotchBody(height: 120) { Text("Allow?") }
        #expect(shared.canAsk && shared.mode == .asking)
    }

    @Test func anOpenMenuKeepsThePillExpandedWhateverTheHover() {
        let model = model()
        model.content.status = .showing
        model.isMenuOpen = true
        #expect(!model.isHovering && model.mode == .expanded)
        model.isHovering = true
        #expect(model.mode == .expanded)
        model.isHovering = false
        model.isMenuOpen = false
        #expect(model.mode == .showing)
    }

    @Test func popUpMenuHoldsTheMenuOpenExactlyWhileItShows() {
        let model = model()
        var during: (open: Bool, mode: NotchMode)?
        var closed = 0
        model.onMenuClosed = { closed += 1 }
        model.presentMenu = { _, _ in
            during = (model.isMenuOpen, model.mode)
            // A second click while it's open is ignored.
            model.popUpMenu(NSMenu(), from: nil)
        }
        model.popUpMenu(NSMenu(), from: nil)
        #expect(during?.open == true && during?.mode == .expanded)
        #expect(!model.isMenuOpen && closed == 1)
    }

    @Test func theDockSlotCanWithholdExpandingAndAsking() {
        let model = model()
        model.content.status = .showing
        #expect(model.slot == .solo)
        model.slot = NotchSlot(mayExpand: false, mayAsk: false)
        model.isHovering = true
        #expect(model.mode == .showing)
        model.content.prompt = NotchBody(height: 120) { Text("Allow?") }
        #expect(!model.canAsk && model.mode == .showing)
        model.slot = .solo
        #expect(model.mode == .asking)
    }

    @Test func theMeterReadsZeroWhileOff() {
        let model = model()
        model.content.level = 0.7
        #expect(model.level == 0)
        model.content.status = .quiet
        #expect(model.level == 0.7)
        model.content.level = 3
        #expect(model.level == 1)
    }

    @Test func wantsAreOrdered() {
        #expect(NotchWant.none < .quiet && NotchWant.quiet < .notice && NotchWant.notice < .live && NotchWant.live < .urgent)
        #expect(NotchWant.allCases.sorted() == NotchWant.allCases)
    }

    // MARK: - Sizes

    /// Every mode in every placement on a 14" MacBook Pro (notch 188×32), with a 46 pt showing body, the default
    /// expanded panel and a 120 pt question. These are the numbers both apps used before the package.
    @Test func sizeTable() {
        let notch = model()
        notch.content.prompt = NotchBody(height: 120) { Color.clear }
        let shared = model(shares: true)
        shared.content.prompt = notch.content.prompt
        let bar = model(TestScreens.external)
        bar.content.prompt = notch.content.prompt
        let table: [(NotchViewModel, NotchMode, CGSize)] = [
            (notch, .hidden, CGSize(width: 188, height: 32)),
            (notch, .quiet, CGSize(width: 188 + 80, height: 32)),             // the notch and two 40 pt ears
            (notch, .showing, CGSize(width: 500, height: 32 + 46)),
            (notch, .expanded, CGSize(width: 560, height: 32 + 300)),
            (notch, .asking, CGSize(width: 540, height: 32 + 120 + 6)),
            (shared, .hidden, .zero),
            (shared, .quiet, CGSize(width: 84, height: 5)),
            (shared, .showing, CGSize(width: 500, height: 10 + 46)),
            (shared, .expanded, CGSize(width: 560, height: 10 + 300)),
            (shared, .asking, CGSize(width: 540, height: 10 + 120 + 6)),
            (bar, .hidden, .zero),
            (bar, .quiet, CGSize(width: 190, height: 30)),
            (bar, .showing, CGSize(width: 520, height: 30 + 46)),
            (bar, .expanded, CGSize(width: 560, height: 30 + 300)),
            (bar, .asking, CGSize(width: 540, height: 30 + 120 + 6)),
        ]
        for (model, mode, expected) in table {
            #expect(model.size(for: mode) == expected, "\(model.placement) \(mode)")
            // Every look fits inside the fixed panel, so SwiftUI can animate between them.
            let size = model.size(for: mode)
            #expect(size.width <= model.metrics.panelSize.width && size.height <= model.metrics.panelSize.height)
        }
    }

    /// Captioner's "Add to Apple Notes?" line was its own mode, 440 wide and a few points taller on the notch
    /// than elsewhere. As a showing body with its own width and per-placement heights it keeps those sizes.
    @Test func aBodyWithItsOwnWidthAndHeights() {
        let offer = NotchBody(width: 440, bottomRadius: 18, height: { placement in
            switch placement {
            case .notch: 40
            case .belowNotch: 36
            case .menuBar: 38
            }
        }) { Text("Add this session to Apple Notes?") }
        for (model, expected) in [(model(), CGSize(width: 440, height: 32 + 40)),
                                  (model(shares: true), CGSize(width: 440, height: 10 + 36)),
                                  (model(TestScreens.external), CGSize(width: 440, height: 30 + 38))] {
            model.content.showing = offer
            #expect(model.size(for: .showing) == expected, "\(model.placement)")
        }
        // An expanded body sets the hover panel's height (Monitor's firewall lists).
        let model = model()
        model.content.expanded = NotchBody(height: 252) { Color.clear }
        #expect(model.size(for: .expanded) == CGSize(width: 560, height: 32 + 252))
    }

    @Test func aBodyHeightFollowsTheAppsOwnState() {
        let settings = InMemoryNotchSettings()
        let content = NotchContent()
        // Like a headline box: one line of the app's text size plus padding, read where the pill is sized.
        content.showing = NotchBody(height: { _ in
            8 + NotchTextStyle(size: CGFloat(settings.notch.fontSize)).lineHeight + 12
        }) { Color.clear }
        let model = NotchViewModel(content: content, settings: settings, geometry: TestScreens.geometry(TestScreens.notches[0]))
        let small = model.size(for: .showing).height
        settings.notch.fontSize = 22
        #expect(model.size(for: .showing).height > small)
        let bodyTextWidth: CGFloat = 500 - 2 * 18 - 2 * 6
        #expect(model.bodyTextWidth == bodyTextWidth)
    }
}
