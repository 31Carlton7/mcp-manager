import Testing
import Foundation
import MCPMCore
@testable import MCPMControl

@Test func requestDecodesByMethod() throws {
    let json = #"{"id":7,"method":"servers.setClient","params":{"id":"notion","client":"cursor","enabled":true}}"#
    let req = try JSONDecoder.mcpm.decode(ControlRequest.self, from: Data(json.utf8))
    #expect(req.id == 7)
    guard case .setClient(let p) = req.command else { Issue.record("wrong command"); return }
    #expect(p.id == "notion"); #expect(p.client == .cursor); #expect(p.enabled)
}

@Test func requestEncodesRoundTrip() throws {
    let req = ControlRequest(id: 1, command: .setAll(.init(id: "a", enabled: false)))
    let data = try JSONEncoder.mcpm.encode(req)
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["method"] as! String == "servers.setAll")
    #expect(try JSONDecoder.mcpm.decode(ControlRequest.self, from: data) == req)
}

@Test func unknownMethodFailsToDecode() {
    #expect(throws: (any Error).self) {
        try JSONDecoder.mcpm.decode(ControlRequest.self, from: Data(#"{"id":1,"method":"nope"}"#.utf8))
    }
}

@Test func responseAndEventEncode() throws {
    let ok = ControlResponse(id: 3, result: .status(DaemonStatus(daemonVersion: "0.1.0", apiVersion: 1, servers: [], clients: [])))
    let s = String(decoding: try JSONEncoder.mcpm.encode(ok), as: UTF8.self)
    #expect(s.contains("\"ok\" : true"))
    let err = ControlResponse(id: 3, error: "boom")
    #expect(String(decoding: try JSONEncoder.mcpm.encode(err), as: UTF8.self).contains("\"error\" : \"boom\""))
    let ev = ControlEvent.status(DaemonStatus(daemonVersion: "0.1.0", apiVersion: 1, servers: [], clients: []))
    #expect(String(decoding: try JSONEncoder.mcpm.encode(ev), as: UTF8.self).contains("\"event\" : \"status\""))
}

@Test func wireEncoderEmitsSingleLine() throws {
    let ev = ControlEvent.status(DaemonStatus(daemonVersion: "0.1.0", apiVersion: 1, servers: [], clients: []))
    let s = String(decoding: try JSONEncoder.mcpmWire.encode(ev), as: UTF8.self)
    #expect(!s.contains("\n"))
}

@Test func inboundDistinguishesResponsesFromEvents() throws {
    let status = DaemonStatus(daemonVersion: "0.1.0", apiVersion: 1, servers: [], clients: [])
    let evData = try JSONEncoder.mcpmWire.encode(ControlEvent.status(status))
    guard case .event(let e) = try ControlInbound.decode(evData) else { Issue.record("expected event"); return }
    #expect(e == .status(status))

    let respData = try JSONEncoder.mcpmWire.encode(ControlResponse(id: 4, result: .ack))
    guard case .response(let r) = try ControlInbound.decode(respData) else { Issue.record("expected response"); return }
    #expect(r.id == 4); #expect(r.ok); #expect(r.result == .ack)
}

@Test func clientAndDaemonStatusCarryWatchedAndLastError() throws {
    let c = ClientStatus(id: .cursor, displayName: "Cursor", installed: true, configPath: "/tmp/x",
                         healthy: false, watched: true, error: "nope", lastSync: nil)
    let status = DaemonStatus(daemonVersion: "0.1.0", apiVersion: controlAPIVersion, servers: [],
                              clients: [c], lastError: "sync failed")
    let round = try JSONDecoder.mcpm.decode(DaemonStatus.self, from: JSONEncoder.mcpmWire.encode(status))
    #expect(round == status)
    #expect(round.clients[0].watched)
    #expect(round.lastError == "sync failed")
}

@Test(arguments: [
    ControlCommand.authStart(.init(id: "notion")),
    .authSignOut(.init(id: "notion")),
    .authForget(.init(id: "notion")),
    .authSetHeader(.init(id: "notion", name: "X-Api-Key", value: "s3cret")),
    .testServer(.init(id: "notion")),
])
func authAndTestCommandsRoundTrip(command: ControlCommand) throws {
    let data = try JSONEncoder.mcpm.encode(ControlRequest(id: 2, command: command))
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["method"] as! String == command.method)
    #expect(try JSONDecoder.mcpm.decode(ControlRequest.self, from: data).command == command)
}

@Test func updateServerParamsCarriesHeadersAndOmitsUntouchedFields() throws {
    let p = UpdateServerParams(id: "notion", headers: ["X-Trace": "on"], auth: .none)
    let data = try JSONEncoder.mcpm.encode(p)
    #expect(try JSONDecoder.mcpm.decode(UpdateServerParams.self, from: data) == p)

    // A patch says nothing about the fields it leaves out, so they must not be on the wire at all.
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["headers"] as! [String: String] == ["X-Trace": "on"])
    #expect(obj["url"] == nil)
    #expect(try JSONDecoder.mcpm.decode(UpdateServerParams.self,
                                        from: Data(#"{"id":"notion"}"#.utf8)).headers == nil)
}

@Test func authAndTestMethodNames() {
    #expect(ControlCommand.authStart(.init(id: "n")).method == "auth.start")
    #expect(ControlCommand.authSignOut(.init(id: "n")).method == "auth.signOut")
    #expect(ControlCommand.authForget(.init(id: "n")).method == "auth.forget")
    #expect(ControlCommand.authSetHeader(.init(id: "n", name: "a", value: "b")).method == "auth.setHeader")
    #expect(ControlCommand.testServer(.init(id: "n")).method == "servers.test")
}

@Test func authorizeURLAndTestResultRoundTrip() throws {
    let url = ControlResult.authorizeURL("https://mcp.notion.com/authorize?client_id=x&state=y")
    #expect(try JSONDecoder.mcpm.decode(ControlResult.self, from: JSONEncoder.mcpmWire.encode(url)) == url)

    let result = ControlResult.testResult(TestResult(ok: true, serverName: "notion", serverVersion: "1.2",
                                                     protocolVersion: "2025-06-18", toolCount: 12,
                                                     durationMs: 340))
    #expect(try JSONDecoder.mcpm.decode(ControlResult.self, from: JSONEncoder.mcpmWire.encode(result)) == result)

    let failed = TestResult(ok: false, error: "needs sign-in", durationMs: 12)
    #expect(try JSONDecoder.mcpm.decode(TestResult.self, from: JSONEncoder.mcpmWire.encode(failed)) == failed)
}

@Test func daemonStatusCarriesGatewayPort() throws {
    let s = ServerStatus(server: Server(id: "notion", name: "Notion", kind: .remote,
                                        url: "https://mcp.notion.com/mcp", auth: .oauth,
                                        source: "manual", createdAt: .init()),
                         state: "needsAuth")
    let status = DaemonStatus(daemonVersion: "0.1.0", apiVersion: controlAPIVersion, servers: [s],
                              clients: [], gatewayPort: 7337)
    let round = try JSONDecoder.mcpm.decode(DaemonStatus.self, from: JSONEncoder.mcpmWire.encode(status))
    #expect(round == status)
    #expect(round.gatewayPort == 7337)
    #expect(round.servers[0].state == "needsAuth")
}

/// An app built before the gateway existed sends statuses without the key; a daemon rolled back
/// to one has to keep decoding them.
@Test func daemonStatusDecodesWithoutGatewayPort() throws {
    let json = #"{"daemonVersion":"0.1.0","apiVersion":1,"servers":[],"clients":[]}"#
    let status = try JSONDecoder.mcpm.decode(DaemonStatus.self, from: Data(json.utf8))
    #expect(status.gatewayPort == nil)
}

@Test func addServerParamsDecodesWithoutHeaders() throws {
    let json = #"{"id":9,"method":"servers.add","params":{"name":"notion","kind":"remote","args":[],"env":{},"url":"https://mcp.notion.com/mcp","auth":"none","clients":{"cursor":true}}}"#
    let req = try JSONDecoder.mcpm.decode(ControlRequest.self, from: Data(json.utf8))
    guard case .addServer(let p) = req.command else { Issue.record("wrong command"); return }
    #expect(p.headers == [:])
    #expect(p.url == "https://mcp.notion.com/mcp")

    let withHeaders = AddServerParams(name: "n", kind: .remote, url: "https://x.dev/mcp", headers: ["X-Key": "v"])
    let round = try JSONDecoder.mcpm.decode(AddServerParams.self, from: JSONEncoder.mcpm.encode(withHeaders))
    #expect(round == withHeaders)
}

// MARK: - Settings

@Test func settingsCommandsRoundTripOverTheWire() throws {
    for command in [ControlCommand.getSettings,
                    .setSettings(.init(gatewayPort: 9001, backupRetention: 3)),
                    .setSettings(.init(backupRetention: 3))] {
        let req = ControlRequest(id: 4, command: command)
        let round = try JSONDecoder.mcpm.decode(ControlRequest.self, from: JSONEncoder.mcpmWire.encode(req))
        #expect(round == req)
    }
    let result = ControlResult.settings(Settings(gatewayPort: 9001, backupRetention: 3))
    #expect(try JSONDecoder.mcpm.decode(ControlResult.self, from: JSONEncoder.mcpmWire.encode(result)) == result)
}

@Test func daemonStatusCarriesThePendingRestartFlag() throws {
    let status = DaemonStatus(daemonVersion: "0.1.0", apiVersion: controlAPIVersion, servers: [], clients: [],
                              gatewayPort: 7337, settingsPendingRestart: true)
    let round = try JSONDecoder.mcpm.decode(DaemonStatus.self, from: JSONEncoder.mcpmWire.encode(status))
    #expect(round == status)
    #expect(round.settingsPendingRestart)
}

/// A daemon from before settings existed sends a status without the key; it means "nothing
/// pending", not "undecodable".
@Test func daemonStatusDecodesWithoutThePendingRestartFlag() throws {
    let json = #"{"daemonVersion":"0.1.0","apiVersion":1,"servers":[],"clients":[],"gatewayPort":7337}"#
    let status = try JSONDecoder.mcpm.decode(DaemonStatus.self, from: Data(json.utf8))
    #expect(status.settingsPendingRestart == false)
    #expect(status.gatewayPort == 7337)
}

@Test func addServerParamsCarriesTheTransport() throws {
    let p = AddServerParams(name: "a", kind: .remote, url: "https://a/mcp", transport: .sse)
    let req = ControlRequest(id: 1, command: .addServer(p))
    let round = try JSONDecoder.mcpm.decode(ControlRequest.self, from: JSONEncoder.mcpmWire.encode(req))
    guard case .addServer(let back) = round.command else { Issue.record("wrong command"); return }
    #expect(back.transport == .sse)
}

/// An older app sends no `transport`; that is HTTP, not a decode failure.
@Test func addServerParamsDecodesWithoutTransport() throws {
    let json = #"{"id":9,"method":"servers.add","params":{"name":"a","kind":"remote","args":[],"env":{},"url":"https://a/mcp","auth":"none","clients":{}}}"#
    let req = try JSONDecoder.mcpm.decode(ControlRequest.self, from: Data(json.utf8))
    guard case .addServer(let p) = req.command else { Issue.record("wrong command"); return }
    #expect(p.transport == nil)
}
