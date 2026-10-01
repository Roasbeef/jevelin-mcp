#!/usr/bin/env python3
"""Exercise the installed shipment from another directory, including a reinstall."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import ThreadingHTTPServer

from e2e import CREDENTIAL, Fixture, FrameReader


ROOT = Path(__file__).resolve().parents[1]
TOOLS = {"jev_choice", "jev_score", "jev_noul", "jev_batch"}


def install(prefix):
    # The parent e2e target compiled the shipment. Exercise the public install
    # recipe without repeating that build, including Make's prefix handling.
    subprocess.run(
        ["make", "--no-print-directory", "-o", "release", "install", "PREFIX=" + str(prefix)],
        cwd=ROOT, check=True, timeout=30,
    )


def start(prefix, directory, fixture, incomplete_runtime):
    environment = {
        name: value for name, value in os.environ.items()
        if not name.startswith("JEV_")
    }
    environment.update({
        "PATH": str(prefix / "bin") + os.pathsep + str(incomplete_runtime / "erts-0/bin"),
        "JEV_API_KEY": CREDENTIAL,
        "JEV_BASE_URL": f"http://127.0.0.1:{fixture.server_port}",
        "ROOTDIR": str(incomplete_runtime),
        "ERL_ROOTDIR": str(incomplete_runtime),
        "BINDIR": str(incomplete_runtime / "erts-0/bin"),
        "EMU": "missing-loom-emulator",
        "PROGNAME": "loomd",
        "ERL_FLAGS": "-boot missing-loom-boot",
        "ERL_AFLAGS": "-boot missing-loom-boot",
        "ERL_ZFLAGS": "-boot missing-loom-boot",
        "ERL_LIBS": str(incomplete_runtime / "lib"),
    })
    return subprocess.Popen(
        ["jevelin-mcp"], cwd=directory, env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )


def call(process, reader, identifier, method, parameters):
    request = {
        "jsonrpc": "2.0", "id": identifier,
        "method": method, "params": parameters,
    }
    process.stdin.write(json.dumps(request).encode() + b"\n")
    process.stdin.flush()
    response = json.loads(reader.read(8))
    assert response["id"] == identifier, response
    return response["result"]


def initialize(process, reader):
    result = call(process, reader, 1, "initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "install-fixture", "version": "1"},
    })
    assert result["serverInfo"]["name"] == "jevelin-mcp", result
    process.stdin.write(
        b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
    )
    process.stdin.flush()


def run(fixture):
    with tempfile.TemporaryDirectory(prefix="jevelin-install-") as directory:
        unrelated = Path(directory)
        prefix = unrelated / "prefix with 'quotes' $dollar `ticks`"
        incomplete_runtime = unrelated / "loom/server.incomplete"
        incomplete_bin = incomplete_runtime / "erts-0/bin"
        incomplete_bin.mkdir(parents=True)
        (incomplete_bin / "erl").write_text(
            "#!/bin/sh\necho 'The incomplete Loom runtime was used.' >&2\nexit 69\n"
        )
        (incomplete_bin / "erl").chmod(0o755)
        install(prefix)
        original = (prefix / "bin/jevelin-mcp").read_text()
        process = start(prefix, unrelated, fixture, incomplete_runtime)
        reader = FrameReader(process.stdout)
        try:
            initialize(process, reader)
            tools = call(process, reader, 2, "tools/list", {})["tools"]
            assert {tool["name"] for tool in tools} == TOOLS, tools
            result = call(process, reader, 3, "tools/call", {
                "name": "jev_choice", "arguments": {
                    "state": "Installed runtime fixture.",
                    "choices": [{"label": "review"}, {"label": "build"}],
                },
            })
            assert not result.get("isError", False), result
            assert result["structuredContent"]["answer"]["choice"] == "review", result
            assert len(fixture.requests) == 1, fixture.requests
            assert fixture.requests[0][1] == "Bearer " + CREDENTIAL

            # Reinstallation publishes another copy without changing the live VM.
            install(prefix)
            assert (prefix / "bin/jevelin-mcp").read_text() != original
            assert len(list((prefix / "lib/jevelin-mcp").iterdir())) == 2
            tools = call(process, reader, 4, "tools/list", {})["tools"]
            assert {tool["name"] for tool in tools} == TOOLS, tools
            process.stdin.close()
            process.stdin = None
            output, errors = process.communicate(timeout=8)
            assert process.returncode == 0, errors
            assert not output and not reader.pending and not errors, (output, errors)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=8)

        # A new invocation also boots from the newly published shipment.
        process = start(prefix, unrelated, fixture, incomplete_runtime)
        reader = FrameReader(process.stdout)
        try:
            initialize(process, reader)
            tools = call(process, reader, 2, "tools/list", {})["tools"]
            assert {tool["name"] for tool in tools} == TOOLS, tools
            process.stdin.close()
            process.stdin = None
            output, errors = process.communicate(timeout=8)
            assert process.returncode == 0 and not errors, errors
            assert not output and not reader.pending, output
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=8)

    print("Installed MCP: bundled runtime, hostile Loom environment, fixture call, arbitrary cwd, and reinstall passed.")


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
