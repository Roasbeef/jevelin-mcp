//// This native peer consumes Jevelin's shared definition, not raw arguments.
//// It has only the MCP credential; the server alone owns upstream Jev access.

import gleam/io
import gleam/option
import gleam/result
import gleam_mcp/client
import gleam_mcp/client_http
import gleam_mcp/request
import jevelin/content
import jevelin_mcp/evaluation
import jevelin_mcp/tool

/// Calls the compiled HTTP server and prints a typed Choice projection.
///
/// ## Examples
///
/// ```gleam
/// // typed_client.call("http://127.0.0.1:8000/mcp")
/// ```
pub fn call(url: String) -> Nil {
  case run(url) {
    Ok(selected) -> io.println("SELECTED:" <> selected)
    Error(reason) -> io.println_error("TYPED_CLIENT_FAILED:" <> reason)
  }
}

fn run(url: String) -> Result(String, String) {
  use endpoint <- result.try(
    client_http.new(url, [
      #("authorization", "Bearer independent-mcp-fixture-token"),
    ]),
  )
  use definition <- result.try(
    tool.choice("jev-latest")
    |> result.map_error(fn(_) { "definition refused" }),
  )
  use args <- result.try(
    evaluation.choice(
      content.Text("typed HTTP client"),
      "jev-latest",
      [#("review", option.None), #("build", option.None)],
      option.None,
    )
    |> result.map_error(evaluation.message),
  )
  use outcome <- result.try(
    client.call(
      client_http.endpoint(endpoint),
      definition,
      args,
      request.options("jev-typed-peer", "1") |> request.with_timeout(5000),
    )
    |> result.map_error(fn(_) { "exchange refused" }),
  )
  case outcome {
    client.Complete(output) ->
      Ok(evaluation.output_value(output).answers.selected)
    client.ToolFailed(_) -> Error("tool failed")
    client.InputRequired(_) -> Error("unexpected continuation")
  }
}
