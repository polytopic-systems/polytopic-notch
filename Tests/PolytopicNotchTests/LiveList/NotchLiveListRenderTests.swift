import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// Renders live lists offscreen: newest-first rows with actions (an event log) and a newest-last transcript, live and held with the "N new" capsule, in the pill's black look (dark) and the menu bar look (light).
/// PNGs with `NOTCH_RENDER_DIR=<folder>`: `live-list-<edge>-<live|held>[-dark].png`.
@MainActor
@Suite(.serialized)
struct NotchLiveListRenderTests {
    static let size = NSSize(width: 440, height: 210)

    func model(dark: Bool) -> NotchViewModel {
        let model = NotchViewModel.test(dark ? TestScreens.geometry(TestScreens.notches[0]) : TestScreens.external)
        model.theme = NotchRenderTests.theme
        return model
    }

    func feed(_ edge: NotchLiveEdge, held: Bool) -> NotchLiveFeed<LiveItem> {
        let feed = NotchLiveFeed<LiveItem>(edge: edge)
        let first = (1...12).map { LiveItem(id: $0, text: Self.texts[$0 % Self.texts.count]) }
        feed.publish(edge == .top ? first.reversed() : first)
        if held {
            feed.hold(.app("render"))
            let more = (1...17).map { LiveItem(id: $0, text: Self.texts[$0 % Self.texts.count]) }
            feed.publish(edge == .top ? more.reversed() : more)
        }
        return feed
    }

    static let texts = ["api.example.com", "updates.example.org", "time.apple.com", "cdn.example.net",
                        "telemetry.example.io", "mail.example.com"]

    @Test(arguments: [NotchLiveEdge.top, .bottom])
    func liveAndHeld(edge: NotchLiveEdge) async throws {
        for held in [false, true] {
            for dark in [false, true] {
                let feed = feed(edge, held: held)
                let model = model(dark: dark)
                let name = "live-list-\(edge == .top ? "top" : "bottom")-\(held ? "held" : "live")"
                let rep = try await OffscreenRender.window(name, size: Self.size, dark: dark) {
                    ZStack {
                        (dark ? Color.black : Color(white: 0.93))
                        Group {
                            if edge == .top {
                                NotchLiveList(feed, spacing: 2) { item in EventRow(item: item, dark: dark) }
                            } else {
                                NotchLiveList(feed, spacing: 4) { item in TranscriptLine(item: item, dark: dark) }
                            }
                        }
                        .padding(10)
                    }
                    .environment(model)
                }
                #expect(OffscreenRender.inkCoverage(rep) > 0.02, "\(name) drew nothing")
                #expect(feed.isHeld == held)
                #expect(feed.pendingNew == (held ? 5 : 0))
            }
        }
    }

    @Test func capsuleTextIsReadable() {
        let onYellow = NSColor(NotchLiveNewCapsule.readableText(on: .yellow)).usingColorSpace(.sRGB)!
        let onNavy = NSColor(NotchLiveNewCapsule.readableText(on: Color(red: 0, green: 0, blue: 0.3))).usingColorSpace(.sRGB)!
        #expect(onYellow.redComponent < 0.2, "dark text on a light fill")
        #expect(onNavy.redComponent > 0.9, "white text on a dark fill")
    }
}

/// A row like Monitor's: app, host, and two buttons; the row is marked as an action.
private struct EventRow: View {
    let item: LiveItem
    let dark: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.dashed").foregroundStyle(dark ? .white.opacity(0.7) : .secondary)
            Text("App \(item.id)").font(.system(size: 12, weight: .semibold))
            Text(item.text).font(.system(size: 12)).foregroundStyle(dark ? .white.opacity(0.7) : .secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button("Allow") {}.controlSize(.small)
            Button("Block") {}.controlSize(.small)
        }
        .foregroundStyle(dark ? .white : .primary)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .notchLiveAction()
    }
}

/// A transcript line: text only, not marked.
private struct TranscriptLine: View {
    let item: LiveItem
    let dark: Bool

    var body: some View {
        Text("\(item.id). Speech segment about \(item.text), which goes on long enough to wrap onto a second line.")
            .font(.system(size: 13))
            .foregroundStyle(dark ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
