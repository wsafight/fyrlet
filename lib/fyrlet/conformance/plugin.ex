defmodule Fyrlet.Conformance.Plugin do
  @moduledoc """
  Checks a plugin against the rules in `Fyrlet.Plugin` (temp spec §7.3). Plugin authors call
  `run/1` from their own tests; Fyrlet runs it on its reference plugins.

      assert [] = Fyrlet.Conformance.Plugin.failures(MyPlugin)

  What it verifies is how the plugin behaves along the official paths: shape of its
  declarations, additive and namespaced migrations, declared capabilities, entries that refuse
  unauthenticated requests, and processes that start and stop cleanly. It cannot prove that
  arbitrary code is harmless - a plugin runs with the same rights as Fyrlet - so passing is a
  floor, not a certificate.
  """
  import Plug.Test, only: [conn: 2]

  @probe_paths ["", "records", "admin/secret", "../sessions"]

  # A malformed plugin is reported by its shape alone: the later checks call into it and would
  # only crash or add noise. A plugin that failed to load is never mounted, so its entry is
  # closed by construction and is not probed.
  def run(plugin) do
    case shape(plugin) do
      :ok -> run_checks(plugin)
      error -> [{:shape, error}]
    end
  end

  defp run_checks(plugin) do
    identity = identity(plugin)

    [
      {:shape, :ok},
      {:identity, identity},
      {:migrations, migrations(plugin)},
      {:capabilities_declared, capabilities_declared(plugin)},
      {:contract_only, contract_only(plugin)},
      {:fail_closed, if(identity == :ok, do: fail_closed(plugin), else: :ok)},
      {:lifecycle, lifecycle(plugin)}
    ]
  end

  def failures(plugin), do: for({check, {:error, reason}} <- run(plugin), do: {check, reason})

  defp shape(plugin) do
    cond do
      not Code.ensure_loaded?(plugin) ->
        {:error, "module cannot be loaded"}

      not (function_exported?(plugin, :name, 0) and function_exported?(plugin, :version, 0)) ->
        {:error, "name/0 and version/0 are required"}

      not valid_capabilities?(plugin) ->
        {:error, "capabilities/0 must return %{name => positive integer}"}

      not valid_list?(plugin, :requires) ->
        {:error, "requires/0 must return a list of names"}

      true ->
        :ok
    end
  end

  defp valid_capabilities?(plugin) do
    not function_exported?(plugin, :capabilities, 0) or
      (is_map(plugin.capabilities()) and
         Enum.all?(plugin.capabilities(), fn {k, v} ->
           is_binary(k) and is_integer(v) and v > 0
         end))
  end

  defp valid_list?(plugin, function),
    do:
      not function_exported?(plugin, function, 0) or
        (is_list(apply(plugin, function, [])) and
           Enum.all?(apply(plugin, function, []), &is_binary/1))

  defp identity(plugin) do
    case Fyrlet.Plugins.load() |> Enum.find(&(&1.module == plugin)) do
      %{status: :ok} -> :ok
      %{status: {:error, reason}} -> {:error, reason}
      nil -> check_unconfigured(plugin)
    end
  end

  defp check_unconfigured(plugin) do
    previous = Application.get_env(:fyrlet, :plugins, [])
    Application.put_env(:fyrlet, :plugins, previous ++ [plugin])

    try do
      case Fyrlet.Plugins.load() |> Enum.find(&(&1.module == plugin)) do
        %{status: :ok} -> :ok
        %{status: {:error, reason}} -> {:error, reason}
      end
    after
      Application.put_env(:fyrlet, :plugins, previous)
    end
  end

  defp migrations(plugin) do
    name = plugin.name()

    problems =
      for path <- call(plugin, :migrations, []),
          file <- Path.wildcard(Path.join(path, "*.exs")),
          do: {Path.basename(file), File.read!(file)}

    bad =
      Enum.flat_map(problems, fn {file, source} ->
        for table <-
              Regex.scan(~r/(?:alter|drop|rename)\s+table\(\s*:(\w+)/, source)
              |> Enum.map(&List.last/1),
            table in Fyrlet.Plugins.core_tables(),
            do: "#{file} changes Fyrlet's table #{table}"
      end)

    created =
      Enum.flat_map(problems, fn {file, source} ->
        for table <-
              Regex.scan(~r/create(?:_if_not_exists)?\s+table\(\s*:(\w+)/, source)
              |> Enum.map(&List.last/1),
            not String.starts_with?(table, name <> "_"),
            do: "#{file} creates #{table}, which is not prefixed #{name}_"
      end)

    case bad ++ created do
      [] -> :ok
      [first | _] -> {:error, first}
    end
  end

  # Every capability a definition depends on must be named by the plugin or already exist.
  defp capabilities_declared(plugin) do
    own = call(plugin, :capabilities, %{})
    core = Application.get_env(:fyrlet, :capabilities, %{})

    used =
      for definition <- call(plugin, :definitions, []),
          {_kind, entries} <- Map.take(definition.contract(), ["operations", "subscriptions"]),
          {_name, spec} <- entries,
          capability = spec["capability"],
          do: capability

    case Enum.reject(used, &(Map.has_key?(own, &1) or Map.has_key?(core, &1))) do
      [] -> :ok
      missing -> {:error, "uses undeclared capability #{Enum.join(Enum.uniq(missing), ", ")}"}
    end
  end

  # A plugin adds contract entries; it does not invent new protocol events or top-level sections.
  defp contract_only(plugin) do
    odd =
      for definition <- call(plugin, :definitions, []),
          key <- Map.keys(definition.contract()),
          key not in ["operations", "subscriptions"],
          do: key

    if odd == [],
      do: :ok,
      else: {:error, "contract sections #{Enum.join(odd, ", ")} are not part of the protocol"}
  end

  defp fail_closed(plugin) do
    if function_exported?(plugin, :call, 2) do
      public = call(plugin, :public_paths, [])
      prefix = "/api/v1/plugins/" <> plugin.name() <> "/"

      served =
        for path <- @probe_paths -- public,
            headers <- [
              [],
              [{"authorization", "Bearer rts_not_a_real_token"}],
              [{"authorization", "Bearer"}]
            ],
            reply = request(plugin, prefix <> path, headers),
            reply.status not in [401, 403, 404, 400, 405, 422],
            do: "#{inspect(path)} answered #{reply.status} without valid credentials"

      case served do
        [] -> :ok
        [first | _] -> {:error, first}
      end
    else
      :ok
    end
  end

  defp request(plugin, path, headers) do
    segments = path |> String.split("/", trim: true) |> Enum.drop(4)

    conn =
      Enum.reduce(headers, conn(:get, path), fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)
      |> Plug.Conn.put_private(:phoenix_endpoint, FyrletWeb.Endpoint)

    conn = plugin.call(conn, segments)

    if conn.state in [:sent, :set],
      do: conn,
      else: Plug.Conn.send_resp(conn, 500, "plugin did not answer")
  end

  # Starting and stopping its processes must work and leave nothing behind.
  defp lifecycle(plugin) do
    children = call(plugin, :children, [[]], [])

    if children == [], do: :ok, else: isolated(fn -> start_and_stop(children) end)
  end

  # A child that fails to start takes its linked supervisor down with an exit signal; run the
  # check in its own process so that is reported rather than propagated to the caller.
  defp isolated(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:lifecycle, self(), fun.()})
      end)

    receive do
      {:lifecycle, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, "children failed to start: #{inspect(reason)}"}
    after
      10_000 -> {:error, "children did not start within 10 seconds"}
    end
  end

  defp start_and_stop(children) do
    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, supervisor} ->
        alive =
          Supervisor.which_children(supervisor)
          |> Enum.all?(fn {_id, pid, _type, _modules} -> is_pid(pid) end)

        Supervisor.stop(supervisor)
        if alive, do: :ok, else: {:error, "a child process did not start"}

      # A named process that Fyrlet's own supervisor already runs counts as a successful start.
      {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, _pid}}}} ->
        :ok

      {:error, reason} ->
        {:error, "children failed to start: #{inspect(reason)}"}
    end
  end

  defp call(plugin, function, default), do: call(plugin, function, [], default)

  defp call(plugin, function, arguments, default) do
    if function_exported?(plugin, function, length(arguments)),
      do: apply(plugin, function, arguments),
      else: default
  end
end
