import Foundation
import Security

public enum KeychainError: Error, Equatable, CustomStringConvertible {
    case status(OSStatus, String)

    public var description: String {
        switch self {
        case let .status(code, op):
            let message = SecCopyErrorMessageString(code, nil).map { String($0) } ?? "OSStatus \(code)"
            return "keychain \(op) failed: \(message)"
        }
    }
}

/// Generic-password items in the login keychain, one per secret: account `token.<id>`,
/// `header.<id>` or `client.<id>` under a single service. Values are the same JSON the file store
/// writes.
///
/// Development note: an unsigned `mcpmd` gets a new code identity on every rebuild, so macOS shows
/// the "wants to use your confidential information stored in …" panel each time. Set
/// `MCPM_TOKEN_STORE=file` while developing to use `FileTokenStore` instead.
public struct KeychainTokenStore: TokenStore, Sendable {
    public let service: String

    public init(service: String = "co.charmtechnologies.mcpm") {
        self.service = service
    }

    // MARK: - TokenStore

    public func token(for id: String) throws -> TokenRecord? { try get(account: "token.\(id)") }
    public func setToken(_ token: TokenRecord, for id: String) throws { try set(token, account: "token.\(id)") }
    public func removeToken(for id: String) throws { try remove(account: "token.\(id)") }

    public func header(for id: String) throws -> HeaderSecret? { try get(account: "header.\(id)") }
    public func setHeader(_ header: HeaderSecret, for id: String) throws { try set(header, account: "header.\(id)") }
    public func removeHeader(for id: String) throws { try remove(account: "header.\(id)") }

    public func clientRegistration(for id: String) throws -> ClientRegistration? {
        try get(account: "client.\(id)")
    }
    public func setClientRegistration(_ registration: ClientRegistration, for id: String) throws {
        try set(registration, account: "client.\(id)")
    }

    /// Drops the registration too — "Forget this server" rather than "sign out".
    public func removeClientRegistration(for id: String) throws { try remove(account: "client.\(id)") }

    // MARK: - SecItem

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // No kSecAttrSynchronizable: these must not leave the machine via iCloud Keychain.
        ]
    }

    private func get<T: Decodable>(account: String) throws -> T? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status, "read \(account)")
        }
        return try TokenCoding.decoder.decode(T.self, from: data)
    }

    private func set<T: Encodable>(_ value: T, account: String) throws {
        let data = try TokenCoding.encoder.encode(value)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status, "update \(account)") }

        var add = query(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "MCP Manager — \(account)"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus, "add \(account)") }
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status, "delete \(account)")
        }
    }
}
