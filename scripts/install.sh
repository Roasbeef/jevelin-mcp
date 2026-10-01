#!/usr/bin/env bash
# Publish a complete shipment without tying the installed server to this checkout.
set -euo pipefail
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
task_prefix=${PREFIX:-"$HOME/.local"}

if [ ! -x "$task_root/build/erlang-shipment/entrypoint.sh" ]; then
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
cp -R "$task_root/build/erlang-shipment/." "$task_shipment/"
chmod 755 "$task_shipment"

# Rename the complete wrapper only after copying finishes. Bash quoting keeps
# spaces and shell metacharacters in an operator's prefix literal at startup.
task_launcher=$(mktemp "$task_prefix/bin/.jevelin-mcp.XXXXXX")
trap 'rm -f -- "$task_launcher"' EXIT
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'task_shipment=%q\n' "$task_shipment"
  printf 'exec "$task_shipment/entrypoint.sh" run "$@"\n'
} > "$task_launcher"
chmod 755 "$task_launcher"
mv -f -- "$task_launcher" "$task_prefix/bin/jevelin-mcp"
printf 'Installed %s/bin/jevelin-mcp\n' "$task_prefix"
