//// Four discoverable tools share one evaluation boundary. Their schemas expose
//// application criteria, not credentials or URLs; the handlers decode the same
//// shape and reject unknown fields before constructing Jevelin requests.

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

/// Registers Choice, Score, Noul, and mixed-batch tools with one transport.
/// Each handler owns total argument validation and Jevelin response validation.
///
/// ## Examples
///
/// ```gleam
/// tool.server("jev-latest", transport)
/// // -> Ok(server) with four evaluation tools.
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

/// Shares the Choice argument and request-bound result contract with clients.
///
/// ## Examples
///
/// ```gleam
/// // tool.choice("jev-latest") returns the definition for client.call.
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

/// Shares the Score argument and bounded rubric result contract with clients.
///
/// ## Examples
///
/// ```gleam
/// // tool.score("jev-latest") accepts only evaluation.Arguments(Score).
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

/// Shares the Noul argument and probability result contract with clients.
///
/// ## Examples
///
/// ```gleam
/// // tool.noul("jev-latest") returns probabilities without choosing a threshold.
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

/// Shares the mixed batch contract, preserving each question's named answer.
///
/// ## Examples
///
/// ```gleam
/// // tool.batch("jev-latest") binds the names carried by evaluation.mixed.
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
  use input <- result.try(
    schema.new(input_schema(name))
    |> result.map_error(fn(_) { server.InvalidSchema }),
  )
  use output <- result.try(
    schema.new(output_schema(name))
    |> result.map_error(fn(_) { server.InvalidSchema }),
  )
  let args =
    codec.new(input, evaluation.arguments_json, fn(value) {
      decode(value) |> result.map_error(evaluation.message)
    })

  // An answer has no independent decoder: its labels and rubric bounds are
  // justified only by the exact original arguments retained by the client.
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
  server.bind(definition, fn(args) {
    evaluation.execute(args, transport)
    |> result.map_error(fn(error) {
      server.ExecutionFailed(evaluation.message(error))
    })
  })
}

/// Produces the public input contract, including structured content and explicit
/// list-based labels and names that cannot silently overwrite one another.
///
/// ## Examples
///
/// ```gleam
/// tool.input_schema("jev_choice")
/// // -> An object JSON Schema with required state and choices fields.
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

/// Produces schemas for structured successful results. Per-request labels,
/// probability mass, and rubric bounds are additionally enforced by Jevelin.
///
/// ## Examples
///
/// ```gleam
/// tool.output_schema("jev_batch")
/// // -> An object JSON Schema requiring model, answers, and usage.
/// ```
pub fn output_schema(name: String) -> JsonValue {
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
