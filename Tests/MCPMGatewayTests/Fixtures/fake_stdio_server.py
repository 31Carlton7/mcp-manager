#!/usr/bin/env python3
"""A line-delimited JSON-RPC server with just enough MCP in it for MCPProbe's handshake.

Reads one JSON object per line on stdin and answers on stdout. Notifications (no "id") are
read and dropped, which is what a real server does and what the probe expects.
"""

import json
import sys

TOOLS = [
    {"name": "search", "description": "Search the fake corpus",
     "inputSchema": {"type": "object", "properties": {"q": {"type": "string"}}}},
    {"name": "fetch", "description": "Fetch a fake page",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}}},
]


def handle(message):
    method = message.get("method")
    if method == "initialize":
        params = message.get("params") or {}
        return {
            # Echoed back, so a test can tell the server saw what the probe sent.
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "fake", "version": "1.0"},
        }
    if method == "tools/list":
        return {"tools": TOOLS}
    return None


def main():
    while True:
        # readline() rather than `for line in sys.stdin`, which reads ahead in blocks and would
        # sit on the request until the pipe filled.
        line = sys.stdin.readline()
        if not line:
            return
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if "id" not in message:
            continue

        result = handle(message)
        if result is None:
            answer = {"jsonrpc": "2.0", "id": message["id"],
                      "error": {"code": -32601, "message": "no such method"}}
        else:
            answer = {"jsonrpc": "2.0", "id": message["id"], "result": result}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()


main()
