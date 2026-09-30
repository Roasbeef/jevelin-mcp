# Jevelin MCP

A stdio MCP server for [Jev](https://docs.typesafe.ai/api), built with the
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

The client starts the server, negotiates MCP `2025-06-18` or `2024-11-05`,
discovers tools and calls them over newline-delimited JSON-RPC. Keep the
credential in local configuration; it is never a tool argument.

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
Jevelin's smart constructors before HTTP runs. Argument failures are
JSON-RPC errors; provider and response failures are MCP tool errors with
`isError`. Upstream bodies and native HTTP diagnostics do not appear in
public errors.

## Operator settings

| Environment variable | Default | Meaning |
|---|---|---|
| `JEV_API_KEY` | Required | Bearer credential for Jev. |
| `JEV_MODEL` | `jev-latest` | Default model, overridden by an explicit tool model. |
| `JEV_TIMEOUT_MS` | `30000` | One HTTP attempt's timeout, from 1 through 120000 ms. |
| `JEV_BASE_URL` | `https://api.typesafe.ai` | Official HTTPS origin; loopback HTTP is accepted for local fixtures. |

Tool arguments cannot select an HTTP origin or override credentials.
Redirects are disabled and official HTTPS uses the HTTP library's TLS
verification. The adapter accepts UTF-8 responses up to 4 MiB. The HTTP
library buffers a complete response before that limit is checked, so the
limit bounds accepted data rather than network buffering. Calls make one
attempt; the server does not retry decisions automatically.

## Development

`make check` runs warning-free compilation, formatting, unit tests, the
copied Loom linter and its tests, source and documentation checks, and a
real subprocess MCP exchange against a local mock HTTP provider. The mock
checks authorization, request shapes, malformed and failed responses, and
credential exclusion without spending a live API credential. CI runs on
Linux and macOS.

Both libraries are consumed through exact Git commit dependencies. Jevelin
is used directly rather than copied into the application. Read
[the style guide](docs/gleam-style.md) and [current handoff](docs/next.md)
before changing the server.
