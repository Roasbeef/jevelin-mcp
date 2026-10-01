#!/usr/bin/env bash
# Assemble the same bundled-ERTS release shape as Loom, with no runtime on PATH.
set -euo pipefail
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$task_root"
gleam export erlang-shipment
task_version=$(sed -n 's/^version *= *"\([^"]*\)"/\1/p' gleam.toml)
task_erts=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(version)]), halt().')
task_work=$(mktemp -d "$task_root/build/release-work.XXXXXX")
trap 'rm -rf -- "$task_work"' EXIT
mkdir "$task_work/libs"
cp -R build/erlang-shipment/. "$task_work/libs/"

# Relx computes the OTP application closure, including crypto, ssl and inets.
# Startup remains the compiled Gleam main, without relx's distributed launcher.
cat > "$task_work/rebar.config" <<EOF
{erl_opts, []}.
{deps, []}.
{project_app_dirs, []}.
{relx, [
  {release, {jevelin_mcp, "$task_version"}, [jevelin_mcp]},
  {lib_dirs, ["libs"]},
  {include_erts, true},
  {include_src, false},
  {dev_mode, false},
  {debug_info, strip}
]}.
EOF
(cd "$task_work" && rebar3 release)
task_release="$task_root/build/release/jevelin-mcp"
mkdir -p "$task_root/build/release"
rm -rf -- "$task_release"
mv "$task_work/_build/default/rel/jevelin_mcp" "$task_release"
test -f "$task_release/bin/no_dot_erlang.boot"

# Homebrew's crypto NIF links to a Homebrew dylib. Copy it into the release and
# relocate that reference so moving the runtime does not retain the build host.
if [ "$(uname -s)" = Darwin ]; then
  for task_crypto in "$task_release"/lib/crypto-*/priv/lib/crypto.so; do
    task_library=$(otool -L "$task_crypto" | awk '$1 ~ /libcrypto[.].*[.]dylib$/ {print $1}')
    case "$task_library" in
      ''|/usr/lib/*|/System/*) ;;
      /*)
        task_name=${task_library##*/}
        mkdir -p "$task_release/lib/native"
        cp "$task_library" "$task_release/lib/native/$task_name"
        chmod u+w "$task_crypto" "$task_release/lib/native/$task_name"
        install_name_tool -id "@loader_path/$task_name" "$task_release/lib/native/$task_name"
        install_name_tool -change "$task_library" "@loader_path/../../../native/$task_name" "$task_crypto"
        codesign --force --sign - "$task_release/lib/native/$task_name" "$task_crypto"
        ;;
      *) echo 'Cannot relocate the crypto library reference.' >&2; exit 1 ;;
    esac
  done
fi

# Erlexec receives this release's paths explicitly. It cannot select a parent's
# bundled runtime, stale boot tree, or injected emulator flags from environment.
cat > "$task_release/bin/jevelin-mcp" <<EOF
#!/bin/sh
set -eu
ROOTDIR=\$(CDPATH= cd -- "\${0%/*}/.." && pwd -P)
BINDIR="\$ROOTDIR/erts-$task_erts/bin"
EMU=beam
PROGNAME=jevelin-mcp
export ROOTDIR BINDIR EMU PROGNAME
unset ERL_ROOTDIR ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ERL_LIBS
exec "\$BINDIR/erlexec" \\
  -boot "\$ROOTDIR/bin/no_dot_erlang" \\
  -pa "\$ROOTDIR"/lib/*/ebin \\
  -noshell -eval 'jevelin_mcp@@main:run(jevelin_mcp)' -extra "\$@"
EOF
chmod 755 "$task_release/bin/jevelin-mcp"
printf 'Self-contained release: %s\n' "$task_release"
