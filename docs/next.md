# Current handoff

Audited on 2026-09-30 against application and lock baseline `1aa013e`.
The previous handoff was an in-progress stub; the executable now uses the
existing Jevelin library directly and the published Gleam MCP dependency.

## Where the tree is

The compiled stdio server exposes `jev_choice`, `jev_score`, `jev_noul` and
`jev_batch`. Jevelin is pinned to `73634519e4846047769726a24a1f6bc3dec6966d`;
Gleam MCP is pinned to `ed5758bb11939ceab4adaceda26e891172550ec1`.
No local sibling checkout is required. Schemas and total argument decoding
lead into Jevelin's smart constructors before a provider request starts.
Mixed batches preserve the typed question/answer coupling.

`make check` passed against those Git dependencies: ten Gleam tests, 139
copied-linter tests, three negative tooling tests, and the compiled server
against a local HTTP provider. The subprocess exchange covers all four
tools, raw Unicode, invalid arguments without HTTP, malformed/failed
responses, redirects, credential reflection, timeout and EOF drain.
Independent review checked the wire and configuration boundaries; its
library custody and test-reader findings were fixed and rechecked.
Hosted CI is pending publication. No authenticated live Jev call was made.

## Rulings already made

The provider origin and credential are captured from operator configuration,
never tool arguments. Official HTTPS uses TLS verification; redirects are
disabled. Public errors use fixed categories rather than provider bodies.
Calls make one attempt. HTTP's configured budget fits inside the stdio
request budget, including preparation and decoding allowance.

The accepted UTF-8 response limit is four MiB after the HTTP library buffers
its full body. It does not bound network buffering. Startup errors currently
write a fixed stderr diagnostic and return normally, so their process exit
status is zero; that CLI limitation is recorded rather than hidden.

## What to do next

1. After the initial repositories and Loom extraction PR are published,
   update the shared MCP dependency for the latest protocol, HTTP and typed
   tool definitions. Exit: the existing Jev tools consume that API and
   both transport exchanges retain constructor and answer validation.
2. Run an authenticated live Jev check when a credential is available.
   Exit: real provider request and decoded answer recorded without secrets.
3. Record exact hosted CI and clean-consumer results. Exit: both platforms
   pass the published head and the launcher runs from a built checkout.

Run `make check` or `make release`; `bin/jevelin-mcp` executes the shipment.
See [execution](execution.md) and [the style guide](gleam-style.md).
