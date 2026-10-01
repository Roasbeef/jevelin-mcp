//// Tool definitions share one contract between discovery, server, and client.
//// Each definition pairs an input schema and typed argument codec with an output
//// schema and encoder. The server binds an evaluation transport later; a Gleam
//// client can construct the same definition without owning upstream credentials.
////
//// A general output schema cannot enumerate the labels or rubric size of every
//// future request. `definition` therefore installs a result decoder that takes
//// the original Arguments value. An independent output decoder is deliberately
//// unavailable: the schema checks shape, then the retained Jevelin request checks
//// the runtime criteria. Both checks survive a typed client's continuation.
////
//// ## Flow
////
//// 1. `server` obtains `choice`, `score`, `noul`, and `batch` definitions.
//// 2. Each calls `definition`, which constructs `input_schema` and `output_schema`,
////    pairs their codecs, and installs `evaluation.decode_output` for original args.
//// 3. `bind` uses `server.bind` to connect each typed definition to
////    `evaluation.execute` through the same caller-owned transport.
//// 4. `server.new` registers the resulting heterogeneous tools for discovery and
////    dispatch. Schema construction or binding failure stops registration.
//// 5. A Gleam client uses the unbound public definition with `client.call`;
////    argument encoding and request-bound result decoding need no Jev key.
////
//// Schema helper declarations follow the shapes they describe: named questions,
//// Choice and Score criteria, answer variants, then shared JSON primitives.
//// Credentials and origin have no place in any advertised argument shape.

import gleam/list
import gleam/result
import gleam_mcp/codec
import gleam_mcp/json.{type JsonValue, Array, Bool, Int, Object, String}
import gleam_mcp/schema
import gleam_mcp/server
import gleam_mcp/tool as mcp_tool
import jevelin/probability
import jevelin/question
import jevelin_mcp/evaluation

/// Registers all four tools after binding their typed definitions to one transport.
/// The type variable in each binding preserves its answer type until `server.bind`
/// packages it as a registry entry. Registration failure returns an error before a
/// protocol runner starts. This function constructs callbacks; it performs no I/O.
///
/// ## Examples
///
/// ```gleam
/// tool.server("jev-latest", transport)
/// // -> Ok(registry) with Choice, Score, Noul, and mixed-batch handlers.
/// ```
pub fn server(
  model: String,
  transport: evaluation.Transport,
) -> Result(server.Server, server.ConfigurationError) {
  use choice <- result.try(bind(choice(model), transport))
  use score <- result.try(bind(score(model), transport))
  use noul <- result.try(bind(noul(model), transport))
  use batch <- result.try(bind(batch(model), transport))

  // Heterogeneous definitions become registry entries only after each typed
  // argument and output contract has been bound to the same effect boundary.
  server.new("jevelin-mcp", "0.2.0", [choice, score, noul, batch])
}

/// Builds a shared typed definition for the exact selected-label and probability-key checks.
/// The definition owns discovery schemas, argument admission, and original-argument
/// result decoding. It captures the default model, but no transport or credential;
/// use it in a client call or bind it to a server handler.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_ok(tool.choice("jev-latest"))
/// ```
pub fn choice(
  default_model: String,
) -> Result(
  mcp_tool.Tool(
    evaluation.Arguments(question.Choice(String)),
    evaluation.Output(question.Choice(String)),
  ),
  server.ConfigurationError,
) {
  definition(
    "jev_choice",
    "Choose one supplied label and return its probability distribution.",
    evaluation.decode_choice(_, default_model),
  )
}

/// Builds a shared typed definition for the original rubric index range and legend/probability keys.
/// The definition owns discovery schemas, argument admission, and original-argument
/// result decoding. It captures the default model, but no transport or credential;
/// use it in a client call or bind it to a server handler.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_ok(tool.score("jev-latest"))
/// ```
pub fn score(
  default_model: String,
) -> Result(
  mcp_tool.Tool(
    evaluation.Arguments(question.Score),
    evaluation.Output(question.Score),
  ),
  server.ConfigurationError,
) {
  definition(
    "jev_score",
    "Rate content against two to ten ordered rubric levels; return a fractional expected index.",
    evaluation.decode_score(_, default_model),
  )
}

/// Builds a shared typed definition for a Probability in [0, 1] with no decision threshold.
/// The definition owns discovery schemas, argument admission, and original-argument
/// result decoding. It captures the default model, but no transport or credential;
/// use it in a client call or bind it to a server handler.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_ok(tool.noul("jev-latest"))
/// ```
pub fn noul(
  default_model: String,
) -> Result(
  mcp_tool.Tool(
    evaluation.Arguments(probability.Probability),
    evaluation.Output(probability.Probability),
  ),
  server.ConfigurationError,
) {
  definition(
    "jev_noul",
    "Evaluate a yes/no question and return its probability of yes, without an implicit threshold.",
    evaluation.decode_noul(_, default_model),
  )
}

/// Builds a shared typed definition for the complete original name set and each typed question decoder.
/// The definition owns discovery schemas, argument admission, and original-argument
/// result decoding. It captures the default model, but no transport or credential;
/// use it in a client call or bind it to a server handler.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_ok(tool.batch("jev-latest"))
/// ```
pub fn batch(
  default_model: String,
) -> Result(
  mcp_tool.Tool(
    evaluation.Arguments(List(#(String, evaluation.Answer))),
    evaluation.Output(List(#(String, evaluation.Answer))),
  ),
  server.ConfigurationError,
) {
  definition(
    "jev_batch",
    "Evaluate independent Choice, Score, and Noul questions against one state in a single HTTP request.",
    evaluation.decode_mixed(_, default_model),
  )
}

fn definition(
  name: String,
  description: String,
  decode: fn(JsonValue) -> Result(evaluation.Arguments(a), evaluation.Error),
) -> Result(
  mcp_tool.Tool(evaluation.Arguments(a), evaluation.Output(a)),
  server.ConfigurationError,
) {
  // A schema is itself admitted data. Keeping its construction fallible makes
  // a broken advertised contract a startup failure instead of a lying tool.
  use input <- result.try(
    schema.new(input_schema(name))
    |> result.map_error(fn(_) { server.InvalidSchema }),
  )
  use output <- result.try(
    schema.new(output_schema(name))
    |> result.map_error(fn(_) { server.InvalidSchema }),
  )

  // Encoding typed Arguments uses their retained public JSON; decoding raw
  // input enters the very same evaluation constructors. The codec additionally
  // checks the advertised schema in both directions.
  let args =
    codec.new(input, evaluation.arguments_json, fn(value) {
      decode(value) |> result.map_error(evaluation.message)
    })

  // Shape alone cannot justify a selected label or rubric index. Refusing an
  // independent decoder prevents callers from accidentally discarding the
  // original Arguments value when interpreting a remote successful result.
  let result =
    codec.new(output, evaluation.output_json, fn(_) {
      Error("The original arguments are required to decode this result.")
    })
  use definition <- result.try(
    mcp_tool.new(name, description, args, result)
    |> result.map_error(fn(_) { server.InvalidSchema }),
  )
  Ok(
    mcp_tool.with_result_decoder(definition, fn(args, value) {
      evaluation.decode_output(args, value)
      |> result.map_error(evaluation.message)
    }),
  )
}

fn bind(
  definition: Result(
    mcp_tool.Tool(evaluation.Arguments(a), evaluation.Output(a)),
    server.ConfigurationError,
  ),
  transport: evaluation.Transport,
) -> Result(server.Tool, server.ConfigurationError) {
  use definition <- result.try(definition)

  // The callback is the only entry to evaluation effects. A schema or argument
  // refusal happens in server.bind's codec boundary before execute is invoked.
  server.bind(definition, fn(args) {
    evaluation.execute(args, transport)
    |> result.map_error(fn(error) {
      server.ExecutionFailed(evaluation.message(error))
    })
  })
}

/// Describes the four input shapes for discovery and codec admission.
/// Labels and batch names use arrays so duplicates remain detectable by Jevelin's
/// constructors. A missing model uses the operator default in the domain decoder.
/// Unknown names return a closed empty-object schema, not a tool definition.
///
/// ## Examples
///
/// ```gleam
/// tool.input_schema("jev_choice")
/// // -> An object schema requiring state and a choices array.
/// ```
pub fn input_schema(name: String) -> JsonValue {
  let common = [
    #("state", content_schema()),
    #("model", Object([#("type", String("string")), #("minLength", Int(1))])),
    #("instructions", optional_content_schema()),
  ]
  case name {
    "jev_batch" ->
      object_schema(
        [
          #("state", content_schema()),
          #(
            "model",
            Object([#("type", String("string")), #("minLength", Int(1))]),
          ),
          #(
            "questions",
            Object([
              #("type", String("array")),
              #("minItems", Int(1)),
              #(
                "items",
                Object([
                  #(
                    "oneOf",
                    Array(list.map(["choice", "score", "noul"], named_schema)),
                  ),
                ]),
              ),
            ]),
          ),
        ],
        ["state", "questions"],
      )
    "jev_choice" ->
      object_schema([#("choices", choices_schema()), ..common], [
        "state",
        "choices",
      ])
    "jev_score" ->
      object_schema([#("levels", levels_schema()), ..common], [
        "state",
        "levels",
      ])
    "jev_noul" ->
      object_schema(
        [
          #("yes", optional_content_schema()),
          #("no", optional_content_schema()),
          ..common
        ],
        ["state"],
      )
    _ -> object_schema([], [])
  }
}

/// Describes structured successful results, including model and usage.
/// Per-request labels, rubric length, exact batch names, and probability mass
/// require the original Jevelin decoder in addition to this schema. A general
/// Score schema permits [0, 9]; the original rubric may permit a smaller range.
///
/// ## Examples
///
/// ```gleam
/// tool.output_schema("jev_batch")
/// // -> An object schema requiring model, named answers, and usage.
/// ```
pub fn output_schema(name: String) -> JsonValue {
  // Discovery describes every possible call. The schema's widest Score range
  // cannot replace the tighter bound carried by a particular Arguments value.
  let common = [
    #("model", primitive("string")),
    #(
      "usage",
      object_schema(
        [
          #("input_tokens", nonnegative_integer()),
          #("output_tokens", nonnegative_integer()),
        ],
        ["input_tokens", "output_tokens"],
      ),
    ),
  ]
  case name {
    "jev_batch" ->
      object_schema(
        [
          #(
            "answers",
            Object([
              #("type", String("object")),
              #("minProperties", Int(1)),
              #(
                "additionalProperties",
                Object([
                  #(
                    "oneOf",
                    Array(list.map(["choice", "score", "noul"], answer_schema)),
                  ),
                ]),
              ),
            ]),
          ),
          ..common
        ],
        ["model", "answers", "usage"],
      )
    "jev_choice" ->
      object_schema([#("answer", answer_schema("choice")), ..common], [
        "model",
        "answer",
        "usage",
      ])
    "jev_score" ->
      object_schema([#("answer", answer_schema("score")), ..common], [
        "model",
        "answer",
        "usage",
      ])
    "jev_noul" ->
      object_schema([#("answer", answer_schema("noul")), ..common], [
        "model",
        "answer",
        "usage",
      ])
    _ -> object_schema([], [])
  }
}

fn named_schema(kind: String) -> JsonValue {
  let common = [
    #("name", primitive("string")),
    #("type", constant(kind)),
    #("instructions", optional_content_schema()),
  ]
  case kind {
    "choice" ->
      object_schema([#("choices", choices_schema()), ..common], [
        "name",
        "type",
        "choices",
      ])
    "score" ->
      object_schema([#("levels", levels_schema()), ..common], [
        "name",
        "type",
        "levels",
      ])
    "noul" ->
      object_schema(
        [
          #("yes", optional_content_schema()),
          #("no", optional_content_schema()),
          ..common
        ],
        ["name", "type"],
      )
    _ -> object_schema([], [])
  }
}

fn choices_schema() -> JsonValue {
  Object([
    #("type", String("array")),
    #("minItems", Int(1)),
    #("maxItems", Int(255)),
    #(
      "items",
      object_schema(
        [
          #("label", primitive("string")),
          #("description", optional_content_schema()),
        ],
        ["label"],
      ),
    ),
  ])
}

fn levels_schema() -> JsonValue {
  Object([
    #("type", String("array")),
    #("minItems", Int(2)),
    #("maxItems", Int(10)),
    #("items", content_schema()),
  ])
}

fn answer_schema(kind: String) -> JsonValue {
  case kind {
    "noul" ->
      object_schema(
        [#("type", constant(kind)), #("noul", probability_schema())],
        ["type", "noul"],
      )
    "choice" ->
      object_schema(
        [
          #("type", constant(kind)),
          #("choice", primitive("string")),
          #("confidence", probability_schema()),
          #("probabilities", probability_map_schema()),
        ],
        ["type", "choice", "confidence", "probabilities"],
      )
    "score" ->
      object_schema(
        [
          #("type", constant(kind)),
          #(
            "score",
            Object([
              #("type", String("number")),
              #("minimum", Int(0)),
              #("maximum", Int(9)),
            ]),
          ),
          #("confidence", probability_schema()),
          #("probabilities", probability_map_schema()),
          #(
            "legend",
            Object([
              #("type", String("object")),
              #("additionalProperties", content_schema()),
            ]),
          ),
        ],
        ["type", "score", "confidence", "probabilities", "legend"],
      )
    _ -> object_schema([], [])
  }
}

fn object_schema(
  properties: List(#(String, JsonValue)),
  required: List(String),
) -> JsonValue {
  Object([
    #("type", String("object")),
    #("properties", Object(properties)),
    #("required", Array(list.map(required, String))),
    #("additionalProperties", Bool(False)),
  ])
}

fn content_schema() -> JsonValue {
  Object([#("oneOf", Array(list.map(["string", "object", "array"], primitive)))])
}

fn optional_content_schema() -> JsonValue {
  Object([
    #(
      "oneOf",
      Array(list.map(["string", "object", "array", "null"], primitive)),
    ),
  ])
}

fn probability_schema() -> JsonValue {
  Object([
    #("type", String("number")),
    #("minimum", Int(0)),
    #("maximum", Int(1)),
  ])
}

fn probability_map_schema() -> JsonValue {
  Object([
    #("type", String("object")),
    #("additionalProperties", probability_schema()),
  ])
}

fn nonnegative_integer() -> JsonValue {
  Object([#("type", String("integer")), #("minimum", Int(0))])
}

fn primitive(kind: String) -> JsonValue {
  Object([#("type", String(kind))])
}

fn constant(value: String) -> JsonValue {
  Object([#("type", String("string")), #("const", String(value))])
}
