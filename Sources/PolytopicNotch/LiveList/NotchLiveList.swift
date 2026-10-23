import AppKit
import SwiftUI

/// A list inside the pill that follows its newest item, and holds still while the user works with it or reads.
/// Shows `feed.shown` in a `ScrollView` + `LazyVStack`, keeps the live edge in view while live, holds while the
/// pointer is on an element marked `.notchLiveAction()`, while the pill's menu is open, and while the user has
/// scrolled away, and draws an "N new" capsule at the live edge while held with something new.
///
///     NotchLiveList(feed, spacing: 2) { event in
///         EventRow(event)                    // its Allow/Block buttons carry .notchLiveAction()
///     }
public struct NotchLiveList<Item: Identifiable & Equatable, Row: View>: View {
    private let feed: NotchLiveFeed<Item>
    private let spacing: CGFloat
    private let showsIndicators: Bool
    private let row: (Item) -> Row

    @Environment(NotchViewModel.self) private var model: NotchViewModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: ScrollPosition
    @State private var phase: ScrollPhase = .idle
    /// Set while the list scrolls itself to the live edge: positions on the way don't count as the user reading.
    @State private var scrollingBackSince: Date?

    /// - Parameters:
    ///   - feed: the list's feed, kept by the app's model.
    ///   - spacing: between rows.
    ///   - showsIndicators: the scroll indicator, as the app likes it (hidden by default, like the pill's other bodies).
    ///   - row: the view for one item; mark rows with actions `.notchLiveAction()`.
    public init(_ feed: NotchLiveFeed<Item>, spacing: CGFloat = 0, showsIndicators: Bool = false,
                @ViewBuilder row: @escaping (Item) -> Row) {
        self.feed = feed
        self.spacing = spacing
        self.showsIndicators = showsIndicators
        self.row = row
        _position = State(initialValue: ScrollPosition(edge: feed.edge == .top ? .top : .bottom))
    }

    private var anchor: UnitPoint { feed.edge == .top ? .top : .bottom }
    private var scrollEdge: Edge { feed.edge == .top ? .top : .bottom }

    public var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: spacing) {
                ForEach(feed.shown) { item in
                    row(item)
                }
            }
        }
        .scrollIndicators(showsIndicators ? .automatic : .hidden)
        .scrollPosition($position)
        .defaultScrollAnchor(anchor)
        .defaultScrollAnchor(anchor, for: .sizeChanges)
        .onScrollPhaseChange { _, new in
            phase = new
            if new == .tracking || new == .interacting { scrollingBackSince = nil }   // the user took over
        }
        .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
            ScrollSnapshot(geometry, edge: feed.edge)
        } action: { old, new in
            report(old: old, new: new)
        }
        .overlay(alignment: feed.edge == .top ? .top : .bottom) {
            if feed.isHeld, feed.pendingNew > 0 {
                NotchLiveNewCapsule(count: feed.pendingNew, edge: feed.edge) { feed.resumeLive() }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .environment(\.notchLiveActionTarget, NotchLiveActionTarget(feed))
        .onAppear {
            feed.attach()
            feed.menu(open: model?.isMenuOpen ?? false)
        }
        .onDisappear { feed.detach() }
        .onChange(of: model?.isMenuOpen ?? false) { _, open in feed.menu(open: open) }
        .onChange(of: feed.scrollToEdgeRequest) { scrollToEdge(animated: true) }
        .onChange(of: feed.shown.map(\.id)) {
            // Live: the newest item stays in view as items arrive.
            if !feed.isHeld { scrollToEdge(animated: false) }
        }
    }

    private func report(old: ScrollSnapshot, new: ScrollSnapshot) {
        if let since = scrollingBackSince {
            if new.atLiveEdge || Date().timeIntervalSince(since) > 0.8 { scrollingBackSince = nil }
            return
        }
        if phase == .animating { return }
        guard old.contentHeight == new.contentHeight, old.containerHeight == new.containerHeight else {
            // Rows arrived or the pill resized: never the user leaving the edge.
            if new.atLiveEdge, !old.atLiveEdge { feed.scrolled(atLiveEdge: true, moved: false) }
            return
        }
        guard abs(old.offset - new.offset) > 0.5 else { return }
        feed.scrolled(atLiveEdge: new.atLiveEdge, moved: true)
    }

    private func scrollToEdge(animated: Bool) {
        scrollingBackSince = Date()
        if animated && !reduceMotion {
            withAnimation(.smooth(duration: 0.35)) { position.scrollTo(edge: scrollEdge) }
        } else {
            position.scrollTo(edge: scrollEdge)
        }
    }
}

/// What the list watches of its scroll view.
struct ScrollSnapshot: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var atLiveEdge: Bool

    init(_ geometry: ScrollGeometry, edge: NotchLiveEdge) {
        offset = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        atLiveEdge = edge.contains(visible: geometry.visibleRect, contentHeight: geometry.contentSize.height)
    }
}

/// "12 new ↑": at the live edge while the list is held and something arrived. A click returns to live.
struct NotchLiveNewCapsule: View {
    let count: Int
    let edge: NotchLiveEdge
    let action: () -> Void
    @Environment(NotchViewModel.self) private var model: NotchViewModel?

    var body: some View {
        let fill = model?.theme.accent() ?? .accentColor
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: edge == .top ? "arrow.up" : "arrow.down")
                Text("\(count) new")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Self.readableText(on: fill))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("\(count) new, show the latest")
    }

    /// Near-black or white, whichever contrasts more with the fill (WCAG relative luminance).
    static func readableText(on fill: Color) -> Color {
        guard let rgb = NSColor(fill).usingColorSpace(.sRGB) else { return .black }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        let onBlack = (luminance + 0.05) / 0.05, onWhite = 1.05 / (luminance + 0.05)
        return onBlack >= onWhite ? Color(white: 0.08) : .white
    }
}

// MARK: - Marking actions

/// Where a marked element reports hover: the list around it (from the environment) or a feed passed explicitly.
public struct NotchLiveActionTarget: Sendable {
    let hover: @MainActor @Sendable (Bool, AnyHashable) -> Void

    @MainActor
    public init<Item>(_ feed: NotchLiveFeed<Item>) {
        hover = { inside, token in feed.actionHover(inside, token: token) }
    }
}

extension EnvironmentValues {
    /// Set by `NotchLiveList` for the rows inside it.
    @Entry public var notchLiveActionTarget: NotchLiveActionTarget? = nil
}

private struct NotchLiveActionModifier: ViewModifier {
    let explicit: NotchLiveActionTarget?
    @Environment(\.notchLiveActionTarget) private var inherited
    @State private var token = UUID()
    @State private var inside = false

    private var target: NotchLiveActionTarget? { explicit ?? inherited }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != inside else { return }
                inside = hovering
                target?.hover(hovering, token)
            }
            .onDisappear {
                // A row scrolled away or removed under the pointer.
                guard inside else { return }
                inside = false
                target?.hover(false, token)
            }
    }
}

extension View {
    /// Marks an element (a row with buttons, or the buttons) whose hover holds the `NotchLiveList` it's in, so it
    /// doesn't move from under the pointer. Content that is only read (transcript text) isn't marked: pointing at it
    /// must not freeze the list.
    public func notchLiveAction() -> some View {
        modifier(NotchLiveActionModifier(explicit: nil))
    }

    /// As `notchLiveAction()`, for an element outside the list (or a list of the app's own) that holds `feed`.
    public func notchLiveAction<Item>(_ feed: NotchLiveFeed<Item>) -> some View {
        modifier(NotchLiveActionModifier(explicit: NotchLiveActionTarget(feed)))
    }
}
