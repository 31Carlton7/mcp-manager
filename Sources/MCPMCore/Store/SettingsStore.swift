import Foundation

/// User preferences that outlive a daemon run, kept in `~/.mcpm/settings.json`. Deliberately
/// small: anything the daemon can work out for itself does not belong here.
public struct Settings: Codable, Equatable, Sendable {
    /// The port the auth gateway binds, and the port written into every client config that goes
    /// through it. Changing it only takes effect on the next daemon start — see `SettingsService`.
    public var gatewayPort: Int
    /// How many timestamped copies of each client config to keep under `~/.mcpm/backups`.
    public var backupRetention: Int

    public static let defaultGatewayPort = 7337
    public static let defaultBackupRetention = 5
    /// The range a TCP port can occupy. 0 is excluded on purpose: it means "any free port", which
    /// would hand out an ephemeral one that no client config points at.
    public static let portRange = 1...65535

    public init(gatewayPort: Int = Settings.defaultGatewayPort,
                backupRetention: Int = Settings.defaultBackupRetention) {
        self.gatewayPort = gatewayPort
        self.backupRetention = backupRetention
    }

    /// Every key is optional on the way in, so a file written by another version — older, missing
    /// a key, or newer, carrying one we don't know — still loads instead of reading as corrupt.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gatewayPort = try c.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? Settings.defaultGatewayPort
        backupRetention = try c.decodeIfPresent(Int.self, forKey: .backupRetention) ?? Settings.defaultBackupRetention
    }
}

public struct SettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    /// Defaults when the file isn't there yet — the ordinary state on a fresh install, and not
    /// worth writing a file for. A file that exists but won't parse throws instead: overwriting it
    /// with defaults would silently discard a value the user hand-edited and mistyped.
    public func load() throws -> Settings {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return Settings() }
        catch { throw StoreError.unreadable(String(describing: error)) }
        do { return try JSONDecoder.mcpm.decode(Settings.self, from: data) }
        catch { throw StoreError.corrupt(String(describing: error)) }
    }

    public func save(_ settings: Settings) throws {
        try AtomicFile.write(try JSONEncoder.mcpm.encode(settings), to: url, mode: 0o600)
    }
}
