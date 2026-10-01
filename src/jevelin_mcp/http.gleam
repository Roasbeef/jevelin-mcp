//// The upstream transport owns the Jev credential, origin, and HTTP attempt.
//// Pure evaluation preparation cannot choose an authority or attach a secret.
//// An opaque Configuration is admitted once from operator settings; `transport`
//// then captures only the credential, origin, and timeout in its HTTP closure.
////
//// ## Flow
////
//// 1. `from_environment` reads settings; `configure` validates their values and
////    `validate_origin` permits the official HTTPS authority or loopback HTTP.
//// 2. The executable uses `model` as the tool default and `timeout_ms` to derive
////    its stdio callback budget. Neither accessor exposes credential or origin.
//// 3. `transport` replaces the origin path with Jevelin's prepared endpoint and
////    attaches authorization only when dispatching one native HTTP attempt.
//// 4. It checks complete-body size, UTF-8, then `disclosable` before returning
////    HttpResponse. `evaluation.execute` owns request-bound answer validation.
//// 5. `message` renders configuration failures without their supplied values.
////
//// ## Attempt boundaries
////
//// | Stage | Success permits | Failure category |
//// | --- | --- | --- |
//// | Build URI or dispatch HTTP | Complete buffered native response | Unavailable |
//// | Complete-body byte check | At most four MiB for decoding | ResponseTooLarge |
//// | UTF-8 conversion | String body | InvalidUtf8 |
//// | Credential reflection check | HttpResponse may enter Jevelin | CredentialInResponse |
////
//// TLS verification and disabled redirects are retained from gleam_httpc defaults.
//// The response bound applies after the HTTP client buffers the entire body; it
//// cannot bound socket/native buffering. The configured timeout bounds that HTTP
//// attempt, not every preparation/decoding stage or remote provider effect.
//// No retry or provider-error logging is performed here.

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
  /// Only configure can admit settings into this effect boundary.
  Configuration(
    /// A nonblank secret with no CR/LF header separators; never a tool input.
    credential: String,
    /// An admitted authority without userinfo, endpoint path, query, or fragment.
    origin: uri.Uri,
    /// The nonblank default model; an explicit tool model may override it.
    model: String,
    /// Native HTTP timeout in milliseconds, from 1 through 120000.
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

/// Reads upstream settings once before the selected protocol runner starts.
/// The API key is required; missing optional settings use the official origin,
/// Jev's stable model alias, and a 30 second native HTTP timeout. A malformed
/// present timeout fails instead of falling back to the default.
///
/// ## Examples
///
/// ```gleam
/// http.from_environment()
/// // -> Ok(configuration) with a valid JEV_API_KEY and optional settings.
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

/// Admits operator settings without performing I/O. Official HTTPS or loopback
/// HTTP are the only permitted authorities; endpoint paths come from Jevelin.
/// The opaque result prevents transport callers from bypassing origin, header,
/// model, or timeout checks. This validation does not resolve loopback hostnames.
///
/// ## Examples
///
/// ```gleam
/// assert http.configure("fixture", "https://other.example", "jev-latest", 1000)
///   == Error(http.InvalidOrigin)
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

fn validate_origin(origin: uri.Uri) -> Result(Nil, ConfigurationError) {
  // An origin is an authority, not a partly user-selected endpoint. Rejecting
  // extra URI components keeps request.path the sole source of endpoint routing.
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

/// Creates the one-attempt Jevelin transport, capturing operator authority.
/// Authorization is attached after pure request preparation. TLS verification
/// and disabled redirects remain gleam_httpc defaults, so the bearer credential
/// cannot follow a provider redirect.
///
/// The native client buffers a complete body before the four MiB acceptance check.
/// UTF-8 and credential-reflection checks run before Jevelin sees either success
/// or failure bodies. Native errors become Unavailable without their diagnostics.
/// Timeout does not establish that remote provider work has stopped or rolled back.
///
/// ## Examples
///
/// ```gleam
/// jevelin.send(prepared, http.transport(configuration))
/// // -> A request-validated answer or a safe transport/response error.
/// ```
pub fn transport(configuration: Configuration) -> evaluation.Transport {
  let Configuration(credential:, origin:, timeout_ms:, ..) = configuration

  // Destructuring here keeps the closure's captured authority explicit. The
  // model already belongs to the prepared request and need not be captured.
  fn(prepared: jevelin.HttpRequest) {
    use request <- result.try(
      request.from_uri(uri.Uri(..origin, path: prepared.path))
      |> result.map_error(fn(_) { evaluation.Unavailable }),
    )

    // Prepared requests contain a relative endpoint and negotiation headers.
    // Authority comes only from Configuration, and the credential is attached
    // here, after evaluation has admitted the question criteria.
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

    // dispatch_bits has already received the full body. This check prevents
    // acceptance/JSON decoding above the limit; it is not a streaming limit.
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

fn disclosable(
  body: String,
  credential: String,
) -> Result(Nil, evaluation.TransportError) {
  // Scan raw text and parsed/re-encoded JSON so Unicode escapes cannot hide an
  // exact echoed token. This is an exact-substring disclosure check, not general
  // secret detection; transformed or partially echoed credentials may differ.
  // Invalid JSON skips normalization and is still scanned raw. Jevelin refuses
  // invalid successful JSON later, and public HTTP errors discard their bodies.
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
