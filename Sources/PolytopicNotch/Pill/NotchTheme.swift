import SwiftUI

/// The app's colours and fonts as the pill uses them. The pill itself is black like the notch (glass without
/// one); only these marks carry the brand. Colours are closures so an app whose palette changes at runtime
/// (an app's own appearance settings) recolours the pill: a closure that reads observable state is tracked by
/// whichever view calls it.
public struct NotchTheme: Sendable {
    /// Fills and large marks (the Settings preview's backdrop, primary buttons in package views).
    public var accent: @MainActor @Sendable () -> Color
    /// Accent-coloured text and thin marks in a colour scheme: the status dot while showing, the quiet line.
    public var accentText: @MainActor @Sendable (ColorScheme) -> Color
    /// Something needs the user: the dot and the quiet line turn this colour.
    public var attention: Color
    /// Working on it (`NotchContent.busy`): the loading bars and sweep.
    public var busy: Color
    /// The dot while active and quiet.
    public var quiet: Color
    /// The dot while off.
    public var off: Color
    /// The Settings preview's miniature desktop.
    public var previewBackdrop: @MainActor @Sendable () -> [Color]
    /// The title in the band on screens without a notch.
    public var bandTitleFont: Font

    public init(accent: @escaping @MainActor @Sendable () -> Color = { .accentColor },
                accentText: @escaping @MainActor @Sendable (ColorScheme) -> Color = { _ in .accentColor },
                attention: Color = .orange, busy: Color = .orange, quiet: Color = .green, off: Color = .gray,
                previewBackdrop: (@MainActor @Sendable () -> [Color])? = nil,
                bandTitleFont: Font = .system(size: 12, weight: .semibold)) {
        self.accent = accent
        self.accentText = accentText
        self.attention = attention
        self.busy = busy
        self.quiet = quiet
        self.off = off
        self.previewBackdrop = previewBackdrop ?? { [accent().opacity(0.45), accent().opacity(0.15), .gray.opacity(0.25)] }
        self.bandTitleFont = bandTitleFont
    }

    /// The system accent colour and the usual status colours.
    public static let standard = NotchTheme()
}
