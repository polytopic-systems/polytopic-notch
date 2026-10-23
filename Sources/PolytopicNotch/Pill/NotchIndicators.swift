import AppKit
import SwiftUI

/// A small bouncing level meter.
public struct NotchLevelBars: View {
    public var level: Double
    public var color: Color
    public var barCount: Int
    public var maxHeight: CGFloat

    private static let shape: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.4, 0.75, 0.5]

    public init(level: Double, color: Color = .white, barCount: Int = 5, maxHeight: CGFloat = 14) {
        self.level = level
        self.color = color
        self.barCount = barCount
        self.maxHeight = maxHeight
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: 3 + CGFloat(level) * (maxHeight - 3) * Self.shape[i % Self.shape.count])
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Three bars rising and falling in turn: "working on it".
public struct NotchLoadingBars: View {
    public var color: Color
    public var maxHeight: CGFloat

    public init(color: Color = .orange, maxHeight: CGFloat = 14) {
        self.color = color
        self.maxHeight = maxHeight
    }

    public var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = (1 + sin(t * 2 * .pi / 0.9 - Double(index) * 0.7)) / 2
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 4 + (maxHeight - 4) * wave)
                }
            }
            .frame(height: maxHeight)
        }
    }
}

/// An indeterminate progress line: a bright band that glides back and forth along a soft track.
public struct NotchLoadingSweep: View {
    public var color: Color
    public var height: CGFloat

    public init(color: Color = .orange, height: CGFloat = 3.5) {
        self.color = color
        self.height = height
    }

    public var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { proxy in
                let width = proxy.size.width
                let band = max(18, width * 0.38)
                // A smooth there-and-back glide, about 1.6 s per cycle.
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (1 - cos(t * 2 * .pi / 1.6)) / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.22))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.2), color, .yellow, color, color.opacity(0.2)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: band)
                        .offset(x: (width - band) * phase)
                        .shadow(color: color.opacity(0.9), radius: height * 1.6)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// The status dot beside the notch: the content's own `dot`, or the theme's colour for the status (pulsing while
/// showing).
///
/// The pulse is a Core Animation animation that the window server plays by itself. As a SwiftUI `repeatForever`
/// animation it re-rendered and committed a frame from the app at the display's refresh rate (120 Hz on ProMotion)
/// for as long as the pill showed it: about 9% CPU and 120 wakeups a second while nothing was happening.
struct NotchStatusDot: View {
    var model: NotchViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let content = model.content
        let dot = content.dot ?? NotchDot(color: themeColor, pulsing: content.status == .showing || content.status == .attention)
        NotchPulsingDot(color: NSColor(dot.color), pulsing: dot.pulsing)
            .frame(width: 8, height: 8)
    }

    private var themeColor: Color {
        let theme = model.theme
        switch model.content.status {
        case .off: return theme.off
        case .quiet: return theme.quiet
        case .showing: return theme.accentText(colorScheme)
        case .attention: return theme.attention
        }
    }
}

/// The quiet indicator when it sits under the notch (or below a shared one): a thin glowing line that breathes with
/// the level, or a moving band while busy.
struct NotchQuietLine: View {
    var model: NotchViewModel

    var body: some View {
        let content = model.content
        // The line sits on the black notch: the dark-background shade.
        let color = content.lineColor ?? (model.needsAttention ? model.theme.attention : model.theme.accentText(.dark))
        let level = CGFloat(model.level)
        if content.busy {
            NotchLoadingSweep(color: model.theme.busy, height: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0.55), color, color.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 34 + level * 50, height: 3.5)
                .shadow(color: color.opacity(0.9), radius: 4 + level * 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.15), value: level)
        }
    }
}

/// Reads the level in its own body so meter updates don't re-render the bodies.
struct NotchMeter: View {
    var model: NotchViewModel
    var color: Color

    var body: some View {
        if model.content.busy {
            NotchLoadingBars(color: model.theme.busy, maxHeight: 14)
        } else {
            NotchLevelBars(level: model.level, color: color)
        }
    }
}

/// A dot whose opacity breathes between 1 and 0.45 (0.9 s each way) while `pulsing`.
public struct NotchPulsingDot: NSViewRepresentable {
    public var color: NSColor
    public var pulsing: Bool

    public init(color: NSColor, pulsing: Bool) {
        self.color = color
        self.pulsing = pulsing
    }

    public func makeNSView(context: Context) -> NotchPulsingDotView { NotchPulsingDotView() }

    public func updateNSView(_ view: NotchPulsingDotView, context: Context) {
        view.color = color
        view.pulsing = pulsing
    }
}

public final class NotchPulsingDotView: NSView {
    private let dot = CALayer()
    static let pulseKey = "pulse"

    public var color: NSColor = .gray { didSet { if color != oldValue { applyColor() } } }
    public var pulsing = false { didSet { if pulsing != oldValue { applyPulse() } } }
    /// Whether the Core Animation pulse is attached (for tests).
    public var isAnimating: Bool { dot.animation(forKey: Self.pulseKey) != nil }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations don't survive leaving the window; start again when shown.
        dot.removeAnimation(forKey: Self.pulseKey)
        applyPulse()
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = color.cgColor }
        CATransaction.commit()
    }

    private func applyPulse() {
        guard pulsing, window != nil else {
            dot.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard dot.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: Self.pulseKey)
    }
}
