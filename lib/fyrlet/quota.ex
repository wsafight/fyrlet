defmodule Fyrlet.Quota do
  @moduledoc """
  Per-project limits on how fast a project may call operations and how many subscriptions
  it may hold open. Nothing is limited unless configured, so existing deployments behave as
  before.

      config :fyrlet,
        quotas: [
          default: [reads_per_second: 200, writes_per_second: 50, max_subscriptions: 5_000],
          projects: %{"7c1f..." => [writes_per_second: 500]}
        ]

  Unset or `nil` means unlimited; a project entry overrides the default key by key.

  **Rates** count calls in one-second windows (`:ets.update_counter/4`, so concurrent callers
  never lose an increment and need no lock). A caller that sends its whole allowance at the end
  of one second and again at the start of the next can get up to twice the limit through in
  that span; the limit holds for any whole second. Calls refused still count, so a client that
  ignores `retry_after_ms` stays refused.

  **Subscriptions** are counted by `Fyrlet.Subscriptions.Tracker`.

  All counts are **per node**. With several nodes a project can use up to the limit on each.
  """
  use GenServer
  alias Fyrlet.Error

  @table __MODULE__
  @classes [:read, :write]
  @sweep_ms 10_000
  @keys [:reads_per_second, :writes_per_second, :max_subscriptions]

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Raises unless the configured quotas are well formed; called when the application starts."
  def validate! do
    quotas = Application.get_env(:fyrlet, :quotas, [])
    check_entry!(Keyword.get(quotas, :default, []), "default")

    for {project, entry} <- Keyword.get(quotas, :projects, %{}) do
      unless is_binary(project), do: raise(ArgumentError, "Quota projects are keyed by id string")
      check_entry!(entry, project)
    end

    :ok
  end

  defp check_entry!(entry, name) do
    unless Keyword.keyword?(entry),
      do: raise(ArgumentError, "Quota entry #{name} must be a keyword list")

    for {key, value} <- entry do
      unless key in @keys, do: raise(ArgumentError, "Unknown quota #{inspect(key)} in #{name}")

      unless is_nil(value) or (is_integer(value) and value >= 1),
        do: raise(ArgumentError, "Quota #{key} in #{name} must be nil or a positive integer")
    end
  end

  @doc """
  Counts one call of `class` (`:read` or `:write`) for `project_id`.
  Returns `:ok`, or a retryable `LIMIT_EXCEEDED` whose details say when to try again.
  """
  def check(project_id, class) when class in @classes do
    case limit(project_id, class_key(class)) do
      nil -> :ok
      limit -> consume(project_id, class, limit)
    end
  end

  @doc "The subscription cap for `project_id`, or nil."
  def max_subscriptions(project_id), do: limit(project_id, :max_subscriptions)

  defp class_key(:read), do: :reads_per_second
  defp class_key(:write), do: :writes_per_second

  defp limit(project_id, key) do
    quotas = Application.get_env(:fyrlet, :quotas, [])

    with %{^project_id => entry} <- Keyword.get(quotas, :projects, %{}),
         {:ok, value} <- Keyword.fetch(entry, key) do
      value
    else
      _no_override -> quotas |> Keyword.get(:default, []) |> Keyword.get(key)
    end
  end

  defp consume(project_id, class, limit) do
    # Monotonic time may be negative, and `div`/`rem` truncate toward zero: floor them.
    now = System.monotonic_time(:millisecond)
    key = {project_id, class, Integer.floor_div(now, 1000)}

    if :ets.update_counter(@table, key, 1, {key, 0}) <= limit do
      :ok
    else
      :telemetry.execute([:fyrlet, :quota, :rejected], %{count: 1}, %{
        project_id: project_id,
        class: class
      })

      retry = 1000 - Integer.mod(now, 1000)

      {:error,
       Error.new(
         "LIMIT_EXCEEDED",
         "The project is over its #{class} rate limit",
         %{
           "scope" => "project",
           "class" => to_string(class),
           "limit" => limit,
           "retry_after_ms" => retry
         },
         true
       )}
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = Integer.floor_div(System.monotonic_time(:millisecond), 1000) - 2
    :ets.select_delete(@table, [{{{:_, :_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
