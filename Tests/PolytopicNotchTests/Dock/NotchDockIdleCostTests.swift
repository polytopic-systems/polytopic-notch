import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// A docked app that isn't changing anything posts nothing and schedules nothing: the meter, captions and titles
/// never reach the dock; only what decides the layout does.
@MainActor
@Suite(.serialized)
struct NotchDockIdleCostTests {
    @Test func aDockedIdleAppPostsNothingAndSchedulesNothing() async throws {
        let rig = DockedApps()
        defer { rig.stop() }
        let quiet = rig.add("com.example.idle.a", pid: 4_300_001) { $0.status = .quiet; $0.want = .quiet }
        let talking = rig.add("com.example.idle.b", pid: 4_300_002) { $0.status = .showing; $0.want = .live }
        talking.dock.setStyle(.merged)
        await rig.settle()
        try await Task.sleep(for: .milliseconds(200))
        await rig.settle()

        let posted = rig.bus.log.count
        let layouts = rig.apps.map(\.controller.layoutCount)
        let revisions = rig.apps.map(\.dock.revision)
        // The meter moves, captions change their words, the title changes: none of it is the dock's business.
        for i in 0..<30 {
            quiet.content.level = Double(i % 10) / 10
            talking.content.level = Double((i + 5) % 10) / 10
            talking.content.title = "Listening \(i)"
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(400))
        await rig.settle()
        #expect(rig.bus.log.count == posted, "nothing was announced")
        #expect(rig.apps.map(\.controller.layoutCount) == layouts, "nothing was laid out again")
        #expect(rig.apps.map(\.dock.revision) == revisions)
        #expect(rig.apps.allSatisfy { $0.dock.pendingHoldTimers == 0 }, "no timers without an urgent question")

        // One real change is one announcement.
        quiet.content.status = .showing
        quiet.content.want = .notice
        await rig.settle()
        let announces = rig.bus.log.dropFirst(posted).filter { if case .announce(let a) = $0 { a.pid == 4_300_001 } else { false } }
        #expect(announces.count == 1)
    }
}
