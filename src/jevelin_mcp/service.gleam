//// Transport selection belongs to operator configuration, before tool admission.
//// Stdio remains the default. HTTP binds loopback and keeps its MCP credential
//// separate from the credential that the evaluation transport sends to Jev.

import envoy
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/http_headers
import gleam_mcp/server_http

/// The operator chooses exactly one foreground protocol transport.
pub type Mode {
  /// The MCP client owns the executable's standard input and output.
  Stdio

  /// A loopback HTTP listener applies its own Origin and credential admission.
  Http(config: server_http.Config)
}

/// Reads the protocol transport settings without consulting Jev credentials.
/// HTTP uses bearer admission unless the operator explicitly selects no auth.
///
/// ## Examples
///
/// ```gleam
/// // service.from_environment() defaults to Ok(service.Stdio).
/// ```
pub fn from_environment() -> Result(Mode, String) {
  case envoy.get("JEV_MCP_TRANSPORT") |> result.unwrap("stdio") {
    "stdio" -> Ok(Stdio)
    "http" -> http_from_environment()
    _ -> Error("JEV_MCP_TRANSPORT must be stdio or http.")
  }
}

/// Constructs a loopback endpoint with explicit host-selected admission.
/// None deliberately selects unauthenticated access; it isn't the HTTP default.
///
/// ## Examples
///
/// ```gleam
/// // service.http_mode(8000, [], Some("local-mcp-token"))
/// ```
pub fn http_mode(
  port: Int,
  origins: List(String),
  token: Option(String),
) -> Result(Mode, String) {
  use admission <- result.try(case token {
    None -> Ok(server_http.LocalUnauthenticated)
    Some(token) -> bearer_admission(token)
  })
  server_http.new(port, "/mcp", origins, admission)
  |> result.map(Http)
  |> result.map_error(fn(_) { "JEV_MCP_PORT must be between 0 and 65535." })
}

fn http_from_environment() -> Result(Mode, String) {
  use port <- result.try(
    envoy.get("JEV_MCP_PORT")
    |> result.unwrap("8000")
    |> int.parse
    |> result.map_error(fn(_) { "JEV_MCP_PORT must be an integer." }),
  )
  let origins =
    envoy.get("JEV_MCP_ALLOWED_ORIGINS")
    |> result.unwrap("")
    |> string.split(",")
    |> list.map(string.trim)
    |> list.filter(fn(value) { value != "" })
  use token <- result.try(
    case envoy.get("JEV_MCP_AUTH") |> result.unwrap("bearer") {
      "none" -> Ok(None)
      "bearer" ->
        envoy.get("JEV_MCP_TOKEN")
        |> result.map(Some)
        |> result.map_error(fn(_) {
          "JEV_MCP_TOKEN is required for HTTP bearer admission."
        })
      _ -> Error("JEV_MCP_AUTH must be bearer or none.")
    },
  )
  http_mode(port, origins, token)
}

fn bearer_admission(token: String) -> Result(server_http.Admission, String) {
  let valid =
    token != ""
    && list.all(string.to_graphemes(token), fn(character) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/=",
        character,
      )
    })
  use Nil <- result.try(case valid {
    True -> Ok(Nil)
    False -> Error("JEV_MCP_TOKEN must contain only bearer-token characters.")
  })

  // Only the MCP credential authorizes callers. Neither protocol metadata nor
  // the upstream Jev key can satisfy this admission function.
  Ok(
    server_http.Authenticate(fn(headers) {
      case http_headers.get(headers, "authorization") {
        Ok(value) ->
          case
            crypto.secure_compare(
              bit_array.from_string(value),
              bit_array.from_string("Bearer " <> token),
            )
          {
            True -> Ok(Nil)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    }),
  )
}
