# Current handoff

Audited on 2026-09-30 against application HEAD
`6d68fb64797ad99b3cb305002deb03b8a1c57b9b` and the local literate source/docs
pass based on that head. The pass changes comments, documentation, declaration
order, and formatter-required trailing commas only. A declaration-token
comparison preserved all five root modules' imports, signatures, string
literals, and 91 declaration bodies. No feature, public interface, dependency,
test, or assertion changed.

The complete local `make check` gate exited zero on the resulting source tree:
13 application tests, 139 copied-linter tests, four negative tooling tests,
formatting, warning-free compilation, house rules, source/doc boundaries, and
the original compiled stdio and HTTP peers. The first sandboxed end-to-end run
could not bind its local mock listener; the fresh permissioned full gate passed.
The copied linter reports zero errors and 30 existing warning-level findings.
`gleam docs build` also exited zero. No credential or live-provider call was used.

## Where the tree is

The server exposes `jev_choice`, `jev_score`, `jev_noul`, and `jev_batch` over
stdio or a configured loopback HTTP endpoint. It consumes Jevelin at
`73634519e4846047769726a24a1f6bc3dec6966d` and Gleam MCP at
`686955fc0461630bf64a4dc8eb51565dc7ca1ac9` through exact public Git dependencies.
No private snapshot or sibling path is required.

Shared typed definitions bind schemas, argument preparation, result encoding,
and original-argument result decoding for both clients and server handlers.
`Arguments(answer)` retains the Jevelin request and decoder; `Output(answer)`
retains the decoded domain value and public JSON. Mixed batches wrap each
validated typed answer before combining them into a homogeneous Answer list.
A separate native BEAM client calls Choice over HTTP using the shared definition
and only an MCP credential.

All five application modules open with a real `## Flow`. Public variants,
fields, and functions explain their invariants; function examples exercise
contracts or mark effectful examples. The new
[architecture reading path](architecture.md) follows startup, admission,
request execution, and typed result decoding. [Principles](principles.md)
records the reasons for the boundaries. README and mirrored package docs link
both. The copied Loom style guide remains the language reference, with its
application-specific scope qualified by the package docs.

## Rulings and limits

The Jev origin and credential come from operator configuration, never tool
arguments. Official HTTPS verifies TLS; redirects are disabled. Calls make one
attempt. MCP HTTP admission uses a separate required bearer token by default;
explicit `JEV_MCP_AUTH=none` permits unauthenticated loopback access. Present
Origins must match the configured exact allowlist.

The accepted UTF-8 response limit is four MiB after the native HTTP library
buffers the complete body. It does not bound network/native buffering. Raw
and normalized JSON are scanned for the exact credential; transformed or
partial secret echoes are not a general redaction guarantee. Public errors
carry fixed categories and numeric statuses, never provider bodies or parser
diagnostics. Successful state, instructions, and answers can remain sensitive.

Stdio's callback budget is `JEV_TIMEOUT_MS + 5000`, with EOF drain owned by the
SDK. HTTP startup does not receive those stdio options. Its upstream native
HTTP attempt uses `JEV_TIMEOUT_MS`, which is not a wall-clock bound for all MCP
preparation/decoding work. Stopping a local worker does not prove remote provider
effects stopped or rolled back. Startup errors write fixed stderr diagnostics
and return normally, so their process exit status is zero.

Request-bound decoding checks exact Choice labels, batch names, the Score
range and legend/probability keys, and probabilities. Score legend content is decoded but not compared
with input rubric descriptions. Equal-shaped criteria can admit an answer for
different state or instructions; decoding does not authenticate semantic
provenance. The shared tool codec owns JSON Schema checking separately from
`evaluation.decode_output`'s Jevelin validation.

HTTP admission starts after the connection and SSE factories register. Reverse
shutdown ends admission before retiring them. The SDK pins Glisten
`3eb785919be0736da0a20732a56275dce0132327` and Mist
`28b43178ff57bfb619c64b8c3544831646d5fdb9`. Preserve that startup/shutdown order
when updating dependencies. The
[pinned SDK contracts](https://github.com/Roasbeef/gleam-mcp/blob/686955fc0461630bf64a4dc8eb51565dc7ca1ac9/docs/protocol.md#http-dependencies)
and [rawhat/glisten#55](https://github.com/rawhat/glisten/issues/55) record why.

## Evidence and next work

The compiled stdio peer covers all tools, Unicode, invalid input/answers,
provider failures, redirect refusal, credential reflection, timeout, and EOF
response drain. The HTTP peer distinguishes MCP admission from upstream
authorization, rejects bad Origins and mirrored metadata before provider
effects, and exercises the shared typed Choice client. Their provider is an
independent local mock. No authenticated live Jev success is implied.

Runtime publication `fb5b434` passed Linux and macOS CI in
[run 36766066616](https://github.com/Roasbeef/jevelin-mcp/actions/runs/36766066616).
The previous handoff recorded its fresh public Linux full gate and fifty HTTP
suite runs, including expected authorization and Origin refusals. That is
historical runtime evidence; it is not hosted CI evidence for this literate
pass. The public dependency pins remain unchanged.

1. Preserve reproducible dependency updates. Exit: the full original gate and
   Linux/macOS CI pass each new application head through its public pins,
   including the compiled HTTP peer.
2. Run an authenticated live Jev check when a credential is available. Exit: a
   real provider request and typed answer are recorded without secrets.
3. Keep optional MCP features in the shared library's scope; resources and
   prompts remain tracked in its issue #1. This app remains four decision tools.

Run `make check` or `make release`; `bin/jevelin-mcp` executes the compiled
shipment. See [execution](execution.md), [README](../README.md),
[architecture](architecture.md), and [principles](principles.md) before changing
configuration or typed boundaries.
