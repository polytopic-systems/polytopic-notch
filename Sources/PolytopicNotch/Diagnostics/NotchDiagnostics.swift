import AppKit

/// The notch's latest placement, recorded by `NotchPanelController` for an app's developer console and
/// diagnostics reports. The app owns one (usually next to its neighbor monitor) and reads it when it builds a report.
@MainActor
public final class NotchDiagnostics {
    public let log: NotchLog

    public private(set) var geometry: NotchGeometry?
    public private(set) var display: NotchDisplay = .builtIn
    public private(set) var sharing: NotchSharing = .automatic
    public private(set) var neighborPresent = false
    public private(set) var obstruction: CGRect?
    /// Apps we're making room for at the notch, e.g. "Boring Notch, Atoll".
    public private(set) var neighborNames: [String] = []
    /// Detected but ignored at the user's request.
    public private(set) var ignoredNames: [String] = []
    /// Whose bar `obstruction` is.
    public private(set) var barOwner: String?
    public private(set) var changes = 0

    public init(log: NotchLog = .silent) {
        self.log = log
    }

    public func record(_ geometry: NotchGeometry, display: NotchDisplay, sharing: NotchSharing, neighborPresent: Bool,
                       obstruction: CGRect?) {
        let previous = self.geometry
        self.geometry = geometry
        self.display = display
        self.sharing = sharing
        self.neighborPresent = neighborPresent
        self.obstruction = obstruction
        guard previous != geometry else { return }
        changes += 1
        let screen = geometry.screenFrame
        var line = "placement → \(geometry.placement) on \(Int(screen.width))×\(Int(screen.height)) screen"
        line += geometry.hasNotch ? " (notch \(Int(geometry.notchSize.width))×\(Int(geometry.notchSize.height)))" : " (no notch)"
        line += String(format: " · centerX %.0f · anchorY %.0f", geometry.centerX, geometry.anchorY)
        if geometry.drop > 0 { line += String(format: " · drop %.0f pt", geometry.drop) }
        line += " · display \(display.rawValue) · sharing \(sharing.rawValue)"
        log.notice(line)
    }

    /// Who's being made room for. The monitor logs each detection decision itself; this keeps the
    /// summary for the console and the report, and logs the bar coming and going.
    public func recordNeighbors(_ neighbors: [NotchNeighborMonitor.Neighbor], ignored: [NotchNeighborMonitor.Neighbor],
                                obstruction: CGRect?, barOwner: String?) {
        let names = neighbors.map(\.name)
        if names != neighborNames {
            log.notice("notch neighbors: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
            neighborNames = names
        }
        ignoredNames = ignored.map(\.name)
        // Compared with what was recorded last time, which `record` (called after this) then replaces.
        if (obstruction == nil) != (self.obstruction == nil) || (obstruction != nil && obstruction != self.obstruction) {
            if let obstruction {
                log.info(String(format: "%@ bar showing at %.0f,%.0f %.0f×%.0f", barOwner ?? "Menu bar manager",
                                obstruction.minX, obstruction.minY, obstruction.width, obstruction.height))
            } else if self.obstruction != nil {
                log.info("\(self.barOwner ?? "Menu bar manager") bar hidden")
            }
        }
        self.barOwner = barOwner
    }
}
