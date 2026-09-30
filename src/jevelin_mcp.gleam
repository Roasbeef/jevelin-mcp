//// This executable owns operator configuration and service lifetime.
//// Tool construction stays pure until the upstream HTTP closure is invoked.
//// The stdio runner writes protocol frames; Mist owns the HTTP listener.
//// Startup diagnostics use stderr in either transport mode.

import gleam/erlang/process
import gleam/io
import gleam/result
import gleam_mcp/server_http
import gleam_mcp/server_stdio
import jevelin_mcp/http
import jevelin_mcp/service
import jevelin_mcp/tool

/// Starts the configured stdio server or loopback HTTP listener. Closing stdin
/// ends stdio service cleanly. Configuration failures produce a fixed stderr
/// diagnostic and no protocol data.
///
/// ## Examples
///
/// ```gleam
/// jevelin_mcp.main()
/// // -> Serves MCP requests through the configured transport.
/// ```
pub fn main() -> Nil {
  case run() {
    Ok(Nil) -> Nil
    Error(message) -> io.println_error(message)
  }
}

fn run() -> Result(Nil, String) {
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

  // The outer tool budget includes HTTP's complete deadline and five seconds
  // for argument preparation and response decoding. EOF drains admitted work.
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
