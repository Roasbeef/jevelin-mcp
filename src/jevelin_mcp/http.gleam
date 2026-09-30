//// Only operator configuration may select an origin or supply a credential.
//// The transport closure captures that authority and adds it after the pure
//// Jevelin request is prepared. Native HTTP diagnostics and provider bodies
//// never become tool errors. The ecosystem HTTP client receives the complete
//// body; the byte limit here bounds accepted responses, not socket buffering.

import envoy
import gleam/bit_array
import gleam/http as method
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleam_mcp/json as wire_json
import jevelin
import jevelin_mcp/evaluation

/// Validated operator settings keep the bearer secret outside the tool surface.
pub opaque type Configuration {
  Configuration(
    credential: String,
    origin: uri.Uri,
    model: String,
    timeout_ms: Int,
  )
}

/// Configuration failures name a setting without printing its supplied value.
pub type ConfigurationError {
  /// JEV_API_KEY is absent, blank, or contains HTTP header separators.
  InvalidCredential

  /// JEV_BASE_URL is not the official HTTPS origin or loopback HTTP.
  InvalidOrigin

  /// JEV_TIMEOUT_MS is outside one to 120000 milliseconds.
  InvalidTimeout

  /// JEV_MODEL is blank.
  InvalidModel
}

/// The largest complete UTF-8 response accepted by this adapter.
pub const max_response_bytes = 4_194_304

/// Reads configuration once before starting the stdio service. Missing optional
/// settings use the official origin, stable model alias, and a 30 second timeout.
///
/// ## Examples
///
/// ```gleam
/// http.from_environment()
/// // -> Ok(configuration) when JEV_API_KEY is supplied.
/// ```
pub fn from_environment() -> Result(Configuration, ConfigurationError) {
  use credential <- result.try(
    envoy.get("JEV_API_KEY") |> result.map_error(fn(_) { InvalidCredential }),
  )
  let origin = envoy.get("JEV_BASE_URL") |> result.unwrap(jevelin.origin)
  let model = envoy.get("JEV_MODEL") |> result.unwrap(jevelin.latest)
  use timeout <- result.try(
    envoy.get("JEV_TIMEOUT_MS")
    |> result.unwrap("30000")
    |> int.parse
    |> result.map_error(fn(_) { InvalidTimeout }),
  )
  configure(credential, origin, model, timeout)
}

/// Validates settings without performing I/O. Custom origins are restricted to
/// loopback HTTP for local fixtures; credentials cannot accompany a model-selected
/// URL because the URL never appears in tool arguments.
///
/// ## Examples
///
/// ```gleam
/// http.configure("fixture-key", "http://127.0.0.1:1234", "jev-latest", 1000)
/// // -> Ok(configuration).
/// ```
pub fn configure(
  credential: String,
  origin: String,
  model: String,
  timeout_ms: Int,
) -> Result(Configuration, ConfigurationError) {
  use _ <- result.try(case string.trim(credential) {
    "" -> Error(InvalidCredential)
    _ ->
      case
        string.contains(credential, "\r") || string.contains(credential, "\n")
      {
        True -> Error(InvalidCredential)
        False -> Ok(Nil)
      }
  })
  use _ <- result.try(case string.trim(model) {
    "" -> Error(InvalidModel)
    _ -> Ok(Nil)
  })
  use _ <- result.try(case timeout_ms >= 1 && timeout_ms <= 120_000 {
    True -> Ok(Nil)
    False -> Error(InvalidTimeout)
  })

  use origin <- result.try(
    uri.parse(origin) |> result.map_error(fn(_) { InvalidOrigin }),
  )
  use _ <- result.try(validate_origin(origin))
  Ok(Configuration(credential:, origin:, model:, timeout_ms:))
}

/// Returns the model default without exposing the credential or origin.
///
/// ## Examples
///
/// ```gleam
/// http.model(configuration)
/// // -> "jev-latest" with default settings.
/// ```
pub fn model(configuration: Configuration) -> String {
  configuration.model
}

/// Returns the HTTP deadline used to derive a longer outer MCP tool budget.
///
/// ## Examples
///
/// ```gleam
/// http.timeout_ms(configuration)
/// // -> 30000 with default settings.
/// ```
pub fn timeout_ms(configuration: Configuration) -> Int {
  configuration.timeout_ms
}

/// Creates the caller-owned Jevelin transport. TLS verification and disabled
/// redirects are HTTP-client defaults, retained so bearer credentials cannot
/// follow a provider redirect. Each invocation makes exactly one attempt.
///
/// ## Examples
///
/// ```gleam
/// jevelin.send(prepared, http.transport(configuration))
/// // -> A validated Jevelin result or a public transport category.
/// ```
pub fn transport(configuration: Configuration) -> evaluation.Transport {
  let Configuration(credential:, origin:, timeout_ms:, ..) = configuration
  fn(prepared: jevelin.HttpRequest) {
    use request <- result.try(
      request.from_uri(uri.Uri(..origin, path: prepared.path))
      |> result.map_error(fn(_) { evaluation.Unavailable }),
    )
    let request =
      request.Request(
        ..request,
        method: case prepared.method {
          jevelin.Get -> method.Get
          jevelin.Post -> method.Post
        },
        headers: [
          #("authorization", "Bearer " <> credential),
          ..prepared.headers
        ],
        body: bit_array.from_string(prepared.body),
      )

    let settings = httpc.configure() |> httpc.timeout(timeout_ms)
    use response <- result.try(
      httpc.dispatch_bits(settings, request)
      |> result.map_error(fn(_) { evaluation.Unavailable }),
    )
    use _ <- result.try(
      case bit_array.byte_size(response.body) <= max_response_bytes {
        True -> Ok(Nil)
        False -> Error(evaluation.ResponseTooLarge)
      },
    )
    use body <- result.try(
      bit_array.to_string(response.body)
      |> result.map_error(fn(_) { evaluation.InvalidUtf8 }),
    )
    use _ <- result.try(disclosable(body, credential))
    Ok(jevelin.HttpResponse(response.status, response.headers, body))
  }
}

/// Renders configuration errors without leaking their supplied values.
///
/// ## Examples
///
/// ```gleam
/// assert http.message(http.InvalidCredential) == "Set JEV_API_KEY to a nonempty bearer credential."
/// ```
pub fn message(error: ConfigurationError) -> String {
  case error {
    InvalidCredential -> "Set JEV_API_KEY to a nonempty bearer credential."
    InvalidOrigin ->
      "JEV_BASE_URL must be https://api.typesafe.ai or loopback HTTP."
    InvalidTimeout -> "JEV_TIMEOUT_MS must be an integer from 1 through 120000."
    InvalidModel -> "JEV_MODEL must be a nonempty model name."
  }
}

fn validate_origin(origin: uri.Uri) -> Result(Nil, ConfigurationError) {
  use _ <- result.try(
    case origin.userinfo, origin.path, origin.query, origin.fragment {
      None, "", None, None | None, "/", None, None -> Ok(Nil)
      _, _, _, _ -> Error(InvalidOrigin)
    },
  )
  case origin.scheme, origin.host, origin.port {
    Some("https"), Some("api.typesafe.ai"), None
    | Some("https"), Some("api.typesafe.ai"), Some(443)
    -> Ok(Nil)
    Some("http"), Some(host), port
      if host == "127.0.0.1"
      || host == "localhost"
      || host == "[::1]"
      || host == "::1"
    ->
      case port {
        None -> Ok(Nil)
        Some(port) if port >= 1 && port <= 65_535 -> Ok(Nil)
        Some(_) -> Error(InvalidOrigin)
      }
    _, _, _ -> Error(InvalidOrigin)
  }
}

fn disclosable(
  body: String,
  credential: String,
) -> Result(Nil, evaluation.TransportError) {
  // Normalizing successful JSON also catches an echoed token whose characters
  // arrived as Unicode escapes. Invalid JSON is never returned as successful data.
  let normalized =
    wire_json.parse(body)
    |> result.map(wire_json.to_string)
    |> result.unwrap("")
  case
    list.any([body, normalized], fn(text) { string.contains(text, credential) })
  {
    True -> Error(evaluation.CredentialInResponse)
    False -> Ok(Nil)
  }
}
