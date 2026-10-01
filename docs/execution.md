# Execution

Run `make check` from the repository root. It includes a warning-free build,
formatting, application tests, copied linter tests, house rules, source
boundaries and documentation mirrors. `make fmt` formats both packages.
Capture a command's own exit status before reading its log; the exit status
of a later log reader says nothing about the gate.

`make e2e` compiles the shipment, then runs the launcher against a local
mock HTTP provider. Both stdio and HTTP peers exercise all four tools. A
separate BEAM client consumes the shared Choice definition and its original
request decoder through the native HTTP transport, without an upstream key.
These fixtures exercise protocol and HTTP behavior without a live Jev
credential. Provider calls make one attempt under the configured budget.

The installation peer copies that shipment into an isolated prefix, invokes
`jevelin-mcp` through `PATH` from an unrelated directory, and checks discovery
before and after reinstalling while the first process is running. A new process
then starts through the replacement launcher. It uses a dummy credential and
never calls the provider. `make install` runs the release build before publishing
the shipment under `PREFIX` (`~/.local` by default); `make release` only builds.

Use separate checkouts for independent builds. Give parallel workers explicit
file ownership and preserve one another's edits. Review source plus tests,
verify each reported failure against reachable callers, and run the relevant
gate on the resulting tree before committing. Commit dependency manifests
separately from source and refresh the handoff after each body of work.

Native protocol tests read through a complete newline under one absolute
deadline. Readability alone does not establish that a frame is complete.
Compile before connecting an MCP client, because build output cannot enter
protocol stdout. Keep diagnostics on stderr.
