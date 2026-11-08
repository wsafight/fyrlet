defmodule Fyrlet.TestPlugins.Counter do
  @moduledoc "A reference plugin: a process, a table, a worker queue, a gated subscription and an authenticated entry."
  @behaviour Fyrlet.Plugin
  import Ecto.Query
  alias Fyrlet.Repo

  defmodule Definition do
    @behaviour Fyrlet.Definition
    @impl true
    def contract do
      %{
        "operations" => %{},
        "subscriptions" => %{
          "counter.total" => %{
            "capability" => "counter",
            "input" => Fyrlet.Schema.object(%{}),
            "output" => %{"type" => "integer", "minimum" => 0}
          }
        }
      }
    end

    @impl true
    def authorize(_name, _actor, _input), do: :ok
    @impl true
    def scope(_name, actor, _input), do: "counter:#{actor.project_id}"

    @impl true
    def execute("counter.total", actor, _input) do
      total =
        Repo.aggregate(
          from(h in "counter_hits", where: h.project_id == type(^actor.project_id, :binary_id)),
          :count
        )

      {:ok, total, []}
    end
  end

  @impl true
  def name, do: "counter"
  @impl true
  def version, do: "1.2.0"
  @impl true
  def capabilities, do: %{"counter" => 1}
  @impl true
  def children(_config),
    do: [
      %{
        id: :counter_agent,
        start: {Agent, :start_link, [fn -> 0 end, [name: :counter_plugin_agent]]}
      }
    ]

  @impl true
  def migrations, do: [Path.expand("plugins/counter/migrations", __DIR__)]
  @impl true
  def definitions, do: [Definition]
  @impl true
  def queues, do: [counter: 2]
  @impl true
  def public_paths, do: ["ping"]

  @impl true
  def call(conn, ["ping"]), do: Plug.Conn.send_resp(conn, 200, "pong")

  # Deliberately no credential check of its own: the framework dispatch must close it.
  def call(conn, ["open"]), do: Plug.Conn.send_resp(conn, 200, "open")

  def call(conn, ["hits"]) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         [project_id] <- Plug.Conn.get_req_header(conn, "x-project-id"),
         {:ok, actor} <- Fyrlet.Auth.authenticate(token, project_id) do
      Agent.update(:counter_plugin_agent, &(&1 + 1))

      conn = Plug.Conn.put_resp_content_type(conn, "application/json")

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "project" => actor.project_id,
          "calls" => Agent.get(:counter_plugin_agent, & &1)
        })
      )
    else
      _unauthenticated -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthenticated"}))
    end
  end

  def call(conn, _other), do: Plug.Conn.send_resp(conn, 404, "")
end

defmodule Fyrlet.TestPlugins.Mirror do
  @moduledoc "A second plugin that depends on the first one's capability."
  @behaviour Fyrlet.Plugin
  @impl true
  def name, do: "mirror"
  @impl true
  def version, do: "0.1.0"
  @impl true
  def capabilities, do: %{"mirror" => 1}
  @impl true
  def requires, do: ["counter"]
  @impl true
  def call(conn, _path), do: Plug.Conn.send_resp(conn, 401, "")
end

defmodule Fyrlet.TestPlugins.Broken do
  @moduledoc "Optional and unusable on purpose: it needs a capability nobody provides."
  @behaviour Fyrlet.Plugin
  @impl true
  def name, do: "broken"
  @impl true
  def version, do: "0.0.1"
  @impl true
  def capabilities, do: %{"broken" => 1}
  @impl true
  def requires, do: ["does_not_exist"]
  @impl true
  def call(conn, _path), do: Plug.Conn.send_resp(conn, 200, "should never be reachable")
end
