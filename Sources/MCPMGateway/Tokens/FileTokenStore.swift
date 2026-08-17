import Foundation
import MCPMCore

/// Secrets in one 0600 JSON file. For development and tests: an unsigned `mcpmd` rebuild changes
/// its code identity, so the Keychain re-prompts on every build — set `MCPM_TOKEN_STORE=file` to
/// use this instead. Not for production use.
public final class FileTokenStore: TokenStore, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private struct Contents: Codable {
        var tokens: [String: TokenRecord] = [:]
        var headers: [String: HeaderSecret] = [:]
        var registrations: [String: ClientRegistration] = [:]

        init() {}

        /// Every section is optional so a file written before a section existed still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokens = try c.decodeIfPresent([String: TokenRecord].self, forKey: .tokens) ?? [:]
            headers = try c.decodeIfPresent([String: HeaderSecret].self, forKey: .headers) ?? [:]
            registrations = try c.decodeIfPresent([String: ClientRegistration].self, forKey: .registrations) ?? [:]
        }
    }

    private func load() throws -> Contents {
        guard let data = try? Data(contentsOf: url) else { return Contents() }
        return try TokenCoding.decoder.decode(Contents.self, from: data)
    }

    private func mutate(_ body: (inout Contents) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var contents = try load()
        body(&contents)
        try AtomicFile.write(try TokenCoding.encoder.encode(contents), to: url, mode: 0o600)
    }

    private func read<T>(_ body: (Contents) -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(try load())
    }

    public func token(for id: String) throws -> TokenRecord? { try read { $0.tokens[id] } }
    public func setToken(_ token: TokenRecord, for id: String) throws { try mutate { $0.tokens[id] = token } }
    public func removeToken(for id: String) throws { try mutate { $0.tokens[id] = nil } }

    public func header(for id: String) throws -> HeaderSecret? { try read { $0.headers[id] } }
    public func setHeader(_ header: HeaderSecret, for id: String) throws { try mutate { $0.headers[id] = header } }
    public func removeHeader(for id: String) throws { try mutate { $0.headers[id] = nil } }

    public func clientRegistration(for id: String) throws -> ClientRegistration? {
        try read { $0.registrations[id] }
    }
    public func setClientRegistration(_ registration: ClientRegistration, for id: String) throws {
        try mutate { $0.registrations[id] = registration }
    }
    public func removeClientRegistration(for id: String) throws { try mutate { $0.registrations[id] = nil } }
}
