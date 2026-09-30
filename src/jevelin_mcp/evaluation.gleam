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

/// Mixed batches keep each answer's domain distinct.
pub type Answer {
  /// A selected label and a distribution validated against its alternatives.
  Choice(value: question.Choice(String))

  /// A fractional rubric index and its validated distribution.
  Score(value: question.Score)

  /// A yes probability, with no implicit threshold.
  Noul(value: probability.Probability)
}

/// Prepared arguments retain the request that owns their answer decoder.
pub opaque type Arguments(answer) {
  Arguments(
    wire: wire_json.JsonValue,
    request: jevelin.Request(jevelin.Evaluation(answer)),
    encode: fn(jevelin.Evaluation(answer)) -> Result(wire_json.JsonValue, Error),
    layout: Layout,
  )
}

/// Successful output retains both its validated domain value and wire value.
pub opaque type Output(answer) {
  Output(wire: wire_json.JsonValue, value: jevelin.Evaluation(answer))
}

/// A named, already-validated question for a mixed batch.
pub opaque type Named {
  Named(wire: wire_json.JsonValue)
}

type Layout {
  Single
  Mixed
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
  case name {
    "jev_choice" ->
      call_prepared(decode_choice(arguments, default_model), transport)
    "jev_score" ->
      call_prepared(decode_score(arguments, default_model), transport)
    "jev_noul" ->
      call_prepared(decode_noul(arguments, default_model), transport)
    "jev_batch" ->
      call_prepared(decode_mixed(arguments, default_model), transport)
    _ -> Error(InvalidArguments)
  }
}

fn call_prepared(
  args: Result(Arguments(a), Error),
  transport: Transport,
) -> Result(wire_json.JsonValue, Error) {
  use args <- result.try(args)
  use output <- result.try(execute(args, transport))
  Ok(output_json(output))
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

/// Prepares Choice arguments without exposing unrelated tool arguments.
/// Duplicate labels and invalid counts fail before a transport is admitted.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.choice(state, "jev-latest", [("review", None)], None)
/// ```
pub fn choice(
  state: Content,
  model: String,
  choices: List(#(String, Option(Content))),
  instructions: Option(Content),
) -> Result(Arguments(question.Choice(String)), Error) {
  use common <- result.try(common_arguments(state, model, instructions))
  use alternatives <- result.try(
    list.try_map(choices, fn(pair) {
      use description <- result.try(encode_optional_content(pair.1))
      Ok(
        wire_json.Object([
          #("label", wire_json.String(pair.0)),
          #("description", description),
        ]),
      )
    }),
  )
  decode_choice(
    wire_json.Object([#("choices", wire_json.Array(alternatives)), ..common]),
    model,
  )
}

/// Prepares Score arguments with two to ten ordered rubric levels.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.score(state, "jev-latest", [Text("Poor"), Text("Good")], None)
/// ```
pub fn score(
  state: Content,
  model: String,
  levels: List(Content),
  instructions: Option(Content),
) -> Result(Arguments(question.Score), Error) {
  use common <- result.try(common_arguments(state, model, instructions))
  use levels <- result.try(list.try_map(levels, encode_content))
  decode_score(
    wire_json.Object([#("levels", wire_json.Array(levels)), ..common]),
    model,
  )
}

/// Prepares Noul arguments with optional evidence for either outcome.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.noul(state, "jev-latest", None, None, None)
/// ```
pub fn noul(
  state: Content,
  model: String,
  yes: Option(Content),
  no: Option(Content),
  instructions: Option(Content),
) -> Result(Arguments(probability.Probability), Error) {
  use common <- result.try(common_arguments(state, model, instructions))
  use yes <- result.try(encode_optional_content(yes))
  use no <- result.try(encode_optional_content(no))
  decode_noul(wire_json.Object([#("yes", yes), #("no", no), ..common]), model)
}

/// Names an admitted Choice for a mixed batch.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.named_choice("queue", choice_arguments)
/// ```
pub fn named_choice(
  name: String,
  args: Arguments(question.Choice(String)),
) -> Named {
  named(name, "choice", args.wire)
}

/// Names an admitted Score for a mixed batch.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.named_score("quality", score_arguments)
/// ```
pub fn named_score(name: String, args: Arguments(question.Score)) -> Named {
  named(name, "score", args.wire)
}

/// Names an admitted Noul for a mixed batch.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.named_noul("relevant", noul_arguments)
/// ```
pub fn named_noul(
  name: String,
  args: Arguments(probability.Probability),
) -> Named {
  named(name, "noul", args.wire)
}

/// Prepares a mixed batch, rejecting empty batches and duplicate names.
/// Each named question has already passed its criteria constructor.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.mixed(state, "jev-latest", [evaluation.named_noul("relevant", args)])
/// ```
pub fn mixed(
  state: Content,
  model: String,
  questions: List(Named),
) -> Result(Arguments(List(#(String, Answer))), Error) {
  use state <- result.try(encode_content(state))
  decode_mixed(
    wire_json.Object([
      #("state", state),
      #("model", wire_json.String(model)),
      #("questions", wire_json.Array(list.map(questions, fn(q) { q.wire }))),
    ]),
    model,
  )
}

/// Decodes Choice input and constructs its request-bound answer contract.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.decode_choice(arguments, "jev-latest")
/// ```
pub fn decode_choice(
  wire: wire_json.JsonValue,
  default_model: String,
) -> Result(Arguments(question.Choice(String)), Error) {
  use input <- result.try(decode_input("jev_choice", wire, default_model))
  use named <- result.try(single_question(input))
  use alternatives <- result.try(case named.criteria {
    ChoiceCriteria(values) -> Ok(values)
    _ -> Error(InvalidArguments)
  })
  use q <- result.try(
    question.choice(instruction(named.instructions), alternatives)
    |> result.map_error(fn(_) { InvalidCriteria }),
  )
  prepare_single(wire, input, named, q, Choice)
}

/// Decodes Score input before invoking a handler.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.decode_score(arguments, "jev-latest")
/// ```
pub fn decode_score(
  wire: wire_json.JsonValue,
  default_model: String,
) -> Result(Arguments(question.Score), Error) {
  use input <- result.try(decode_input("jev_score", wire, default_model))
  use named <- result.try(single_question(input))
  use levels <- result.try(case named.criteria {
    ScoreCriteria(values) -> Ok(values)
    _ -> Error(InvalidArguments)
  })
  use q <- result.try(
    question.score(instruction(named.instructions), levels)
    |> result.map_error(fn(_) { InvalidCriteria }),
  )
  prepare_single(wire, input, named, q, Score)
}

/// Decodes Noul input before invoking a handler.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.decode_noul(arguments, "jev-latest")
/// ```
pub fn decode_noul(
  wire: wire_json.JsonValue,
  default_model: String,
) -> Result(Arguments(probability.Probability), Error) {
  use input <- result.try(decode_input("jev_noul", wire, default_model))
  use named <- result.try(single_question(input))
  use criteria <- result.try(case named.criteria {
    NoulCriteria(yes, no) -> Ok(#(yes, no))
    _ -> Error(InvalidArguments)
  })
  let q =
    question.noul_with_criteria(
      instruction(named.instructions),
      criteria.0,
      criteria.1,
    )
  prepare_single(wire, input, named, q, Noul)
}

/// Decodes and constructs every question before admitting a mixed batch.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.decode_mixed(arguments, "jev-latest")
/// ```
pub fn decode_mixed(
  wire: wire_json.JsonValue,
  default_model: String,
) -> Result(Arguments(List(#(String, Answer))), Error) {
  use input <- result.try(decode_input("jev_batch", wire, default_model))
  use questions <- result.try(list.try_map(input.questions, prepare_question))
  use request <- result.try(
    jevelin.evaluate_with_model(input.state, input.model, batch.all(questions))
    |> result.map_error(fn(_) { InvalidCriteria }),
  )
  Ok(Arguments(wire, request, encode_evaluation(_, "jev_batch"), Mixed))
}

/// Returns only the admitted tool arguments, never credentials or origins.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.arguments_json(args) is the tool codec's emitted value.
/// ```
pub fn arguments_json(args: Arguments(a)) -> wire_json.JsonValue {
  args.wire
}

/// Returns output validated by the original Jevelin request.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.output_value(choice_output).answers.selected
/// ```
pub fn output_value(output: Output(a)) -> jevelin.Evaluation(a) {
  output.value
}

/// Returns the schema-checked structured result for the tool encoder.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.output_json(output) preserves the public tool result.
/// ```
pub fn output_json(output: Output(a)) -> wire_json.JsonValue {
  output.wire
}

/// Executes exactly one request and retains its typed, validated answer.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.execute(args, transport) returns Output with args' answer type.
/// ```
pub fn execute(
  args: Arguments(a),
  transport: Transport,
) -> Result(Output(a), Error) {
  use value <- result.try(
    jevelin.send(args.request, transport) |> result.map_error(public_error),
  )
  use wire <- result.try(args.encode(value))
  Ok(Output(wire, value))
}

/// Decodes an MCP result with the request carried by its original arguments.
/// A response with unrelated labels, names, or rubric bounds cannot succeed.
///
/// ## Examples
///
/// ```gleam
/// // evaluation.decode_output(original_args, received_structured_content)
/// ```
pub fn decode_output(
  args: Arguments(a),
  wire: wire_json.JsonValue,
) -> Result(Output(a), Error) {
  use model <- result.try(
    field(wire, "model") |> result.map_error(fn(_) { InvalidAnswer }),
  )
  use usage <- result.try(
    field(wire, "usage") |> result.map_error(fn(_) { InvalidAnswer }),
  )
  use answers <- result.try(
    case args.layout {
      Single ->
        field(wire, "answer")
        |> result.map(fn(answer) { wire_json.Object([#("result", answer)]) })
      Mixed -> field(wire, "answers")
    }
    |> result.map_error(fn(_) { InvalidAnswer }),
  )
  let body =
    wire_json.to_string(
      wire_json.Object([
        #("model", model),
        #("usage", usage),
        #("answers", answers),
      ]),
    )

  // The request's decoder is also the client's proof that this result belongs
  // to these exact criteria, including after an MCP continuation is resumed.
  use value <- result.try(
    jevelin.decode_response(args.request, jevelin.HttpResponse(200, [], body))
    |> result.map_error(fn(_) { InvalidAnswer }),
  )
  Ok(Output(wire, value))
}

fn decode_input(
  name: String,
  wire: wire_json.JsonValue,
  model: String,
) -> Result(Input, Error) {
  use Nil <- result.try(validate_arguments(name, wire))
  json.parse(wire_json.to_string(wire), input_decoder(name, model))
  |> result.map_error(fn(_) { InvalidArguments })
}

fn single_question(input: Input) -> Result(NamedQuestion, Error) {
  case input.questions {
    [named] -> Ok(named)
    _ -> Error(InvalidArguments)
  }
}

fn prepare_single(
  wire: wire_json.JsonValue,
  input: Input,
  named: NamedQuestion,
  q: question.Question(a),
  wrap: fn(a) -> Answer,
) -> Result(Arguments(a), Error) {
  let q = case named.instructions {
    Some(_) -> q
    None -> question.without_instructions(q)
  }
  use request <- result.try(
    jevelin.evaluate_with_model(
      input.state,
      input.model,
      batch.question("result", q),
    )
    |> result.map_error(fn(_) { InvalidCriteria }),
  )
  let encode = fn(output: jevelin.Evaluation(a)) {
    encode_evaluation(
      jevelin.Evaluation(
        output.model,
        [#("result", wrap(output.answers))],
        output.usage,
      ),
      "single",
    )
  }
  Ok(Arguments(wire, request, encode, Single))
}

fn encode_content(value: Content) -> Result(wire_json.JsonValue, Error) {
  content.encode(value)
  |> json.to_string
  |> wire_json.parse
  |> result.map_error(fn(_) { InvalidArguments })
}

fn encode_optional_content(
  value: Option(Content),
) -> Result(wire_json.JsonValue, Error) {
  case value {
    Some(value) -> encode_content(value)
    None -> Ok(wire_json.Null)
  }
}

fn common_arguments(
  state: Content,
  model: String,
  instructions: Option(Content),
) -> Result(List(#(String, wire_json.JsonValue)), Error) {
  use state <- result.try(encode_content(state))
  use instructions <- result.try(encode_optional_content(instructions))
  Ok([
    #("state", state),
    #("model", wire_json.String(model)),
    #("instructions", instructions),
  ])
}

fn named(name: String, kind: String, wire: wire_json.JsonValue) -> Named {
  let fields = case wire {
    wire_json.Object(fields) ->
      list.filter(fields, fn(pair) { pair.0 != "state" && pair.0 != "model" })
    _ -> []
  }
  Named(
    wire_json.Object([
      #("name", wire_json.String(name)),
      #("type", wire_json.String(kind)),
      ..fields
    ]),
  )
}
