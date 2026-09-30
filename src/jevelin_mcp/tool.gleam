//// Four discoverable tools share one evaluation boundary. Their schemas expose
//// application criteria, not credentials or URLs; the handlers decode the same
//// shape and reject unknown fields before constructing Jevelin requests.

import gleam/list
import gleam/result
import gleam_mcp/json.{type JsonValue, Array, Bool, Int, Object, String}
import gleam_mcp/protocol
import gleam_mcp/server
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
  use tools <- result.try(
    list.try_map(
      [
        #(
          "jev_choice",
          "Choose one supplied label and return its probability distribution.",
        ),
        #(
          "jev_score",
          "Rate content against two to ten ordered rubric levels; return a fractional expected index.",
        ),
        #(
          "jev_noul",
          "Evaluate a yes/no question and return its probability of yes, without an implicit threshold.",
        ),
        #(
          "jev_batch",
          "Evaluate independent Choice, Score, and Noul questions against one state in a single HTTP request.",
        ),
      ],
      fn(definition) {
        use tool <- result.try(
          server.tool(
            definition.0,
            definition.1,
            input_schema(definition.0),
            fn(arguments) { call(definition.0, arguments, model, transport) },
          ),
        )
        server.with_output_schema(tool, output_schema(definition.0))
      },
    ),
  )
  server.new("jevelin-mcp", "0.1.0", tools)
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

fn call(
  name: String,
  arguments: JsonValue,
  model: String,
  transport: evaluation.Transport,
) -> Result(protocol.CallToolResult, server.ToolError) {
  case evaluation.call(name, arguments, model, transport) {
    Ok(value) -> Ok(server.structured(value))
    Error(evaluation.InvalidArguments as error)
    | Error(evaluation.InvalidCriteria as error) ->
      Error(server.InvalidArguments(evaluation.message(error)))
    Error(error) -> Error(server.ExecutionFailed(evaluation.message(error)))
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
