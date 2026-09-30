#!/usr/bin/env python3
"""Exercise the compiled stdio server against a local HTTP service without a live key."""

import json
import os
from pathlib import Path
import select
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
CREDENTIAL = "fixture-credential-not-a-live-key"


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        assert self.path == "/v1/systemone", self.path
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append((request, self.headers.get("Authorization")))
        mode = self.server.mode
        if mode == "delay":
            time.sleep(self.server.delay)
        elif mode == "deadline":
            # Admission is visible before the fixture withholds the response.
            self.server.request_admitted.set()
            self.server.response_release.wait()
        status = 200
        if mode == "http-error":
            status, body = 429, CREDENTIAL.encode()
        elif mode == "malformed":
            body = b"not JSON"
        elif mode == "oversized":
            body = b"x" * (4_194_304 + 1)
        elif mode == "invalid-utf8":
            body = b"\xff\xfe"
        elif mode == "redirect":
            status, body = 302, b""
        else:
            answers = {}
            for name, question in request["questions"].items():
                kind = question["type"]
                if kind == "choice":
                    labels = list(question["criteria"])
                    selected = "unknown" if mode == "unknown-choice" else labels[0]
                    answers[name] = {
                        "type": kind, "choice": selected, "confidence": 0.9,
                        "probabilities": {label: float(index == 0) for index, label in enumerate(labels)},
                    }
                elif kind == "score":
                    levels = question["criteria"]
                    answers[name] = {
                        "type": kind, "score": 0.25, "confidence": 0.5,
                        "legend": {str(index): level for index, level in enumerate(levels)},
                        "probabilities": {str(index): [0.75, 0.25][index] if index < 2 else 0.0 for index in range(len(levels))},
                    }
                else:
                    answers[name] = {"type": kind, "noul": 0.8}
            if mode == "wrong-names":
                answers = {"unexpected": {"type": "noul", "noul": 0.8}}
            body = json.dumps({
                "model": CREDENTIAL if mode == "credential-echo" else "jev-fixture",
                "answers": answers, "usage": {"input_tokens": 10, "output_tokens": 3},
            }).encode()
            if mode == "escaped-credential-echo":
                escaped = "".join(f"\\u{ord(character):04x}" for character in CREDENTIAL)
                body = body.replace(b"jev-fixture", escaped.encode())
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if status == 302:
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/redirect-target")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # The HTTP deadline may close a delayed fixture response first.
            pass


class FrameReader:
    """Read a complete frame under one deadline and retain pipelined bytes."""

    def __init__(self, stream):
        self.stream = stream
        self.pending = b""

    def read(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("The server did not finish a protocol frame before the deadline.")
            ready, _, _ = select.select([self.stream], [], [], remaining)
            if not ready:
                raise TimeoutError("The server did not finish a protocol frame before the deadline.")
            chunk = os.read(self.stream.fileno(), 65536)
            if not chunk:
                raise EOFError("The server closed stdout before completing a frame.")
            self.pending += chunk
        line, self.pending = self.pending.split(b"\n", 1)
        return line


class Client:
    def __init__(self, fixture, timeout_ms=1000):
        environment = os.environ.copy()
        environment.update({
            "JEV_API_KEY": CREDENTIAL,
            "JEV_BASE_URL": f"http://127.0.0.1:{fixture.server_port}",
            "JEV_MODEL": "jev-default-fixture",
            "JEV_TIMEOUT_MS": str(timeout_ms),
        })
        self.process = subprocess.Popen(
            [str(ROOT / "bin/jevelin-mcp")], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        )
        self.reader = FrameReader(self.process.stdout)
        self.frames = []
        self.next_id = 1
        response = self.call("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "fixture", "version": "1"},
        })
        assert response["result"]["serverInfo"]["name"] == "jevelin-mcp"
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, value):
        self.process.stdin.write(json.dumps(value, ensure_ascii=False).encode() + b"\n")
        self.process.stdin.flush()

    def read(self):
        line = self.reader.read(8)
        assert CREDENTIAL.encode() not in line, "A credential reached protocol output."
        value = json.loads(line)
        assert value["jsonrpc"] == "2.0"
        self.frames.append(value)
        return value

    def call(self, method, parameters):
        identifier = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": parameters})
        response = self.read()
        assert response["id"] == identifier
        return response

    def tool(self, name, arguments):
        return self.call("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        self.process.stdin.close()
        self.process.stdin = None
        output, errors = self.process.communicate(timeout=8)
        assert self.process.returncode == 0
        assert CREDENTIAL.encode() not in output + errors
        assert not errors, "The compiled MCP server emitted a stderr diagnostic."
        assert not output and not self.reader.pending, "Unexpected protocol frames remained at shutdown."


def success(response):
    result = response["result"]
    assert not result.get("isError", False), result
    output = result["structuredContent"]
    assert json.loads(result["content"][0]["text"]) == output
    return output


def failed(response):
    assert response["result"]["isError"] is True
    assert "structuredContent" not in response["result"]


def run(fixture):
    client = Client(fixture)
    try:
        tools = client.call("tools/list", {})["result"]["tools"]
        names = {tool["name"] for tool in tools}
        assert names == {"jev_choice", "jev_score", "jev_noul", "jev_batch"}
        for tool in tools:
            assert tool["inputSchema"]["type"] == "object"
            assert tool["inputSchema"]["additionalProperties"] is False
            assert tool["outputSchema"]["type"] == "object"
            assert "api_key" not in json.dumps(tool)
            assert "endpoint" not in json.dumps(tool)

        choices = [{"label": "review", "description": "Existing code"}, {"label": "build"}]
        state = {"messages": ["help", None], "attempt": 1}
        choice = success(client.tool("jev_choice", {"state": state, "choices": choices}))
        assert choice["answer"]["choice"] == "review"
        assert choice["answer"]["probabilities"] == {"review": 1.0, "build": 0.0}
        score = success(client.tool("jev_score", {
            "state": "relevance", "levels": ["low", {"label": "high"}], "model": "jev-explicit-fixture",
        }))
        assert score["answer"]["score"] == 0.25
        assert score["answer"]["legend"]["1"] == {"label": "high"}
        noul = success(client.tool("jev_noul", {"state": ["hello"], "yes": {"evidence": True}}))
        assert noul["answer"] == {"type": "noul", "noul": 0.8}
        mixed = success(client.tool("jev_batch", {"state": state, "questions": [
            {"name": "route", "type": "choice", "choices": choices},
            {"name": "score", "type": "score", "levels": ["low", "high"]},
            {"name": "urgent", "type": "noul", "instructions": {"question": "Urgent?"}},
        ]}))
        assert set(mixed["answers"]) == {"route", "score", "urgent"}
        assert mixed["usage"] == {"input_tokens": 10, "output_tokens": 3}
        assert fixture.requests[0][0]["state"] == state
        assert fixture.requests[0][0]["model"] == "jev-default-fixture"
        assert fixture.requests[1][0]["model"] == "jev-explicit-fixture"
        assert all(header == "Bearer " + CREDENTIAL for _, header in fixture.requests)
        assert all("authorization" not in json.dumps(body).lower() for body, _ in fixture.requests)

        # Raw UTF-8 crosses native stdin, Jevelin HTTP and structured MCP output.
        unicode_state = "Привет 👋 你好"
        unicode_label = "审阅 🧵"
        unicode_choice = success(client.tool("jev_choice", {
            "state": unicode_state, "choices": [{"label": unicode_label}],
        }))
        assert unicode_choice["answer"]["choice"] == unicode_label
        assert fixture.requests[-1][0]["state"] == unicode_state

        count = len(fixture.requests)
        for name, arguments in [
            ("jev_choice", {"state": "x", "choices": [choices[0], choices[0]]}),
            ("jev_score", {"state": "x", "levels": ["single"]}),
            ("jev_noul", {"state": None}),
            ("jev_noul", {"state": "x", "endpoint": "https://bad.example"}),
            ("jev_batch", {"state": "x", "questions": [{"name": "same", "type": "noul"}] * 2}),
        ]:
            assert client.tool(name, arguments)["error"]["code"] == -32602
        assert len(fixture.requests) == count, "Invalid inputs reached HTTP."

        for mode in ["http-error", "malformed", "wrong-names", "oversized", "invalid-utf8", "credential-echo", "escaped-credential-echo", "redirect"]:
            fixture.mode = mode
            count = len(fixture.requests)
            failed(client.tool("jev_noul", {"state": "fixture"}))
            assert len(fixture.requests) == count + 1, "An evaluation retried or followed a redirect."
        fixture.mode = "unknown-choice"
        failed(client.tool("jev_choice", {"state": "fixture", "choices": choices}))
    finally:
        client.close()

    # The deadline must expire after HTTP admission, with no fixture response.
    # A generous admission budget avoids relying on a thread starting in 30 ms.
    fixture.mode = "deadline"
    fixture.request_admitted = threading.Event()
    fixture.response_release = threading.Event()
    client = Client(fixture, timeout_ms=2000)
    count = len(fixture.requests)
    try:
        client.send({"jsonrpc": "2.0", "id": "deadline", "method": "tools/call", "params": {
            "name": "jev_noul", "arguments": {"state": "deadline"},
        }})
        assert fixture.request_admitted.wait(8), "The deadline request did not reach the HTTP fixture."
        response = client.read()
        assert response["id"] == "deadline"
        failed(response)
        assert not fixture.response_release.is_set(), "The fixture released a response before the deadline failure."
    finally:
        fixture.response_release.set()
        client.close()
    assert len(fixture.requests) == count + 1, "The timed-out evaluation retried."

    # EOF ends admission but drains the admitted request within its HTTP deadline.
    fixture.mode, fixture.delay = "delay", 0.15
    client = Client(fixture)
    client.send({"jsonrpc": "2.0", "id": "last", "method": "tools/call", "params": {
        "name": "jev_noul", "arguments": {"state": "last request"},
    }})
    client.process.stdin.close()
    client.process.stdin = None
    response = client.read()
    assert response["id"] == "last"
    assert success(response)["answer"]["noul"] == 0.8
    output, errors = client.process.communicate(timeout=8)
    assert client.process.returncode == 0 and not output and not errors and not client.reader.pending
    print("Compiled stdio MCP + mock HTTP: four tools, validation, failures, credential confinement, timeout, and EOF passed.")


if __name__ == "__main__":
    fixture = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    fixture.daemon_threads = True
    fixture.requests, fixture.mode, fixture.delay = [], "success", 0
    thread = threading.Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    try:
        run(fixture)
    finally:
        fixture.shutdown()
        fixture.server_close()
        thread.join(timeout=2)
