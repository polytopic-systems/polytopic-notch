import Foundation

/// An app we know by name that uses the notch or the strip under the menu bar.
///
/// Unknown notch apps are still found by the general rule in `NotchNeighborDetection`; a profile adds a
/// name for Settings and the console, and a rule that fits the app where its window bounds would
/// mislead the general one (full-width strips, the Top Shelf canvas, cosmetic apps, bars).
public struct NotchNeighborProfile: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// An island, shelf or HUD that grows out of the notch.
        case notchApp
        /// Drops a bar of hidden menu bar items just under the menu bar (some also have a notch panel).
        case menuBarManager
        /// Decorates the notch or the menu bar; nothing to make room for.
        case cosmetic
    }

    /// Which of its windows means it's using the notch.
    public enum NotchWindow: Equatable, Sendable {
        /// None of them: never a notch neighbor.
        case none
        /// Any window at menu-bar level or above in the band across the top of the screen at or beside
        /// the notch. Bounds aren't trusted beyond that: many are big transparent boxes or full-width strips
        /// whose visible part is notch-sized while idle.
        case overNotch
        /// Bartender's Top Shelf: a tall canvas pinned to the top of the screen, present only while
        /// Top Shelf is on. Counts only while it's there.
        case tallCanvas
    }

    public var name: String
    /// Matched case-insensitively against the start of the bundle ID, so Setapp and dev builds count too.
    public var bundlePrefixes: [String]
    public var role: Role
    public var notchWindow: NotchWindow
    /// Window levels its bar under the menu bar uses; `nil` if it has no such bar.
    public var barLayers: ClosedRange<Int>? = nil

    public func matches(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return bundlePrefixes.contains { id.hasPrefix($0.lowercased()) }
    }

    public static func profile(for bundleID: String) -> NotchNeighborProfile? {
        all.first { $0.matches(bundleID) }
    }

    private static func notchApp(_ name: String, _ prefixes: String...) -> NotchNeighborProfile {
        NotchNeighborProfile(name: name, bundlePrefixes: prefixes, role: .notchApp, notchWindow: .overNotch)
    }

    private static func barManager(_ name: String, _ prefixes: [String], layers: ClosedRange<Int> = 1...999,
                                   notch: NotchWindow = .none) -> NotchNeighborProfile {
        NotchNeighborProfile(name: name, bundlePrefixes: prefixes, role: .menuBarManager, notchWindow: notch, barLayers: layers)
    }

    private static func cosmetic(_ name: String, _ prefix: String) -> NotchNeighborProfile {
        NotchNeighborProfile(name: name, bundlePrefixes: [prefix], role: .cosmetic, notchWindow: .none)
    }

    /// Identifiers come from the apps' sources, Homebrew casks or App Store listings (Oct 2026). Window
    /// shapes noted are what their sources create; the real apps weren't available to check against.
    public static let all: [NotchNeighborProfile] = [
        // Menu bar managers. Bartender 4–7 and its Setapp builds share this prefix; 7's Top Shelf is a
        // notch island on a 500 pt tall canvas. Its bar has always been matched at any level below 1000.
        barManager("Bartender", ["com.surteesstudios.Bartender"], notch: .tallCanvas),
        // Ice and its successor Thaw: the Ice Bar is a level-25 panel flush under the menu bar. Both also
        // keep a full-width, click-through tint at level 25 that the bar rule skips as full-width.
        barManager("Ice", ["com.jordanbaird.Ice"], layers: 24...26),
        barManager("Thaw", ["com.stonerl.Thaw"], layers: 24...26),
        barManager("Barbee", ["com.HyperartFlow.Barbee"]),
        barManager("iBar", ["cn.better365.iBar", "com.better365.iBarPro"]),
        barManager("SaneBar", ["com.sanebar.app"]),
        barManager("Pelmet", ["com.ismatbabirli.Pelmet"]),

        // Notch apps. Boring Notch's window is always a 640×210 transparent box; NotchDrop's and Notchi's
        // span the screen; DynamicNotchKit apps use a half-screen panel at level 1000; Atoll's window
        // follows its content. Most sit at level 27, like our pill.
        notchApp("Boring Notch", "theboringteam.boringnotch"),
        notchApp("Atoll", "com.Ebullioscopic.Atoll"),
        notchApp("NotchNook", "lo.cafe.NotchNook"),
        notchApp("Alcove", "com.henrikruscon.Alcove"),
        notchApp("MediaMate", "com.tweety.MediaMate"),
        notchApp("NotchDrop", "wiki.qaq.NotchDrop"),
        notchApp("MewNotch", "com.monuk7735.mew.notch"),
        notchApp("Notchi", "com.ruban.notchi"),
        notchApp("Vibe Notch", "com.celestial.ClaudeIsland"),
        notchApp("CodeIsland", "com.codeisland.app"),
        notchApp("Vibe Island", "app.vibeisland.macos"),
        notchApp("Open Island", "app.openisland.OpenIsland"),
        notchApp("Ping Island", "com.wudanwu.PingIsland"),
        notchApp("Seam", "app.seam.Seam"),
        notchApp("Droppy", "iordv.Droppy"),
        notchApp("Peninsula", "Celve.Peninsula"),
        notchApp("TickerNotch", "com.bitvibelabs.tickernotch"),
        notchApp("Textream", "dev.fka.textream"),

        // Cosmetic: they draw over or around the notch but show nothing that needs room.
        cosmetic("TopNotch", "pl.maketheweb.TopNotch"),
        cosmetic("Notchmeister", "com.iconfactory.Notchmeister"),
        cosmetic("Say No to Notch", "com.ibluebox.say-no-to-notch"),
    ]
}
