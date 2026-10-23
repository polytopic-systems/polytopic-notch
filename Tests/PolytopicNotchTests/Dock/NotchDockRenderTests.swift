import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// Renders docked apps the way they'd look together: each app's `NotchView` at its slot in its own canvas-sized
/// layer, stacked in window-level order over a grey desktop with a darker menu bar (and, optionally, the physical
/// notch in black). PNGs are written with `NOTCH_RENDER_DIR=<folder>`, at 1× and 2×. Glass comes out blank offscreen.
@MainActor
@Suite(.serialized)
struct NotchDockRenderTests {
    struct Part {
        var appID: String
        var pid: Int32
        var mode: NotchMode
        var want: NotchWant
        var color: Color
        var hovered = false
        var lines = 2
        var title = "App"
    }

    struct Scene {
        var canvas: CGRect
        var screen: NotchDockScreen
        var geometry: NotchGeometry
        /// In drawing order: lowest window level first.
        var models: [NotchViewModel]
        var slots: [Int32: NotchSlot]
    }

    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let notched = TestScreens.geometry(TestScreens.notches[0])   // 1512 wide, notch 188×32 at x 662…850

    func content(_ part: Part) -> NotchContent {
        let content = NotchContent()
        content.status = part.mode == .quiet ? .quiet : .showing
        content.want = part.want
        content.title = part.title
        content.level = 0.6
        content.dot = NotchDot(color: part.color, pulsing: false)
        content.showing = NotchBody(height: CGFloat(8 + part.lines * 20 + 12)) {
            DockSampleCaptions(lines: part.lines, color: part.color)
        }
        content.expanded = NotchBody(height: 150) { DockSampleExpanded(color: part.color) }
        return content
    }

    func scene(_ style: NotchSharingStyle, geometry: NotchGeometry = Self.notched, stranger: Bool = false,
               clearMenuBar: Bool = false, settles: Bool = true, _ parts: [Part]) -> Scene {
        let screen = NotchDockScreen(geometry: geometry, displayID: 1, scale: 2)
        let canvas = NotchPanelController.dockCanvas(for: screen)
        var models: [Int32: NotchViewModel] = [:]
        for part in parts {
            let settings = InMemoryNotchSettings()
            if clearMenuBar { settings.notch.pillShape = .clearMenuBar }
            let model = NotchViewModel(content: content(part), settings: settings,
                                       geometry: geometry.sharingNotch(stranger), theme: NotchRenderTests.theme)
            model.previewMode = part.mode
            model.isHovering = part.hovered
            models[part.pid] = model
        }
        // Twice, as the live dock settles (a slot can change what its app announces), unless `settles` is false.
        var slots: [Int32: NotchSlot] = [:]
        for _ in 0..<(settles ? 2 : 1) {
            let announcements = parts.enumerated().map { index, part in
                NotchDockAnnouncement(
                    appID: part.appID, pid: part.pid, instance: "i\(part.pid)", displayID: 1, want: part.want,
                    since: Self.t0.addingTimeInterval(Double(index)), mode: part.mode, sizes: models[part.pid]!.dockSizes,
                    hovered: part.hovered, seesStranger: stranger, symbol: ["captions.bubble", "network", "bell"][index % 3])
            }
            slots = NotchDockLayout.solve(style: style, screen: screen, participants: announcements,
                                          order: parts.map(\.appID), urgentHold: .standard, now: Self.t0.addingTimeInterval(10))
            for (pid, model) in models {
                let slot = slots[pid]!
                model.slot = slot
                model.dockCanvas = canvas
                var g = geometry.sharingNotch(slot.placement == .belowNotch)
                if g.placement != .notch, let anchor = slot.anchorY { g.drop = max(0, g.anchorY - anchor) }
                model.geometry = g
            }
        }
        let ordered = parts.map { models[$0.pid]! }.sorted {
            ($0.slot.stackHovered ? 100 : 27) + $0.slot.levelOffset < ($1.slot.stackHovered ? 100 : 27) + $1.slot.levelOffset
        }
        return Scene(canvas: canvas, screen: screen, geometry: geometry, models: ordered, slots: slots)
    }

    /// Hosts the scene offscreen and captures it at `scale` (1 or 2), writing `dock-<name>@<scale>x.png`.
    @discardableResult
    func render(_ name: String, _ scene: Scene, scale: CGFloat, physicalNotch: Bool = false) async throws -> NSBitmapImageRep {
        let size = scene.canvas.size
        let menuBar = scene.geometry.menuBarHeight
        let notch = scene.geometry.hasNotch ? scene.geometry.notchRect : .zero
        let notchLocal = CGRect(x: notch.minX - scene.canvas.minX, y: scene.canvas.maxY - notch.maxY,
                                width: notch.width, height: notch.height)
        let root = ZStack(alignment: .topLeading) {
            Color(white: 0.55)
            Color(white: 0.4).frame(height: menuBar)
            if physicalNotch, !notch.isEmpty {
                Rectangle().fill(.black)
                    .frame(width: notchLocal.width, height: notchLocal.height)
                    .offset(x: notchLocal.minX, y: notchLocal.minY)
            }
            ForEach(Array(scene.models.enumerated()), id: \.offset) { _, model in
                NotchView(model: model)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()

        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        let view = try #require(window.contentView)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try OffscreenRender.write(rep, name: "dock-\(name)\(physicalNotch ? "-notch" : "")@\(Int(scale))x")
        return rep
    }

    // MARK: Pixels

    func isBlack(_ rep: NSBitmapImageRep, px x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return c.redComponent + c.greenComponent + c.blueComponent < 0.15 && c.alphaComponent > 0.9
    }

    /// Canvas-local (y down) rect of a screen rect.
    func local(_ rect: CGRect, _ scene: Scene) -> CGRect {
        CGRect(x: rect.minX - scene.canvas.minX, y: scene.canvas.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static let a = "com.example.render.a", b = "com.example.render.b", c = "com.example.render.c"
    static let teal = Color(red: 0.25, green: 0.8, blue: 0.8), orange = Color.orange, pink = Color.pink

    func two(_ first: NotchMode, _ second: NotchMode, firstWant: NotchWant = .live, secondWant: NotchWant = .notice,
             hovered: (Bool, Bool) = (false, false)) -> [Part] {
        [Part(appID: Self.a, pid: 1, mode: first, want: firstWant, color: Self.teal, hovered: hovered.0, title: "Captions"),
         Part(appID: Self.b, pid: 2, mode: second, want: secondWant, color: Self.orange, hovered: hovered.1, lines: 1,
              title: "Firewall")]
    }

    // MARK: Every style and role

    @Test(arguments: [1.0, 2.0])
    func everyStyleAndRole(scale: Double) async throws {
        let s = CGFloat(scale)
        let three: [Part] = two(.showing, .quiet, secondWant: .quiet)
            + [Part(appID: Self.c, pid: 3, mode: .showing, want: .notice, color: Self.pink, lines: 1, title: "Mail")]
        let scenes: [(String, Scene, Set<NotchSlot.Role>)] = [
            ("priority-notch", scene(.priority, two(.showing, .quiet)), [.whole, .hidden]),
            ("switcher-notch-open", scene(.switcher, two(.expanded, .quiet, hovered: (true, false))), [.whole, .hidden]),
            ("split-notch-quiet", scene(.split, two(.quiet, .quiet, firstWant: .quiet, secondWant: .quiet)), [.leftWing, .rightWing]),
            ("split-notch-one-showing", scene(.split, two(.quiet, .showing, firstWant: .quiet)), [.leftWing, .rightWing]),
            ("split-notch-both-showing", scene(.split, two(.showing, .showing)), [.leftWing, .rightWing]),
            ("split-notch-three", scene(.split, three), [.leftWing, .rightWing]),
            ("merged-notch", scene(.merged, two(.showing, .quiet, secondWant: .quiet)), [.top, .bottom]),
            ("merged-notch-three", scene(.merged, three), [.top, .middle, .bottom]),
            ("merged-notch-hovered", scene(.merged, two(.showing, .expanded, hovered: (false, true))), [.top, .bottom]),
            ("priority-menubar", scene(.priority, geometry: TestScreens.external, two(.showing, .quiet)), [.whole, .hidden]),
            ("split-menubar", scene(.split, geometry: TestScreens.external, two(.quiet, .showing, firstWant: .quiet)), [.whole]),
            ("merged-menubar", scene(.merged, geometry: TestScreens.external, two(.showing, .quiet, secondWant: .quiet)), [.whole]),
            ("merged-below-stranger", scene(.merged, stranger: true, two(.showing, .showing)), [.whole]),
            ("split-below-stranger", scene(.split, stranger: true, two(.showing, .quiet, secondWant: .quiet)), [.whole]),
        ]
        for (name, scene, roles) in scenes {
            #expect(Set(scene.slots.values.map(\.role)) == roles, "\(name)")
            let rep = try await render(name, scene, scale: s)
            #expect(OffscreenRender.inkCoverage(rep) > 0.004, "\(name) drew nothing")
        }
    }

    // MARK: Switcher dots

    /// While two or more apps are docked in Switcher, the open pill shows the dots in a 26 pt row of their own above the
    /// body, centred under the notch, in every placement (at the notch they used to sit in the band, crowding the body's
    /// top-right buttons). The layout's slot is exactly as tall as the pill, from the first layout.
    @Test func theSwitcherDotsAlwaysGetACentredRowAboveTheBody() {
        let open = two(.expanded, .quiet, hovered: (true, false))
        let cases: [(String, Scene)] = [
            ("notch", scene(.switcher, open)),
            ("below a stranger", scene(.switcher, stranger: true, open)),
            ("menu bar kept clear", scene(.switcher, clearMenuBar: true, open)),
            ("menu bar", scene(.switcher, geometry: TestScreens.external, open)),
            ("notch, first layout", scene(.switcher, settles: false, open)),
        ]
        for (name, scene) in cases {
            let model = scene.models.first { $0.slot.isOpen }!
            #expect(model.showsSwitcherDots, "\(name)")
            #expect(model.switcherRowHeight == 26, "\(name)")
            let pill = model.size(for: .expanded)
            let band = model.placement == .notch ? model.notchTop(for: .expanded) : model.topBandHeight
            #expect(pill.height == band + 26 + 150, "\(name): band, row, body")
            #expect(model.slot.frame!.height == pill.height, "\(name): the layout makes room for the row too")
            let dockBand = NotchDockMetrics(model.metrics).band(model.placement, notchHeight: model.geometry.notchSize.height)
            #expect(model.dockSizes.expanded?.bodyHeight == Double(pill.height - dockBand - 26), "\(name): the row isn't announced")
        }
        // The other app (not open) and an app alone get no row.
        let closed = scene(.switcher, two(.expanded, .quiet, hovered: (true, false))).models.first { !$0.slot.isOpen }!
        #expect(!closed.showsSwitcherDots)
        let alone = scene(.switcher, stranger: true, [two(.expanded, .quiet, hovered: (true, false))[0]])
        #expect(!alone.models[0].showsSwitcherDots && alone.models[0].switcherRowHeight == 0)
        #expect(alone.models[0].slot.frame!.height == alone.models[0].size(for: .expanded).height)
    }

    @Test(arguments: [1.0, 2.0])
    func switcherDotsRow(scale: Double) async throws {
        let open = two(.expanded, .quiet, hovered: (true, false))
        for (name, scene) in [("switcher-notch-open", scene(.switcher, open)),
                              ("switcher-below-stranger-open", scene(.switcher, stranger: true, open)),
                              ("switcher-clear-menubar-open", scene(.switcher, clearMenuBar: true, open)),
                              ("switcher-menubar-open", scene(.switcher, geometry: TestScreens.external, open))] {
            let rep = try await render(name, scene, scale: CGFloat(scale), physicalNotch: true)
            #expect(OffscreenRender.inkCoverage(rep) > 0.004, "\(name) drew nothing")
        }
    }

    // MARK: Merged joints

    /// Where a lower part meets the part above, every pixel across the joint is black (no seam line, no lighter row),
    /// and the sides line up exactly (no step: the pixel column just outside is the desktop above and below).
    @Test(arguments: [1.0, 2.0])
    func mergedJointsArePureBlack(scale: Double) async throws {
        let s = CGFloat(scale)
        let three: [Part] = two(.showing, .quiet, secondWant: .quiet)
            + [Part(appID: Self.c, pid: 3, mode: .showing, want: .notice, color: Self.pink, lines: 1, title: "Mail")]
        let cases: [(String, Scene)] = [
            ("joint-two", scene(.merged, two(.showing, .quiet, secondWant: .quiet))),
            ("joint-three", scene(.merged, three)),
            ("joint-hovered", scene(.merged, two(.showing, .expanded, hovered: (false, true)))),
        ]
        for (name, scene) in cases {
            let rep = try await render(name, scene, scale: s)
            let parts = scene.models.map(\.slot).sorted { $0.levelOffset > $1.levelOffset }   // top first
            for (above, below) in zip(parts, parts.dropFirst()) {
                let upper = local(above.visibleFrame!, scene), lower = local(below.frame!, scene)
                let jointRow = Int((upper.maxY * s).rounded())
                let firstColumn = Int((lower.minX * s).rounded()), lastColumn = Int((lower.maxX * s).rounded()) - 1
                var nonBlack = 0
                for row in (jointRow - 1)...(jointRow) {
                    for column in firstColumn...lastColumn where !isBlack(rep, px: column, row) { nonBlack += 1 }
                }
                #expect(nonBlack == 0, "\(name) @\(scale)x: \(nonBlack) non-black pixels at the joint (row \(jointRow))")
                // The sides: the column just outside the lower part is desktop right above and below the joint, and
                // its own edge columns are black.
                for column in [firstColumn - 1, lastColumn + 1] {
                    for row in [jointRow - 2, jointRow + 2] {
                        #expect(!isBlack(rep, px: column, row), "\(name) @\(scale)x: a step at the joint's side (\(column), \(row))")
                    }
                }
                for column in [firstColumn, lastColumn] {
                    #expect(isBlack(rep, px: column, jointRow - 2) && isBlack(rep, px: column, jointRow + 2),
                            "\(name) @\(scale)x: the edge column \(column) isn't black across the joint")
                }
            }
        }
    }

    // MARK: Split slit

    /// The slit between the two wings lies inside the notch: drawn over the physical notch it's black; without the
    /// notch it shows only within the notch's height; below the notch there's nothing between quiet ears.
    @Test(arguments: [1.0, 2.0])
    func theSplitSlitHidesInTheNotch(scale: Double) async throws {
        let s = CGFloat(scale)
        let quiet = scene(.split, two(.quiet, .quiet, firstWant: .quiet, secondWant: .quiet))
        let left = quiet.slots[1]!, right = quiet.slots[2]!
        let notch = quiet.geometry.notchRect
        #expect(left.frame!.maxX > notch.minX && right.frame!.minX < notch.maxX)
        let slit = local(CGRect(x: left.frame!.maxX, y: notch.minY, width: right.frame!.minX - left.frame!.maxX,
                                height: notch.height), quiet)
        let midColumn = Int((slit.midX * s).rounded(.down)), midRow = Int((slit.midY * s).rounded(.down))
        let bare = try await render("slit", quiet, scale: s)
        #expect(!isBlack(bare, px: midColumn, midRow), "without the notch the slit is visible")
        #expect(isBlack(bare, px: Int((slit.minX - 2) * s), midRow) && isBlack(bare, px: Int((slit.maxX + 2) * s), midRow))
        let real = try await render("slit", quiet, scale: s, physicalNotch: true)
        #expect(isBlack(real, px: midColumn, midRow), "over the notch the slit is hidden")
        // Just below the notch, between the ears: desktop.
        #expect(!isBlack(real, px: midColumn, Int((slit.maxY + 2) * s)))
        // The quiet ears stay within today's quiet ears: 40 pt beside the notch on each side.
        #expect(left.frame!.minX == notch.minX - 40 && right.frame!.maxX == notch.maxX + 40)
        let earLeft = local(left.frame!, quiet)
        #expect(!isBlack(real, px: Int((earLeft.minX - 1) * s), Int(4 * s)), "nothing beyond the ear")
        #expect(isBlack(real, px: Int((earLeft.minX + 8) * s), Int(4 * s)), "the ear itself")

        // Showing on both sides: the bodies' slit runs on below the notch, 6 pt wide, the same in both renders.
        let both = scene(.split, two(.showing, .showing))
        let bodyGap = both.slots[2]!.bodyFrame!.minX - both.slots[1]!.bodyFrame!.maxX
        #expect(bodyGap == 6)
        _ = try await render("slit-showing", both, scale: s, physicalNotch: true)
    }

    // MARK: Settings rows

    @Test func dockSettingsRows() async throws {
        let storage = InMemoryNotchDockSettingsStorage()
        let settings = NotchDockSettings(storage: storage)
        settings.setOrder(["com.example.Captioner", "com.example.Monitor"])
        settings.setStyle(.split)
        let dock = NotchDock(appID: "com.example.Monitor", pid: 4_200_001, symbol: "network",
                             channel: InMemoryNotchDockBus().makeChannel(), trust: NotchDockStaticTrust(trusted: []),
                             settings: settings, processes: ManualNotchDockProcessWatcher())
        for dark in [false, true] {
            let rep = try await OffscreenRender.window("dock-settings-rows", size: NSSize(width: 560, height: 640), dark: dark) {
                Form {
                    Section("Sharing the notch with your other apps") {
                        NotchDockSettingsRows(dock: dock)
                    }
                }
                .formStyle(.grouped)
            }
            #expect(OffscreenRender.inkCoverage(rep) > 0.02)
        }
        #expect(NotchDockAppList.rows(order: ["x", "y"], me: "me", peers: ["p", "x"]) == ["x", "y", "me", "p"])
        // The rows write the shared settings.
        dock.setUrgentHold(.untilAnswered)
        #expect(settings.urgentHold == .untilAnswered && dock.urgentHoldSeconds == 30)
        dock.setUrgentHold(.seconds(45))
        dock.setUrgentHold(.untilAnswered)
        #expect(dock.urgentHoldSeconds == 45, "the seconds are kept while it's until answered")
    }
}

// MARK: - Sample bodies

private struct DockSampleCaptions: View {
    var lines: Int
    var color: Color
    @Environment(NotchViewModel.self) private var model
    static let sample = ["so the plan is to ship both apps with the shared notch",
                         "and the captions keep flowing in the top slot",
                         "while the firewall's strip sits right underneath"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<lines, id: \.self) { i in
                Text(Self.sample[i % Self.sample.count])
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(i == lines - 1 ? color : .white)
                    .lineLimit(1)
                    .frame(height: 20, alignment: .leading)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: model.bodyTextWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private struct DockSampleExpanded: View {
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(color.opacity(0.8)))
                Spacer()
                // Buttons at the top-right corner, as apps put them (open the app, settings): the Switcher dots
                // must never cover them.
                Image(systemName: "arrow.up.forward.app")
                Image(systemName: "gearshape")
            }
            Text("Controls while hovered").font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}
