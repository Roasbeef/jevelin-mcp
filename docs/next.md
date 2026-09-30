# Current handoff

Audited on 2026-09-30 against application source and dependency baseline
`1137bf5b086b6580c590172ed00b1abe9671e981`, consuming published SDK
`686955fc0461630bf64a4dc8eb51565dc7ca1ac9`. The full local gate passed
through public Git dependencies, including the original compiled HTTP peer.
Application publication and hosted CI for these pins are pending. The red
hosted result at prior head `7f5a63b` remains a result for that head; the local
pass does not establish a green hosted replacement.

## Where the tree is

The server exposes `jev_choice`, `jev_score`, `jev_noul` and `jev_batch` over
stdio or a configured loopback HTTP endpoint. It consumes the existing
Jevelin library at `73634519e4846047769726a24a1f6bc3dec6966d`. Shared tool
definitions couple input schemas, typed argument preparation and output
validation for Gleam clients and server handlers. Mixed batches retain
question/answer coupling; every decoded answer passes the original Jevelin
request's label, rubric and batch-name contract.

The application and lock consume the exact published SDK commit above.
The complete `make check` gate exited zero through those Git dependencies:
13 Gleam tests, 139 copied-linter tests, four negative tooling tests, compiled
stdio exchanges and compiled HTTP exchanges against an independent mock
provider. Both original peers passed without assertion changes and exercise
all four tools. No private snapshot or sibling path is required.

A separate BEAM client calls Choice through the shared typed definition;
it has no upstream key and proves original-request answer decoding.

The SDK brings Glisten `3eb785919be0736da0a20732a56275dce0132327` and Mist
`28b43178ff57bfb619c64b8c3544831646d5fdb9`. Glisten registers its connection
factory before the listener and acceptors start; Mist registers its SSE
factory before Glisten starts. Those dependencies close the local HTTP
startup blocker, so the original compiled peer can complete its exchanges.
The upstream report is
[rawhat/glisten#55](https://github.com/rawhat/glisten/issues/55).
The previous handoff's SDK pin `a3de7047` and gate description are superseded
by this public-dependency result.

HTTP tests distinguish MCP admission from upstream authorization, reject
bad Origins and mirrored metadata before provider effects, and exercise
invalid criteria and invalid selected labels. The stdio peer covers raw
Unicode, provider failures, redirects, credential reflection, timeout and
EOF drain. No authenticated live Jev request was made.

## Rulings already made

The provider origin and credential come from operator configuration, never
tool arguments. Official HTTPS verifies TLS; redirects are disabled. MCP
HTTP admission defaults to a separate required bearer token. Explicit
`JEV_MCP_AUTH=none` permits unauthenticated loopback access. Present Origins
must match the configured exact allowlist.

HTTP admission starts only after the connection and SSE factories have
registered. Reverse shutdown stops admission before retiring those factories.
Preserve that ordering when updating the SDK or its transitive dependencies;
the [pinned SDK contracts](https://github.com/Roasbeef/gleam-mcp/blob/686955fc0461630bf64a4dc8eb51565dc7ca1ac9/docs/protocol.md#http-dependencies)
record the fork pins and framing requirements.

Public errors carry fixed categories rather than provider bodies. Calls
make one attempt. HTTP's upstream budget fits inside the stdio request
budget, including preparation and decoding allowance. Modern argument
refusals are completed tool errors; legacy profiles preserve their existing
JSON-RPC argument behavior.

The accepted UTF-8 response limit is four MiB after the HTTP library buffers
the complete body; it does not bound network buffering. Startup errors
write fixed stderr diagnostics and return normally, so their process exit
status is zero. No live-provider success is implied by mock exchanges.

## What to do next

1. Publish the application with SDK `686955fc` and verify hosted checks.
   Exit: Linux and macOS CI pass the new application head, including its
   original compiled HTTP peer through the public dependency pins.
2. Run an authenticated live Jev check when a credential is available.
   Exit: a real provider request and typed answer are recorded without secrets.
3. Keep optional MCP features in the shared library's feature scope; resources
   and prompts are tracked in its issue #1. The current app remains focused
   on its four decision tools.

Run `make check` or `make release`; `bin/jevelin-mcp` executes the compiled
shipment. See [execution](execution.md), [README](../README.md) and the style
and package docs before changing configuration or typed boundaries.
