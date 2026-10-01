# Principles for this application

We keep the criteria, decoder, and answer together, and give each effect one
owner. The application is small enough that these rules can be followed through
five modules. [Architecture](architecture.md) traces the actual startup and
request paths; this document explains the choices that a future change must
preserve.

## Admit data before effects

MCP input starts as untrusted JSON. A field whitelist rejects values outside the
advertised tool surface, total decoders establish content shape, and Jevelin's
smart constructors establish criteria validity. The transport runs only after
all three stages succeed. Keeping duplicate labels and names in lists until
construction makes their rejection possible; an early dictionary conversion
would erase the evidence.

Typed local callers go through the same preparation path as remote callers.
`evaluation.choice`, `score`, `noul`, and `mixed` encode their arguments, then
use the wire admission functions. A typed constructor does not acquire a
separate, weaker interpretation of the public contract.

## Use types for relationships, decoders for values

`Arguments(answer)` and `Output(answer)` express a static relationship: a
Choice input produces a Choice output. Their opaque constructors restrict
creation to the functions that establish the contract. The lowercase parameter
names a type, not a value; Gleam cannot encode a particular runtime label list
in that parameter. The retained Jevelin request supplies the decoder that
checks those labels, rubric bounds, names, and probability distributions.

`Answer` is a sum type for a mixed batch. A list requires one element type,
so Choice, Score, and Noul answers use explicit variants. The question decoder
validates first, then `batch.map` wraps the valid value. Wrapping a raw response
without its question decoder would remove the central guarantee.

The constraints are precisely scoped. Score validates its original index
range and key set, while returned legend text is decoded without comparison to
the input descriptions. Original-argument decoding does not prove semantic
provenance when another request has the same shape. The provider still supplies
the decision; local code validates the contract of that decision.

## Keep authority outside criteria

The operator configures the Jev origin and credential once. An opaque
`http.Configuration` admits them before a closure captures the upstream effect.
Tools carry evaluation content and model names, never URLs or credentials.
The MCP bearer token authenticates callers separately from the upstream key.
Origin admission is another check; it does not replace caller authentication.

A successful argument or answer can contain sensitive user content even though
it cannot contain transport configuration. Fixed errors discard provider
bodies and native diagnostics. The exact credential-reflection check provides
an additional refusal for direct echoes; it is not a general content-redaction
policy.

## Let the existing runtime own lifetime

The application does not invent an actor state machine for a synchronous
preparation path. `Mode` represents the operator's two transport choices, and
the executable enters one runner after configuration and registration succeed.
Gleam MCP and its weft scopes own admission, request workers, cancellation, and
drain. Mist owns the HTTP listener's supervision tree, retained by the
foreground executable process.

The native HTTP timeout bounds one attempt. Stdio additionally gets a callback
budget of that timeout plus five seconds. HTTP startup does not receive those
stdio options. Cancellation of a local worker does not prove a remote decision
was stopped or undone, and the four MiB response acceptance check runs after
native buffering. A documented limit must name the stage it actually bounds.

## Make the code readable in execution order

Large module docs include `## Flow` with an ordered spine of real functions.
Types appear before the functions that consume them; declarations broadly
follow construction, admission, execution, then result projection. Alternate
client and server entries remain explicit rather than forcing every path into
one fictitious sequence. Transition tables describe real match decisions or
lifetime boundaries, and name when another library owns the state machine.

Domain calls stay qualified (`jevelin.send`, `question.choice`, `batch.map`)
so their responsibility is visible. Helpers describe domain work such as
`prepare_question`, `validate_arguments`, and `encode_evaluation`; extracting
a tiny wrapper solely to shorten a call adds another place to read. Comments
explain ownership, required ordering, and the failure being excluded. A comment
that only restates the next statement does not supply any missing reasoning.

For Gleam readers, a `use` line passes the remainder as a continuation.
`result.try` calls that continuation only for `Ok`; an `Error` skips later
preparation or transport. `decode.field` composes the field decoder in the same
style. Explicit variants and exhaustive matches retain compiler help when a
domain gains a new case. No new lint rule is needed for these reading principles;
the existing gates and review remain the verification mechanisms.
