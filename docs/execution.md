# Execution

Run `make check` from the repository root. It includes a warning-free build,
formatting, application tests, copied linter tests, house rules, source
boundaries and documentation mirrors. `make fmt` formats both packages.
Capture a command's own exit status before reading its log; the exit status
of a later log reader says nothing about the gate.

`make e2e` builds the bundled OTP release, then runs the launcher against a local
mock HTTP provider. Both stdio and HTTP peers exercise all four tools. A
separate BEAM client consumes the shared Choice definition and its original
request decoder through the native HTTP transport, without an upstream key.
These fixtures exercise protocol and HTTP behavior without a live Jev
credential. Provider calls make one attempt under the configured budget.

The installation peer copies that release into an isolated prefix, invokes
`jevelin-mcp` through `PATH` from an unrelated directory, and checks discovery
before and after reinstalling while the first process is running. A new process
then starts through the replacement launcher. Both processes inherit PATH and
Erlang boot variables pointing at an incomplete Loom runtime, with no host
Erlang or Bash on PATH. A tool call reaches the independent local mock provider
using a dummy credential. `make install` runs the release build before publishing
under `PREFIX` (`~/.local` by default); `make release` only builds. Build-time
rebar3 computes the application closure and includes ERTS. The runtime launcher
uses absolute paths for erlexec and the boot file, and excludes inherited Erlang
flag variables so they cannot override those paths.

Use separate checkouts for independent builds. Give parallel workers explicit
file ownership and preserve one another's edits. Review source plus tests,
verify each reported failure against reachable callers, and run the relevant
gate on the resulting tree before committing. Commit dependency manifests
separately from source and refresh the handoff after each body of work.

Native protocol tests read through a complete newline under one absolute
deadline. Readability alone does not establish that a frame is complete.
Compile before connecting an MCP client, because build output cannot enter
protocol stdout. Keep diagnostics on stderr.
