//// The executable owns configuration, tool registration, and service lifetime.
//// It admits operator settings before starting either protocol runner. Tool
//// construction stays pure until a bound evaluation callback invokes the HTTP
//// transport. Stdio writes MCP frames; the SDK and Mist own the HTTP listener.
//// Startup diagnostics use stderr so they cannot become protocol stdout.
////
//// ## Flow
////
//// 1. `main` calls `run` and renders a fixed startup/runtime error on stderr.
//// 2. `run` reads `service.from_environment` and `http.from_environment` before
////    constructing `tool.server` with the default model and upstream closure.
//// 3. Stdio enters `server_stdio.run_with_options`, which owns request scopes
////    and stdin EOF drain. Its callback budget is HTTP timeout plus five seconds.
//// 4. HTTP enters `server_http.start_server`. `process.sleep_forever` retains
////    the foreground owner of Mist's linked supervision tree.
////
//// ## Lifetime transitions
////
//// | Boundary | Success | Failure/end |
//// | --- | --- | --- |
//// | Transport/upstream configuration | Register tools | Fixed stderr diagnostic; return. |
//// | Tool registration | Start selected runner | Fixed stderr diagnostic; return. |
//// | Stdio runner | Admit and serve requests | EOF drains admitted work; runner returns. |
//// | HTTP listener start | Retain linked foreground owner | Fixed stderr diagnostic; return. |
////
//// These are sequential lifetime boundaries, not an application-owned actor state
//// machine. The SDK owns request cancellation and drain. HTTP does not receive
//// stdio's outer callback timeout options; its upstream attempt still uses the
//// configured HTTP timeout. Startup errors return Nil normally, so they do not
//// produce a nonzero process exit status.

import gleam/erlang/process
import gleam/io
import gleam/result
import gleam_mcp/server_http
import gleam_mcp/server_stdio
import jevelin_mcp/http
import jevelin_mcp/service
import jevelin_mcp/tool

/// Starts the configured stdio service or loopback HTTP listener after admitting
/// configuration and registering all tools. Stdio returns after its EOF drain;
/// HTTP retains the foreground owner of the linked listener tree. Fixed failures
/// print to stderr and return Nil normally, including configuration errors.
///
/// ## Examples
///
/// ```gleam
/// jevelin_mcp.main()
/// // -> Serves MCP through the selected transport until that service ends.
/// ```
pub fn main() -> Nil {
  case run() {
    Ok(Nil) -> Nil
    Error(message) -> io.println_error(message)
  }
}

fn run() -> Result(Nil, String) {
  // `use` passes the remainder as a Result continuation. A failed setting
  // therefore stops startup before callbacks or listeners can be admitted.
  use mode <- result.try(service.from_environment())
  use configuration <- result.try(
    http.from_environment() |> result.map_error(http.message),
  )
  use server <- result.try(
    tool.server(http.model(configuration), http.transport(configuration))
    |> result.map_error(fn(_) {
      "The Jev MCP tool definitions could not be registered."
    }),
  )

  // Stdio's callback budget leaves five seconds beyond the native HTTP timeout
  // for preparation and decoding. The SDK retains admitted callback custody
  // through EOF drain. HTTP startup below does not consume these stdio options.
  let options =
    server_stdio.options()
    |> server_stdio.with_request_timeout(http.timeout_ms(configuration) + 5000)
  case mode {
    service.Stdio ->
      server_stdio.run_with_options(server, options)
      |> result.map_error(fn(_) {
        "The Jev MCP stdio transport stopped with an error."
      })
    service.Http(config) -> {
      use _ <- result.try(
        server_http.start_server(config, server)
        |> result.map_error(fn(_) {
          "The Jev MCP HTTP listener could not start."
        }),
      )

      // Mist links its supervision tree to this foreground owner. Keeping the
      // owner alive retains that custody; no additional polling process is needed.
      process.sleep_forever()
      Ok(Nil)
    }
  }
}
