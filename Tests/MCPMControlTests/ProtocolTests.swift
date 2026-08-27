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
    let command = ControlCommand.setAll(.init(id: "a", enabled: false))
    #expect(command.method == "servers.setAll")
    #expect(try roundTrip(command).command == command)
}

@Test func unknownMethodFailsToDecode() {
    #expect(throws: (any Error).self) {
        try JSONDecoder.mcpm.decode(ControlRequest.self, from: Data(#"{"id":1,"method":"nope"}"#.utf8))
    }
}

@Test func responseAndEventEncode() throws {
    let ok = ControlResponse(id: 3, result: .status(aStatus()))
    let s = String(decoding: try JSONEncoder.mcpm.encode(ok), as: UTF8.self)
    #expect(s.contains("\"ok\" : true"))
    let err = ControlResponse(id: 3, error: "boom")
    #expect(String(decoding: try JSONEncoder.mcpm.encode(err), as: UTF8.self).contains("\"error\" : \"boom\""))
    let ev = ControlEvent.status(aStatus())
    #expect(String(decoding: try JSONEncoder.mcpm.encode(ev), as: UTF8.self).contains("\"event\" : \"status\""))
}

@Test func wireEncoderEmitsSingleLine() throws {
    let s = String(decoding: try JSONEncoder.mcpmWire.encode(ControlEvent.status(aStatus())), as: UTF8.self)
    #expect(!s.contains("\n"))
}

@Test func inboundDistinguishesResponsesFromEvents() throws {
    let status = aStatus()
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
    let status = aStatus(clients: [c], lastError: "sync failed")
    let round = try roundTrip(status)
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
    #expect(try roundTrip(command, id: 2).command == command)
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
    #expect(try roundTrip(url) == url)

    let result = ControlResult.testResult(TestResult(ok: true, serverName: "notion", serverVersion: "1.2",
                                                     protocolVersion: "2025-06-18", toolCount: 12,
                                                     durationMs: 340))
    #expect(try roundTrip(result) == result)

    let failed = TestResult(ok: false, error: "needs sign-in", durationMs: 12)
    #expect(try roundTrip(failed) == failed)
}

@Test func daemonStatusCarriesGatewayPort() throws {
    let s = ServerStatus(server: Server(id: "notion", name: "Notion", kind: .remote,
                                        url: "https://mcp.notion.com/mcp", auth: .oauth,
                                        source: "manual", createdAt: .init()),
                         state: "needsAuth")
    let status = aStatus(servers: [s], gatewayPort: 7337)
    let round = try roundTrip(status)
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
    #expect(try roundTrip(withHeaders) == withHeaders)
}

// MARK: - Settings

@Test func settingsCommandsRoundTripOverTheWire() throws {
    for command in [ControlCommand.getSettings,
                    .setSettings(.init(gatewayPort: 9001, backupRetention: 3)),
                    .setSettings(.init(backupRetention: 3))] {
        #expect(try roundTrip(command, id: 4).command == command)
    }
    let result = ControlResult.settings(Settings(gatewayPort: 9001, backupRetention: 3))
    #expect(try roundTrip(result) == result)
}

@Test func daemonStatusCarriesThePendingRestartFlag() throws {
    let status = aStatus(gatewayPort: 7337, settingsPendingRestart: true)
    let round = try roundTrip(status)
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
    guard case .addServer(let back) = try roundTrip(.addServer(p)).command else {
        Issue.record("wrong command"); return
    }
    #expect(back.transport == .sse)
}

/// An older app sends no `transport`; that is HTTP, not a decode failure.
@Test func addServerParamsDecodesWithoutTransport() throws {
    let json = #"{"id":9,"method":"servers.add","params":{"name":"a","kind":"remote","args":[],"env":{},"url":"https://a/mcp","auth":"none","clients":{}}}"#
    let req = try JSONDecoder.mcpm.decode(ControlRequest.self, from: Data(json.utf8))
    guard case .addServer(let p) = req.command else { Issue.record("wrong command"); return }
    #expect(p.transport == nil)
}

@Test(arguments: [ControlCommand.syncPreview, .confirmImport])
func onboardingCommandsRoundTrip(command: ControlCommand) throws {
    #expect(try roundTrip(command, id: 9).command == command)
}

@Test func syncPreviewRoundTrips() throws {
    let preview = SyncPreview(
        adopted: [ServerSummary(id: "notion", name: "Notion", kind: .remote, clients: [.cursor, .codex])],
        writes: [ClientWrite(client: .cursor, adds: ["linear"], removes: [], changes: ["notion"])])
    let result = ControlResult.syncPreview(preview)
    #expect(try roundTrip(result) == result)
}

/// A daemon that predates onboarding sends no such key, and gating a working install behind a
/// setup sheet because of a missing field would be the worse of the two readings.
@Test func aStatusWithoutImportConfirmedReadsAsConfirmed() throws {
    let json = #"{"daemonVersion":"0.1.0","apiVersion":1,"servers":[],"clients":[]}"#
    let status = try JSONDecoder.mcpm.decode(DaemonStatus.self, from: Data(json.utf8))
    #expect(status.importConfirmed)
    #expect(status.settingsPendingRestart == false)
}

@Test func aStatusCarriesAnUnconfirmedImportAcrossTheWire() throws {
    let status = aStatus(importConfirmed: false)
    let round = try roundTrip(status)
    #expect(round == status)
    #expect(round.importConfirmed == false)
}

@Test(arguments: [
    ControlCommand.catalogSearch(.init(query: "posthog", limit: 10)),
    .catalogSearch(.init(query: "")),
    .inspectURL(.init(url: "https://mcp.posthog.com/mcp")),
])
func catalogAndInspectCommandsRoundTrip(command: ControlCommand) throws {
    #expect(try roundTrip(command, id: 9).command == command)
}

/// An app built before the check existed sends no `autoDetectAuth`, and gets it anyway.
@Test func addServerParamsDefaultsAutoDetectOnForOlderApps() throws {
    let json = #"{"name":"PostHog","kind":"remote","args":[],"env":{},"headers":{},"#
        + #""url":"https://mcp.posthog.com/mcp","auth":"none","clients":{}}"#
    let p = try JSONDecoder.mcpm.decode(AddServerParams.self, from: Data(json.utf8))
    #expect(p.autoDetectAuth)
    #expect(try roundTrip(p) == p)
}

@Test func catalogEntriesAndInspectionsSurviveTheWire() throws {
    let entry = CatalogEntry(slug: "posthog", name: "PostHog", description: "Analytics",
                             kind: .remote, url: "https://mcp.posthog.com/mcp", transport: .http,
                             auth: .oauth, homepage: "https://posthog.com", iconDomain: "posthog.com",
                             source: .bundled, official: true, verified: true)
    let result = ControlResult.catalog([entry])
    #expect(try roundTrip(result) == result)

    let inspection = ControlResult.inspection(
        URLInspection(verdict: "notMCP", suggestion: "https://mcp.posthog.com/mcp",
                      detail: "not an MCP endpoint"))
    #expect(try roundTrip(inspection) == inspection)
}

/// A verdict this app has never heard of must not break the decode — it reads as "not one I know".
@Test func anUnknownVerdictStillDecodes() throws {
    let json = #"{"verdict":"quantum","authRequired":false,"authKind":"none","detail":"?"}"#
    let inspection = try JSONDecoder.mcpm.decode(URLInspection.self, from: Data(json.utf8))
    #expect(inspection.parsedVerdict == nil)
    #expect(inspection.verdict == "quantum")
}
