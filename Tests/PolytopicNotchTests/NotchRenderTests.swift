import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// Renders the pill offscreen in each look, and the Settings rows. PNGs are written only with
/// `NOTCH_RENDER_DIR=<folder>`. The pill is drawn over a grey "desktop" with a darker menu bar strip, so the black
/// shape is visible.
@MainActor
@Suite(.serialized)
struct NotchRenderTests {
    static let theme = NotchTheme(accent: { Color(red: 0.55, green: 0.36, blue: 0.96) },
                                  accentText: { $0 == .dark ? Color(red: 0.72, green: 0.6, blue: 1) : Color(red: 0.42, green: 0.24, blue: 0.82) })

    /// Bodies like an app's: a headline, an expanded panel with a menu button, a question.
    func content(_ status: NotchContent.Status) -> NotchContent {
        let content = NotchContent()
        content.status = status
        content.title = "Heartbeat"
        content.symbol = "waveform.path.ecg"
        content.level = 0.6
        content.showing = NotchBody(height: 46) { SampleHeadline() }
        content.expanded = NotchBody(height: 180) { SampleExpanded() }
        return content
    }

    func model(_ mode: NotchMode, shape: NotchPillShape = .grow, indicator: NotchIndicatorPosition = .besideNotch,
               geometry: NotchGeometry = TestScreens.geometry(TestScreens.notches[0]), sharing: Bool = false,
               busy: Bool = false) -> NotchViewModel {
        let content = content(mode == .quiet ? .quiet : .showing)
        content.busy = busy
        if mode == .asking { content.prompt = NotchBody(height: 92) { SampleQuestion() } }
        let model = NotchViewModel(content: content, settings: InMemoryNotchSettings(NotchSettings(pillShape: shape, indicator: indicator)),
                                   geometry: geometry.sharingNotch(sharing), theme: Self.theme)
        model.previewMode = mode
        return model
    }

    static let canvas = NSSize(width: 680, height: 380)

    func render(_ name: String, _ model: NotchViewModel) async throws -> NSBitmapImageRep {
        let menuBar = model.geometry.menuBarHeight
        let panel = model.metrics.panelSize
        return try await OffscreenRender.window(name, size: Self.canvas) {
            ZStack(alignment: .top) {
                Color(white: 0.55)
                Color(white: 0.4).frame(height: menuBar)
                NotchView(model: model)
                    .frame(width: panel.width, height: panel.height)
            }
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .clipped()
        }
    }

    @Test func pillLooks() async throws {
        let looks: [(String, NotchViewModel)] = [
            ("notch-quiet", model(.quiet)),
            ("notch-quiet-under", model(.quiet, indicator: .underNotch)),
            ("notch-quiet-busy", model(.quiet, busy: true)),
            ("notch-showing", model(.showing)),
            ("notch-showing-clear-menu-bar", model(.showing, shape: .clearMenuBar)),
            ("notch-expanded", model(.expanded)),
            ("notch-asking", model(.asking)),
            ("shared-quiet", model(.quiet, sharing: true)),
            ("shared-showing", model(.showing, sharing: true)),
            ("shared-expanded", model(.expanded, sharing: true)),
            ("menubar-showing", model(.showing, geometry: TestScreens.external)),
        ]
        for (name, model) in looks {
            let rep = try await render(name, model)
            #expect(OffscreenRender.inkCoverage(rep) > 0.004, "\(name) drew nothing")
        }
    }

    /// The two shapes measured in pixels: growing covers the menu bar beside the notch, keeping it clear doesn't.
    @Test func theShapesInPixels() async throws {
        let notch = TestScreens.notches[0]
        let centre = Self.canvas.width / 2
        let besideNotch = centre + notch.1 / 2 + 40           // in the menu bar, beside the notch
        let grow = try await render("pixels-grow", model(.showing))
        #expect(OffscreenRender.isBlack(grow, x: besideNotch, y: 10, pointSize: Self.canvas))
        let clear = try await render("pixels-clear", model(.showing, shape: .clearMenuBar))
        #expect(!OffscreenRender.isBlack(clear, x: besideNotch, y: 10, pointSize: Self.canvas), "the menu bar stays clear")
        #expect(OffscreenRender.isBlack(clear, x: centre, y: 10, pointSize: Self.canvas), "the neck is the notch")
        #expect(OffscreenRender.isBlack(clear, x: besideNotch, y: notch.3 + 30, pointSize: Self.canvas), "full width below the bar")
    }

    @Test func settingsRows() async throws {
        let settings = InMemoryNotchSettings(NotchSettings(ignoredApps: [NotchIgnoredApp(bundleID: "com.example.island", name: "Agent Island")]))
        let monitor = NotchNeighborMonitor()
        for dark in [false, true] {
            let rep = try await OffscreenRender.window("settings-rows", size: NSSize(width: 560, height: 640), dark: dark) {
                Form {
                    Section {
                        NotchPreview(settings: settings, theme: Self.theme) {
                            Text("A live headline from the app")
                                .font(NotchTextStyle(size: CGFloat(settings.notch.fontSize)).swiftUIFont)
                                .foregroundStyle(.white)
                                .padding(.top, 6)
                        }
                        .listRowInsets(EdgeInsets())
                    }
                    Section {
                        NotchDisplayPicker(settings: settings)
                        NotchSharingPicker(settings: settings)
                        NotchNeighborRows(settings: settings, monitor: monitor)
                    } header: {
                        Text("Sharing the notch")
                    }
                    Section("When the notch is yours") {
                        NotchOwnLookRows(settings: settings, monitor: monitor)
                    }
                }
                .formStyle(.grouped)
            }
            #expect(OffscreenRender.inkCoverage(rep) > 0.02)
        }
    }
}

// MARK: - Sample bodies

private struct SampleHeadline: View {
    @Environment(NotchViewModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: model.content.symbol)
                .foregroundStyle(model.theme.accentText(.dark))
            Text("Beat 5: everything is fine")
                .font(NotchTextStyle(size: 15).swiftUIFont)
                .foregroundStyle(model.isDark ? .white : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: model.bodyTextWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private struct SampleExpanded: View {
    @Environment(NotchViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(model.theme.accent()))
                NotchMenuButton(menu: { NSMenu() }) { isOpen in
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").font(.system(size: 10))
                        Text("Engine").font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(isOpen ? 0.22 : 0.12)))
                }
                Spacer()
                Image(systemName: "gearshape")
            }
            ForEach(["Beat 1 at rest", "Beat 2, steady", "Beat 3, a little faster"], id: \.self) { line in
                Text(line).font(.system(size: 13))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .foregroundStyle(model.isDark ? .white : .primary)
    }
}

private struct SampleQuestion: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow “curl” to reach example.com?").font(.system(size: 14, weight: .semibold))
            HStack {
                Text("Port 443 · first time").font(.system(size: 12)).opacity(0.7)
                Spacer()
                Text("Block").padding(.horizontal, 12).padding(.vertical, 4).background(Capsule().fill(.white.opacity(0.15)))
                Text("Allow").padding(.horizontal, 12).padding(.vertical, 4).background(Capsule().fill(.green.opacity(0.7)))
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
    }
}
