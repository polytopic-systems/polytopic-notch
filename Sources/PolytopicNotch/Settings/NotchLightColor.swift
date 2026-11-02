import AppKit
import SwiftUI

/// The colour the user picked for the notch light (`NotchSettings.lightColor`), as 8-bit sRGB. It is stored and coded
/// as "#RRGGBB", so an app can keep it in its own preferences as a plain string.
public struct NotchRGB: Hashable, Sendable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#RRGGBB" or "RRGGBB" (any case, surrounding spaces ignored); nil for anything else.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.first == "#" { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// From hue (degrees, wrapped into 0..<360), saturation and brightness (0...1, clamped).
    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation, 0), 1), v = min(max(brightness, 0), 1)
        func channel(_ n: Double) -> UInt8 {
            let k = (n + h).truncatingRemainder(dividingBy: 6)
            return UInt8(((v - v * s * max(0, min(k, 4 - k, 1))) * 255).rounded())
        }
        self.init(red: channel(5), green: channel(3), blue: channel(1))
    }

    /// The nearest colour to `color` in sRGB; nil for colours that have no RGB value (patterns).
    @MainActor
    public init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ c: CGFloat) -> UInt8 { UInt8((min(max(c, 0), 1) * 255).rounded()) }
        self.init(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
    }

    /// "#RRGGBB", upper case.
    public var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// Hue in degrees (0..<360; 0 for greys), saturation and brightness (0...1).
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxC = max(r, g, b), delta = maxC - min(r, g, b)
        var hue = 0.0
        if delta > 0 {
            switch maxC {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        return (hue, maxC > 0 ? delta / maxC : 0, maxC)
    }

    /// The memory slots a new user starts with: cyan, red, green, white.
    public static let defaultMemory: [NotchRGB] = ["#00C8FF", "#FF3B30", "#34C759", "#FFFFFF"].compactMap(NotchRGB.init(hex:))

    public init(from decoder: any Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let rgb = NotchRGB(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not #RRGGBB: \(hex)"))
        }
        self = rgb
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension NotchTheme {
    /// This theme with every light the pill draws in `light`: the status dot in each state, the quiet line, the
    /// busy bars and sweep, attention, and the meter; off is `light` at 35%. Fills (`accent`) keep the app's colour.
    /// `nil` returns the theme unchanged. The view model applies the user's `NotchSettings.lightColor` with it.
    public func lit(by light: NotchRGB?) -> NotchTheme {
        guard let light else { return self }
        let color = light.color
        var theme = self
        theme.accentText = { _ in color }
        theme.attention = color
        theme.busy = color
        theme.quiet = color
        theme.off = color.opacity(0.35)
        theme.meter = color
        return theme
    }
}
