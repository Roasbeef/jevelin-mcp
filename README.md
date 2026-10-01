# Jevelin MCP

A tools MCP server for [Jev](https://docs.typesafe.ai/api), built with the
existing [Jevelin Gleam library](https://github.com/Roasbeef/jevelin) and
[Gleam MCP](https://github.com/Roasbeef/gleam-mcp). It exposes typed decisions
as four MCP tools. Jevelin constructs requests and validates answers; the
application supplies HTTP and operator configuration.

## Run

Use Gleam >= 1.18 and Erlang/OTP >= 29:

```sh
git clone https://github.com/Roasbeef/jevelin-mcp.git
cd jevelin-mcp
make release
JEV_API_KEY=your-api-key bin/jevelin-mcp
```

`make release` compiles an Erlang shipment. The launcher runs that compiled
shipment, so build status messages cannot enter the MCP stdout stream.
Provide the API key through the MCP client's environment configuration.

```json
{
  "mcpServers": {
    "jev": {
      "command": "/absolute/path/jevelin-mcp/bin/jevelin-mcp",
      "env": { "JEV_API_KEY": "your-api-key" }
    }
  }
}
```

Stdio supports modern MCP `2026-07-28` requests with per-request metadata and
the existing initialization profiles `2025-06-18` and `2024-11-05`. Keep the
credential in local configuration; it is never a tool argument.

For a loopback HTTP endpoint:

```sh
JEV_API_KEY=your-api-key JEV_MCP_TRANSPORT=http \
JEV_MCP_TOKEN=your-mcp-token bin/jevelin-mcp
```

Connect a modern MCP client to `http://127.0.0.1:8000/mcp` with
`Authorization: Bearer your-mcp-token`. This token admits MCP callers;
`JEV_API_KEY` authorizes the server's upstream requests. HTTP uses POST
and request-scoped SSE, with no initialization session or event replay.
A remote deployment needs an authenticated TLS front proxy to the loopback
listener. See [the pinned Gleam MCP protocol contracts](https://github.com/Roasbeef/gleam-mcp/blob/686955fc0461630bf64a4dc8eb51565dc7ca1ac9/docs/protocol.md).

## Tools

| Tool | Decision | Additional required arguments |
|---|---|---|
| `jev_choice` | Selects a labeled alternative, with probabilities and confidence. | `choices`: distinct objects with `label` and optional `description`. |
| `jev_score` | Scores against ordered levels, with probabilities and confidence. | `levels`: two to ten content values. |
| `jev_noul` | Returns a zero-to-one probability. | None; optional `yes` and `no` criteria. |
| `jev_batch` | Evaluates named, mixed question types in one request. | `questions`: objects with `name`, `type` and type-specific arguments. |

All tools require `state`. Jevelin content can be a string, structured
object or array. Single-question tools accept optional `instructions` and
`model`; batch questions each carry their instructions while the batch
selects one model. A missing model uses the operator's configured default.
Question types are `choice`, `score` and `noul`.

For example, call `jev_choice` with:

```json
{
  "state": "The user wants to inspect a failed build.",
  "instructions": "Choose the most relevant next action.",
  "choices": [
    { "label": "logs", "description": "Read the compiler error." },
    { "label": "tests", "description": "Run the test suite." }
  ]
}
```

Single tools return `{model, answer, usage}`; batch returns
`{model, answers, usage}` keyed by the supplied question names. MCP results
include structured content and its JSON text representation. Inputs pass
Jevelin's smart constructors before HTTP runs. Modern argument failures are
completed tool errors with `isError`; unknown tools and malformed requests
are protocol errors. The legacy stdio profiles retain their JSON-RPC argument
errors. Provider and response failures are tool errors. Upstream bodies and
native HTTP diagnostics do not appear in public errors.

## Typed Gleam clients

`jevelin_mcp/tool` exports the same definitions that the server binds to its
handlers. A Gleam client can use `tool.choice`, `tool.score`, `tool.noul`, or
`tool.batch` with `gleam_mcp/client.call`. Construct arguments with
`evaluation.choice`, `score`, `noul`, or `mixed`; their opaque types retain
the original Jevelin request and its answer decoder.

The result is `evaluation.Output(answer)`. `evaluation.output_value` returns
the typed evaluation, so a Choice exposes its selected label and validated
probabilities, while Noul exposes a probability without a threshold. The original
request's decoder checks exact Choice labels, batch names, and the Score range
and legend/probability keys. It does not authenticate semantic provenance or compare
returned Score legend descriptions with the original level content. See
[the native typed client example](test/support/typed_client.gleam).

## Operator settings

| Environment variable | Default | Meaning |
|---|---|---|
| `JEV_API_KEY` | Required | Bearer credential for Jev. |
| `JEV_MODEL` | `jev-latest` | Default model, overridden by an explicit tool model. |
| `JEV_TIMEOUT_MS` | `30000` | One HTTP attempt's timeout, from 1 through 120000 ms. |
| `JEV_BASE_URL` | `https://api.typesafe.ai` | Official HTTPS origin; loopback HTTP is accepted for local fixtures. |
| `JEV_MCP_TRANSPORT` | `stdio` | `stdio` or a loopback `http` listener. |
| `JEV_MCP_PORT` | `8000` | HTTP listener port. |
| `JEV_MCP_AUTH` | `bearer` | HTTP admission; `none` explicitly permits unauthenticated loopback callers. |
| `JEV_MCP_TOKEN` | Required for HTTP bearer admission | MCP caller credential, separate from the Jev key. |
| `JEV_MCP_ALLOWED_ORIGINS` | Empty | Comma-separated exact browser Origins allowed on HTTP requests. |

Tool arguments cannot select an HTTP origin or override credentials.
Redirects are disabled and official HTTPS uses the HTTP library's TLS
verification. The adapter accepts UTF-8 responses up to 4 MiB. The HTTP
library buffers a complete response before that limit is checked, so the
limit bounds accepted data rather than network buffering. Calls make one
attempt; the server does not retry decisions automatically. Stdio callbacks
have an outer budget of this timeout plus five seconds. HTTP startup does not
receive those stdio timeout options; the configured timeout still applies to
the upstream HTTP attempt.

## Development

`make check` runs warning-free compilation, formatting, unit tests, the
copied Loom linter and its tests, source and documentation checks, and a
real subprocess MCP exchange against a local mock HTTP provider. The mock
checks authorization, request shapes, malformed and failed responses, and
credential exclusion without spending a live API credential. CI runs on
Linux and macOS.

Both libraries are consumed through exact Git commit dependencies. Jevelin
is used directly rather than copied into the application. Read
[architecture and its source reading path](docs/architecture.md),
[major principles](docs/principles.md), [the style guide](docs/gleam-style.md),
and [current handoff](docs/next.md) before changing the server.
