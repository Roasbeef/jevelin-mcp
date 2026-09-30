"""Enforce pure evaluation/definition modules and the custom-FFI boundary."""
from pathlib import Path
import re
import sys

PURE = {"jevelin_mcp/evaluation", "jevelin_mcp/tool"}
MCP_PURE = {"json", "corruption", "jsonrpc", "protocol", "stdio", "server",
            "schema", "codec", "tool", "version", "metadata", "discovery",
            "request", "mrtr", "subscription", "http", "http_headers", "sse"}


def pure_import(module: str) -> bool:
    if module.startswith("jevelin_mcp/"):
        return module in PURE
    if module.startswith("gleam_mcp/"):
        return module in {"gleam_mcp/" + name for name in MCP_PURE}
    if module == "jevelin" or module.startswith("jevelin/"):
        return True
    if module.startswith("gleam/"):
        return not (module in {"gleam/io", "gleam/httpc", "gleam/crypto"}
                    or module.startswith(("gleam/erlang", "gleam/otp")))
    return False


def check(root: Path) -> list[str]:
    errors = []
    for path in sorted((root / "src").rglob("*.gleam")):
        relative = path.relative_to(root).as_posix()
        code = "\n".join(line for line in path.read_text().splitlines()
                         if not line.lstrip().startswith("//"))
        external = re.search(r"@external\s*\(", code)
        if external and not (path.parent.name == "internal" and path.name.startswith("ffi_")):
            errors.append(f"{relative}: custom FFI must live in internal/ffi_*.gleam")
        module = path.relative_to(root / "src").with_suffix("").as_posix()
        if module in PURE:
            imports = re.findall(r"^\s*import\s+([a-zA-Z0-9_/]+)", code, re.M)
            if external or any(not pure_import(name) for name in imports):
                errors.append(f"{relative}: pure evaluation module contains an effect dependency")
    return errors


if __name__ == "__main__":
    errors = check(Path(__file__).resolve().parents[1])
    print("\n".join(errors) if errors else "source-check: pure evaluation and FFI boundaries hold")
    sys.exit(bool(errors))
