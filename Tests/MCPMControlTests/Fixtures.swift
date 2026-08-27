import Testing
import Foundation
import MCPMCore
@testable import MCPMControl

/// The status every wire test needs and none of them is about.
func aStatus(version: String = "0.1.0", servers: [ServerStatus] = [], clients: [ClientStatus] = [],
             lastError: String? = nil, gatewayPort: Int? = nil,
             settingsPendingRestart: Bool = false, importConfirmed: Bool = true) -> DaemonStatus {
    DaemonStatus(daemonVersion: version, apiVersion: controlAPIVersion, servers: servers,
                 clients: clients, lastError: lastError, gatewayPort: gatewayPort,
                 settingsPendingRestart: settingsPendingRestart, importConfirmed: importConfirmed)
}

/// A value through the encoder the daemon actually writes with and back again.
func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder.mcpm.decode(T.self, from: JSONEncoder.mcpmWire.encode(value))
}

/// A command out on the wire and back. The method string it encodes to is checked here: that
/// string, not the case name, is what an older peer decodes by.
@discardableResult
func roundTrip(_ command: ControlCommand, id: Int = 1) throws -> ControlRequest {
    let data = try JSONEncoder.mcpmWire.encode(ControlRequest(id: id, command: command))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["method"] as? String == command.method)
    return try JSONDecoder.mcpm.decode(ControlRequest.self, from: data)
}
