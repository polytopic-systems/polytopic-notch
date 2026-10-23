import SwiftUI

/// The pill at the notch. It reads `NotchContent` and nothing of the app's, so any app can drive it: off is just
/// the black notch, quiet is a meter and a status dot beside it, showing drops the content's body below the notch,
/// hovering opens its expanded body, and a question grows the pill around it.
public struct NotchView: View {
    var model: NotchViewModel

    public init(model: NotchViewModel) {
        self.model = model
    }

    var content: NotchContent { model.content }
    var hasNotch: Bool { model.geometry.hasNotch }
    var dark: Bool { model.isDark }
    var mode: NotchMode { model.mode }

    public var body: some View {
        if let canvas = model.dockCanvas {
            // Placed by the dock: this app's part, wherever the dock put it (NotchDockViews.swift).
            dockedBody(canvas)
        } else {
            soloBody
        }
    }

    /// Alone: the pill hangs top-centre in the panel.
    private var soloBody: some View {
        let size = model.size(for: mode)
        return VStack(spacing: 0) {
            pill
                .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchSpring.animation, value: mode)
        .animation(NotchSpring.animation, value: size)
        // Bodies read the pill (placement, isDark, bodyTextWidth) and its menu hold from here.
        .environment(model)
    }

    // MARK: - Pill

    @ViewBuilder
    var pill: some View {
        switch model.placement {
        case .notch: attachedPill
        case .menuBar: barPill
        case .belowNotch: sharedPill
        }
    }

    /// Hanging below a notch that another app is using: a slim line while quiet, a black rounded panel
    /// for the bodies.
    @ViewBuilder
    private var sharedPill: some View {
        if mode == .quiet {
            NotchQuietLine(model: model)
        } else if mode != .hidden {
            let shape = RoundedRectangle(cornerRadius: mode == .expanded || mode == .asking ? 24 : 18, style: .continuous)
            pillContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(shape.fill(.black))
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private var attachedPill: some View {
        if mode == .quiet && model.indicatorUnderNotch {
            // Quiet, with the indicator under the notch: the notch stays as it is.
            let notch = model.geometry.notchSize
            VStack(spacing: NotchGeometry.sharedGap) {
                model.attachedShape(for: .hidden).fill(.black)
                    .frame(width: notch.width, height: notch.height)
                NotchQuietLine(model: model)
            }
        } else {
            attachedShape
        }
    }

    private var attachedShape: some View {
        let shape = model.attachedShape(for: mode)
        return pillContent
            .padding(.horizontal, model.metrics.pillInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(shape.fill(.black))
            .clipShape(shape)
            .shadow(color: .black.opacity(mode == .expanded || mode == .asking ? 0.35 : 0), radius: 12, y: 6)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var barPill: some View {
        if mode != .hidden {
            let shape = RoundedRectangle(cornerRadius: mode == .quiet ? 15 : 22, style: .continuous)
            pillContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        }
    }

    @ViewBuilder
    var pillContent: some View {
        VStack(spacing: 0) {
            Group {
                if model.placement == .belowNotch || model.keepsMenuBarClear(mode) {
                    Color.clear
                } else {
                    topBand
                }
            }
            .frame(height: model.topBandHeight)
            if model.showsSwitcherDots {
                // Switcher: the dots get a row of their own, centred under the notch, so they never crowd the band or
                // cover the body.
                NotchSwitcherDots(model: model)
                    .frame(maxWidth: .infinity)
                    .frame(height: model.switcherRowHeight)
            }
            if mode == .showing, let body = content.showing {
                bodyView(body, for: .showing)
            }
            if mode == .expanded, let body = content.expanded {
                bodyView(body, for: .expanded)
            }
            if mode == .asking, let body = content.prompt {
                bodyView(body, for: .asking)
            }
        }
    }

    func bodyView(_ body: NotchBody, for mode: NotchMode) -> some View {
        body.view
            .frame(height: body.height(model.placement))
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    /// Meter on the left, status dot on the right, the notch (or the content's title) between. (A Switcher dock's dots
    /// have their own row below.)
    @ViewBuilder
    var topBand: some View {
        if mode != .hidden || !hasNotch {
            HStack(spacing: 0) {
                NotchMeter(model: model, color: dark ? .white : .primary)
                    .frame(width: model.metrics.ear - 6)
                if hasNotch {
                    Spacer(minLength: model.geometry.notchSize.width)
                } else {
                    Text(content.title)
                        .font(model.theme.bandTitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                NotchStatusDot(model: model)
                    .frame(width: model.metrics.ear - 6)
            }
            .transition(.opacity)
        }
    }
}
