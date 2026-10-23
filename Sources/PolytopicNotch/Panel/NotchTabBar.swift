import SwiftUI

/// Tabs for a panel in the pill: a rounded bar of equal-width tabs, the selected one in semibold on a lighter fill.
/// It fills the width it's given and is `NotchTabBar.height` tall. Its colours are `.primary` and `.secondary`, so it
/// reads on the black pill (dark) and in the glass bar on screens without a notch (the system's appearance).
///
///     NotchTabBar(Tab.allCases, selection: $model.tab) { $0.title }
///
/// Keep the selection in the app's model, not in the body's `@State`: bodies are built again every time the pill
/// opens. When a tab shows a `NotchLiveList`, `reset()` its feed when the tab changes (in the model's setter), so the
/// new tab starts following its newest row. Give the content under the bar a fixed height, so the pill doesn't change
/// size from tab to tab.
///
///     var tab: Tab = .events {
///         didSet { if tab != oldValue { feed.reset(); refresh() } }
///     }
///
/// Each tab is a button with the `isSelected` trait while selected; the bar is a tab bar to accessibility.
public struct NotchTabBar<Tab: Hashable, Label: View>: View {
    private let tabs: [Tab]
    @Binding private var selection: Tab
    private let label: (Tab, Bool) -> Label

    /// The bar's height: 20 pt tabs with 2 pt around them.
    public static var height: CGFloat { 24 }

    /// Tabs with views for labels (an icon, or an icon and a word). `label` gets the tab and whether it's selected.
    public init(_ tabs: [Tab], selection: Binding<Tab>, @ViewBuilder label: @escaping (Tab, Bool) -> Label) {
        self.tabs = tabs
        _selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    label(tab, selected)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.primary.opacity(0.16) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }
}

extension NotchTabBar where Label == NotchTabBarText {
    /// Tabs with words for labels: `NotchTabBar(Tab.allCases, selection: $model.tab) { $0.title }`.
    public init(_ tabs: [Tab], selection: Binding<Tab>, label: @escaping (Tab) -> String) {
        self.init(tabs, selection: selection) { tab, selected in
            NotchTabBarText(title: label(tab), isSelected: selected)
        }
    }
}

/// A tab's word in `NotchTabBar`: 11.5 pt, semibold while selected.
public struct NotchTabBarText: View {
    let title: String
    let isSelected: Bool

    public var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            .lineLimit(1)
    }
}
