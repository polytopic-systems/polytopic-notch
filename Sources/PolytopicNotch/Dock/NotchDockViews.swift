import SwiftUI

// How a docked app draws its part. The panel has a fixed frame (`NotchViewModel.dockCanvas`, top of the screen,
// centred on the notch) and the part is drawn at its slot's place inside it, so moves animate with the shared spring
// in every app at once.

extension NotchView {
    @ViewBuilder
    func dockedBody(_ canvas: CGRect) -> some View {
        let slot = model.slot
        ZStack(alignment: .topLeading) {
            switch slot.role {
            case .hidden:
                Color.clear
            case .whole:
                dockedWhole(canvas)
            case .top:
                mergedTop(canvas)
            case .middle, .bottom:
                mergedLower(canvas)
            case .leftWing, .rightWing:
                wing(canvas)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .animation(NotchSpring.animation, value: mode)
        .animation(NotchSpring.animation, value: slot)
        .animation(NotchSpring.animation, value: model.drawnSize(for: mode))
        .environment(model)
    }

    /// Screen rect → offset inside the canvas (y down from the canvas's top).
    func offset(of rect: CGRect, in canvas: CGRect) -> CGSize {
        CGSize(width: rect.minX - canvas.minX, height: canvas.maxY - rect.maxY)
    }

    /// The app's own pill (alone, or one capsule of several), at its slot.
    @ViewBuilder
    private func dockedWhole(_ canvas: CGRect) -> some View {
        let size = model.drawnSize(for: mode)
        let rect = model.pillRect(size: size)
        pill
            .frame(width: size.width, height: size.height)
            .offset(offset(of: rect, in: canvas))
    }

    /// The body a docked part shows for its mode (none while quiet).
    private func dockedBody(for mode: NotchMode) -> NotchBody? {
        switch mode {
        case .showing: content.showing
        case .expanded: content.expanded
        case .asking: content.prompt
        case .hidden, .quiet: nil
        }
    }

    /// The bottom corner radius of the attached pill in a mode (as `NotchViewModel.attachedShape`).
    func dockedBottomRadius(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .hidden: 8
        case .quiet: 10
        case .showing: content.showing?.bottomRadius ?? 20
        case .expanded, .asking: 26
        }
    }

    private func dockShadow(_ slot: NotchSlot) -> Double {
        slot.castsShadow && (slot.stackHovered || mode == .expanded) ? 0.35 : 0
    }

    // MARK: Merged

    /// The top of a Merged stack: attached to the notch, the band with this app's meter and dot, then its body.
    /// Square bottom corners: the next part joins there.
    @ViewBuilder
    private func mergedTop(_ canvas: CGRect) -> some View {
        let slot = model.slot
        let frame = slot.frame ?? .zero
        let shape = NotchShape(topRadius: model.metrics.flare, bottomRadius: 0)
        VStack(spacing: 0) {
            topBand
                .frame(height: model.geometry.notchSize.height)
            if let body = dockedBody(for: mode) {
                bodyView(body, for: mode)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, model.metrics.pillInset)
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(dockShadow(slot)), radius: 12, y: 6)
        .environment(\.colorScheme, .dark)
        .offset(offset(of: frame, in: canvas))
    }

    /// A lower part of a Merged stack. Its black reaches up under every part above it (the full tuck), so only its
    /// bottom edge moves; its content sits in what shows below the part above.
    @ViewBuilder
    private func mergedLower(_ canvas: CGRect) -> some View {
        let slot = model.slot
        let frame = slot.frame ?? .zero
        let visible = slot.visibleFrame ?? frame
        let shape = NotchLowerPartShape(bottomRadius: slot.role == .bottom ? dockedBottomRadius(for: mode) : 0)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if let body = dockedBody(for: mode) {
                    bodyView(body, for: mode)
                } else {
                    NotchDockQuietRow(model: model)
                }
            }
            // At the top: a part reaching down to where its hover began shows its body right under the part above.
            .frame(width: frame.width, height: visible.height, alignment: .top)
        }
        .frame(width: frame.width, height: frame.height)
        .background(shape.fill(.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(dockShadow(slot)), radius: 12, y: 6)
        .environment(\.colorScheme, .dark)
        .offset(offset(of: frame, in: canvas))
    }

    // MARK: Split

    /// A Split wing: this app's ear beside the notch with its indicator, and its body below while it shows something.
    @ViewBuilder
    private func wing(_ canvas: CGRect) -> some View {
        let slot = model.slot
        let isLeft = slot.role == .leftWing
        let band = local(slot.frame ?? .zero, canvas)
        let body = slot.bodyFrame.map { local($0, canvas) }
        let metrics = NotchDockMetrics(model.metrics)
        let outerJoint: NotchSlot.Edges = isLeft ? .left : .right
        let shape = NotchWingShape(band: band, body: body, isLeft: isLeft, isOutermost: !slot.joints.contains(outerJoint),
                                   neckDepth: slot.neckDepth, flare: model.metrics.flare, shoulder: metrics.shoulder,
                                   bodyBottomRadius: dockedBottomRadius(for: .showing))
        let ear = earRect(band: band, canvas: canvas, isLeft: isLeft, outermost: !slot.joints.contains(outerJoint))
        ZStack(alignment: .topLeading) {
            shape.fill(.black)
            NotchDockEarIndicator(model: model, isLeft: isLeft)
                .frame(width: ear.width, height: ear.height)
                .offset(x: ear.minX, y: ear.minY)
            if let body, mode == .showing, let showing = content.showing {
                let box = CGRect(x: body.minX, y: body.minY + metrics.shoulder, width: body.width,
                                 height: max(0, body.height - metrics.shoulder))
                bodyView(showing, for: .showing)
                    .frame(width: box.width, height: box.height)
                    .clipped()
                    .offset(x: box.minX, y: box.minY)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    /// Screen rect → canvas-local rect (y down).
    private func local(_ rect: CGRect, _ canvas: CGRect) -> CGRect {
        CGRect(x: rect.minX - canvas.minX, y: canvas.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The part of a wing's ear that shows beside the notch (canvas-local), as tall as the notch.
    private func earRect(band: CGRect, canvas: CGRect, isLeft: Bool, outermost: Bool) -> CGRect {
        let notch = model.geometry.notchRect
        let notchLocal = notch.isEmpty ? CGRect.null : local(notch, canvas)
        let flare = outermost ? model.metrics.flare : 0
        var minX = band.minX, maxX = band.maxX
        if isLeft {
            minX += flare
            if !notchLocal.isNull { maxX = min(maxX, notchLocal.minX) }
        } else {
            maxX -= flare
            if !notchLocal.isNull { minX = max(minX, notchLocal.maxX) }
        }
        let height = notch.isEmpty ? band.height : min(band.height, notch.height)
        return CGRect(x: minX, y: band.minY, width: max(0, maxX - minX), height: height)
    }
}

/// A Split wing's ear: the app's status dot and meter, in the ~34 pt beside the notch that is this app's.
struct NotchDockEarIndicator: View {
    var model: NotchViewModel
    var isLeft: Bool

    var body: some View {
        HStack(spacing: 3) {
            if isLeft { NotchStatusDot(model: model) }
            NotchMeter(model: model, color: .white)
                .scaleEffect(0.8)
            if !isLeft { NotchStatusDot(model: model) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Merged lower part with nothing to show: a slim row with the app's dot, its title and its meter.
struct NotchDockQuietRow: View {
    var model: NotchViewModel

    var body: some View {
        HStack(spacing: 8) {
            NotchStatusDot(model: model)
            Text(model.content.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 4)
            NotchMeter(model: model, color: .white)
                .scaleEffect(0.8)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Switcher: a dot for each docked app in the open pill. Clicking another app's dot hands it the notch while the
/// pointer stays on the dock.
struct NotchSwitcherDots: View {
    var model: NotchViewModel

    var body: some View {
        let ink: Color = model.isDark ? .white : .primary
        HStack(spacing: 4) {
            ForEach(model.slot.switcherDots, id: \.pid) { dot in
                Button {
                    if !dot.isCurrent { model.onSwitcherDot?(dot.pid) }
                } label: {
                    Image(systemName: dot.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.opacity(dot.isCurrent ? 1 : 0.65))
                        .frame(width: 22, height: 18)
                        .background(Capsule().fill(ink.opacity(dot.isCurrent ? 0.26 : 0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Self.name(of: dot.appID))
                .accessibilityLabel(Self.name(of: dot.appID))
            }
        }
    }

    /// The app's name from its bundle ID (the last component, as a fallback).
    static func name(of appID: String) -> String {
        NotchDockAppName.name(of: appID)
    }
}

/// Docked apps' display names, looked up once each.
@MainActor
enum NotchDockAppName {
    private static var cache: [String: String] = [:]

    static func name(of appID: String) -> String {
        if let cached = cache[appID] { return cached }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first?.localizedName
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        let name = running ?? installed ?? appID.split(separator: ".").last.map(String.init) ?? appID
        cache[appID] = name
        return name
    }
}
