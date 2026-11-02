import AppKit
import MetalKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// The notch light colour: the value, how it lights the theme, the Metal drawing and the picker.
@MainActor
@Suite(.serialized)
struct NotchLightTests {
    @Test func hexParsesAndFormats() {
        #expect(NotchRGB(hex: "#00C8FF") == NotchRGB(red: 0, green: 200, blue: 255))
        #expect(NotchRGB(hex: " 00c8ff ") == NotchRGB(red: 0, green: 200, blue: 255))
        #expect(NotchRGB(red: 10, green: 2, blue: 255).hex == "#0A02FF")
        for bad in ["", "#", "#00C8F", "#00C8FFF", "00C8FG", "#-0C8FF", "+00C8FF", "red"] {
            #expect(NotchRGB(hex: bad) == nil, "\(bad)")
        }
    }

    @Test func hsbRoundTrips() {
        for hex in ["#FF0000", "#00C8FF", "#34C759", "#FFFFFF", "#000000", "#7F3FBF", "#123456"] {
            let rgb = NotchRGB(hex: hex)!
            let hsb = rgb.hsb
            #expect(NotchRGB(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness) == rgb, "\(hex)")
        }
        #expect(NotchRGB(hue: 360 + 120, saturation: 1, brightness: 1) == NotchRGB(hex: "#00FF00"))
        #expect(NotchRGB(hue: -120, saturation: 2, brightness: 1) == NotchRGB(hex: "#0000FF"))
        #expect(NotchRGB(hex: "#808080")!.hsb.hue == 0)
    }

    @Test func codesAsHexString() throws {
        let rgb = NotchRGB(hex: "#00C8FF")!
        let data = try JSONEncoder().encode(rgb)
        #expect(String(decoding: data, as: UTF8.self) == "\"#00C8FF\"")
        #expect(try JSONDecoder().decode(NotchRGB.self, from: data) == rgb)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NotchRGB.self, from: Data("\"blue\"".utf8)) }
    }

    @Test func settingsDefaults() {
        let settings = NotchSettings()
        #expect(settings.lightColor == nil)
        #expect(settings.lightMemory == NotchRGB.defaultMemory)
        #expect(NotchRGB.defaultMemory.count == 4)
    }

    @Test func litThemeUsesTheLightEverywhere() {
        let theme = NotchTheme.standard
        let unlit = theme.lit(by: nil)
        #expect(unlit.meter == nil && unlit.attention == theme.attention && unlit.quiet == theme.quiet)

        let light = NotchRGB(hex: "#FF2D95")!
        let lit = theme.lit(by: light)
        for color in [lit.accentText(.dark), lit.accentText(.light), lit.attention, lit.busy, lit.quiet, lit.meter!] {
            #expect(NotchRGB(color) == light)
        }
        let off = NSColor(lit.off).usingColorSpace(.sRGB)!
        #expect(abs(off.alphaComponent - 0.35) < 0.01)
        #expect(NotchRGB(lit.accent()) == NotchRGB(theme.accent()), "fills keep the app's colour")
    }

    @Test func viewModelDrawsWithTheLight() {
        let settings = InMemoryNotchSettings()
        let model = NotchViewModel(content: NotchContent(), settings: settings, geometry: TestScreens.geometry(TestScreens.notches[0]))
        #expect(model.theme.meter == nil)
        settings.notch.lightColor = NotchRGB(hex: "#00C8FF")
        #expect(NotchRGB(model.theme.quiet) == NotchRGB(hex: "#00C8FF"))
        #expect(NotchRGB(model.theme.meter!) == NotchRGB(hex: "#00C8FF"))
        // Setting the theme sets the app's; the light still applies on top.
        model.theme = NotchTheme(quiet: .yellow)
        #expect(model.appTheme.quiet == .yellow)
        #expect(NotchRGB(model.theme.quiet) == NotchRGB(hex: "#00C8FF"))
        settings.notch.lightColor = nil
        #expect(model.theme.quiet == .yellow)
    }

    // MARK: Metal

    /// CI's virtual Macs may have no GPU; the picker then draws with SwiftUI, and these checks have nothing to draw on.
    nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

    func metal() throws -> NotchLightMetal {
        try #require(NotchLightMetal.shared, "the shader source compiles")
    }

    func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> NotchRGB {
        let i = (y * width + x) * 4    // BGRA
        return NotchRGB(red: bytes[i + 2], green: bytes[i + 1], blue: bytes[i])
    }

    func brightness(_ rgb: NotchRGB) -> Int { Int(rgb.red) + Int(rgb.green) + Int(rgb.blue) }

    @Test(.enabled(if: hasMetal)) func barGlowsInTheLight() throws {
        let light = NotchRGB(hex: "#00C8FF")!
        let (w, h) = (400, 128)
        let bytes = try #require(try metal().pixels(.init(mode: .bar, color: light, scale: 2), width: w, height: h))
        let centre = pixel(bytes, width: w, x: w / 2, y: h / 2)
        #expect(centre.blue == 255 && centre.green >= 200, "the core is the light, running hot")
        let bloom = pixel(bytes, width: w, x: w / 2, y: h / 2 + 20)
        #expect(bloom.blue > 30 && bloom.red < bloom.blue, "bloom around the bar takes its colour: \(bloom.hex)")
        #expect(brightness(pixel(bytes, width: w, x: 2, y: 2)) < brightness(bloom), "fades into the black panel")
    }

    @Test(.enabled(if: hasMetal)) func railShowsTheSpectrumAndTheMarker() throws {
        let (w, h) = (720, 100)
        var uniforms = NotchLightMetal.Uniforms(mode: .rail, color: NotchRGB(hex: "#FF0000")!, scale: 2)
        uniforms.hue = 180
        let bytes = try #require(try metal().pixels(uniforms, width: w, height: h))
        let railY = h - 28
        let atRed = pixel(bytes, width: w, x: 60, y: railY), atBlue = pixel(bytes, width: w, x: w * 240 / 360, y: railY)
        #expect(atRed.red > 200 && atRed.blue < 120, "\(atRed.hex)")
        #expect(atBlue.blue > 200 && atBlue.red < 60, "\(atBlue.hex)")
        // The marker at 180°: white rim, then the light's line inside.
        #expect(brightness(pixel(bytes, width: w, x: w / 2 - 39, y: 20)) > 600, "the rim")
        let line = pixel(bytes, width: w, x: w / 2, y: 32)
        #expect(line.red > 200 && line.green < 60, "the line in the notch is the light: \(line.hex)")
    }

    @Test(.enabled(if: hasMetal)) func ledsLightUpToTheirCount() throws {
        let (w, h) = (640, 32)
        var uniforms = NotchLightMetal.Uniforms(mode: .leds, color: NotchRGB(hex: "#00C8FF")!, scale: 2)
        uniforms.hue = 190
        uniforms.count = 16
        uniforms.lit = 8
        let bytes = try #require(try metal().pixels(uniforms, width: w, height: h))
        let cell = (w + 8) / 16
        let litLED = pixel(bytes, width: w, x: cell * 7 + cell / 2 - 4, y: h / 2 + 4)
        let darkLED = pixel(bytes, width: w, x: cell * 9 + cell / 2 - 4, y: h / 2 + 4)
        #expect(brightness(litLED) > brightness(darkLED) * 4, "\(litLED.hex) vs \(darkLED.hex)")
    }

    // MARK: The picker

    @Test func pickerRenders() async throws {
        let settings = InMemoryNotchSettings(NotchSettings(lightColor: NotchRGB(hex: "#00C8FF")))
        let size = NSSize(width: 560, height: 470)
        let rep = try await OffscreenRender.window("light-picker", size: size, dark: true) {
            NotchLightPicker(settings: settings, theme: NotchRenderTests.theme, title: "HEARTBEAT / NOTCH LIGHT")
                .frame(width: size.width)
        }
        // cacheDisplay doesn't capture Metal layers: draw each light view's frame into the capture, then check it.
        let composed = try await OffscreenRender.window("light-picker-metal", size: size, dark: true, compositeMetal: true) {
            NotchLightPicker(settings: settings, theme: NotchRenderTests.theme, title: "HEARTBEAT / NOTCH LIGHT")
                .frame(width: size.width)
        }
        #expect(OffscreenRender.inkCoverage(rep) > 0.02)
        if NotchLightMetal.shared != nil {
            #expect(OffscreenRender.inkCoverage(composed) > OffscreenRender.inkCoverage(rep), "the Metal parts drew")
        }
    }

    @Test func pickerFollowsTheApp() async throws {
        let settings = InMemoryNotchSettings()
        let rep = try await OffscreenRender.window("light-picker-app-colour", size: NSSize(width: 560, height: 470), dark: true,
                                                   compositeMetal: true) {
            NotchLightPicker(settings: settings, theme: NotchRenderTests.theme)
        }
        #expect(OffscreenRender.inkCoverage(rep) > 0.02)
        #expect(settings.notch.lightColor == nil, "showing the picker chooses nothing")
    }
}
