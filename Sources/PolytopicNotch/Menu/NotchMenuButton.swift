import AppKit
import SwiftUI

/// A button in the pill that opens a native menu below itself, and keeps the pill open while the menu shows.
///
/// A SwiftUI `Menu` can't say when it opens and closes: the pointer moves onto the menu, outside the pill, and the
/// pill collapsed under it. This opens an `NSMenu` with `NSMenu.popUp(positioning:at:in:)` instead, which returns
/// only when the menu closes, and holds `NotchViewModel.isMenuOpen` for exactly that long. Outside a pill (no
/// `NotchViewModel` in the environment) it just opens the menu.
///
///     NotchMenuButton(menu: { EngineMenu.make(session) }) { isOpen in
///         Label("Whisper", systemImage: "waveform")
///             .background(Capsule().fill(.primary.opacity(isOpen ? 0.22 : 0.12)))
///     }
public struct NotchMenuButton<Label: View>: View {
    private let menu: @MainActor () -> NSMenu
    private let label: (Bool) -> Label
    @Environment(NotchViewModel.self) private var model: NotchViewModel?
    @State private var anchor = NotchMenuAnchor()
    /// Outside a pill there is no model to hold the open state.
    @State private var openOutsidePill = false

    /// `menu` is built at each click, so it shows current state. `label` gets whether the menu is open.
    public init(menu: @escaping @MainActor () -> NSMenu, @ViewBuilder label: @escaping (Bool) -> Label) {
        self.menu = menu
        self.label = label
    }

    private var isOpen: Bool { model?.isMenuOpen ?? openOutsidePill }

    public var body: some View {
        Button {
            open()
        } label: {
            label(isOpen)
        }
        .buttonStyle(.plain)
        .background(NotchMenuAnchorView(anchor: anchor))
    }

    private func open() {
        let menu = menu()
        if let model {
            model.popUpMenu(menu, from: anchor.view)
        } else if !openOutsidePill {
            openOutsidePill = true
            NotchMenuButtonPresenter.present(menu, anchor.view)
            openOutsidePill = false
        }
    }
}

/// How a menu opens outside a pill.
@MainActor
enum NotchMenuButtonPresenter {
    static func present(_ menu: NSMenu, _ view: NSView?) {
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// A menu item that runs a closure.
@MainActor
public final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    public init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    public required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}

/// Where a SwiftUI control is in AppKit, so a native menu can open from it.
@MainActor
public final class NotchMenuAnchor {
    public weak var view: NSView?
    public init() {}
}

/// Put behind a SwiftUI control (`.background(NotchMenuAnchorView(anchor: anchor))`) to find it in AppKit.
public struct NotchMenuAnchorView: NSViewRepresentable {
    public let anchor: NotchMenuAnchor

    public init(anchor: NotchMenuAnchor) {
        self.anchor = anchor
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
