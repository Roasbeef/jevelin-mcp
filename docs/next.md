# Current handoff

Audited on 2026-09-30 against the typed-tool and HTTP integration with published SDK
`a3de7047fd594150addee2ba284be5c02a131ed0`. The initial
published baseline `da35e17977fce33ec72795d7c1e67ab33d0ac905` passed Linux and
macOS CI in run `36689261574`. The previous handoff's pending-publication
claim is superseded by that result. This edition records the subsequent typed and HTTP extension. Hosted
checks for its published head remain distinct from the initial CI proof.

## Where the tree is

The server exposes `jev_choice`, `jev_score`, `jev_noul` and `jev_batch` over
stdio or a configured loopback HTTP endpoint. It consumes the existing
Jevelin library at `73634519e4846047769726a24a1f6bc3dec6966d`. Shared tool
definitions couple input schemas, typed argument preparation and output
validation for Gleam clients and server handlers. Mixed batches retain
question/answer coupling; every decoded answer passes the original Jevelin
request's label, rubric and batch-name contract.

The application and lock consume the exact published SDK commit above; no
private snapshot or sibling path is required. The complete gate passed
through those Git dependencies: 13 Gleam tests, 139 copied-linter tests, four
negative tooling tests, compiled stdio exchanges and compiled HTTP exchanges
against an independent mock provider. Both peers exercise all four tools.
A separate BEAM client calls Choice through the shared typed definition;
it has no upstream key and proves original-request answer decoding.

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

1. Keep exact dependency and hosted-check evidence separate from local
   results. Exit: Linux and macOS CI pass the named published application
   head; consumer builds use no private snapshot dependency.
2. Run an authenticated live Jev check when a credential is available.
   Exit: a real provider request and typed answer are recorded without secrets.
3. Keep optional MCP features in the shared library's feature scope; resources
   and prompts are tracked in its issue #1. The current app remains focused
   on its four decision tools.

Run `make check` or `make release`; `bin/jevelin-mcp` executes the compiled
shipment. See [execution](execution.md), [README](../README.md) and the style
and package docs before changing configuration or typed boundaries.
