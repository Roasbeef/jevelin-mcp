//// MCP admission belongs to the operator, before any evaluation tool can run.
//// Stdio uses the client's process pipes. HTTP always binds loopback through the
//// SDK and requires a distinct MCP bearer token unless the operator explicitly
//// selects unauthenticated access. Neither mode reads the upstream Jev key.
////
//// ## Flow
////
//// 1. `from_environment` selects Stdio or enters `http_from_environment`.
//// 2. `http_from_environment` parses the port, exact Origin allowlist, and MCP
////    admission policy; missing bearer credentials are a configuration failure.
//// 3. `http_mode` creates the SDK listener configuration. `bearer_admission`
////    validates token syntax and captures it in a constant-time comparison callback.
//// 4. The executable starts the selected runner. The SDK checks HTTP admission
////    before a handler can reach the evaluation transport.
////
//// ## Admission decisions
////
//// | Operator selection | Result before listener startup |
//// | --- | --- |
//// | Missing transport or stdio | Stdio; HTTP token settings are unused. |
//// | HTTP with missing auth or bearer | Requires JEV_MCP_TOKEN and validates it. |
//// | HTTP with none | Explicitly admits unauthenticated loopback callers. |
//// | Unknown transport/auth or invalid port/token | Fixed configuration error. |
////
//// A present browser Origin must match the SDK's exact allowlist. An empty list
//// rejects present Origins; absence is not evidence of a trusted browser. The
//// bearer policy authenticates callers independently of Origin or MCP metadata.

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
  Http(
    /// Validated loopback port, /mcp path, exact Origins, and admission callback.
    config: server_http.Config,
  )
}

/// Selects the foreground protocol transport before reading Jev credentials.
/// Stdio is the default. HTTP requires a separate MCP bearer token by default;
/// only explicit JEV_MCP_AUTH=none admits unauthenticated loopback access.
/// Environment values are read once; changing them later does not replace callbacks.
///
/// ## Examples
///
/// ```gleam
/// service.from_environment()
/// // -> Ok(service.Stdio) with no JEV_MCP_TRANSPORT setting.
/// ```
pub fn from_environment() -> Result(Mode, String) {
  case envoy.get("JEV_MCP_TRANSPORT") |> result.unwrap("stdio") {
    "stdio" -> Ok(Stdio)
    "http" -> http_from_environment()
    _ -> Error("JEV_MCP_TRANSPORT must be stdio or http.")
  }
}

fn http_from_environment() -> Result(Mode, String) {
  use port <- result.try(
    envoy.get("JEV_MCP_PORT")
    |> result.unwrap("8000")
    |> int.parse
    |> result.map_error(fn(_) { "JEV_MCP_PORT must be an integer." }),
  )

  // The SDK matches Origins exactly. Comma splitting and trimming do not add
  // wildcard, suffix, or URL-origin normalization rules to that policy.
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

/// Constructs the SDK's loopback /mcp listener with explicit caller admission.
/// None deliberately selects unauthenticated access; it is not the environment
/// default. Some(token) validates token characters before creating the callback.
/// Port zero is admitted for an operating-system-selected port.
///
/// ## Examples
///
/// ```gleam
/// assert service.http_mode(-1, [], None)
///   == Error("JEV_MCP_PORT must be between 0 and 65535.")
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

fn bearer_admission(token: String) -> Result(server_http.Admission, String) {
  // A complete expected Authorization value is compared, so a token with
  // separators or unrelated header text cannot broaden the callback's policy.
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
