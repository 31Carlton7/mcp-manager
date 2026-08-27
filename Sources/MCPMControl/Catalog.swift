import Foundation
import MCPMCore

/// One server someone could add, from the curated list that ships with the daemon or from the
/// official registry. Not a `Server`: nothing has been added yet, and half of these will never be.
public struct CatalogEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// The list that ships inside the daemon, and the only one available offline.
        case bundled
        case registry
    }

    public var slug: String
    public var name: String
    public var description: String
    public var kind: ServerKind
    public var url: String?
    public var transport: Transport?
    public var command: String?
    public var args: [String]
    /// Environment the server needs, by name. An empty value is a placeholder for a credential the
    /// user has to paste — `FIGMA_API_KEY` and friends.
    public var env: [String: String]
    public var auth: AuthKind
    public var homepage: String?
    /// The site whose favicon stands for this server, when the MCP host has none of its own.
    public var iconDomain: String?
    public var source: Source
    /// Published by the vendor itself rather than by someone wrapping them.
    public var official: Bool
    /// Whether the endpoint has actually been checked. A curated entry with `false` is a good
    /// guess at a URL that moves around, and the daemon's inspection is what settles it.
    public var verified: Bool
    /// Anything a person should know before adding this one — "archived upstream", most often.
    public var note: String?
    public var version: String?

    public var id: String { slug }

    public init(slug: String, name: String, description: String = "", kind: ServerKind,
                url: String? = nil, transport: Transport? = nil, command: String? = nil,
                args: [String] = [], env: [String: String] = [:], auth: AuthKind = .none,
                homepage: String? = nil, iconDomain: String? = nil, source: Source = .bundled,
                official: Bool = true, verified: Bool = true, note: String? = nil,
                version: String? = nil) {
        self.slug = slug
        self.name = name
        self.description = description
        self.kind = kind
        self.url = url
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.auth = auth
        self.homepage = homepage
        self.iconDomain = iconDomain
        self.source = source
        self.official = official
        self.verified = verified
        self.note = note
        self.version = version
    }

    /// Lenient on purpose: this decodes the curated JSON that ships with the daemon, where every
    /// entry would otherwise have to spell out the same six defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(slug: try c.decode(String.self, forKey: .slug),
                  name: try c.decode(String.self, forKey: .name),
                  description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
                  kind: try c.decode(ServerKind.self, forKey: .kind),
                  url: try c.decodeIfPresent(String.self, forKey: .url),
                  transport: try c.decodeIfPresent(Transport.self, forKey: .transport),
                  command: try c.decodeIfPresent(String.self, forKey: .command),
                  args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                  env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
                  auth: try c.decodeIfPresent(AuthKind.self, forKey: .auth) ?? .none,
                  homepage: try c.decodeIfPresent(String.self, forKey: .homepage),
                  iconDomain: try c.decodeIfPresent(String.self, forKey: .iconDomain),
                  source: try c.decodeIfPresent(Source.self, forKey: .source) ?? .bundled,
                  official: try c.decodeIfPresent(Bool.self, forKey: .official) ?? true,
                  verified: try c.decodeIfPresent(Bool.self, forKey: .verified) ?? true,
                  note: try c.decodeIfPresent(String.self, forKey: .note),
                  version: try c.decodeIfPresent(String.self, forKey: .version))
    }
}

public struct CatalogSearchParams: Codable, Equatable, Sendable {
    /// How many results a search may ask for. A caller asking for a million is asking the daemon
    /// to hold a million.
    public static let limits = 1...100

    public var query: String
    public var limit: Int?
    public init(query: String, limit: Int? = nil) { self.query = query; self.limit = limit }

    /// The requested limit, clamped into range.
    public var clampedLimit: Int { Self.clamp(limit) }

    /// Bounded here rather than at each caller, so the daemon's own searches get the same ceiling
    /// the wire does. `nil` asks for the default page size.
    public static func clamp(_ limit: Int?) -> Int {
        min(max(limit ?? 30, limits.lowerBound), limits.upperBound)
    }
}
