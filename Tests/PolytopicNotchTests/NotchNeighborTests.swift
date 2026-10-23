import AppKit
import Testing
@testable import PolytopicNotch

/// The notch-neighbor rules over synthetic window lists shaped like what each app creates, and like what
/// macOS 27.2 reports on a 14" MacBook Pro (dumped on the development Mac, Oct 2026).
struct NotchNeighborTests {
    typealias Window = NotchNeighborMonitor.WindowInfo
    typealias Screen = NotchNeighborMonitor.ScreenInfo
    typealias App = NotchNeighborDetection.App

    // Built-in display as macOS 27.2 reports it: 2056×1329, menu bar 39 pt, notch 220×38 at x 918.
    static let builtIn = Screen(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329), menuBarHeight: 39,
                                notch: CGRect(x: 918, y: 0, width: 220, height: 38))
    // An external display to the right with no notch, its top 200 pt higher than the built-in's.
    static let external = Screen(frame: CGRect(x: 2056, y: -200, width: 2560, height: 1440), menuBarHeight: 25)
    let screens = [builtIn, external]

    // Processes.
    static let windowServer: pid_t = 430
    static let ownPID: pid_t = 15
    let apps: [pid_t: App] = [
        10: App(pid: 10, bundleID: "com.surteesstudios.Bartender", name: "Bartender 7"),
        15: App(pid: 15, bundleID: "com.example.thisapp", name: "This App"),
        20: App(pid: 20, bundleID: "theboringteam.boringnotch", name: "boringNotch"),
        21: App(pid: 21, bundleID: "com.Ebullioscopic.Atoll.dev", name: "Atoll"),
        22: App(pid: 22, bundleID: "wiki.qaq.NotchDrop", name: "NotchDrop"),
        23: App(pid: 23, bundleID: "com.ruban.notchi", name: "Notchi"),
        24: App(pid: 24, bundleID: "com.bitvibelabs.tickernotch", name: "TickerNotch"),
        25: App(pid: 25, bundleID: "com.iconfactory.Notchmeister", name: "Notchmeister"),
        30: App(pid: 30, bundleID: "com.example.dynamicnotchdemo", name: "Notch Demo"),
        31: App(pid: 31, bundleID: "com.example.agentisland", name: "Agent Island"),
        32: App(pid: 32, bundleID: "com.example.widestrip", name: "Wide Strip"),
        40: App(pid: 40, bundleID: "com.jordanbaird.Ice", name: "Ice"),
        41: App(pid: 41, bundleID: "com.stonerl.Thaw", name: "Thaw"),
        50: App(pid: 50, bundleID: "com.apple.dock", name: "Dock"),
        51: App(pid: 51, bundleID: "com.apple.MenuBarAgent", name: "MenuBarAgent"),
        52: App(pid: 52, bundleID: "com.apple.controlcenter", name: "Control Center"),
        53: App(pid: 53, bundleID: "com.apple.notificationcenterui", name: "Notification Center"),
        60: App(pid: 60, bundleID: "com.bjango.istatmenus.status", name: "iStat Menus Status"),
        61: App(pid: 61, bundleID: "com.lidrun.app", name: "LidRun"),
        62: App(pid: 62, bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
        63: App(pid: 63, bundleID: "com.goodsnooze.vivid", name: "Vivid"),
        70: App(pid: 70, bundleID: nil, name: "qemu-system-aarch64"),
    ]

    func evaluate(_ windows: [Window]) -> NotchNeighborDetection.Result {
        NotchNeighborDetection.evaluate(windows: windows, screens: screens, apps: apps, ownBundleID: "com.example.thisapp")
    }

    func names(_ windows: [Window]) -> [String] {
        evaluate(windows).sightings.map(\.name)
    }

    // What this Mac's window list holds near the top of the screen on macOS 27.2, minus the notch apps.
    var macOS27Baseline: [Window] {
        [
            Window(ownerPID: Self.windowServer, layer: 2_147_483_630, bounds: CGRect(x: 2029, y: 1, width: 28, height: 28)), // privacy dot
            Window(ownerPID: 63, layer: 1_000, bounds: CGRect(x: 1010, y: 1193, width: 36, height: 36)),                // Vivid, bottom
            Window(ownerPID: Self.ownPID, layer: 27, bounds: CGRect(x: 918 - 230, y: 0, width: 680, height: 420)),       // our own panel
            Window(ownerPID: Self.windowServer, layer: 24, bounds: CGRect(x: 0, y: 0, width: 2056, height: 39)),         // "Menubar"
            Window(ownerPID: 51, layer: 24, bounds: CGRect(x: 0, y: 0, width: 2056, height: 39)),                         // MenuBarAgent
            Window(ownerPID: 50, layer: 20, bounds: CGRect(x: 0, y: 0, width: 2056, height: 1329)),                       // Dock
            Window(ownerPID: 53, layer: 21, bounds: CGRect(x: 0, y: 0, width: 2056, height: 1329)),                       // Notification Center
            Window(ownerPID: 52, layer: 25, bounds: CGRect(x: 1700, y: 41, width: 340, height: 600)),                     // Control Center module
            Window(ownerPID: 62, layer: 1_000, bounds: CGRect(x: 0, y: 0, width: 2056, height: 1329)),                    // Claude's full-screen overlay
            Window(ownerPID: 70, layer: 0, bounds: CGRect(x: 1501, y: 39, width: 411, height: 942)),
        ]
    }

    // MARK: - System surfaces and ordinary windows

    @Test func macOS27SystemWindowsAreNotNeighbors() {
        let result = evaluate(macOS27Baseline)
        #expect(result.sightings.isEmpty)
        let reasons = Dictionary(result.exclusions.map { ($0.pid, $0.reason) }, uniquingKeysWith: { first, _ in first })
        #expect(reasons[Self.windowServer]?.contains("system surface") == true)   // the menu bar window has no app
        #expect(reasons[51] == "system surface")                                  // MenuBarAgent
        #expect(reasons[Self.ownPID] == "another copy of this app")
        #expect(reasons[62]?.contains("full-width") == true)                       // full-screen overlay at level 1000
        // The Dock and Notification Center sit below the menu bar level; Control Center doesn't reach the notch.
        #expect(reasons[50] == nil && reasons[53] == nil && reasons[52] == nil)
    }

    @Test func menuBarExtraPopoversDoNotCount() {
        // iStat Menus' dropdown hangs from y 41 at level 24; LidRun's popover at level 101 starts exactly at
        // the notch's bottom edge; one with an arrow reaching 2 pt into the menu bar.
        let popovers = [
            Window(ownerPID: 60, layer: 24, bounds: CGRect(x: 900, y: 41, width: 270, height: 450)),
            Window(ownerPID: 61, layer: 101, bounds: CGRect(x: 880, y: 38, width: 320, height: 526)),
            Window(ownerPID: 61, layer: 101, bounds: CGRect(x: 880, y: 36, width: 320, height: 526)),
        ]
        let result = evaluate(macOS27Baseline + popovers)
        #expect(result.sightings.isEmpty)
        #expect(!result.exclusions.contains { $0.pid == 60 || $0.pid == 61 })
    }

    @Test func statusItemSizedWindowsBesideTheNotchDoNotCount() {
        // macOS 26 still gives each status item its own small window in the menu bar.
        let item = Window(ownerPID: 60, layer: 25, bounds: CGRect(x: 1140, y: 0, width: 30, height: 39))
        #expect(evaluate([item]).sightings.isEmpty)
        #expect(evaluate([item]).exclusions.isEmpty)
    }

    // MARK: - Known notch apps

    @Test func boringNotchIsRecognisedByItsFixedTransparentBox() {
        // Always 640×210, transparent, top-centre, at our level.
        let box = Window(ownerPID: 20, layer: 27, bounds: CGRect(x: 1028 - 320, y: 0, width: 640, height: 210))
        let result = evaluate(macOS27Baseline + [box])
        #expect(result.sightings.map(\.name) == ["Boring Notch"])
        #expect(result.sightings.first?.profile?.name == "Boring Notch")
    }

    @Test func atollCountsWhateverSizeItsWindowIs() {
        let idle = Window(ownerPID: 21, layer: 27, bounds: CGRect(x: 908, y: 0, width: 240, height: 38))
        let open = Window(ownerPID: 21, layer: 27, bounds: CGRect(x: 778, y: 0, width: 500, height: 190))
        #expect(names([idle]) == ["Atoll"])
        #expect(names([open]) == ["Atoll"])   // the dev build's identifier matches by prefix
    }

    @Test func screenWideStripsCountOnlyForTheAppsKnownToUseThem() {
        let notchDrop = Window(ownerPID: 22, layer: 33, bounds: CGRect(x: 0, y: 0, width: 2056, height: 200))
        let notchi = Window(ownerPID: 23, layer: 27, bounds: CGRect(x: 0, y: 0, width: 2056, height: 120))
        let unknown = Window(ownerPID: 32, layer: 27, bounds: CGRect(x: 0, y: 0, width: 2056, height: 200))
        #expect(names([notchDrop]) == ["NotchDrop"])
        #expect(names([notchi]) == ["Notchi"])
        let result = evaluate([unknown])
        #expect(result.sightings.isEmpty)
        #expect(result.exclusions.first?.reason == "full-width strip or overlay")
    }

    @Test func contentBesideTheNotchCountsForKnownApps() {
        // TickerNotch keeps text just right of the notch, where our ears and headline go.
        let ticker = Window(ownerPID: 24, layer: 27, bounds: CGRect(x: 1140, y: 0, width: 300, height: 38))
        #expect(names([ticker]) == ["TickerNotch"])
        // The same window from an unknown app doesn't cover the notch, so it's left alone.
        let unknown = Window(ownerPID: 31, layer: 27, bounds: CGRect(x: 1140, y: 0, width: 300, height: 38))
        #expect(names([unknown]).isEmpty)
    }

    @Test func cosmeticAppsAreNeverNeighbors() {
        let sparkles = Window(ownerPID: 25, layer: 27, bounds: CGRect(x: 878, y: 0, width: 300, height: 60))
        let result = evaluate([sparkles])
        #expect(result.sightings.isEmpty)
        #expect(result.exclusions.first?.reason == "Notchmeister only decorates the notch")
    }

    // MARK: - Unknown notch apps

    @Test func dynamicNotchKitHalfScreenPanelCountsByTheGeneralRule() {
        let panel = Window(ownerPID: 30, layer: 1_000, bounds: CGRect(x: 514, y: 0, width: 1028, height: 664))
        let result = evaluate(macOS27Baseline + [panel])
        #expect(result.sightings.map(\.name) == ["Notch Demo"])
        #expect(result.sightings.first?.profile == nil)
    }

    @Test func unknownWindowsMustHangFromTheTopAndStayBelowOverlayLevels() {
        let detached = Window(ownerPID: 31, layer: 27, bounds: CGRect(x: 878, y: 10, width: 300, height: 80))
        #expect(evaluate([detached]).exclusions.first?.reason == "not attached to the top edge")
        let overlay = Window(ownerPID: 31, layer: 2_000, bounds: CGRect(x: 878, y: 0, width: 300, height: 80))
        #expect(evaluate([overlay]).exclusions.first?.reason.hasPrefix("overlay level") == true)
        let normal = Window(ownerPID: 31, layer: 3, bounds: CGRect(x: 878, y: 0, width: 300, height: 80))
        #expect(evaluate([normal]).exclusions.isEmpty && evaluate([normal]).sightings.isEmpty)
        let noBundle = Window(ownerPID: 70, layer: 27, bounds: CGRect(x: 878, y: 0, width: 300, height: 80))
        #expect(evaluate([noBundle]).exclusions.first?.reason == "not an app bundle")
    }

    @Test func eventIslandCountsAfterASecondLookAndStaysUntilItQuits() {
        var tracker = NotchNeighborTracker()
        let island = Window(ownerPID: 31, layer: 26, bounds: CGRect(x: 878, y: 0, width: 300, height: 80))
        let running = Set(apps.keys)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        func look(_ windows: [Window], at seconds: TimeInterval, running: Set<pid_t>? = nil) -> [NotchNeighborTracker.Event] {
            tracker.update(evaluate(windows).sightings, running: running ?? Set(apps.keys), now: start.addingTimeInterval(seconds))
        }

        // A blink shorter than the confirmation doesn't count.
        #expect(look([island], at: 0).count == 1 && tracker.isConfirming)
        #expect(tracker.neighbors.isEmpty)
        let dropped = look([], at: 0.15)
        #expect(dropped.count == 1 && !tracker.isConfirming)
        if case .dropped = dropped.first {} else { Issue.record("expected the blink to be dropped") }

        // Seen twice, far enough apart: it counts.
        _ = look([island], at: 5)
        _ = look([island], at: 5.1)            // too soon to confirm
        #expect(tracker.neighbors.isEmpty)
        let added = look([island], at: 5.4)
        #expect(tracker.neighbors[31]?.name == "Agent Island")
        if case .added = added.first {} else { Issue.record("expected the island to be added") }

        // It goes away and comes back: the pill doesn't move.
        #expect(look([], at: 8).isEmpty)
        #expect(tracker.neighbors[31] != nil)
        #expect(look([island], at: 12).isEmpty)

        // It quits.
        let quit = look([], at: 20, running: running.subtracting([31]))
        #expect(tracker.neighbors.isEmpty)
        if case .removed(_, let reason) = quit.first { #expect(reason == "quit") } else { Issue.record("expected removal") }
    }

    @Test func knownAppsCountOnFirstSightAndStaySticky() {
        var tracker = NotchNeighborTracker()
        let box = Window(ownerPID: 20, layer: 27, bounds: CGRect(x: 708, y: 0, width: 640, height: 210))
        let now = Date()
        _ = tracker.update(evaluate([box]).sightings, running: [20], now: now)
        #expect(tracker.neighbors[20]?.profileName == "Boring Notch")
        #expect(tracker.neighbors[20]?.live == false)
        _ = tracker.update([], running: [20], now: now.addingTimeInterval(1))
        #expect(tracker.neighbors[20] != nil)
        _ = tracker.update([], running: [], now: now.addingTimeInterval(2))
        #expect(tracker.neighbors.isEmpty)
    }

    // MARK: - Bartender (unchanged behaviour)

    @Test func bartenderTopShelfCountsOnlyWhileItsCanvasIsUp() {
        let overlay = Window(ownerPID: 10, layer: 24, bounds: CGRect(x: 0, y: 0, width: 2056, height: 51))
        let canvas = Window(ownerPID: 10, layer: 25, bounds: CGRect(x: 0, y: 0, width: 2056, height: 500))
        let desktop = Window(ownerPID: 10, layer: -2_147_483_623, bounds: CGRect(x: 0, y: 0, width: 2056, height: 1329))
        // This Mac's list right now: Bartender 7 with Top Shelf on.
        #expect(names(macOS27Baseline + [overlay, canvas, desktop]) == ["Bartender"])
        #expect(names(macOS27Baseline + [overlay, desktop]).isEmpty)

        var tracker = NotchNeighborTracker()
        let now = Date()
        _ = tracker.update(evaluate([overlay, canvas]).sightings, running: [10], now: now)
        #expect(tracker.neighbors[10]?.live == true)
        // Top Shelf switched off while Bartender keeps running: the notch is ours again straight away.
        let events = tracker.update(evaluate([overlay]).sightings, running: [10], now: now.addingTimeInterval(0.5))
        #expect(tracker.neighbors.isEmpty)
        if case .removed(_, let reason) = events.first { #expect(reason == "its notch panel closed") } else { Issue.record("expected removal") }
    }

    @Test func bartenderBarIsStillFoundAtAnyLevelBelow1000() {
        let bar = Window(ownerPID: 10, layer: 25, bounds: CGRect(x: 900, y: 40, width: 420, height: 36))
        let found = NotchNeighborDetection.bar(windows: [bar], screens: screens, apps: apps)
        #expect(found?.rect == bar.bounds && found?.owner == "Bartender")
    }

    // MARK: - Menu bar managers

    @Test func iceAndThawBarsCountButTheirTintAndMenusDoNot() {
        let tint = Window(ownerPID: 40, layer: 25, bounds: CGRect(x: 0, y: 0, width: 2056, height: 44))
        let iceBar = Window(ownerPID: 40, layer: 25, bounds: CGRect(x: 1300, y: 39, width: 420, height: 30))
        let iceMenu = Window(ownerPID: 40, layer: 101, bounds: CGRect(x: 1600, y: 39, width: 220, height: 90))
        let thawBar = Window(ownerPID: 41, layer: 25, bounds: CGRect(x: 800, y: 39, width: 420, height: 30))

        #expect(NotchNeighborDetection.bar(windows: [tint, iceMenu], screens: screens, apps: apps) == nil)
        let ice = NotchNeighborDetection.bar(windows: [tint, iceBar, iceMenu], screens: screens, apps: apps)
        #expect(ice?.rect == iceBar.bounds && ice?.owner == "Ice")
        let thaw = NotchNeighborDetection.bar(windows: [thawBar], screens: screens, apps: apps)
        #expect(thaw?.owner == "Thaw")

        // Neither is a notch neighbor: the tint is explained once and otherwise ignored.
        let result = evaluate(macOS27Baseline + [tint, iceBar])
        #expect(result.sightings.isEmpty)
        #expect(result.exclusions.contains { $0.pid == 40 && $0.reason == "Ice is a menu bar manager" })
    }

    @Test func unknownAppsNeverMakeABar() {
        let popover = Window(ownerPID: 60, layer: 25, bounds: CGRect(x: 900, y: 39, width: 300, height: 60))
        #expect(NotchNeighborDetection.bar(windows: [popover], screens: screens, apps: apps) == nil)
    }

    // MARK: - Several displays

    @Test func screensWithoutANotchUseTheMiddleOfTheMenuBar() {
        // Boring Notch's simulated notch on the external display, and an unknown island there.
        let top = Self.external.frame.minY
        let boring = Window(ownerPID: 20, layer: 27, bounds: CGRect(x: 3336 - 320, y: top, width: 640, height: 210))
        let island = Window(ownerPID: 31, layer: 26, bounds: CGRect(x: 3336 - 120, y: top, width: 240, height: 60))
        let corner = Window(ownerPID: 31, layer: 26, bounds: CGRect(x: 2060, y: top, width: 240, height: 60))
        #expect(names([boring]) == ["Boring Notch"])
        #expect(names([island]) == ["Agent Island"])
        #expect(evaluate([corner]).sightings.isEmpty && evaluate([corner]).exclusions.isEmpty)
        #expect(Self.external.notchArea == CGRect(x: 3236, y: -200, width: 200, height: 25))
        // The built-in display's real notch is used where there is one.
        #expect(Self.builtIn.notchArea == CGRect(x: 918, y: 0, width: 220, height: 38))
    }

    @Test func iceBarOnASecondDisplayIsMeasuredAgainstThatDisplaysMenuBar() {
        let bar = Window(ownerPID: 40, layer: 25, bounds: CGRect(x: 3000, y: -200 + 25, width: 400, height: 28))
        #expect(NotchNeighborDetection.bar(windows: [bar], screens: screens, apps: apps)?.rect == bar.bounds)
    }

    // MARK: - Pace, profiles, levels, settings

    @Test func watchesCloselyOnlyWhenThereIsSomethingToWatch() {
        let none = NotchNeighborTracker()
        let unrelated = [apps[50]!, apps[60]!, apps[62]!, apps[70]!]
        #expect(NotchNeighborDetection.pace(apps: unrelated, tracker: none) == .idle)
        #expect(NotchNeighborDetection.pace(apps: unrelated + [apps[40]!], tracker: none) == .bar)
        #expect(NotchNeighborDetection.pace(apps: unrelated + [apps[10]!], tracker: none) == .bar)
        #expect(NotchNeighborDetection.pace(apps: unrelated + [apps[20]!], tracker: none) == .watching)
        #expect(NotchNeighborDetection.pace(apps: unrelated + [apps[25]!], tracker: none) == .idle)

        // Once Boring Notch is known it needs no close watching: it counts until it quits.
        var known = NotchNeighborTracker()
        let box = Window(ownerPID: 20, layer: 27, bounds: CGRect(x: 708, y: 0, width: 640, height: 210))
        _ = known.update(evaluate([box]).sightings, running: [20], now: Date())
        #expect(NotchNeighborDetection.pace(apps: unrelated + [apps[20]!], tracker: known) == .idle)

        var confirming = NotchNeighborTracker()
        let island = Window(ownerPID: 31, layer: 26, bounds: CGRect(x: 878, y: 0, width: 300, height: 80))
        _ = confirming.update(evaluate([island]).sightings, running: [31], now: Date())
        #expect(NotchNeighborDetection.pace(apps: unrelated, tracker: confirming) == .confirming)
        #expect(NotchNeighborMonitor.Pace.idle.interval == .seconds(10))
    }

    @Test func profilesMatchByPrefixIgnoringCase() {
        #expect(NotchNeighborProfile.profile(for: "com.surteesstudios.Bartender-setapp")?.name == "Bartender")
        #expect(NotchNeighborProfile.profile(for: "com.sanebar.app-setapp")?.name == "SaneBar")
        #expect(NotchNeighborProfile.profile(for: "celve.peninsula")?.name == "Peninsula")
        #expect(NotchNeighborProfile.profile(for: "com.better365.iBarPro")?.name == "iBar")
        #expect(NotchNeighborProfile.profile(for: "com.example.other") == nil)
        // Every bundle prefix belongs to exactly one profile.
        let prefixes = NotchNeighborProfile.all.flatMap(\.bundlePrefixes).map { $0.lowercased() }
        #expect(Set(prefixes).count == prefixes.count)
    }

    @MainActor @Test func panelLevels() {
        // On the notch: above the menu bar, as before.
        #expect(NotchPanel.level(placement: .notch, sharing: false, hovering: false) == .mainMenu + 3)
        #expect(NotchPanel.level(placement: .notch, sharing: false, hovering: true) == .mainMenu + 3)
        // Below a shared notch: under the neighbors' panels, above them while the pointer is on the pill,
        // and still below pop-up menus.
        #expect(NotchPanel.level(placement: .belowNotch, sharing: true, hovering: false) == .statusBar)
        #expect(NotchPanel.level(placement: .belowNotch, sharing: true, hovering: true).rawValue == 100)
        #expect(NotchPanel.level(placement: .menuBar, sharing: true, hovering: true) < .popUpMenu)
        // Stepping under a menu bar manager's bar alone keeps the old level.
        #expect(NotchPanel.level(placement: .belowNotch, sharing: false, hovering: false) == .mainMenu + 3)
    }

    // MARK: - Dock hooks (stage 5 uses them; nothing does yet)

    @Test func excludedProcessesNeverCount() {
        let island = Window(ownerPID: 31, layer: 26, bounds: CGRect(x: 878, y: 0, width: 300, height: 80))
        let box = Window(ownerPID: 20, layer: 27, bounds: CGRect(x: 708, y: 0, width: 640, height: 210))
        let result = NotchNeighborDetection.evaluate(windows: [island, box], screens: screens, apps: apps,
                                                     ownBundleID: "com.example.thisapp", excludedPIDs: [31, 20])
        #expect(result.sightings.isEmpty)
        #expect(result.exclusions.map(\.pid) == [31, 20])
        #expect(result.exclusions.allSatisfy { $0.reason == "excluded (a docked app)" })
        // Without the exclusion both count, as before.
        #expect(names([island, box]) == ["Agent Island", "Boring Notch"])
    }

    @Test func forgettingDropsStickyPresenceAtOnce() {
        var tracker = NotchNeighborTracker()
        let box = Window(ownerPID: 20, layer: 27, bounds: CGRect(x: 708, y: 0, width: 640, height: 210))
        let island = Window(ownerPID: 31, layer: 26, bounds: CGRect(x: 878, y: 0, width: 300, height: 80))
        let now = Date()
        _ = tracker.update(evaluate([box, island]).sightings, running: [20, 31], now: now)
        #expect(tracker.neighbors[20] != nil && tracker.isConfirming)
        #expect(tracker.forget(pid: 20)?.name == "Boring Notch")
        #expect(tracker.neighbors[20] == nil)
        // A pending sighting goes too, so the next look starts the confirmation over.
        #expect(tracker.forget(pid: 31) == nil && !tracker.isConfirming && !tracker.knows(31))
    }

    @MainActor @Test func theMonitorForgetsAProcessAsSoonAsItIsExcluded() {
        let monitor = NotchNeighborMonitor()
        monitor.excludedPIDs = [12345]
        #expect(monitor.excludedPIDs == [12345])
        monitor.excludedPIDs = []
        #expect(monitor.detected.isEmpty)
    }
}
