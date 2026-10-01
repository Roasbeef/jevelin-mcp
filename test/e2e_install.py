#!/usr/bin/env python3
"""Exercise the installed shipment from another directory, including a reinstall."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

from e2e import FrameReader


ROOT = Path(__file__).resolve().parents[1]
TOOLS = {"jev_choice", "jev_score", "jev_noul", "jev_batch"}


def install(prefix):
    # The parent e2e target compiled the shipment. Exercise the public install
    # recipe without repeating that build, including Make's prefix handling.
    subprocess.run(
        ["make", "--no-print-directory", "-o", "release", "install", "PREFIX=" + str(prefix)],
        cwd=ROOT, check=True, timeout=30,
    )


def start(prefix, directory):
    environment = {
        name: value for name, value in os.environ.items()
        if not name.startswith("JEV_")
    }
    environment.update({
        "PATH": str(prefix / "bin") + os.pathsep + environment["PATH"],
        "JEV_API_KEY": "install-fixture-not-a-live-key",
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


def run():
    with tempfile.TemporaryDirectory(prefix="jevelin-install-") as directory:
        unrelated = Path(directory)
        prefix = unrelated / "prefix with 'quotes' $dollar `ticks`"
        install(prefix)
        original = (prefix / "bin/jevelin-mcp").read_text()
        process = start(prefix, unrelated)
        reader = FrameReader(process.stdout)
        try:
            initialize(process, reader)
            tools = call(process, reader, 2, "tools/list", {})["tools"]
            assert {tool["name"] for tool in tools} == TOOLS, tools

            # Reinstallation publishes another copy without changing the live VM.
            install(prefix)
            assert (prefix / "bin/jevelin-mcp").read_text() != original
            assert len(list((prefix / "lib/jevelin-mcp").iterdir())) == 2
            tools = call(process, reader, 3, "tools/list", {})["tools"]
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
        process = start(prefix, unrelated)
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

    print("Installed MCP: PATH discovery, quoted prefix, arbitrary cwd, and reinstall passed.")


if __name__ == "__main__":
    run()
