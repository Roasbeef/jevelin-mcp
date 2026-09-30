#!/usr/bin/env python3
"""Exercise the compiled HTTP MCP service with an independent native peer."""

import http.client
import glob
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
from http.server import ThreadingHTTPServer

from e2e import CREDENTIAL, Fixture

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "independent-mcp-fixture-token"
META = {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {"name": "jev-http-fixture", "version": "1"},
}


def exchange(port, method, params, *, auth=TOKEN, extra=None):
    envelope = {"jsonrpc": "2.0", "id": "http-proof", "method": method,
                "params": dict(params, _meta=META)}
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method}
    if method == "tools/call":
        headers["Mcp-Name"] = params["name"]
    if auth is not None:
        headers["Authorization"] = "Bearer " + auth
    headers.update(extra or {})
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
    try:
        connection.request("POST", "/mcp", json.dumps(envelope, ensure_ascii=False).encode(), headers)
        response = connection.getresponse()
        payload = response.read()
        assert CREDENTIAL.encode() not in payload and TOKEN.encode() not in payload
        content_type = response.getheader("Content-Type", "")
        if "text/event-stream" in content_type:
            messages = []
            for event in payload.decode().split("\n\n"):
                data = "\n".join(line[6:] for line in event.splitlines() if line.startswith("data: "))
                if data:
                    messages.append(json.loads(data))
            assert messages and messages[-1]["id"] == "http-proof", messages
            return response.status, messages[-1]
        return response.status, json.loads(payload) if payload else None
    finally:
        connection.close()


def tool(port, name, arguments, **options):
    return exchange(port, "tools/call", {"name": name, "arguments": arguments}, **options)


def run(fixture):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    environment = dict(os.environ,
        JEV_API_KEY=CREDENTIAL,
        JEV_BASE_URL=f"http://127.0.0.1:{fixture.server_port}",
        JEV_MCP_TRANSPORT="http", JEV_MCP_PORT=str(port), JEV_MCP_AUTH="bearer",
        JEV_MCP_TOKEN=TOKEN, JEV_MCP_ALLOWED_ORIGINS="http://allowed.example",
        JEV_TIMEOUT_MS="2000")
    process = subprocess.Popen([str(ROOT / "bin/jevelin-mcp")], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    try:
        deadline = time.monotonic() + 10
        while True:
            assert process.poll() is None, process.stderr.read().decode()
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                assert time.monotonic() < deadline, "HTTP listener did not start."
                time.sleep(0.02)

        before = len(fixture.requests)
        for bad_token in (None, "wrong-token", CREDENTIAL):
            assert tool(port, "jev_noul", {"state": "unadmitted"}, auth=bad_token)[0] == 401
        assert tool(port, "jev_noul", {"state": "unadmitted"}, extra={"Origin": "http://evil.example"})[0] == 403
        assert tool(port, "jev_noul", {"state": "unadmitted"}, extra={"Mcp-Name": "jev_choice"})[0] == 400
        assert len(fixture.requests) == before

        status, discovered = exchange(port, "server/discover", {})
        assert status == 200 and discovered["result"]["resultType"] == "complete"
        assert "2026-07-28" in discovered["result"]["supportedVersions"]
        status, listed = exchange(port, "tools/list", {})
        assert status == 200
        assert {entry["name"] for entry in listed["result"]["tools"]} == {"jev_choice", "jev_score", "jev_noul", "jev_batch"}
        assert listed["result"]["ttlMs"] == 0
        assert listed["result"]["cacheScope"] == "private"

        calls = [
            ("jev_choice", {"state": "Choose café ☃", "choices": [{"label": "review"}, {"label": "build"}]}),
            ("jev_score", {"state": "Score this", "levels": ["poor", "good"]}),
            ("jev_noul", {"state": "Relevant?"}),
            ("jev_batch", {"state": "Batch", "questions": [
                {"name": "relevance", "type": "noul"},
                {"name": "queue", "type": "choice", "choices": [{"label": "review"}, {"label": "build"}]}]}),
        ]
        for name, arguments in calls:
            status, answer = tool(port, name, arguments, extra={"Origin": "http://allowed.example"})
            assert status == 200 and answer["result"]["resultType"] == "complete", answer
            assert answer["result"].get("isError", False) is False, answer
            assert answer["result"]["structuredContent"]["model"] == "jev-fixture"
            assert fixture.requests[-1][1] == "Bearer " + CREDENTIAL
        assert fixture.requests[before][0]["state"] == "Choose café ☃"

        # The native Gleam client obtains both codecs from the application's
        # shared Choice definition. Its process receives no upstream credential.
        peer_environment = dict(os.environ)
        peer_environment.pop("JEV_API_KEY", None)
        peer_environment.pop("JEV_BASE_URL", None)
        expression = (
            'application:ensure_all_started(jevelin_mcp), '
            f'support@typed_client:call(<<"http://127.0.0.1:{port}/mcp">>), halt().'
        )
        before_peer = len(fixture.requests)
        peer = subprocess.run(
            ["erl", "-noshell", "-pa", *glob.glob(str(ROOT / "build/dev/erlang/*/ebin")),
             "-eval", expression], capture_output=True, timeout=10, env=peer_environment,
        )
        assert peer.returncode == 0 and b"SELECTED:review" in peer.stdout, (peer.stdout, peer.stderr)
        assert len(fixture.requests) == before_peer + 1

        before = len(fixture.requests)
        status, invalid = tool(port, "jev_choice", {"state": "bad", "choices": []})
        assert status == 200 and invalid["result"]["isError"] is True, invalid
        assert len(fixture.requests) == before, "Invalid criteria reached the provider."
        status, unknown = tool(port, "missing", {"state": "bad"})
        assert status == 200 and "error" in unknown, unknown
        assert len(fixture.requests) == before

        fixture.mode = "unknown-choice"
        status, invalid_answer = tool(port, "jev_choice", calls[0][1])
        assert status == 200 and invalid_answer["result"]["isError"] is True, invalid_answer
        assert len(fixture.requests) == before + 1
    finally:
        process.terminate()
        stdout, stderr = process.communicate(timeout=8)
        # HTTP carries protocol frames on its socket. Mist's listener and OTP
        # shutdown diagnostics may use stdout, but neither credential may appear.
        diagnostics = stdout + stderr
        assert CREDENTIAL.encode() not in diagnostics and TOKEN.encode() not in diagnostics


if __name__ == "__main__":
    fixture = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    fixture.mode, fixture.requests = "success", []
    worker = threading.Thread(target=fixture.serve_forever, daemon=True)
    worker.start()
    try:
        run(fixture)
        print("Compiled HTTP MCP + mock Jev: four typed tools, modern discovery, auth, Origin, header admission, and request-bound results passed.")
    finally:
        fixture.shutdown()
        fixture.server_close()
        worker.join(timeout=5)
