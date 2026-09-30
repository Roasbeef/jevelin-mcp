# Jevelin MCP

Read `docs/next.md` before planning work and `docs/gleam-style.md` before
writing code. This repository inherits Loom's literate Gleam style, total
decoders, caller-owned effects, and house-rule linter.

## Working here

Use Gleam >= 1.18 and Erlang/OTP >= 29. `make check` runs formatting, a
warning-free build, tests, the copied custom linter, and documentation checks.
`make fmt` formats the application and linter. Verify commands by their own
exit status. Public functions include examples; module documentation explains
ownership, transitions and failure behavior. Comments are complete sentences
with a blank line above them. Chain fallible steps with `use` and `result.try`.
Use opaque smart constructors for invariants, and domain variants for flags.

The application is an Erlang runtime package. Loom-specific rules in the
copied style guide about its broker, capabilities and frozen interfaces do
not create dependencies here. The pure wire modules remain free of effects;
`scripts/check_source.py` enforces their boundary. Custom Erlang FFI stays in
`internal/ffi_*.gleam` with the reason no maintained Gleam library suffices.
Process ownership and deadline machinery use weft when needed.

The copied linter retains Loom's R0 through R11 rules and promotion levels.
R0, R2, R4 and R10 apply to root source. R6 recognizes Loom's
`packages/core`, `packages/machine` and `packages/prompt` layout; the explicit
source gate owns pure-module enforcement in this standalone package.

## Changes and verification

Preserve unrelated work. Brief parallel workers with disjoint file ownership.
Make incremental commits with the repository owner's Git identity and no AI
attribution. Commit messages use `subsystem: imperative summary`, followed by
prose explaining why. Keep dependency locks and copied tooling separate from
application commits. Update `docs/next.md` and these mirrored package docs
when types, messages or dependencies change. Run one independent adversarial
review before declaring substantive work complete.

## Package boundary

`jevelin_mcp` owns executable startup. `service.Mode` selects stdio or an
explicitly admitted loopback HTTP listener. Its MCP bearer token is separate
from `http.Configuration`, which captures the upstream Jev credential,
origin, model, and timeout and supplies the evaluation transport.

`evaluation.Arguments(answer)` couples admitted MCP inputs to the original
`jevelin.Request(Evaluation(answer))`; `Output(answer)` retains the validated
domain value and its public wire representation. `Named` admits prepared
Choice, Score, or Noul criteria to a mixed batch. `tool` exposes shared typed
definitions and registers all four through `server.bind`. Result decoding
retains the exact original criteria on the client as well as the server.

The application consumes Jevelin and gleam_mcp through pinned dependencies.
SDK `686955fc0461630bf64a4dc8eb51565dc7ca1ac9` brings public Glisten and Mist
pins that register the connection and SSE factories before HTTP admission.
Reverse shutdown ends admission before retiring those factories. Preserve
that order when updating dependencies; the SDK's
[protocol contracts](https://github.com/Roasbeef/gleam-mcp/blob/686955fc0461630bf64a4dc8eb51565dc7ca1ac9/docs/protocol.md#http-dependencies)
and [upstream issue #55](https://github.com/rawhat/glisten/issues/55) record
the dependency requirement.

Tool arguments never carry a credential or provider origin. Decode inputs
before transport and disclose fixed error categories rather than provider
bodies. A mixed batch retains each typed question/answer coupling before
combining them into the common output representation.
