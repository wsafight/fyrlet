defmodule Fyrlet.Retention do
  @moduledoc """
  How long finished data is kept, with a default for every project and optional overrides per
  project.

      config :fyrlet,
        retention: [
          default: [ingest_seconds: 604_800],
          projects: %{"7c1f..." => [ingest_seconds: 86_400], "9a2e..." => [ingest_seconds: nil]}
        ]

  A key a project does not set uses the default. `nil` means **keep forever** (for a project, or as
  the default). Seconds must be at least 60. Built-in defaults apply when nothing is configured, so
  a host application that sets none still gets them.

  Currently covers:

    * `ingest_seconds` - finished ingest items (and then-empty batches) are deleted this long after
      they were processed. Pending items are never deleted. It is also how long a resent batch is
      still recognised as a duplicate, like the idempotency window for writes.
  """
  @keys [:ingest_seconds]
  @defaults [ingest_seconds: 604_800]
  @minimum 60

  @doc "Raises unless the configured retention is well formed; called when the application starts."
  def validate! do
    retention = Application.get_env(:fyrlet, :retention, [])
    check_entry!(Keyword.get(retention, :default, []), "default")

    for {project, entry} <- Keyword.get(retention, :projects, %{}) do
      unless is_binary(project),
        do: raise(ArgumentError, "Retention projects are keyed by id string")

      check_entry!(entry, project)
    end

    :ok
  end

  defp check_entry!(entry, name) do
    unless Keyword.keyword?(entry),
      do: raise(ArgumentError, "Retention entry #{name} must be a keyword list")

    for {key, value} <- entry do
      unless key in @keys,
        do: raise(ArgumentError, "Unknown retention #{inspect(key)} in #{name}")

      unless is_nil(value) or (is_integer(value) and value >= @minimum),
        do:
          raise(
            ArgumentError,
            "Retention #{key} in #{name} must be nil or at least #{@minimum} seconds"
          )
    end
  end

  @doc "Seconds `key` is kept for `project_id`, or `nil` to keep it forever."
  def seconds(project_id, key) do
    case Map.fetch(overrides(key), project_id) do
      {:ok, value} -> value
      :error -> default(key)
    end
  end

  @doc "The default for projects without an override: seconds, or `nil` to keep forever."
  def default(key) do
    config = Application.get_env(:fyrlet, :retention, [])

    case config |> Keyword.get(:default, []) |> Keyword.fetch(key) do
      {:ok, value} -> value
      :error -> Keyword.fetch!(@defaults, key)
    end
  end

  @doc "Per-project overrides of `key` as `%{project_id => seconds | nil}`."
  def overrides(key) do
    :fyrlet
    |> Application.get_env(:retention, [])
    |> Keyword.get(:projects, %{})
    |> Enum.flat_map(fn {project, entry} ->
      case Keyword.fetch(entry, key) do
        {:ok, value} -> [{project, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end
end
