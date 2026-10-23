import AppKit
import SwiftUI

/// Rows for Settings › Notch: how the docked apps share the notch. They write the settings every docked app shares
/// (`NotchDockSettings`), and every running app follows at once. Put them in a Section of the app's own Form:
///
///     Section("Sharing the notch with other apps") {
///         NotchDockSettingsRows(dock: dock)
///     }
public struct NotchDockSettingsRows: View {
    var dock: NotchDock
    var caption: String

    public init(dock: NotchDock, caption: String = NotchDockStylePicker.defaultCaption) {
        self.dock = dock
        self.caption = caption
    }

    public var body: some View {
        Group {
            NotchDockStylePicker(dock: dock, caption: caption)
            NotchDockHoldRows(dock: dock)
            NotchDockAppList(dock: dock)
        }
        // Another app may have changed them while this one's dock wasn't running.
        .onAppear { dock.refreshSharedSettings() }
    }
}

/// Priority, Switcher, Split or Merged, each with a one-line explanation.
public struct NotchDockStylePicker: View {
    var dock: NotchDock
    var caption: String

    public static let defaultCaption = "Shared by every app on this Mac that docks in the notch. A change here applies to all of them."

    public init(dock: NotchDock, caption: String = Self.defaultCaption) {
        self.dock = dock
        self.caption = caption
    }

    public var body: some View {
        Picker(selection: Binding(get: { dock.style }, set: { dock.setStyle($0) })) {
            ForEach(NotchSharingStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.title)
                    Text(style.explanation).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(style)
            }
        } label: {
            Text("Sharing style")
            notchSettingsCaption(caption)
        }
        .pickerStyle(.radioGroup)
    }
}

/// How long an unanswered question keeps the notch from the other apps: a number of seconds, or until answered.
public struct NotchDockHoldRows: View {
    var dock: NotchDock

    public init(dock: NotchDock) {
        self.dock = dock
    }

    public static let secondsRange: ClosedRange<Double> = 5...600

    public var body: some View {
        let untilAnswered = dock.urgentHold == .untilAnswered
        Picker(selection: Binding(get: { untilAnswered },
                                  set: { dock.setUrgentHold($0 ? .untilAnswered : .seconds(dock.urgentHoldSeconds)) })) {
            Text("For a while").tag(false)
            Text("Until answered").tag(true)
        } label: {
            Text("A question keeps the notch")
            notchSettingsCaption("While an app asks something, the others wait. After this the question stays in the app's own window.")
        }
        if !untilAnswered {
            Stepper(value: Binding(get: { dock.urgentHoldSeconds }, set: { dock.setUrgentHold(.seconds($0)) }),
                    in: Self.secondsRange, step: 5) {
                Text("For \(Int(dock.urgentHoldSeconds)) seconds")
            }
        }
    }
}

/// The docked apps in the user's order, which are running, drag (or the arrows) to reorder. Top to bottom is left to
/// right in Split, top to bottom in Merged, and who goes first on a tie in Priority and Switcher.
public struct NotchDockAppList: View {
    var dock: NotchDock

    public init(dock: NotchDock) {
        self.dock = dock
    }

    /// The order with this app and every docked peer in it (a peer that just joined may not be saved yet).
    static func rows(order: [String], me: String, peers: [String], blocked: Set<String> = []) -> [String] {
        var rows = order
        for id in [me] + peers.sorted() + blocked.sorted() where !rows.contains(id) { rows.append(id) }
        return rows
    }

    public var body: some View {
        let rows = Self.rows(order: dock.order, me: dock.me.appID, peers: dock.peers.values.map(\.appID),
                             blocked: dock.blocked)
        LabeledContent {
            EmptyView()
        } label: {
            Text("Order")
            notchSettingsCaption("Left to right in Split, top to bottom in Merged; first in line on a tie otherwise. Drag to reorder.")
        }
        ForEach(Array(rows.enumerated()), id: \.element) { index, appID in
            let docked = dock.isDocked(appID)
            let isBlocked = dock.blocked.contains(appID)
            HStack(spacing: 10) {
                NotchAppIcon(bundleID: appID, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(NotchDockAppName.name(of: appID)).lineLimit(1)
                    Text(appID == dock.me.appID ? "This app" : isBlocked ? "Blocked" : docked ? "Running" : "Not running")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { move(appID, by: -1, in: rows) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move up")
                Button { move(appID, by: 1, in: rows) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == rows.count - 1)
                    .help("Move down")
            }
            .buttonStyle(.borderless)
            .contextMenu {
                if appID != dock.me.appID {
                    Button(isBlocked ? "Allow in the Dock" : "Don't Dock with This App") {
                        dock.setBlocked(appID, !isBlocked)
                    }
                }
                if !docked {
                    Button("Remove from the List") { dock.setOrder(rows.filter { $0 != appID }) }
                }
            }
        }
        .onMove { from, to in
            var order = rows
            order.move(fromOffsets: from, toOffset: to)
            dock.setOrder(order)
        }
    }

    private func move(_ appID: String, by step: Int, in rows: [String]) {
        guard let index = rows.firstIndex(of: appID) else { return }
        let target = index + step
        guard rows.indices.contains(target) else { return }
        var order = rows
        order.swapAt(index, target)
        dock.setOrder(order)
    }
}
