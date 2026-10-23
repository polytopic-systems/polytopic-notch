import CoreGraphics
import Foundation
import Security
import Testing
@testable import PolytopicNotch

@Suite("Announcement codec")
struct DockCodecTests {
    let full = NotchDockAnnouncement(appID: Fx.captioner, pid: 42, instance: "abc", displayID: 7, want: .live,
                                since: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7), mode: .showing,
                                restMode: .showing, sizes: Fx.captions, hovered: true, menuOpen: false,
                                hoverHold: CGRect(x: 476.5, y: 650, width: 560, height: 332),
                                hoverSince: Date(timeIntervalSinceReferenceDate: 812_345_679.25),
                                switcherClaim: NotchSwitcherClaim(pid: 9, at: Date(timeIntervalSinceReferenceDate: 1.5)),
                                seesStranger: true, barRect: CGRect(x: 1.5, y: 2, width: 3, height: 4),
                                supportedStyles: ["priority", "split", "future-style"], symbol: "captions.bubble")

    @Test("every message round-trips exactly, dates included",
          arguments: [NotchDockMessage.Kind.hello, .announce, .style, .bye])
    func roundTrip(kind: NotchDockMessage.Kind) {
        let message: NotchDockMessage = switch kind {
        case .hello: .hello(full)
        case .announce: .announce(full)
        case .style: .style(pid: 42, settings: NotchDockSharedSettings(
            style: "split", holdSeconds: 45, holdUntilAnswered: false, order: [Fx.captioner, Fx.monitor], blocked: [Fx.third],
            updatedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.5), writer: Fx.captioner))
        case .bye: .bye(pid: 42, instance: "abc")
        }
        let name = NotchDockWire.name(kind)
        #expect(name == "systems.polytopic.notch.v2.\(kind.rawValue)")
        #expect(NotchDockWire.decode(name: name, payload: NotchDockWire.encode(message)) == message)
    }

    @Test("unknown fields are ignored; unknown enum values degrade; missing fields default")
    func unknownFields() throws {
        let json = """
        {"appID":"com.example.Future","pid":5,"instance":"x","want":"frantic","mode":"hologram",
         "sizes":{"quiet":{"width":100,"bodyHeight":0,"depth":3},"teleport":{"width":1,"bodyHeight":1}},
         "since":10,"newField":{"nested":[1,2,3]},"supportedStyles":["priority","orbit"],"colour":"red"}
        """
        guard case .announce(let a)? = NotchDockWire.decode(kind: .announce, payload: json) else {
            Issue.record("did not decode")
            return
        }
        #expect(a.appID == "com.example.Future")
        #expect(a.want == .notice)
        #expect(a.mode == .quiet)
        #expect(a.sizes.quiet == NotchDockSize(width: 100, bodyHeight: 0))
        #expect(a.displayID == 0 && !a.hovered && a.barRect == nil && a.switcherClaim == nil)
        #expect(a.restMode == nil && a.rest == .quiet && a.hoverHold == nil && a.hoverSince == nil, "0.2.1 peers")
        #expect(a.symbol == "circle")
        #expect(a.supports(.priority) && !a.supports(.split))
        #expect(a.supportedStyles.contains("orbit"))
    }

    @Test("garbage and other majors are dropped")
    func garbage() {
        #expect(NotchDockWire.decode(kind: .announce, payload: "{}") == nil)
        #expect(NotchDockWire.decode(kind: .announce, payload: "not json") == nil)
        let payload = NotchDockWire.encode(.announce(full))
        #expect(NotchDockWire.decode(name: "systems.polytopic.notch.v3.announce", payload: payload) == nil)
        #expect(NotchDockWire.decode(name: "systems.polytopic.notch.v2.shout", payload: payload) == nil)
        // The 0.x protocol (v1, the payload in userInfo) is never read.
        #expect(NotchDockWire.decode(name: "com.example.polytopic.notch.v1.announce", payload: payload) == nil)
    }

    @Test("an announcement is small and carries no content")
    func small() {
        let payload = NotchDockWire.encode(.announce(full))
        #expect(payload.utf8.count < 800)
    }

    @Test("style names: unknown stored value reads as Priority")
    func styleNames() {
        #expect(NotchSharingStyle(stored: "merged") == .merged)
        #expect(NotchSharingStyle(stored: "orbit") == .priority)
        #expect(NotchSharingStyle(stored: nil) == .priority)
        #expect(NotchWant.none < .quiet && .quiet < .notice && .notice < .live && .live < .urgent)
    }
}

@Suite("Shared settings store")
@MainActor
struct DockSettingsStoreTests {
    @Test("defaults, writes, unknown style, order dedupe, register")
    func store() {
        let d = TestDefaults()
        defer { d.remove() }
        let s = NotchDockSettings(storage: d.defaults)
        #expect(s.style == .priority)
        #expect(s.urgentHold == .seconds(30))
        #expect(s.order.isEmpty)
        s.setStyle(.merged)
        #expect(s.style == .merged)
        d.defaults.set("orbit", forKey: "notch.sharingStyle")
        #expect(s.style == .priority)
        s.setUrgentHold(.untilAnswered)
        #expect(s.urgentHold == .untilAnswered)
        s.setUrgentHold(.seconds(12))
        #expect(s.urgentHold == .seconds(12))
        s.setOrder([Fx.monitor, Fx.captioner, Fx.monitor])
        #expect(s.order == [Fx.monitor, Fx.captioner])
        s.register(appID: Fx.captioner)
        s.register(appID: Fx.third)
        #expect(s.order == [Fx.monitor, Fx.captioner, Fx.third])
        #expect(NotchDockSettings.suiteName == "systems.polytopic.notch")
        #expect(s.blocked.isEmpty)
        s.setBlocked([Fx.third, Fx.captioner])
        #expect(s.blocked == [Fx.captioner, Fx.third])
    }
}

@Suite("Trust")
struct DockTrustTests {
    @Test("the default check rejects this test runner (Apple platform or ad hoc code) and Apple's own processes")
    func realRejects() async {
        let trust = DeveloperIDTrust()
        #expect(!trust.check(pid: getpid()))
        #expect(await trust.verify(pid: 1) == false) // launchd
        #expect(await trust.verify(pid: 999_999) == false) // no such process
    }

    @Test("both requirements compile")
    func requirementsCompile() {
        for text in [DeveloperIDTrust.releaseRequirement, DeveloperIDTrust.developmentRequirement] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        }
    }

    @Test("development certificates are admitted by default only in DEBUG")
    func developmentDefault() {
        #if DEBUG
        #expect(DeveloperIDTrust().admitsDevelopment)
        #else
        #expect(!DeveloperIDTrust().admitsDevelopment)
        #endif
    }

    @Test("the team check admits Apple-anchored code only with the team's OU")
    func requirementShape() {
        #expect(!CodeSignatureTrust(teamID: "NOTATEAM").signatureMatches(pid: getpid()))
        #expect(!CodeSignatureTrust(teamID: "NOTATEAM").signatureMatches(pid: 1))
    }

    /// In Release the override is compiled out. Run this in the Release configuration too:
    ///     swift test -c release -Xswiftc -enable-testing --scratch-path ~/Library/Caches/polytopic-notch-build-release --filter Trust
    @Test("the ad-hoc override exists only in DEBUG: in Release hasAdHocOverride is false")
    func adHocOverride() {
        #if DEBUG
        #expect(CodeSignatureTrust.hasAdHocOverride && DeveloperIDTrust.hasAdHocOverride)
        #else
        #expect(!CodeSignatureTrust.hasAdHocOverride && !DeveloperIDTrust.hasAdHocOverride)
        #endif
    }
}
