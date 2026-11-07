defmodule Fyrlet.StaticCache do
  @moduledoc false
  # Results that depend only on configuration and compiled code (the merged contract, the
  # loaded plugins) are computed once and kept in :persistent_term, which reads without copying
  # or locking. An entry is valid for the `key` it was computed under, so changing the
  # configuration the result was derived from recomputes it. `config :fyrlet, runtime_cache:
  # false` turns the cache off (tests that rewrite contracts at run time do this).

  def fetch(name, key, compute) do
    if Application.get_env(:fyrlet, :runtime_cache, true) do
      case :persistent_term.get({__MODULE__, name}, nil) do
        {^key, value} ->
          value

        _stale_or_missing ->
          value = compute.()
          :persistent_term.put({__MODULE__, name}, {key, value})
          value
      end
    else
      compute.()
    end
  end

  def clear(name), do: :persistent_term.erase({__MODULE__, name})
end
