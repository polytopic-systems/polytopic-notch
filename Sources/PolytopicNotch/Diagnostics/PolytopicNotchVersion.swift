/// This package's release, for an app's diagnostics. `CHANGELOG.md`'s newest entry names the same version (a test checks).
public enum PolytopicNotchVersion {
    public static let string = "1.1.0"
    /// The dock protocol's major (`NotchDockWire.prefix` ends with it). Apps on different majors don't dock together.
    public static let dockProtocol = 2
}
