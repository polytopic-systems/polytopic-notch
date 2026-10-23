import AppKit
import SwiftUI

/// The content's question (`NotchContent.prompt`) when the pill can't show it: on a display without a notch, with
/// the pill turned off, or (with the dock) when another app has the notch. A small dark window that floats above
/// other windows at the top right of the screen, on every Space; it never takes focus from the app in front.
///
///     let prompts = NotchPromptWindowController(content: content) { notch.pillShowsPrompt }
///     observe { prompts.update() }   // re-run whenever what it read changes
@MainActor
public final class NotchPromptWindowController {
    private let content: NotchContent
    /// True while the notch pill is showing the question itself.
    private let pillShowsIt: @MainActor () -> Bool
    private var panel: NSPanel?

    public init(content: NotchContent, pillShowsIt: @escaping @MainActor () -> Bool) {
        self.content = content
        self.pillShowsIt = pillShowsIt
    }

    /// Call from an observation loop: reads the prompt and where the pill is.
    public func update() {
        if let prompt = content.prompt, !pillShowsIt() {
            show(prompt)
        } else {
            panel?.orderOut(nil)
        }
    }

    public var isShowing: Bool { panel?.isVisible ?? false }
    /// Tests keep the window transparent and off every screen.
    var keepsOffscreen = false

    private func show(_ prompt: NotchBody) {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        // The view observes the app's own model, so it is built once per appearance.
        let host = NSHostingView(rootView: NotchPromptView(prompt: prompt))
        host.sizingOptions = []
        panel.contentView = host
        let size = NotchPromptView.size(for: prompt)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: screen.maxX - size.width - 14, y: screen.maxY - size.height - 10,
                              width: size.width, height: size.height), display: true)
        if keepsOffscreen {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// The floating window's content: the question's view on the notch's black, rounded.
public struct NotchPromptView: View {
    var prompt: NotchBody
    public static let width: CGFloat = 480

    public init(prompt: NotchBody) {
        self.prompt = prompt
    }

    /// The window has no notch, so the question is measured as if below one.
    @MainActor
    public static func size(for prompt: NotchBody) -> NSSize {
        NSSize(width: width, height: prompt.height(.belowNotch) + 8)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        prompt.view
            .frame(width: Self.width, height: prompt.height(.belowNotch))
            .padding(.vertical, 4)
            .background(shape.fill(Color.black.opacity(0.94)))
            .overlay(shape.strokeBorder(.white.opacity(0.12)))
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
    }
}
