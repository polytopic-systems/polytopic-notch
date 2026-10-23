import Foundation
import Observation
import Testing
@testable import PolytopicNotch

/// Stands in for an app's own settings: its own field names (Captioner's), stored as one Codable blob, with
/// the package's enums inside. The bridge maps them; what's stored doesn't change.
@MainActor
@Observable
final class AppLikeSettings: NotchSettingsStore {
    struct Preferences: Codable, Equatable {
        struct AppReference: Codable, Equatable {
            var bundleID: String
            var name: String
            var label: String? = nil
        }
        var showNotch = true
        var notchDisplay: NotchDisplay = .builtIn
        var notchSharing: NotchSharing = .automatic
        var notchIgnoredNeighbors: [AppReference] = []
        var notchCaptionShape: NotchPillShape = .grow
        var notchIndicator: NotchIndicatorPosition = .besideNotch
        var notchFontSize: Double = 15
        var notchCaptionLines = 2
    }

    var prefs = Preferences()

    var notch: NotchSettings {
        get {
            NotchSettings(isShown: prefs.showNotch, display: prefs.notchDisplay, sharing: prefs.notchSharing,
                          ignoredApps: prefs.notchIgnoredNeighbors.map { NotchIgnoredApp(bundleID: $0.bundleID, name: $0.name) },
                          pillShape: prefs.notchCaptionShape, indicator: prefs.notchIndicator, fontSize: prefs.notchFontSize)
        }
        set {
            prefs.showNotch = newValue.isShown
            prefs.notchDisplay = newValue.display
            prefs.notchSharing = newValue.sharing
            prefs.notchIgnoredNeighbors = newValue.ignoredApps.map { app in
                // Keep what the app stores beyond the package's fields.
                prefs.notchIgnoredNeighbors.first { $0.bundleID == app.bundleID }
                    ?? Preferences.AppReference(bundleID: app.bundleID, name: app.name)
            }
            prefs.notchCaptionShape = newValue.pillShape
            prefs.notchIndicator = newValue.indicator
            prefs.notchFontSize = newValue.fontSize
        }
    }
}

@MainActor
struct NotchSettingsTests {
    @Test func defaultsAreTodaysBehaviour() {
        let settings = NotchSettings()
        #expect(settings.isShown && settings.display == .builtIn && settings.sharing == .automatic)
        #expect(settings.pillShape == .grow && settings.indicator == .besideNotch && settings.ignoredApps.isEmpty)
        #expect(settings.fontSize == 15)
    }

    /// The raw values the apps already store. Renaming one would reset everyone's choice.
    @Test func storedRawValuesNeverChange() throws {
        #expect(NotchPillShape.allCases.map(\.rawValue) == ["grow", "clearMenuBar"])
        #expect(NotchIndicatorPosition.allCases.map(\.rawValue) == ["besideNotch", "underNotch"])
        #expect(NotchSharing.allCases.map(\.rawValue) == ["automatic", "always", "never"])
        #expect(NotchDisplay.allCases.map(\.rawValue) == ["builtIn", "active"])
        // An app's blob encodes them as those strings, under the app's own keys.
        var prefs = AppLikeSettings.Preferences()
        prefs.notchCaptionShape = .clearMenuBar
        prefs.notchIndicator = .underNotch
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as? [String: Any])
        #expect(json["notchCaptionShape"] as? String == "clearMenuBar")
        #expect(json["notchIndicator"] as? String == "underNotch")
        #expect(json["notchSharing"] as? String == "automatic")
        #expect(json["notchDisplay"] as? String == "builtIn")
        #expect(json["notch"] == nil && json["pillShape"] == nil, "the package adds no keys")
        // And a blob saved before the package existed still decodes.
        let old = try JSONSerialization.data(withJSONObject: ["showNotch": false, "notchDisplay": "active", "notchSharing": "never",
                                                              "notchIgnoredNeighbors": [], "notchCaptionShape": "clearMenuBar",
                                                              "notchIndicator": "underNotch", "notchFontSize": 18, "notchCaptionLines": 3])
        let decoded = try JSONDecoder().decode(AppLikeSettings.Preferences.self, from: old)
        #expect(decoded.notchCaptionShape == .clearMenuBar && decoded.notchSharing == .never && decoded.notchDisplay == .active)
    }

    @Test func theBridgeRoundTripsAndKeepsTheAppsOwnFields() {
        let settings = AppLikeSettings()
        settings.prefs.notchIgnoredNeighbors = [.init(bundleID: "com.example.island", name: "Island", label: "Kept")]
        var notch = settings.notch
        notch.pillShape = .clearMenuBar
        notch.sharing = .always
        notch.ignoredApps.append(NotchIgnoredApp(bundleID: "com.example.strip", name: "Strip"))
        settings.notch = notch
        #expect(settings.prefs.notchCaptionShape == .clearMenuBar && settings.prefs.notchSharing == .always)
        #expect(settings.prefs.notchIgnoredNeighbors.map(\.bundleID) == ["com.example.island", "com.example.strip"])
        #expect(settings.prefs.notchIgnoredNeighbors.first?.label == "Kept")
        #expect(settings.prefs.notchCaptionLines == 2, "fields the package doesn't know are left alone")
        #expect(settings.notch == notch)
        // The binding helper writes through the bridge.
        settings.binding(\.indicator).wrappedValue = .underNotch
        #expect(settings.prefs.notchIndicator == .underNotch)
    }

    @Test func theModelReadsTheAppsSettingsThroughTheBridge() {
        let settings = AppLikeSettings()
        let model = NotchViewModel(content: NotchContent(), settings: settings, geometry: TestScreens.geometry(TestScreens.notches[0]))
        #expect(!model.keepsMenuBarClear(.showing))
        settings.prefs.notchCaptionShape = .clearMenuBar
        #expect(model.keepsMenuBarClear(.showing))
    }

    @Test func observationFollowsTheBridge() {
        let settings = AppLikeSettings()
        final class Flag: @unchecked Sendable { var raised = false }
        let changed = Flag()
        withObservationTracking {
            _ = settings.notch.pillShape
        } onChange: {
            changed.raised = true
        }
        settings.prefs.notchCaptionShape = .clearMenuBar
        #expect(changed.raised)
    }

    @Test func neighborRowsListDetectedThenIgnoredApps() {
        let boring = NotchNeighborMonitor.Neighbor(pid: 20, bundleID: "theboringteam.boringnotch", name: "Boring Notch",
                                                   profileName: "Boring Notch", live: false)
        let island = NotchNeighborMonitor.Neighbor(pid: 31, bundleID: "com.example.island", name: "Island", profileName: nil, live: false)
        let rows = NotchNeighborRows.rows(detected: [boring, island],
                                          ignored: [NotchIgnoredApp(bundleID: "com.example.island", name: "Island"),
                                                    NotchIgnoredApp(bundleID: "com.example.gone", name: "Gone")])
        #expect(rows.map(\.name) == ["Boring Notch", "Island", "Gone"])
        #expect(rows.map(\.running) == [true, true, false])
        #expect(rows.map(NotchNeighborRows.subtitle) == ["Known notch app", "Found by its window over the notch", "Not running"])
        let bartender = NotchNeighborRows.Row(bundleID: "com.surteesstudios.Bartender", name: "Bartender", running: true,
                                              profileName: "Bartender")
        #expect(NotchNeighborRows.subtitle(bartender) == "Top Shelf is on")
    }
}
