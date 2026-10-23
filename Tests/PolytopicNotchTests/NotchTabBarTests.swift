import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// `NotchTabBar`: clicking a tab selects it, and the bar draws in the pill, in the glass bar and in a plain window. PNGs with `NOTCH_RENDER_DIR`.
@MainActor
@Suite(.serialized)
struct NotchTabBarTests {
    enum Tab: String, CaseIterable { case connections = "Connections", dns = "DNS", blocked = "Blocked" }

    @Observable
    final class Model {
        var tab: Tab = .connections
        var resets = 0
        // The pattern the doc comment teaches: the selection in the app's model, a feed reset on change.
        var changes: Tab = .connections {
            didSet { if changes != oldValue { resets += 1 } }
        }
    }

    struct Bar: View {
        @Bindable var model: Model

        var body: some View {
            NotchTabBar(Tab.allCases, selection: $model.tab) { $0.rawValue }
                .frame(width: 300)
                .padding(10)
        }
    }

    /// Clicks the window at a point (window coordinates, y up), as the pointer would.
    func click(_ window: NSWindow, at point: NSPoint) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func clickingATabSelectsIt() async throws {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Bar(model: model))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))

        // Three equal tabs across 300 pt (10 pt in from the window's left): their centres.
        let tabWidth = (300 - 2 * 2 - 2 * 2) / 3.0
        func centre(_ tab: Tab) -> NSPoint {
            NSPoint(x: 10 + 2 + (tabWidth + 2) * Double(Tab.allCases.firstIndex(of: tab)!) + tabWidth / 2, y: 22)
        }
        try await click(window, at: centre(.dns))
        #expect(model.tab == .dns)
        try await click(window, at: centre(.blocked))
        #expect(model.tab == .blocked)
        try await click(window, at: centre(.connections))
        #expect(model.tab == .connections)
        try await click(window, at: NSPoint(x: 4, y: 22))
        #expect(model.tab == .connections, "a click beside the bar selects nothing")

        // The model's setter sees each change once (where an app resets its live feed).
        model.changes = .dns
        model.changes = .dns
        model.changes = .blocked
        #expect(model.resets == 2)
    }

    @Test func tabBarLooks() async throws {
        // In the open pill (black, dark) and in the glass bar on a screen without a notch.
        for (name, geometry) in [("tabbar-pill", TestScreens.geometry(TestScreens.notches[0])), ("tabbar-menubar", TestScreens.external)] {
            let model = Model()
            model.tab = .dns
            let content = NotchContent()
            content.status = .showing
            content.title = "Monitor"
            content.expanded = NotchBody(height: 120) {
                VStack(spacing: 8) {
                    NotchTabBar(Tab.allCases, selection: Binding(get: { model.tab }, set: { model.tab = $0 })) { $0.rawValue }
                    Text("Rows for \(model.tab.rawValue)").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            let pill = NotchViewModel(content: content, settings: InMemoryNotchSettings(), geometry: geometry,
                                      theme: NotchRenderTests.theme)
            pill.previewMode = .expanded
            let rep = try await OffscreenRender.window(name, size: NotchRenderTests.canvas) {
                ZStack(alignment: .top) {
                    Color(white: 0.55)
                    Color(white: 0.4).frame(height: geometry.menuBarHeight)
                    NotchView(model: pill).frame(width: pill.metrics.panelSize.width, height: pill.metrics.panelSize.height)
                }
                .frame(width: NotchRenderTests.canvas.width, height: NotchRenderTests.canvas.height, alignment: .top)
                .clipped()
            }
            #expect(OffscreenRender.inkCoverage(rep) > 0.004, "\(name) drew nothing")
        }
        // Outside the pill, light and dark, with icon labels.
        for dark in [false, true] {
            let model = Model()
            let rep = try await OffscreenRender.window("tabbar-window", size: NSSize(width: 340, height: 100), dark: dark) {
                VStack(spacing: 10) {
                    Bar(model: model)
                    NotchTabBar(Tab.allCases, selection: .constant(Tab.blocked)) { tab, selected in
                        Image(systemName: ["network", "globe", "hand.raised"][Tab.allCases.firstIndex(of: tab)!])
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    }
                    .frame(width: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            #expect(OffscreenRender.inkCoverage(rep) > 0.01)
        }
    }
}
