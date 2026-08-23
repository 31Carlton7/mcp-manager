/// The one place the product version is written. The daemon, the probe's `clientInfo`, the app's
/// `MARKETING_VERSION` in `Apps/MCPManager/project.yml`, and `DaemonClient`'s fallback all read
/// from here — bump this and `project.yml` together.
///
/// The release tag must match `MCPMVersion.current` (tag `v0.1.0` for `"0.1.0"`).
public enum MCPMVersion {
    public static let current = "0.1.0"
}
