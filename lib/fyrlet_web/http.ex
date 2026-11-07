defmodule FyrletWeb.HTTP do
  use Plug.Builder
  require Logger

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {FyrletWeb.CacheBodyReader, :read_body, []},
    length: 65_536

  plug FyrletWeb.Router

  def call(conn, options) do
    super(conn, options)
  rescue
    exception in [
      Plug.Parsers.ParseError,
      Plug.Parsers.BadEncodingError,
      Plug.Parsers.UnsupportedMediaTypeError
    ] ->
      FyrletWeb.Response.error(
        conn,
        Fyrlet.Error.new("VALIDATION_FAILED", "A valid JSON request body is required"),
        Plug.Exception.status(exception)
      )

    _exception in Plug.Parsers.RequestTooLargeError ->
      FyrletWeb.Response.error(
        conn,
        Fyrlet.Error.new("LIMIT_EXCEEDED", "The request body is too large"),
        413
      )

    exception ->
      Logger.error("HTTP request failed: #{inspect(exception.__struct__)}")

      FyrletWeb.Response.error(
        conn,
        Fyrlet.Error.new("INTERNAL_ERROR", "The request could not be completed")
      )
  end
end
