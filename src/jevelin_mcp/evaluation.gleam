//// Prepared arguments keep the criteria and their answer decoder together.
//// MCP starts with untrusted JSON; Jevelin's smart constructors admit the criteria
//// and build a request whose decoder closes over them. This module keeps that
//// request until either a local transport response or a remote MCP result arrives.
//// Neither path can substitute a general answer decoder for the original one.
////
//// The lowercase `answer` in `Arguments(answer)` and `Output(answer)` is a type
//// parameter: a Choice call returns a Choice, while a Noul call returns a
//// Probability. That static relationship cannot encode a particular label list,
//// so the opaque record also retains the request's runtime decoder. In Gleam,
//// `opaque` exports the type while keeping its constructor private to this module.
////
//// Mixed batches use `Answer` to put different answer types in one homogeneous
//// list. Each question's decoder validates its own answer before `batch.map`
//// wraps it in Choice, Score, or Noul. `batch.all` then combines those decoders;
//// wrapping never replaces validation with a generic JSON pass-through.
////
//// ## Flow
////
//// 1. `call` dispatches raw tool JSON, or `choice`, `score`, `noul`, and `mixed`
////    prepare the same wire shape for a typed Gleam caller.
//// 2. `decode_choice`, `decode_score`, `decode_noul`, and `decode_mixed` enter
////    `decode_input`: allowed fields are checked before the content decoder runs.
//// 3. `prepare_single` or `prepare_question` couples a Jevelin question to its
////    answer decoder. `jevelin.evaluate_with_model` admits the final model and batch.
//// 4. `execute` invokes `jevelin.send` once through the caller's transport.
////    Jevelin decodes the HTTP response with the retained request.
//// 5. `encode_evaluation` and `encode_answer` project validated domain answers
////    into the MCP result. `output_value` retains the domain value for Gleam callers.
//// 6. A typed MCP client uses `decode_output` with its original Arguments. It
////    reconstructs the Jevelin envelope and runs that request's decoder again.
////
//// ## Boundaries
////
//// No environment lookup, HTTP client, process, credential, or origin lives here.
//// Passing a function does not make preparation effectful: only `execute` or
//// `call` invokes the injected transport. Their public errors discard provider
//// bodies and parser diagnostics through `public_error` and `message`.
////
//// Request-bound decoding enforces answer shape and criteria constraints, not
//// semantic provenance. Equal label/name sets or equal rubric sizes can admit the
//// same answer shape for different states. Score validates its numeric range, probabilities,
//// and legend keys; it does not compare returned legend content with input levels.
//// The server's tool codec separately checks the advertised JSON Schema.

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
  UpstreamRejected(
    /// The HTTP status only; response headers and body are discarded.
    status: Int,
  )

  /// A successful HTTP body failed the request-bound answer decoder.
  InvalidAnswer

  /// The HTTP adapter failed before a usable response was available.
  TransportFailed(
    /// The adapter's safe category, without the native HTTP error.
    reason: TransportError,
  )
}

/// A caller-owned transport performs exactly one attempt per evaluation.
pub type Transport =
  fn(jevelin.HttpRequest) -> Result(jevelin.HttpResponse, TransportError)

/// Mixed batches keep each answer's domain distinct.
pub type Answer {
  /// A selected label and a distribution validated against its alternatives.
  Choice(
    /// The selected string label and probabilities in request order.
    value: question.Choice(String),
  )

  /// A fractional rubric index and its validated distribution.
  Score(
    /// A value bounded by the original rubric length, plus its legend and mass.
    value: question.Score,
  )

  /// A yes probability, with no implicit threshold.
  Noul(
    /// A validated value in [0, 1]; callers choose any decision threshold.
    value: probability.Probability,
  )
}

/// Admitted tool input paired with its exact request and result projection.
/// The private constructor prevents callers from mixing a wire value, request,
/// and encoder that were prepared for different answer types or criteria.
pub opaque type Arguments(answer) {
  /// Only the preparation functions can assemble this contract.
  Arguments(
    /// The admitted MCP input, used by the shared argument codec.
    wire: wire_json.JsonValue,
    /// Jevelin's request retains the decoder justified by these criteria.
    request: jevelin.Request(jevelin.Evaluation(answer)),
    /// The matching projection from that decoder's answer to public JSON.
    encode: fn(jevelin.Evaluation(answer)) -> Result(wire_json.JsonValue, Error),
    /// Whether MCP exposes one answer or an object of named answers.
    layout: Layout,
  )
}

/// An answer that passed a retained Jevelin request's decoder.
/// Both representations stay available so Gleam callers can use domain values
/// and MCP can encode structured content without repeating provider I/O.
pub opaque type Output(answer) {
  /// Constructed only after request-bound validation succeeds.
  Output(
    /// The public MCP representation, with no provider headers or error body.
    wire: wire_json.JsonValue,
    /// The decoded answer, resolved model name, and reported token usage.
    value: jevelin.Evaluation(answer),
  )
}

/// Criteria from an admitted single question, given a mixed-batch name.
/// Naming alone does not prove uniqueness: `mixed` admits the final name set.
/// A single question's state and model are omitted so the batch owns both.
pub opaque type Named {
  /// Constructed from a typed Arguments value, never arbitrary JSON.
  Named(
    /// Type-specific criteria, optional instructions, name, and kind.
    wire: wire_json.JsonValue,
  )
}

// A single answer uses the private Jevelin name "result". Mixed answers retain
// their public names. This distinction is data, so result decoding cannot infer
// a layout from whichever fields an untrusted response happens to contain.
type Layout {
  Single
  Mixed
}

// Wire decoding identifies the domain before smart constructors admit it.
// Lists preserve duplicate labels and names until Jevelin can reject them;
// converting to a dictionary here would silently erase the invalid input.
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

/// Admits raw JSON for a known tool, performs one transport attempt, and returns
/// its validated public result. Unknown tools and invalid inputs fail before the
/// transport function is called. Typed server handlers use `execute` directly.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.call("unknown", wire_json.Null, "jev-latest", fn(_) {
///   Error(evaluation.Unavailable)
/// }) == Error(evaluation.InvalidArguments)
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

/// Prepares Choice arguments with one to 255 distinct labels. The selected label
/// remains a String, and the request retains the decoder for this exact label set.
/// The constructor follows the same wire admission path as remote MCP inputs;
/// invalid counts or duplicate labels fail before any transport can run.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.choice(content.Text("Build failed"), "jev-latest", [], None)
///   == Error(evaluation.InvalidCriteria)
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

/// Prepares Score arguments with two to ten ordered rubric levels. The answer is
/// a fractional index in [0, level_count - 1], not an enum selecting one level.
/// The retained decoder also checks the corresponding legend and probability keys.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.score(content.Text("Build failed"), "jev-latest", [
///   content.Text("Poor"),
/// ], None) == Error(evaluation.InvalidCriteria)
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

/// Prepares a yes/no probability question with optional content for each outcome.
/// The Probability answer carries no implicit yes/no threshold. Omitted criteria
/// and instructions remain absent upstream; they do not become invented text.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_ok(evaluation.noul(content.Text("Build failed"), "jev-latest",
///   None, None, None))
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

/// Names an admitted Choice for a mixed batch, retaining its criteria and optional
/// instructions. The single question's state and model are dropped because the
/// batch supplies one state and model for every question. `mixed` checks names.
///
/// ## Examples
///
/// ```gleam
/// let question = evaluation.named_choice("route", args)
/// evaluation.mixed(content.Text("Batch state"), "jev-latest", [question])
/// // -> Ok(batch_args) when args was admitted. No transport runs.
/// ```
pub fn named_choice(
  name: String,
  args: Arguments(question.Choice(String)),
) -> Named {
  named(name, "choice", args.wire)
}

/// Names an admitted Score for a mixed batch, retaining its criteria and optional
/// instructions. The single question's state and model are dropped because the
/// batch supplies one state and model for every question. `mixed` checks names.
///
/// ## Examples
///
/// ```gleam
/// let question = evaluation.named_score("quality", args)
/// evaluation.mixed(content.Text("Batch state"), "jev-latest", [question])
/// // -> Ok(batch_args) when args was admitted. No transport runs.
/// ```
pub fn named_score(name: String, args: Arguments(question.Score)) -> Named {
  named(name, "score", args.wire)
}

/// Names an admitted Noul for a mixed batch, retaining its criteria and optional
/// instructions. The single question's state and model are dropped because the
/// batch supplies one state and model for every question. `mixed` checks names.
///
/// ## Examples
///
/// ```gleam
/// let question = evaluation.named_noul("relevant", args)
/// evaluation.mixed(content.Text("Batch state"), "jev-latest", [question])
/// // -> Ok(batch_args) when args was admitted. No transport runs.
/// ```
pub fn named_noul(
  name: String,
  args: Arguments(probability.Probability),
) -> Named {
  named(name, "noul", args.wire)
}

/// Prepares every named question before admitting one mixed-batch request.
/// Empty batches and duplicate names fail here. Each element already came from
/// a typed single question, then passes the same criteria constructors again as
/// untrusted mixed JSON. Output order follows question order, not response order.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.mixed(content.Text("Batch state"), "jev-latest", [])
///   == Error(evaluation.InvalidCriteria)
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

fn named(name: String, kind: String, wire: wire_json.JsonValue) -> Named {
  // A Named value moves only the question into batch custody. State and model
  // belong to the final request, so retaining either from the single request
  // would imply per-question values that the provider never receives.
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

/// Admits Choice JSON, then pairs its original label set with Jevelin's Choice
/// decoder. Field admission and content decoding prove shape; `question.choice`
/// separately proves count and uniqueness. No transport is invoked.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.decode_choice(wire_json.Null, "jev-latest")
///   == Error(evaluation.InvalidArguments)
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

/// Admits Score JSON and builds the decoder for the original rubric length.
/// Malformed content fails as InvalidArguments; a decoded list outside the two
/// to ten level contract fails as InvalidCriteria. No transport is invoked.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.decode_score(wire_json.Null, "jev-latest")
///   == Error(evaluation.InvalidArguments)
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

/// Admits Noul JSON and prepares a Probability answer with optional yes/no
/// criteria. The default model is used only when the model field is absent;
/// a present model must decode as a String and pass Jevelin's model constructor.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.decode_noul(wire_json.Object([
///   #("state", wire_json.String("Relevant passage")),
///   #("model", wire_json.String("")),
/// ]), "jev-latest") == Error(evaluation.InvalidCriteria)
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

/// Admits all mixed JSON questions before constructing the final batch request.
/// Each question decoder retains its own criteria and maps its valid answer into
/// Answer. Jevelin then checks the complete batch's names and model before effects.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.decode_mixed(wire_json.Object([
///   #("state", wire_json.String("Batch state")),
///   #("questions", wire_json.Array([])),
/// ]), "jev-latest") == Error(evaluation.InvalidCriteria)
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

fn decode_input(
  name: String,
  wire: wire_json.JsonValue,
  model: String,
) -> Result(Input, Error) {
  // Admission precedes the JSON-library conversion. Reusing this path for
  // typed builders prevents local callers from acquiring a weaker contract.
  use Nil <- result.try(validate_arguments(name, wire))
  json.parse(wire_json.to_string(wire), input_decoder(name, model))
  |> result.map_error(fn(_) { InvalidArguments })
}

fn validate_arguments(
  name: String,
  arguments: wire_json.JsonValue,
) -> Result(Nil, Error) {
  // Total field decoders establish required values but allow unrelated fields.
  // This separate whitelist rejects credential, origin, and misspelled fields
  // before their values can be discarded by that more permissive decoder.
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

fn input_decoder(name: String, default_model: String) -> Decoder(Input) {
  // `use` passes the remainder as the decoder's continuation. Each field must
  // succeed before Input can exist; malformed fields never use the defaults.
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
  // Absence and JSON null both mean no instructions. A wrong present type
  // remains a decoder failure, rather than silently discarding supplied content.
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

fn alternative_decoder() -> Decoder(question.Alternative(String)) {
  use label <- decode.field("label", decode.string)
  use description <- decode.optional_field(
    "description",
    None,
    optional_content(),
  )
  decode.success(question.Alternative(label:, value: label, description:))
}

fn optional_content() -> Decoder(Option(Content)) {
  decode.optional(content.decoder())
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

fn instruction(instructions: Option(Content)) -> Content {
  option.unwrap(instructions, Text(""))
}

fn prepare_question(
  named: NamedQuestion,
) -> Result(batch.Batch(#(String, Answer)), Error) {
  // The criteria variant selects both the smart constructor and the matching
  // Answer wrapper. The type checker rejects pairing a Score question with
  // Choice, even though both become Answer only after decoding succeeds.
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

fn named_batch(
  named: NamedQuestion,
  q: question.Question(a),
  wrap: fn(a) -> Answer,
) -> batch.Batch(#(String, Answer)) {
  // Jevelin's constructors take Content, so an empty value is only a local
  // placeholder. Explicit omission removes the upstream field without changing
  // the already-built answer decoder.
  let q = case named.instructions {
    Some(_) -> q
    None -> question.without_instructions(q)
  }
  batch.question(named.name, q)
  |> batch.map(fn(answer) { #(named.name, wrap(answer)) })
}

/// Invokes one caller-owned transport attempt, validates the response with the
/// request inside args, and encodes the validated answer. The shared type variable
/// a connects Arguments(a) to Output(a); the retained decoder adds the runtime
/// criteria constraints that the type variable cannot express. Errors retain only
/// public categories. Cancellation and native effect lifetime belong to transport.
///
/// ## Examples
///
/// ```gleam
/// evaluation.execute(args, transport)
/// // -> Ok(output) with args' answer type, or a safe evaluation error.
/// ```
pub fn execute(
  args: Arguments(a),
  transport: Transport,
) -> Result(Output(a), Error) {
  // `result.try` runs the rest only for Ok. A refused transport or decoder
  // therefore cannot enter the success encoder, and there is no hidden retry.
  use value <- result.try(
    jevelin.send(args.request, transport) |> result.map_error(public_error),
  )
  use wire <- result.try(args.encode(value))
  Ok(Output(wire, value))
}

fn public_error(error: jevelin.Error(TransportError)) -> Error {
  // Jevelin preserves native transport failures and complete HTTP error bodies.
  // This application owns disclosure, so only a safe category or status leaves
  // the adapter. Parser paths and the provider's text are deliberately dropped.
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
  // A valid domain answer crosses JSON libraries here: Jevelin uses gleam_json,
  // while MCP uses JsonValue. The conversion can fail, so every projection stays
  // in Result rather than assuming an encoder cannot reject data.
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

/// Validates remote MCP structured content against the request in original args.
/// Single and mixed MCP layouts become the same Jevelin response envelope, then
/// the retained decoder checks labels, index bounds, names, and probabilities.
/// No network call occurs. The shared tool's codec checks JSON Schema first;
/// calling this function directly performs Jevelin validation only.
///
/// The decoder proves those constraints, not the provider's semantic use of state
/// or instructions. Equal label sets or equal rubric lengths can admit the same
/// answer shape. Score legend descriptions are decoded but not compared to inputs.
///
/// ## Examples
///
/// ```gleam
/// assert evaluation.decode_output(args, wire_json.Null)
///   == Error(evaluation.InvalidAnswer)
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

  // Reusing the request checks its labels, name set, and rubric bounds even
  // after an MCP continuation. No independent decoder can drop those checks.
  // This is a criteria check; it cannot prove the provider used the input state.
  use value <- result.try(
    jevelin.decode_response(args.request, jevelin.HttpResponse(200, [], body))
    |> result.map_error(fn(_) { InvalidAnswer }),
  )
  Ok(Output(wire, value))
}

/// Returns the admitted MCP input for the shared argument encoder. The opaque
/// Arguments constructor guarantees it came through preparation. The value can
/// contain sensitive evaluation content; absence of credentials does not make
/// state or instructions safe to log.
///
/// ## Examples
///
/// ```gleam
/// evaluation.arguments_json(args)
/// // -> The original admitted tool JSON, with no transport configuration.
/// ```
pub fn arguments_json(args: Arguments(a)) -> wire_json.JsonValue {
  args.wire
}

/// Returns the typed answer plus model provenance and usage, without rerunning
/// transport or decoding. Choice exposes its selected string and distribution;
/// Noul exposes a Probability that callers can interpret with their own policy.
///
/// ## Examples
///
/// ```gleam
/// evaluation.output_value(choice_output).answers.selected
/// // -> A String selected from the original Choice labels.
/// ```
pub fn output_value(output: Output(a)) -> jevelin.Evaluation(a) {
  output.value
}

/// Returns the public JSON retained alongside the validated domain answer.
/// The shared tool codec applies its output schema when encoding this value;
/// this accessor performs no additional validation and no transport effect.
///
/// ## Examples
///
/// ```gleam
/// evaluation.output_json(output)
/// // -> The retained single-answer or named-batch MCP result.
/// ```
pub fn output_json(output: Output(a)) -> wire_json.JsonValue {
  output.wire
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
  // Matching every category keeps a new failure from accidentally disclosing
  // dependency diagnostics through a generic string conversion.
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
