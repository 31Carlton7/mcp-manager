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
