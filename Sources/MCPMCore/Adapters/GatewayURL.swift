import Foundation

public enum GatewayURL {
    public static func make(port: Int, serverID: String) -> String {
        "http://localhost:\(port)/s/\(serverID)/mcp"
    }
    /// Returns the server id if `url` points at our gateway on `port`.
    public static func serverID(from url: String, port: Int) -> String? {
        guard let u = URL(string: url), let host = u.host, u.port == port,
              host == "localhost" || host == "127.0.0.1" else { return nil }
        let parts = u.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "s", parts[2] == "mcp" else { return nil }
        return String(parts[1])
    }
}
