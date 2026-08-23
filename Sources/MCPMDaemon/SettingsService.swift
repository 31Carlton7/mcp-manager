import Foundation
import MCPMCore

/// Owns `~/.mcpm/settings.json` for the life of the daemon: one reader, one writer, and the
/// answer to "does this need a restart yet?".
///
/// The gateway port is the awkward one. The coordinator's `gatewayPort` is baked into every
/// client config it writes, and the gateway is already listening on the old one, so rebinding on
/// the fly would leave URLs pointing at a port nothing answers on — for however long it took the
/// rebind to fail. So a new port is saved, reported as pending, and applied on the next start.
public actor SettingsService {
    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case port(Int)
        case retention(Int)

        public var description: String {
            switch self {
            case .port(let p): "\(p) is not a valid port (\(Settings.portRange.lowerBound)–\(Settings.portRange.upperBound))"
            case .retention(let n): "backup retention must be between 0 and 100, got \(n)"
            }
        }
    }

    /// What the app shows next to the Restart button when a saved port is not the running one.
    public static let restartNote = "Restart the background service to apply the new port."
    static let retentionRange = 0...100

    private let store: SettingsStore
    /// The port this daemon actually resolved at startup. Compared against the saved one rather
    /// than tracked as a flag, so setting the port back to what is running clears the pending
    /// state on its own.
    private let runningPort: Int
    /// `MCPM_GATEWAY_PORT` outranks the file, so while it is set a restart would not apply a saved
    /// port either — claiming otherwise would send the user round a loop that changes nothing.
    private let portOverriddenByEnvironment: Bool
    private var current: Settings
    /// Applied to the live coordinator, so a retention change takes effect without a restart.
    private let applyRetention: @Sendable (Int) async -> Void

    public init(store: SettingsStore, initial: Settings, runningPort: Int,
                portOverriddenByEnvironment: Bool = false,
                applyRetention: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.store = store
        self.current = initial
        self.runningPort = runningPort
        self.portOverriddenByEnvironment = portOverriddenByEnvironment
        self.applyRetention = applyRetention
    }

    public var settings: Settings { current }

    public var pendingRestart: Bool {
        !portOverriddenByEnvironment && current.gatewayPort != runningPort
    }

    /// Validates the whole patched value before writing any of it: a save that took the port and
    /// rejected the retention would leave the file and the caller disagreeing about what happened.
    @discardableResult
    public func apply(_ patch: SettingsPatch) async throws -> Settings {
        var next = current
        if let port = patch.gatewayPort {
            guard Settings.portRange.contains(port) else { throw ValidationError.port(port) }
            next.gatewayPort = port
        }
        if let keep = patch.backupRetention {
            guard Self.retentionRange.contains(keep) else { throw ValidationError.retention(keep) }
            next.backupRetention = keep
        }
        guard next != current else { return current }
        try store.save(next)
        current = next
        await applyRetention(next.backupRetention)
        return next
    }
}

/// The daemon-side shape of a settings change, so `SettingsService` does not depend on the control
/// protocol's params type.
public struct SettingsPatch: Sendable, Equatable {
    public var gatewayPort: Int?
    public var backupRetention: Int?
    public init(gatewayPort: Int? = nil, backupRetention: Int? = nil) {
        self.gatewayPort = gatewayPort; self.backupRetention = backupRetention
    }
}
