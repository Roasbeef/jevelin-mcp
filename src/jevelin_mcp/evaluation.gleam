//// MCP arguments are untrusted JSON, while Jevelin requests carry the decoder
//// justified by their criteria. This adapter crosses that boundary once, before
//// invoking transport. Mixed batches project each typed answer into an explicit
//// sum type, preserving Jevelin's validation rather than passing raw HTTP JSON
//// through as a successful tool result.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/json as wire_json
import jevelin
import jevelin/batch
import jevelin/content.{type Content, Text}
import jevelin/probability
import jevelin/question

/// Transport failures contain only a public category, never native diagnostics.
pub type TransportError {
  /// The HTTP connection failed or reached its deadline.
  Unavailable

  /// The complete response exceeds the accepted byte limit.
  ResponseTooLarge

  /// The response body is not UTF-8.
  InvalidUtf8

  /// The service echoed the credential into its response.
  CredentialInResponse
}

/// All evaluation failures can be rendered without retaining request content.
pub type Error {
  /// The arguments do not satisfy the advertised tool contract.
  InvalidArguments

  /// A local smart constructor rejected the question or batch.
  InvalidCriteria

  /// HTTP completed with a non-success status; its body stays private.
  UpstreamRejected(status: Int)

  /// A successful HTTP body failed the request-bound answer decoder.
  InvalidAnswer

  /// The HTTP adapter failed before a usable response was available.
  TransportFailed(reason: TransportError)
}

/// A caller-owned transport performs exactly one attempt per evaluation.
pub type Transport =
  fn(jevelin.HttpRequest) -> Result(jevelin.HttpResponse, TransportError)

type Answer {
  Choice(value: question.Choice(String))
  Score(value: question.Score)
  Noul(value: probability.Probability)
}

type Criteria {
  ChoiceCriteria(alternatives: List(question.Alternative(String)))
  ScoreCriteria(levels: List(Content))
  NoulCriteria(yes: Option(Content), no: Option(Content))
}

type NamedQuestion {
  NamedQuestion(name: String, instructions: Option(Content), criteria: Criteria)
}

type Input {
  Input(state: Content, model: String, questions: List(NamedQuestion))
}

/// Evaluates a known tool through the injected transport, returning validated
/// output. Arguments are completely decoded and constructed before HTTP starts.
///
/// ## Examples
///
/// ```gleam
/// evaluation.call("jev_noul", arguments, "jev-latest", transport)
/// // -> Ok(output) or Error(evaluation.Error).
/// ```
pub fn call(
  name: String,
  arguments: wire_json.JsonValue,
  default_model: String,
  transport: Transport,
) -> Result(wire_json.JsonValue, Error) {
  use _ <- result.try(validate_arguments(name, arguments))
  case name {
    "jev_choice" | "jev_score" | "jev_noul" | "jev_batch" -> {
      use input <- result.try(
        json.parse(
          wire_json.to_string(arguments),
          input_decoder(name, default_model),
        )
        |> result.map_error(fn(_) { InvalidArguments }),
      )
      use questions <- result.try(list.try_map(
        input.questions,
        prepare_question,
      ))
      use request <- result.try(
        jevelin.evaluate_with_model(
          input.state,
          input.model,
          batch.all(questions),
        )
        |> result.map_error(fn(_) { InvalidCriteria }),
      )

      // The response decoder remains attached to the original criteria through
      // transport. Its public projections are the only values serialized below.
      use output <- result.try(
        jevelin.send(request, transport) |> result.map_error(public_error),
      )
      encode_evaluation(output, name)
    }
    _ -> Error(InvalidArguments)
  }
}

/// Renders a failure using fixed descriptions and a numeric HTTP status.
/// Provider bodies, parser diagnostics, and transport details remain private.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.message(evaluation.UpstreamRejected(429))
///   == "Jev rejected the request with HTTP status 429."
/// ```
pub fn message(error: Error) -> String {
  case error {
    InvalidArguments -> "Arguments do not match this tool's input schema."
    InvalidCriteria -> "Question criteria or batch names are invalid."
    UpstreamRejected(status) ->
      "Jev rejected the request with HTTP status "
      <> int.to_string(status)
      <> "."
    InvalidAnswer -> "Jev returned an answer that does not match the request."
    TransportFailed(Unavailable) -> "The Jev HTTP request failed or timed out."
    TransportFailed(ResponseTooLarge) ->
      "The Jev HTTP response exceeds the byte limit."
    TransportFailed(InvalidUtf8) -> "The Jev HTTP response is not UTF-8."
    TransportFailed(CredentialInResponse) ->
      "The Jev HTTP response could not be disclosed."
  }
}

fn input_decoder(name: String, default_model: String) -> Decoder(Input) {
  use state <- decode.field("state", content.decoder())
  use model <- decode.optional_field("model", default_model, decode.string)
  use questions <- decode.then(case name {
    "jev_batch" ->
      decode.at(["questions"], decode.list(named_question_decoder()))
    "jev_choice" ->
      decode.map(question_decoder("choice", "result"), fn(q) { [q] })
    "jev_score" ->
      decode.map(question_decoder("score", "result"), fn(q) { [q] })
    "jev_noul" -> decode.map(question_decoder("noul", "result"), fn(q) { [q] })
    _ -> decode.failure([], "a known evaluation tool")
  })
  decode.success(Input(state:, model:, questions:))
}

fn named_question_decoder() -> Decoder(NamedQuestion) {
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("type", decode.string)
  question_decoder(kind, name)
}

fn question_decoder(kind: String, name: String) -> Decoder(NamedQuestion) {
  use instructions <- decode.optional_field(
    "instructions",
    None,
    optional_content(),
  )
  use criteria <- decode.then(case kind {
    "choice" ->
      decode.map(
        decode.at(["choices"], decode.list(alternative_decoder())),
        ChoiceCriteria,
      )
    "score" ->
      decode.map(
        decode.at(["levels"], decode.list(content.decoder())),
        ScoreCriteria,
      )
    "noul" -> {
      use yes <- decode.optional_field("yes", None, optional_content())
      use no <- decode.optional_field("no", None, optional_content())
      decode.success(NoulCriteria(yes:, no:))
    }
    _ -> decode.failure(NoulCriteria(None, None), "choice, score, or noul")
  })
  decode.success(NamedQuestion(name:, instructions:, criteria:))
}

fn optional_content() -> Decoder(Option(Content)) {
  decode.optional(content.decoder())
}

fn alternative_decoder() -> Decoder(question.Alternative(String)) {
  use label <- decode.field("label", decode.string)
  use description <- decode.optional_field(
    "description",
    None,
    optional_content(),
  )
  decode.success(question.Alternative(label:, value: label, description:))
}

fn prepare_question(
  named: NamedQuestion,
) -> Result(batch.Batch(#(String, Answer)), Error) {
  case named.criteria {
    ChoiceCriteria(alternatives) -> {
      use q <- result.try(
        question.choice(instruction(named.instructions), alternatives)
        |> result.map_error(fn(_) { InvalidCriteria }),
      )
      Ok(named_batch(named, q, Choice))
    }
    ScoreCriteria(levels) -> {
      use q <- result.try(
        question.score(instruction(named.instructions), levels)
        |> result.map_error(fn(_) { InvalidCriteria }),
      )
      Ok(named_batch(named, q, Score))
    }
    NoulCriteria(yes, no) ->
      Ok(named_batch(
        named,
        question.noul_with_criteria(instruction(named.instructions), yes, no),
        Noul,
      ))
  }
}

fn instruction(instructions: Option(Content)) -> Content {
  option.unwrap(instructions, Text(""))
}

fn named_batch(
  named: NamedQuestion,
  q: question.Question(a),
  wrap: fn(a) -> Answer,
) -> batch.Batch(#(String, Answer)) {
  let q = case named.instructions {
    Some(_) -> q
    None -> question.without_instructions(q)
  }
  batch.question(named.name, q)
  |> batch.map(fn(answer) { #(named.name, wrap(answer)) })
}

fn public_error(error: jevelin.Error(TransportError)) -> Error {
  case error {
    jevelin.TransportFailed(reason) -> TransportFailed(reason)
    jevelin.ResponseFailed(jevelin.HttpFailure(response)) ->
      UpstreamRejected(response.status)
    jevelin.ResponseFailed(jevelin.InvalidResponse(_)) -> InvalidAnswer
  }
}

fn encode_evaluation(
  output: jevelin.Evaluation(List(#(String, Answer))),
  name: String,
) -> Result(wire_json.JsonValue, Error) {
  use answers <- result.try(
    list.try_map(output.answers, fn(named) {
      use answer <- result.try(encode_answer(named.1))
      Ok(#(named.0, answer))
    }),
  )
  use fields <- result.try(case name, answers {
    "jev_batch", answers -> Ok([#("answers", wire_json.Object(answers))])
    _, [#(_, answer)] -> Ok([#("answer", answer)])
    _, _ -> Error(InvalidAnswer)
  })
  Ok(
    wire_json.Object([
      #("model", wire_json.String(output.model)),
      #(
        "usage",
        wire_json.Object([
          #("input_tokens", wire_json.Int(output.usage.input_tokens)),
          #("output_tokens", wire_json.Int(output.usage.output_tokens)),
        ]),
      ),
      ..fields
    ]),
  )
}

fn encode_answer(answer: Answer) -> Result(wire_json.JsonValue, Error) {
  case answer {
    Noul(p) ->
      Ok(
        wire_json.Object([
          #("type", wire_json.String("noul")),
          #("noul", wire_json.Float(probability.value(p))),
        ]),
      )
    Choice(value) ->
      Ok(
        wire_json.Object([
          #("type", wire_json.String("choice")),
          #("choice", wire_json.String(value.selected)),
          #("confidence", wire_json.Float(probability.value(value.confidence))),
          #(
            "probabilities",
            wire_json.Object(
              list.map(value.probabilities, fn(pair) {
                #(pair.0, wire_json.Float(probability.value(pair.1)))
              }),
            ),
          ),
        ]),
      )
    Score(value) -> {
      use legend <- result.try(
        list.try_map(dict.to_list(value.legend), fn(pair) {
          use encoded <- result.try(
            content.encode(pair.1)
            |> json.to_string
            |> wire_json.parse
            |> result.map_error(fn(_) { InvalidAnswer }),
          )
          Ok(#(pair.0, encoded))
        }),
      )
      Ok(
        wire_json.Object([
          #("type", wire_json.String("score")),
          #("score", wire_json.Float(value.value)),
          #("confidence", wire_json.Float(probability.value(value.confidence))),
          #("legend", wire_json.Object(legend)),
          #(
            "probabilities",
            wire_json.Object(
              list.map(dict.to_list(value.probabilities), fn(pair) {
                #(pair.0, wire_json.Float(probability.value(pair.1)))
              }),
            ),
          ),
        ]),
      )
    }
  }
}

fn validate_arguments(
  name: String,
  arguments: wire_json.JsonValue,
) -> Result(Nil, Error) {
  let common = ["state", "model", "instructions"]
  case name {
    "jev_choice" -> validate_choice(arguments, common)
    "jev_score" -> fields_allowed(arguments, ["levels", ..common])
    "jev_noul" -> fields_allowed(arguments, ["yes", "no", ..common])
    "jev_batch" -> {
      use _ <- result.try(
        fields_allowed(arguments, ["state", "model", "questions"]),
      )
      use questions <- result.try(field(arguments, "questions"))
      case questions {
        wire_json.Array(questions) ->
          list.try_each(questions, fn(q) {
            use kind <- result.try(field(q, "type"))
            let common = ["name", "type", "instructions"]
            case kind {
              wire_json.String("choice") -> validate_choice(q, common)
              wire_json.String("score") ->
                fields_allowed(q, ["levels", ..common])
              wire_json.String("noul") ->
                fields_allowed(q, ["yes", "no", ..common])
              _ -> Error(InvalidArguments)
            }
          })
        _ -> Error(InvalidArguments)
      }
    }
    _ -> Error(InvalidArguments)
  }
}

fn validate_choice(
  value: wire_json.JsonValue,
  common: List(String),
) -> Result(Nil, Error) {
  use _ <- result.try(fields_allowed(value, ["choices", ..common]))
  use alternatives <- result.try(field(value, "choices"))
  case alternatives {
    wire_json.Array(alternatives) ->
      list.try_each(alternatives, fn(a) {
        fields_allowed(a, ["label", "description"])
      })
    _ -> Error(InvalidArguments)
  }
}

fn fields_allowed(
  value: wire_json.JsonValue,
  allowed: List(String),
) -> Result(Nil, Error) {
  case value {
    wire_json.Object(fields) ->
      case list.all(fields, fn(pair) { list.contains(allowed, pair.0) }) {
        True -> Ok(Nil)
        False -> Error(InvalidArguments)
      }
    _ -> Error(InvalidArguments)
  }
}

fn field(
  value: wire_json.JsonValue,
  name: String,
) -> Result(wire_json.JsonValue, Error) {
  case value {
    wire_json.Object(fields) ->
      list.find(fields, fn(pair) { pair.0 == name })
      |> result.map(fn(pair) { pair.1 })
      |> result.map_error(fn(_) { InvalidArguments })
    _ -> Error(InvalidArguments)
  }
}
