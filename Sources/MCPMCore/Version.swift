/// The one place the product version is written. The daemon, the probe's `clientInfo`, the app's
/// `MARKETING_VERSION` in `Apps/MCPManager/project.yml`, and `DaemonClient`'s fallback all read
/// from here — bump this and `project.yml` together.
///
/// `.github/workflows/release.yml` greps the line below and refuses to publish a tag that does not
/// match it, so keep the `static let current = "..."` shape.
public enum MCPMVersion {
    public static let current = "0.1.2"
}
