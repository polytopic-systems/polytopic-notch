import SwiftUI

/// Picks the notch light's colour (`NotchSettings.lightColor`): a black instrument panel with the light as a glowing
/// bar, a spectrum rail whose marker is a notch, rows of LEDs for intensity and white mix, a hex field, four memory
/// keys, how each state will look, and a readout. BREATHE moves the bar like the quiet line moves with the level.
/// The bar, the rail and the LEDs are drawn with Metal (`NotchLightMetal`), with SwiftUI where Metal isn't available.
///
/// Put it in a Settings form row with `.listRowInsets(EdgeInsets())`. Nothing animates unless BREATHE is on. The app's
/// `NotchSettingsStore` must store `lightColor` and `lightMemory` for the choice to stick.
public struct NotchLightPicker: View {
    var settings: any NotchSettingsStore
    var theme: NotchTheme
    var title: String

    /// The control's own position, so hue survives white (no hue) and the LEDs keep their steps.
    @State private var hue = 0.0
    @State private var intensity = Self.steps
    @State private var whiteMix = 0
    @State private var slot = 0
    @State private var breathing = false
    @State private var hexText = ""
    @State private var hexError = false
    @FocusState private var hexFocused: Bool
    @FocusState private var railFocused: Bool

    static let steps = 16

    /// `theme` is the app's, for "APP COLOUR" (no light colour chosen) and the states it draws then. `title` heads the
    /// panel, e.g. "TATTLE / NOTCH LIGHT".
    public init(settings: any NotchSettingsStore, theme: NotchTheme = .standard, title: String = NotchLightPicker.defaultTitle) {
        self.settings = settings
        self.theme = theme
        self.title = title
    }

    /// The default title, in the app's language.
    @usableFromInline static var defaultTitle: String {
        String(localized: "NOTCH LIGHT", bundle: .module, comment: "Title of the notch light colour panel; keep it uppercase")
    }

    /// What the notch shows now: the chosen colour, or the app's own.
    private var shown: NotchRGB {
        settings.notch.lightColor ?? NotchRGB(theme.accentText(.dark)) ?? NotchRGB(red: 255, green: 255, blue: 255)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(hexError ? String(localized: "Enter six hex digits, like #00C8FF", bundle: .module, comment: "Error under a hex colour field") : " ")
                .font(Self.mono(11))
                .foregroundStyle(Color(red: 1, green: 0.41, blue: 0.38))
                .frame(maxWidth: .infinity, alignment: .trailing)
            bar
                .frame(height: 64)
            rail
            Self.divider
            ledRows
            Self.divider
            memoryRow
            Self.divider
            statesRow
            Self.divider
            telemetry
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .overlay { NotchLightBrackets().stroke(Self.dim, lineWidth: 1) }
        .padding(14)
        .background(.black, in: .rect(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onAppear { load(shown) }
        .onChange(of: settings.notch.lightColor) { _, new in
            // Changed elsewhere (another window, the app): follow it unless it is what the control already says.
            if let new, new != position { load(new) }
            if !hexFocused { hexText = shown.hex }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Self.label(title)
            Spacer()
            Self.key(String(localized: "BREATHE", bundle: .module, comment: "Uppercase key on a black instrument panel; keep it uppercase and short. Makes the light pulse slowly"), on: breathing) { breathing.toggle() }
                .accessibilityLabel(String(localized: "Breathe", bundle: .module, comment: "Accessibility: the key that makes the light pulse slowly"))
                .accessibilityValue(breathing ? Self.on : Self.off)
            TextField("", text: $hexText)
                .textFieldStyle(.plain)
                .font(Self.mono(15))
                .tracking(3)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .frame(width: 104)
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(Self.hairline).frame(height: 1) }
                .focused($hexFocused)
                .accessibilityLabel(String(localized: "Hex colour", bundle: .module, comment: "Accessibility: the field for a #RRGGBB colour"))
                .onChange(of: hexText) { _, text in
                    hexError = false
                    // Only typing chooses a colour; the control filling the field in doesn't.
                    if hexFocused, let rgb = NotchRGB(hex: text), rgb != settings.notch.lightColor { choose(rgb) }
                }
                .onSubmit { checkHex() }
                .onChange(of: hexFocused) { _, focused in if !focused { checkHex() } }
        }
    }

    private var bar: some View {
        let color = shown.color
        return TimelineView(.animation(paused: !breathing)) { context in
            let level = breathing ? Self.breath(context.date) : 1
            let glow = Double(intensity) / Double(Self.steps) * level
            if let metal = NotchLightMetal.shared {
                NotchLightMetalView(renderer: metal, uniforms: barUniforms(level: level, glow: glow))
            } else {
                GeometryReader { proxy in
                    Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.35), color, color.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * (0.4 + 0.34 * level), height: 8)
                    .shadow(color: color, radius: 4 + 12 * glow)
                    .shadow(color: color.opacity(0.5), radius: 10 + 20 * glow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var rail: some View {
        GeometryReader { proxy in
            Group {
                if let metal = NotchLightMetal.shared {
                    NotchLightMetalView(renderer: metal, uniforms: railUniforms)
                } else {
                    Canvas { context, size in
                        Self.drawRail(context, size: size, hue: hue, light: shown.color, focused: railFocused)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                railFocused = true
                setHue(max(0, min(359.9, drag.location.x / max(1, proxy.size.width) * 360)))
            })
        }
        .frame(height: 50)
        .focusable()
        .focusEffectDisabled()
        .focused($railFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let step = press.modifiers.contains(.shift) ? 10.0 : 1
            setHue((hue + (press.key == .rightArrow ? step : -step) + 360).truncatingRemainder(dividingBy: 360))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Hue", bundle: .module, comment: "Accessibility: the colour spectrum slider"))
        .accessibilityValue(String(localized: "\(Int(hue.rounded())) degrees", bundle: .module, comment: "Accessibility: the hue's angle"))
        .accessibilityAdjustableAction { direction in
            setHue((hue + (direction == .increment ? 10 : -10) + 360).truncatingRemainder(dividingBy: 360))
        }
    }

    private var ledRows: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
            GridRow {
                Self.label(String(localized: "INTENSITY", bundle: .module, comment: "Uppercase row label on a black instrument panel; keep it uppercase and short")).frame(width: 96, alignment: .leading)
                NotchLightLEDs(count: Self.steps, lit: intensity, metal: ledUniforms(.intensity, lit: intensity), color: { step in
                    NotchRGB(hue: hue, saturation: saturation, brightness: Self.brightness(step)).color
                }, unlit: { step in
                    NotchRGB(hue: hue, saturation: saturation, brightness: Self.brightness(step)).color.opacity(0.12)
                }) { lit in
                    intensity = max(1, lit)
                    commit()
                }
                .accessibilityLabel(String(localized: "Intensity", bundle: .module, comment: "Accessibility: the light's brightness"))
                Self.readout(intensity)
            }
            GridRow {
                Self.label(String(localized: "WHITE MIX", bundle: .module, comment: "Uppercase row label on a black instrument panel; keep it uppercase and short. How much white is mixed into the colour")).frame(width: 96, alignment: .leading)
                NotchLightLEDs(count: Self.steps, lit: whiteMix, metal: ledUniforms(.whiteMix, lit: whiteMix), color: { step in
                    NotchRGB(hue: hue, saturation: 1 - Double(step) / Double(Self.steps), brightness: 1).color
                }, unlit: { _ in .white.opacity(0.08) }) { lit in
                    whiteMix = lit
                    commit()
                }
                .accessibilityLabel(String(localized: "White mix", bundle: .module, comment: "Accessibility: how much white is mixed into the colour"))
                Self.readout(whiteMix)
            }
        }
        .padding(.vertical, 16)
    }

    private var memoryRow: some View {
        let memory = settings.notch.lightMemory
        return HStack(spacing: 6) {
            Self.label(String(localized: "MEMORY", bundle: .module, comment: "Uppercase row label on a black instrument panel; keep it uppercase and short. Four stored colours")).frame(width: 96, alignment: .leading)
            ForEach(memory.indices, id: \.self) { index in
                Button {
                    slot = index
                    choose(memory[index])
                    load(memory[index])
                } label: {
                    Text(verbatim: "\(index + 1)")
                        .font(Self.mono(11))
                        .foregroundStyle(index == slot ? .white : Self.muted)
                        .frame(width: 34, height: 34)
                        .background(Color(white: 0.03), in: .rect(cornerRadius: 4))
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(memory[index].color).frame(width: 5, height: 5).padding(4)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(index == slot ? .white : Self.hairlineStrong, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Memory \(index + 1), \(memory[index].hex)", bundle: .module, comment: "Accessibility: a stored colour, its number and its hex code"))
            }
            Spacer()
            Self.key(String(localized: "STORE", bundle: .module, comment: "Uppercase key on a black instrument panel; keep it uppercase and short. Stores the colour in the selected memory"), on: false) {
                var memory = settings.notch.lightMemory
                guard memory.indices.contains(slot) else { return }
                memory[slot] = shown
                settings.notch.lightMemory = memory
            }
            .accessibilityLabel(String(localized: "Store in memory \(slot + 1)", bundle: .module, comment: "Accessibility: store the colour in memory number N"))
        }
        .padding(.vertical, 16)
    }

    private var statesRow: some View {
        let lit = theme.lit(by: settings.notch.lightColor)
        let states: [(String, Color, CGFloat, Bool)] = [
            (String(localized: "SHOWING", bundle: .module, comment: "Uppercase row label on a black instrument panel; keep it uppercase and short. The pill's state while it shows something"), lit.accentText(.dark), 0.6, true),
            (String(localized: "QUIET", bundle: .module, comment: "Uppercase row label on a black instrument panel; keep it uppercase and short. The pill's state while there's nothing to show"), lit.quiet, 0.4, true),
            (String(localized: "ALERT", bundle: .module, comment: "Uppercase row label on a black instrument panel; keep it uppercase and short. The pill's state while it needs attention"), lit.attention, 0.72, true),
            (String(localized: "OFF", bundle: .module, comment: "Uppercase row label on a black instrument panel; keep it uppercase and short. The pill's state while it's off"), lit.off, 0.28, false),
        ]
        return HStack(spacing: 12) {
            ForEach(states, id: \.0) { name, color, width, glows in
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { proxy in
                        UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                            .fill(Color(white: 0.03))
                            .frame(height: 16)
                            .overlay(alignment: .bottom) {
                                Capsule().fill(color).frame(width: proxy.size.width * width, height: 2)
                                    .shadow(color: glows ? color : .clear, radius: 3)
                                    .offset(y: 6)
                            }
                    }
                    .frame(height: 22)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Self.label(name)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 14)
    }

    private var telemetry: some View {
        let rgb = shown
        let following = settings.notch.lightColor == nil
        return HStack {
            Text(String(localized: "HUE \(Self.three(hue))  ·  INT \(Self.three(Double(intensity) / Double(Self.steps) * 100))  ·  MIX \(Self.three(Double(whiteMix) / Double(Self.steps) * 100))  ·  RGB \(rgb.red) \(rgb.green) \(rgb.blue)",
                        bundle: .module,
                        comment: "Uppercase readout on an instrument panel: hue, intensity, white mix, RGB. Keep it uppercase, short and abbreviated; keep the two spaces around each ·"))
                .font(Self.mono(11))
                .tracking(2)
                .foregroundStyle(Self.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Self.key(String(localized: "APP COLOUR", bundle: .module, comment: "Uppercase key on a black instrument panel; keep it uppercase and short. Goes back to the app's own colours"), on: following) {
                settings.notch.lightColor = nil
                load(shown)
            }
            .help(String(localized: "Follow the app's own colours", bundle: .module, comment: "Tooltip of APP COLOUR"))
            .accessibilityValue(following ? Self.on : Self.off)
        }
        .padding(.top, 12)
    }

    // MARK: Metal

    @Environment(\.displayScale) private var displayScale

    private func barUniforms(level: Double, glow: Double) -> NotchLightMetal.Uniforms {
        var uniforms = NotchLightMetal.Uniforms(mode: .bar, color: shown, scale: displayScale)
        uniforms.level = Float(level)
        uniforms.glow = Float(glow)
        return uniforms
    }

    private var railUniforms: NotchLightMetal.Uniforms {
        var uniforms = NotchLightMetal.Uniforms(mode: .rail, color: shown, scale: displayScale)
        uniforms.hue = Float(hue)
        uniforms.focused = railFocused ? 1 : 0
        return uniforms
    }

    private func ledUniforms(_ kind: NotchLightMetal.Uniforms.LEDKind, lit: Int) -> NotchLightMetal.Uniforms {
        var uniforms = NotchLightMetal.Uniforms(mode: .leds, color: shown, scale: displayScale)
        uniforms.ledKind = kind.rawValue
        uniforms.hue = Float(hue)
        uniforms.saturation = Float(saturation)
        uniforms.count = Float(Self.steps)
        uniforms.lit = Float(lit)
        return uniforms
    }

    // MARK: State

    private var saturation: Double { 1 - Double(whiteMix) / Double(Self.steps) }

    /// The colour the control's position stands for.
    private var position: NotchRGB {
        NotchRGB(hue: hue, saturation: saturation, brightness: Self.brightness(intensity))
    }

    private func setHue(_ new: Double) {
        hue = new
        commit()
    }

    /// The control moved: its position becomes the light.
    private func commit() {
        choose(position)
    }

    private func choose(_ rgb: NotchRGB) {
        if settings.notch.lightColor != rgb { settings.notch.lightColor = rgb }
        if !hexFocused { hexText = rgb.hex }
    }

    /// Puts the control at `rgb` (to the nearest LED step) without changing the light.
    private func load(_ rgb: NotchRGB) {
        let hsb = rgb.hsb
        if hsb.saturation > 0, hsb.brightness > 0 { hue = hsb.hue }
        whiteMix = Int(((1 - hsb.saturation) * Double(Self.steps)).rounded())
        intensity = max(1, min(Self.steps, Int(((hsb.brightness - 0.2) / 0.8 * Double(Self.steps)).rounded())))
        if !hexFocused { hexText = rgb.hex }
    }

    private func checkHex() {
        if let rgb = NotchRGB(hex: hexText) {
            hexError = false
            load(rgb)
            hexText = rgb.hex
        } else {
            hexError = true
        }
    }

    // MARK: Drawing

    /// Intensity step 1...16 → brightness 0.25...1 (the light never goes fully dark).
    static func brightness(_ step: Int) -> Double { 0.2 + 0.8 * Double(step) / Double(steps) }

    /// 0.35...1, a slow breath with a faster flicker on top, like a level that moves with activity.
    static func breath(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate * 1000
        return 0.35 + 0.65 * abs(sin(t / 900)) * (0.6 + 0.4 * abs(sin(t / 260)))
    }

    static func drawRail(_ context: GraphicsContext, size: CGSize, hue: Double, light: Color, focused: Bool) {
        let railRect = CGRect(x: 0, y: size.height - 18, width: size.width, height: 8)
        let spectrum = stride(from: 0.0, through: 360, by: 30).map { Color(hue: $0 / 360, saturation: 1, brightness: 1) }
        context.fill(Path(roundedRect: railRect, cornerRadius: 4),
                     with: .linearGradient(Gradient(colors: spectrum), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)))

        // The marker is a notch: white outline, black inside, the light's line in it, a stem down to the rail.
        let x = min(max(hue / 360 * size.width, 21), size.width - 21)
        context.fill(notchPath(centre: x, halfWidth: 20, top: 2, bottom: 23, radius: 6), with: .color(focused ? .white : Color(white: 0.85)))
        context.fill(notchPath(centre: x, halfWidth: 18.5, top: 2, bottom: 21.5, radius: 4.5), with: .color(.black))
        var glow = context
        glow.addFilter(.shadow(color: light, radius: 4))
        glow.fill(Path(roundedRect: CGRect(x: x - 8, y: 15, width: 16, height: 2.5), cornerRadius: 1.25), with: .color(light))
        context.fill(Path(CGRect(x: x - 0.75, y: 23, width: 1.5, height: railRect.minY - 23 + 4)), with: .color(.white))
    }

    static func notchPath(centre x: CGFloat, halfWidth: CGFloat, top: CGFloat, bottom: CGFloat, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x - halfWidth, y: top))
        path.addLine(to: CGPoint(x: x + halfWidth, y: top))
        path.addLine(to: CGPoint(x: x + halfWidth, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: x + halfWidth - radius, y: bottom), control: CGPoint(x: x + halfWidth, y: bottom))
        path.addLine(to: CGPoint(x: x - halfWidth + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: x - halfWidth, y: bottom - radius), control: CGPoint(x: x - halfWidth, y: bottom))
        path.closeSubpath()
        return path
    }

    // MARK: Style

    static let dim = Color(white: 0.37)
    static let muted = Color(white: 0.48)
    static let hairline = Color(white: 0.11)
    static let hairlineStrong = Color(white: 0.18)

    static var on: String { String(localized: "On", bundle: .module, comment: "Accessibility value: a switch-like key is on") }
    static var off: String { String(localized: "Off", bundle: .module, comment: "Accessibility value: a switch-like key is off") }

    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

    static var divider: some View { Rectangle().fill(hairline).frame(height: 1) }

    static func label(_ text: String) -> some View {
        Text(text).font(mono(11)).tracking(3).foregroundStyle(dim).lineLimit(1).minimumScaleFactor(0.7)
    }

    static func readout(_ step: Int) -> some View {
        Text(verbatim: "\(Int((Double(step) / Double(steps) * 100).rounded()))")
            .font(mono(12)).foregroundStyle(.white)
            .frame(width: 34, alignment: .trailing)
    }

    static func three(_ value: Double) -> String { String(format: "%03d", Int(value.rounded())) }

    static func key(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(mono(11)).tracking(3)
                .foregroundStyle(on ? .white : muted)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(on ? .white : hairlineStrong, lineWidth: 1) }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A row of LED pills: tap or drag across to set how many are lit.
struct NotchLightLEDs: View {
    var count: Int
    var lit: Int
    /// Drawn by `NotchLightMetal` when it's available; `color`/`unlit` draw them with SwiftUI otherwise.
    var metal: NotchLightMetal.Uniforms
    var color: (Int) -> Color
    var unlit: (Int) -> Color
    var set: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let renderer = NotchLightMetal.shared {
                    NotchLightMetalView(renderer: renderer, uniforms: metal)
                } else {
                    HStack(spacing: 4) {
                        ForEach(1...count, id: \.self) { step in
                            let on = step <= lit
                            let c = color(step)
                            Capsule()
                                .fill(on ? c : unlit(step))
                                .shadow(color: on ? c.opacity(0.55) : .clear, radius: 3)
                        }
                    }
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let step = Int((drag.location.x / max(1, proxy.size.width) * CGFloat(count)).rounded(.up))
                let clamped = max(0, min(count, step))
                if clamped != lit { set(clamped) }
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityValue(String(localized: "\(Int((Double(lit) / Double(count) * 100).rounded())) percent", bundle: .module, comment: "Accessibility: how many LEDs are lit, in percent"))
        .accessibilityAdjustableAction { direction in
            set(max(0, min(count, lit + (direction == .increment ? 1 : -1))))
        }
    }
}

/// Corner brackets, like a viewfinder's, around the panel's content.
struct NotchLightBrackets: Shape {
    var length: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)] {
            path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return path
    }
}
