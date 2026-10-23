import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// Pointer walks over two docked apps with realistic content, in every style: the pointer held still must leave the
/// dock settled (nothing changes after about a second), moving from one app's part to the other's hands over once,
/// only one pill is open at a time, and a panel takes clicks only while hovered and only over its own part.
///
/// The apps: "captioner" shows captions (captions 500 × 60, a tall expanded transcript 560 × 340, live), "monitor" posts
/// short notices (a short post 360 × 30, an expanded panel 440 × 210). The test screen is 1512 × 1000 with a 188 × 32
/// notch centred at x = 756.
@MainActor
@Suite(.serialized)
struct NotchDockHoverTests {
    static let captioner = "com.example.test.captioner", monitor = "com.example.test.monitor"

    static func captionerLike(_ content: NotchContent) {
        content.status = .showing
        content.want = .live
        content.showing = NotchBody(height: 60) { Text("captions") }
        content.expanded = NotchBody(height: 340) { Text("transcript") }
    }

    static func monitorLike(showing: Bool) -> (NotchContent) -> Void {
        { content in
            content.status = showing ? .showing : .quiet
            content.want = showing ? .notice : .quiet
            content.showing = NotchBody(width: 360, height: 30) { Text("post") }
            content.expanded = NotchBody(width: 440, height: 210) { Text("panel") }
        }
    }

    func rig(_ style: NotchSharingStyle, monitorShowing: Bool, pids: (Int32, Int32))
        async -> (DockedApps, DockedApps.App, DockedApps.App) {
        let rig = DockedApps()
        let captioner = rig.add(Self.captioner, pid: pids.0, configure: Self.captionerLike)
        let monitor = rig.add(Self.monitor, pid: pids.1, configure: Self.monitorLike(showing: monitorShowing))
        captioner.dock.setOrder([Self.captioner, Self.monitor])
        captioner.dock.setStyle(style)
        await rig.settle()
        return (rig, captioner, monitor)
    }

    func expectSettled(_ rig: DockedApps, _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rig.quiet(for: 0.5), "\(what): still changing a second after the pointer stopped", sourceLocation: sourceLocation)
        #expect(rig.clickViolations.isEmpty, "\(what): \(rig.clickViolations.prefix(3))", sourceLocation: sourceLocation)
        #expect(rig.doubleOpen.isEmpty, "\(what): \(rig.doubleOpen.prefix(3))", sourceLocation: sourceLocation)
    }

    func contains(_ app: DockedApps.App, _ point: NSPoint) -> Bool { DockedApps.drawnPart(app).contains(point) }

    // MARK: Priority (the owner saw it working: a regression guard)

    @Test func priorityHoverSettles() async {
        let (rig, captioner, monitor) = await rig(.priority, monitorShowing: true, pids: (4_200_001, 4_200_002))
        defer { rig.stop() }
        let notch = rig.geometry.notchRect
        rig.move(to: NSPoint(x: notch.midX, y: notch.midY))
        await rig.hold(1.5)
        #expect(captioner.model.mode == .expanded && monitor.slot.role == .hidden)
        expectSettled(rig, "Priority, pointer on the notch")
        rig.move(to: NSPoint(x: notch.midX, y: 300))
        await rig.hold(1.2)
        #expect(!captioner.model.isHovering && captioner.model.mode == .showing)
        expectSettled(rig, "Priority, pointer gone")
    }

    // MARK: Switcher

    /// Finding 1: after a dot click the target must stay open under the pointer until the pointer leaves the dock.
    @Test func switcherDotClickLeavesTheTargetOpenUnderThePointer() async throws {
        let (rig, captioner, monitor) = await rig(.switcher, monitorShowing: false, pids: (4_200_011, 4_200_012))
        defer { rig.stop() }
        let notch = rig.geometry.notchRect
        rig.move(to: NSPoint(x: notch.midX, y: notch.midY))
        await rig.hold(1.0)
        #expect(captioner.model.mode == .expanded && captioner.slot.switcherDots.count == 2)
        // The dots sit in the open pill's band, just before the status dot: Monitor's is the second, around x = 985.
        let open = DockedApps.drawnPart(captioner)
        let dot = NSPoint(x: open.maxX - 6 - 34 - 11, y: open.maxY - 16)
        rig.move(to: dot)
        await rig.hold(0.3)
        #expect(captioner.model.isHovering, "still on the open pill")
        captioner.model.onSwitcherDot?(4_200_012)
        let after = await rig.hold(2.0)
        #expect(monitor.slot.role == .whole && monitor.model.mode == .expanded, "the target is open")
        #expect(captioner.slot.role == .hidden, "the claimer stays aside")
        #expect(contains(monitor, dot), "the target's open pill is under the pointer")
        #expect(rig.hoverOns(after, app: 0) == 0, "the claimer never comes back under the pointer")
        #expect(after.filter { $0.app == 0 && $0.state.hasPrefix("whole") }.isEmpty, "no flash back to the claimer")
        expectSettled(rig, "Switcher, after a dot click")

        // The pointer leaves the dock: the claim ends and Priority decides again (the live app).
        rig.move(to: NSPoint(x: notch.midX, y: 300))
        await rig.hold(1.2)
        #expect(captioner.dock.me.switcherClaim == nil)
        #expect(captioner.slot.role == .whole && captioner.model.mode == .showing && !monitor.model.isHovering)
        expectSettled(rig, "Switcher, pointer gone")
    }

    // MARK: Merged

    /// Finding 2: hover moves from the top part down to the lower one and back.
    @Test func mergedHoverHandsOverBetweenPartsWithoutJumping() async throws {
        let (rig, captioner, monitor) = await rig(.merged, monitorShowing: false, pids: (4_200_021, 4_200_022))
        defer { rig.stop() }
        #expect(captioner.slot.role == .top && monitor.slot.role == .bottom)

        // On the captions: Captioner's part opens; Monitor's row moves down with it.
        let topPart = try #require(captioner.slot.visibleFrame)
        rig.move(to: NSPoint(x: topPart.midX, y: topPart.minY + 20))
        await rig.hold(1.2)
        #expect(captioner.model.mode == .expanded && monitor.model.mode == .quiet)
        expectSettled(rig, "Merged, on the top part")

        // Down onto Monitor's row: Monitor's part opens and stays under the pointer.
        let row = try #require(monitor.slot.visibleFrame)
        let onRow = NSPoint(x: row.midX, y: row.midY)
        rig.resetChecks()
        rig.move(to: onRow)
        let changes = await rig.hold(2.0)
        #expect(monitor.model.mode == .expanded, "the lower part is open")
        #expect(captioner.model.mode == .showing, "only the hovered part is taller")
        #expect(contains(monitor, onRow), "and it is still under the pointer")
        #expect(rig.hoverOns(changes, app: 1) == 1, "handed over once")
        #expect(rig.hoverOns(changes, app: 0) == 0, "no ping-pong back to the top part")
        expectSettled(rig, "Merged, moved down to the lower part")

        // Back up onto the captions.
        let top = try #require(captioner.slot.visibleFrame)
        let onTop = NSPoint(x: top.midX, y: top.maxY - 50)
        rig.resetChecks()
        rig.move(to: onTop)
        let up = await rig.hold(2.0)
        #expect(captioner.model.mode == .expanded && monitor.model.mode == .quiet)
        #expect(contains(captioner, onTop))
        #expect(rig.hoverOns(up, app: 0) == 1 && rig.hoverOns(up, app: 1) == 0)
        expectSettled(rig, "Merged, moved back up")

        rig.move(to: NSPoint(x: 756, y: 200))
        await rig.hold(1.2)
        #expect(!captioner.model.isHovering && !monitor.model.isHovering && captioner.model.mode == .showing)
        expectSettled(rig, "Merged, pointer gone")
    }

    /// Three parts, both showing and quiet ones: a walk down and up the stack hands over once per part, and the part
    /// under the pointer is always the open one.
    @Test func mergedThreePartWalk() async throws {
        let rig = DockedApps()
        defer { rig.stop() }
        let captioner = rig.add(Self.captioner, pid: 4_200_061, configure: Self.captionerLike)
        let monitor = rig.add(Self.monitor, pid: 4_200_062, configure: Self.monitorLike(showing: true))
        let third = rig.add("com.example.test.third", pid: 4_200_063, configure: Self.monitorLike(showing: false))
        captioner.dock.setOrder([Self.captioner, Self.monitor, "com.example.test.third"])
        captioner.dock.setStyle(.merged)
        await rig.settle()
        #expect(captioner.slot.role == .top && monitor.slot.role == .middle && third.slot.role == .bottom)
        let apps = [captioner, monitor, third]
        // Top, bottom, middle, top, middle, bottom: each time into the middle of what shows of that part now.
        for (step, target) in [0, 2, 1, 0, 1, 2].enumerated() {
            let part = try #require(DockedApps.drawnPart(apps[target]).nonEmpty)
            let point = NSPoint(x: part.midX, y: part.minY + min(12, part.height / 2))
            rig.resetChecks()
            rig.move(to: point)
            let walk = await rig.hold(1.5)
            #expect(apps[target].model.mode == .expanded, "step \(step): the part under the pointer is open")
            #expect(contains(apps[target], point), "step \(step): and still under the pointer")
            for i in apps.indices where i != target {
                #expect(apps[i].model.mode != .expanded, "step \(step): app \(i) is closed")
            }
            #expect(rig.hoverOns(walk, app: target) <= 1, "step \(step): handed over once")
            expectSettled(rig, "Merged, three parts, step \(step)")
        }
        rig.move(to: NSPoint(x: 756, y: 100))
        await rig.hold(1.2)
        #expect(apps.allSatisfy { !$0.model.isHovering && $0.model.mode != .expanded })
        expectSettled(rig, "Merged, three parts, pointer gone")
    }

    /// Finding 4: a hovered panel must not take clicks beside its part (other apps' parts, menu bar items in the
    /// canvas), not even while its hover winds down.
    @Test func aHoveredPanelTakesClicksOnlyOverItsOwnPart() async throws {
        let (rig, captioner, monitor) = await rig(.merged, monitorShowing: false, pids: (4_200_031, 4_200_032))
        defer { rig.stop() }
        let topPart = try #require(captioner.slot.visibleFrame)
        rig.move(to: NSPoint(x: topPart.midX, y: topPart.minY + 20))
        await rig.hold(1.0)
        #expect(captioner.model.isHovering && !captioner.controller.panelIgnoresMouse)
        #expect(monitor.controller.panelIgnoresMouse)
        // A menu bar item beside the notch, inside the docked panel's canvas: the click must reach it at once.
        let canvas = NotchPanelController.dockCanvas(for: rig.screen)
        let menuBarItem = NSPoint(x: canvas.minX + 40, y: 990)
        #expect(canvas.contains(menuBarItem))
        rig.move(to: menuBarItem)
        #expect(captioner.controller.panelIgnoresMouse, "the panel lets the click through beside its part")
        #expect(monitor.controller.panelIgnoresMouse)
        await rig.hold(1.0)
        #expect(!captioner.model.isHovering && captioner.controller.panelIgnoresMouse)
        #expect(rig.clickViolations.isEmpty, "\(rig.clickViolations.prefix(3))")
    }

    // MARK: Split

    /// Finding 3 (and 5): hovering the outer edge of Monitor's half, where its open pill (440 wide) doesn't reach.
    @Test func splitHoverAtTheEdgeOfAHalfSettles() async throws {
        let (rig, _, monitor) = await rig(.split, monitorShowing: true, pids: (4_200_041, 4_200_042))
        defer { rig.stop() }
        let body = try #require(monitor.slot.bodyFrame)
        let edge = NSPoint(x: body.maxX - 4, y: body.midY)
        rig.move(to: edge)
        let changes = await rig.hold(2.0)
        #expect(monitor.model.mode == .expanded, "Monitor opens")
        #expect(contains(monitor, edge), "its open pill covers where the pointer is")
        #expect(rig.hoverOns(changes, app: 1) == 1, "no ping-pong")
        expectSettled(rig, "Split, pointer at the edge of a half")
    }

    /// Finding 3: one app's pill is open; the pointer moves along the band to the other app's ear and back.
    @Test func splitEarsHandTheOpenPillOver() async throws {
        let (rig, captioner, monitor) = await rig(.split, monitorShowing: true, pids: (4_200_051, 4_200_052))
        defer { rig.stop() }
        #expect(captioner.slot.role == .leftWing && monitor.slot.role == .rightWing)
        let notch = rig.geometry.notchRect
        let leftEar = NSPoint(x: notch.minX - 20, y: notch.midY)
        let rightEar = NSPoint(x: notch.maxX + 20, y: notch.midY)
        rig.move(to: leftEar)
        await rig.hold(1.0)
        #expect(captioner.model.mode == .expanded && monitor.slot.role == .hidden)
        expectSettled(rig, "Split, on the left ear")

        rig.resetChecks()
        rig.move(to: NSPoint(x: notch.midX, y: notch.midY))
        await rig.hold(0.5)
        #expect(captioner.model.mode == .expanded, "crossing the notch keeps the open pill")
        rig.move(to: rightEar)
        let over = await rig.hold(1.5)
        #expect(monitor.model.mode == .expanded && captioner.slot.role == .hidden, "the right ear hands the pill to Monitor")
        #expect(contains(monitor, rightEar))
        #expect(rig.hoverOns(over, app: 1) == 1 && rig.hoverOns(over, app: 0) == 0)
        expectSettled(rig, "Split, moved to the right ear")

        rig.resetChecks()
        rig.move(to: leftEar)
        let back = await rig.hold(1.5)
        #expect(captioner.model.mode == .expanded && monitor.slot.role == .hidden)
        #expect(rig.hoverOns(back, app: 0) == 1 && rig.hoverOns(back, app: 1) == 0)
        expectSettled(rig, "Split, back to the left ear")

        rig.move(to: NSPoint(x: notch.midX, y: 200))
        await rig.hold(1.2)
        #expect(captioner.slot.role == .leftWing && monitor.slot.role == .rightWing)
        expectSettled(rig, "Split, pointer gone")
    }
}

extension CGRect {
    var nonEmpty: CGRect? { isNull || isEmpty ? nil : self }
}
