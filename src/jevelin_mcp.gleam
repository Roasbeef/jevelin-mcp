//// This executable owns operator configuration and stdio service lifetime.
//// Tool construction stays pure until the HTTP closure is invoked; protocol
//// output is written only by the MCP runner. Startup diagnostics use stderr.

import gleam/io
import gleam/result
import gleam_mcp/server_stdio
import jevelin_mcp/http
import jevelin_mcp/tool

/// Starts the compiled stdio server. Closing stdin ends the server cleanly;
/// configuration failures produce a fixed stderr diagnostic and no protocol data.
///
/// ## Examples
///
/// ```gleam
/// jevelin_mcp.main()
/// // -> Serves MCP requests until stdin closes.
/// ```
pub fn main() -> Nil {
  case run() {
    Ok(Nil) -> Nil
    Error(message) -> io.println_error(message)
  }
}

fn run() -> Result(Nil, String) {
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
  server_stdio.run_with_options(server, options)
  |> result.map_error(fn(_) {
    "The Jev MCP stdio transport stopped with an error."
  })
}
