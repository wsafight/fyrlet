defmodule FyrletExamples.Web do
  @moduledoc "The host router and browser UI shared by the independent example applications."
  import Plug.Conn
  @root Path.expand("../../../..", __DIR__)
  @external_resource Path.join(@root, "examples/support/priv/app.js")
  @external_resource Path.join(@root, "examples/support/priv/index.html")
  @script File.read!(Path.join(@root, "examples/support/priv/app.js"))
  @page File.read!(Path.join(@root, "examples/support/priv/index.html"))
  @assets Map.new(Path.wildcard(Path.join(@root, "sdks/typescript/dist/*.js")), fn file ->
            {Path.basename(file), File.read!(file)}
          end)
  @phoenix File.read!(
             Path.join(@root, "sdks/typescript/node_modules/phoenix/priv/static/phoenix.mjs")
           )

  def init(options), do: options

  def call(%{method: "GET", path_info: []} = conn, _options),
    do:
      respond(
        conn,
        "text/html",
        String.replace(@page, "__DOMAIN__", Application.fetch_env!(:fyrlet, :example_domain))
      )

  def call(%{method: "GET", path_info: ["app.js"]} = conn, _options),
    do: respond(conn, "text/javascript", @script)

  def call(%{method: "GET", path_info: ["sdk", "phoenix.mjs"]} = conn, _options),
    do: respond(conn, "text/javascript", @phoenix)

  def call(%{method: "GET", path_info: ["sdk", name]} = conn, _options) do
    case Map.fetch(@assets, name) do
      {:ok, content} -> respond(conn, "text/javascript", content)
      :error -> Fyrlet.HTTP.error(conn, Fyrlet.Error.not_found())
    end
  end

  def call(conn, _options), do: Fyrlet.HTTP.error(conn, Fyrlet.Error.not_found())

  defp respond(conn, type, body), do: conn |> put_resp_content_type(type) |> send_resp(200, body)
end
