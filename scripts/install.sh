#!/usr/bin/env bash
# Publish a complete shipment without tying the installed server to this checkout.
set -euo pipefail
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
task_prefix=${PREFIX:-"$HOME/.local"}

task_source="$task_root/build/release/jevelin-mcp"
if [ ! -x "$task_source/bin/jevelin-mcp" ]; then
  echo 'Build the server first with make release.' >&2
  exit 1
fi

mkdir -p -- "$task_prefix/bin" "$task_prefix/lib/jevelin-mcp"
task_prefix=$(CDPATH= cd -- "$task_prefix" && pwd -P)
if [ -d "$task_prefix/bin/jevelin-mcp" ]; then
  echo 'The install destination bin/jevelin-mcp is a directory.' >&2
  exit 1
fi

# Fresh physical paths keep a running VM on its original modules after an update.
task_shipment=$(mktemp -d "$task_prefix/lib/jevelin-mcp/shipment.XXXXXX")
cp -R "$task_source/." "$task_shipment/"
chmod 755 "$task_shipment"

# Rename the complete wrapper only after copying finishes. Single-quote escaping
# keeps the installed wrapper independent of Bash and of its caller's PATH.
task_launcher=$(mktemp "$task_prefix/bin/.jevelin-mcp.XXXXXX")
trap 'rm -f -- "$task_launcher"' EXIT
task_escaped=$(printf '%s' "$task_shipment" | sed "s/'/'\\\\''/g")
{
  printf '#!/bin/sh\nset -eu\n'
  printf "task_shipment='%s'\n" "$task_escaped"
  printf 'exec "$task_shipment/bin/jevelin-mcp" "$@"\n'
} > "$task_launcher"
chmod 755 "$task_launcher"
mv -f -- "$task_launcher" "$task_prefix/bin/jevelin-mcp"
printf 'Installed %s/bin/jevelin-mcp\n' "$task_prefix"
