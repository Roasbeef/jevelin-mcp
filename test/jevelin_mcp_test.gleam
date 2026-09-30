import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam_mcp/json.{Array, Bool, Float, Int, Null, Object, String}
import gleeunit
import jevelin
import jevelin/content
import jevelin/probability
import jevelin_mcp/evaluation
import jevelin_mcp/http
import jevelin_mcp/tool

pub fn main() -> Nil {
  gleeunit.main()
}

fn arguments(fields: List(#(String, json.JsonValue))) -> json.JsonValue {
  Object([#("state", String("fixture state")), ..fields])
}

fn reply(answers: String) -> jevelin.HttpResponse {
  jevelin.HttpResponse(
    200,
    [],
    "{\"model\":\"jev-1.13.0\",\"answers\":"
      <> answers
      <> ",\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}",
  )
}

fn never_called(
  _: jevelin.HttpRequest,
) -> Result(jevelin.HttpResponse, evaluation.TransportError) {
  panic as "Invalid arguments must fail before transport."
}

pub fn choices_use_smart_constructors_before_transport_test() -> Nil {
  let choice = Object([#("label", String("review"))])
  list.each([[], [choice, choice], list.repeat(choice, 256)], fn(choices) {
    assert evaluation.call(
        "jev_choice",
        arguments([#("choices", Array(choices))]),
        "jev-latest",
        never_called,
      )
      == Error(evaluation.InvalidCriteria)
  })
}

pub fn score_rubric_bounds_fail_before_transport_test() -> Nil {
  list.each([0, 1, 11], fn(count) {
    assert evaluation.call(
        "jev_score",
        arguments([#("levels", Array(list.repeat(String("level"), count)))]),
        "jev-latest",
        never_called,
      )
      == Error(evaluation.InvalidCriteria)
  })
}

pub fn batch_names_and_model_fail_before_transport_test() -> Nil {
  let q = Object([#("name", String("same")), #("type", String("noul"))])
  list.each([[], [q, q]], fn(questions) {
    assert evaluation.call(
        "jev_batch",
        arguments([#("questions", Array(questions))]),
        "jev-latest",
        never_called,
      )
      == Error(evaluation.InvalidCriteria)
  })
  assert evaluation.call(
      "jev_noul",
      arguments([#("model", String(" \n"))]),
      "jev-latest",
      never_called,
    )
    == Error(evaluation.InvalidCriteria)
}

pub fn input_shape_and_extra_fields_fail_before_transport_test() -> Nil {
  let invalid = [
    Int(1),
    Bool(True),
    Null,
    Array([]),
    Object([#("state", Int(2))]),
    arguments([#("api_key", String("forbidden"))]),
    arguments([#("endpoint", String("https://untrusted.example"))]),
    arguments([#("instructions", Bool(False))]),
  ]
  list.each(invalid, fn(value) {
    assert evaluation.call("jev_noul", value, "jev-latest", never_called)
      == Error(evaluation.InvalidArguments)
  })
  assert evaluation.call(
      "jev_choice",
      arguments([
        #(
          "choices",
          Array([
            Object([
              #("label", String("review")),
              #("endpoint", String("bad")),
            ]),
          ]),
        ),
      ]),
      "jev-latest",
      never_called,
    )
    == Error(evaluation.InvalidArguments)
  assert evaluation.call(
      "jev_batch",
      arguments([
        #(
          "questions",
          Array([
            Object([
              #("name", String("q")),
              #("type", String("noul")),
              #("levels", Array([])),
            ]),
          ]),
        ),
      ]),
      "jev-latest",
      never_called,
    )
    == Error(evaluation.InvalidArguments)
}

pub fn noul_keeps_structured_state_and_optional_criteria_test() -> Nil {
  let input =
    Object([
      #("state", Object([#("record", Array([String("hello"), Null]))])),
      #("yes", Object([#("required", Bool(True))])),
      #("model", String("jev-1.13.0")),
    ])
  let assert Ok(output) =
    evaluation.call("jev_noul", input, "ignored", fn(request) {
      assert request.method == jevelin.Post
      assert request.path == "/v1/systemone"
      assert request.headers
        == [
          #("content-type", "application/json"),
          #("accept", "application/json"),
        ]
      let assert Ok(body) = json.parse(request.body)
        as "The prepared body is JSON."
      assert body
        == Object([
          #("state", Object([#("record", Array([String("hello"), Null]))])),
          #("model", String("jev-1.13.0")),
          #(
            "questions",
            Object([
              #(
                "result",
                Object([
                  #("type", String("noul")),
                  #(
                    "criteria",
                    Object([#("true", Object([#("required", Bool(True))]))]),
                  ),
                ]),
              ),
            ]),
          ),
        ])
      Ok(reply("{\"result\":{\"type\":\"noul\",\"noul\":0.75}}"))
    })
    as "The request-bound probability is valid."
  assert output
    == Object([
      #("model", String("jev-1.13.0")),
      #(
        "usage",
        Object([#("input_tokens", Int(12)), #("output_tokens", Int(3))]),
      ),
      #("answer", Object([#("type", String("noul")), #("noul", Float(0.75))])),
    ])
}

pub fn mixed_batch_retains_all_typed_answers_test() -> Nil {
  let input =
    arguments([
      #(
        "questions",
        Array([
          Object([
            #("name", String("route")),
            #("type", String("choice")),
            #(
              "choices",
              Array([
                Object([#("label", String("review"))]),
                Object([#("label", String("build"))]),
              ]),
            ),
          ]),
          Object([
            #("name", String("relevance")),
            #("type", String("score")),
            #(
              "levels",
              Array([String("low"), Object([#("label", String("high"))])]),
            ),
          ]),
          Object([#("name", String("urgent")), #("type", String("noul"))]),
        ]),
      ),
    ])
  let assert Ok(output) =
    evaluation.call("jev_batch", input, "jev-latest", fn(_) {
      Ok(reply(
        "{
      \"urgent\":{\"type\":\"noul\",\"noul\":0.8},
      \"route\":{\"type\":\"choice\",\"choice\":\"review\",\"confidence\":0.9,\"probabilities\":{\"review\":0.8,\"build\":0.2}},
      \"relevance\":{\"type\":\"score\",\"score\":0.6,\"confidence\":0.7,\"legend\":{\"0\":\"low\",\"1\":{\"label\":\"high\"}},\"probabilities\":{\"0\":0.4,\"1\":0.6}}
    }",
      ))
    })
    as "A mixed request preserves each answer decoder."
  let assert Object(fields) = output as "Evaluation output is structured."
  let assert Ok(#(_, Object(answers))) =
    list.find(fields, fn(pair) { pair.0 == "answers" })
    as "Named answers are present."
  assert list.map(answers, fn(pair) { pair.0 })
    == ["route", "relevance", "urgent"]
  assert string.contains(json.to_string(output), "\"score\":0.6")
  assert string.contains(json.to_string(output), "\"label\":\"high\"")
}

pub fn provider_errors_are_public_categories_without_bodies_test() -> Nil {
  list.each([401, 422, 429, 529], fn(status) {
    assert evaluation.call("jev_noul", arguments([]), "jev-latest", fn(_) {
        Ok(jevelin.HttpResponse(
          status,
          [#("authorization", "private")],
          "private provider body",
        ))
      })
      == Error(evaluation.UpstreamRejected(status))
    assert !string.contains(
      evaluation.message(evaluation.UpstreamRejected(status)),
      "private",
    )
  })
  assert evaluation.call("jev_noul", arguments([]), "jev-latest", fn(_) {
      Error(evaluation.Unavailable)
    })
    == Error(evaluation.TransportFailed(evaluation.Unavailable))
}

pub fn malformed_or_mismatched_answers_fail_closed_test() -> Nil {
  list.each(
    [
      "not JSON",
      "{\"model\":\"m\",\"answers\":{\"unknown\":{\"type\":\"noul\",\"noul\":0.5}},\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}",
      "{\"model\":\"m\",\"answers\":{\"result\":{\"type\":\"noul\",\"noul\":2}},\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}",
    ],
    fn(body) {
      assert evaluation.call("jev_noul", arguments([]), "jev-latest", fn(_) {
          Ok(jevelin.HttpResponse(200, [], body))
        })
        == Error(evaluation.InvalidAnswer)
    },
  )
}

pub fn operator_configuration_restricts_origin_and_headers_test() -> Nil {
  list.each(
    [
      "http://api.typesafe.ai", "https://other.example",
      "http://127.0.0.1@other.example", "http://127.0.0.1:1234/path",
      "http://127.0.0.1:1234?query=1", "https://api.typesafe.ai:444",
    ],
    fn(origin) {
      assert http.configure("fixture", origin, "jev-latest", 1000)
        == Error(http.InvalidOrigin)
    },
  )
  assert http.configure("fixture\r\nheader", jevelin.origin, "jev-latest", 1000)
    == Error(http.InvalidCredential)
  assert http.configure("", jevelin.origin, "jev-latest", 1000)
    == Error(http.InvalidCredential)
  assert http.configure("fixture", jevelin.origin, "", 1000)
    == Error(http.InvalidModel)
  list.each([0, 120_001], fn(timeout) {
    assert http.configure("fixture", jevelin.origin, "jev-latest", timeout)
      == Error(http.InvalidTimeout)
  })
  list.each(
    [
      jevelin.origin,
      "http://127.0.0.1:1234",
      "http://localhost:1234",
      "http://[::1]:1234",
    ],
    fn(origin) {
      let assert Ok(configuration) =
        http.configure("fixture", origin, "jev-latest", 1000)
        as "Allowed origin."
      assert http.model(configuration) == "jev-latest"
    },
  )
}

pub fn discovery_schemas_cover_four_shapes_without_authority_test() -> Nil {
  list.each(["jev_choice", "jev_score", "jev_noul", "jev_batch"], fn(name) {
    let input = tool.input_schema(name) |> json.to_string
    assert string.contains(input, "\"additionalProperties\":false")
    assert !string.contains(input, "api_key")
    assert !string.contains(input, "endpoint")
    assert string.contains(
      tool.output_schema(name) |> json.to_string,
      "\"usage\"",
    )
  })
  let assert Ok(_) = tool.server("jev-latest", never_called)
    as "Tool schemas register."
  Nil
}

pub fn typed_choice_retains_its_original_labels_test() -> Nil {
  let assert Ok(args) =
    evaluation.choice(
      content.Text("fixture state"),
      "jev-latest",
      [#("review", option.None), #("build", option.None)],
      option.None,
    )
    as "Choice criteria must construct."
  let assert Ok(output) =
    evaluation.execute(args, fn(_) {
      Ok(reply(
        "{\"result\":{\"type\":\"choice\",\"choice\":\"review\",\"confidence\":0.8,\"probabilities\":{\"review\":0.8,\"build\":0.2}}}",
      ))
    })
    as "The original label distribution must decode."
  assert evaluation.output_value(output).answers.selected == "review"
  assert evaluation.decode_output(args, evaluation.output_json(output))
    |> result.is_ok

  let assert Ok(unrelated) =
    evaluation.choice(
      content.Text("fixture state"),
      "jev-latest",
      [#("accept", option.None), #("reject", option.None)],
      option.None,
    )
    as "The second Choice must construct independently."
  assert evaluation.decode_output(unrelated, evaluation.output_json(output))
    == Error(evaluation.InvalidAnswer)
}

pub fn typed_constructors_reject_invalid_criteria_before_transport_test() -> Nil {
  assert evaluation.choice(content.Text("state"), "jev-latest", [], option.None)
    == Error(evaluation.InvalidCriteria)
  assert evaluation.score(
      content.Text("state"),
      "jev-latest",
      [content.Text("one")],
      option.None,
    )
    == Error(evaluation.InvalidCriteria)
  let assert Ok(args) =
    evaluation.noul(
      content.Text("state"),
      "jev-latest",
      option.None,
      option.None,
      option.None,
    )
    as "Noul criteria must construct."
  let named = evaluation.named_noul("same", args)
  assert evaluation.mixed(content.Text("state"), "jev-latest", [named, named])
    == Error(evaluation.InvalidCriteria)
}

pub fn typed_noul_and_batch_keep_distinct_answer_shapes_test() -> Nil {
  let assert Ok(args) =
    evaluation.noul(
      content.Text("state"),
      "jev-latest",
      option.None,
      option.None,
      option.None,
    )
    as "Noul criteria must construct."
  let assert Ok(single) =
    evaluation.execute(args, fn(_) {
      Ok(reply("{\"result\":{\"type\":\"noul\",\"noul\":0.75}}"))
    })
    as "The single probability must decode."
  assert probability.value(evaluation.output_value(single).answers) == 0.75
  let assert Ok(batch) =
    evaluation.mixed(content.Text("state"), "jev-latest", [
      evaluation.named_noul("relevant", args),
    ])
    as "The named batch must construct."
  assert evaluation.decode_output(batch, evaluation.output_json(single))
    == Error(evaluation.InvalidAnswer)
}
