defmodule Fyrlet.Pruning do
  alias Fyrlet.Repo
  @key {__MODULE__, :budget}

  def validate! do
    options = Application.get_env(:fyrlet, :pruning, [])

    for {key, maximum, default} <- [{:max_rows, 5_000, 5_000}, {:max_duration_ms, 30_000, 1_000}] do
      value = Keyword.get(options, key, default)

      unless is_integer(value) and value > 0 and value <= maximum,
        do: raise(ArgumentError, "pruning #{key} must be between 1 and #{maximum}")
    end
  end

  def run(callback) do
    validate!()
    previous = Process.get(@key)
    options = Application.get_env(:fyrlet, :pruning, [])
    started = System.monotonic_time(:millisecond)

    Process.put(@key, %{
      remaining: Keyword.get(options, :max_rows, 5_000),
      deadline: started + Keyword.get(options, :max_duration_ms, 1_000),
      deleted: 0,
      limited: false
    })

    try do
      result = callback.()
      available?()
      state = Process.get(@key)

      {result,
       %{
         deleted: state.deleted,
         duration_ms: System.monotonic_time(:millisecond) - started,
         limited: state.limited
       }}
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  def available?, do: batch_size(1) > 0

  def batch_size(default) do
    case Process.get(@key) do
      nil ->
        default

      state ->
        if state.remaining > 0 and System.monotonic_time(:millisecond) < state.deadline do
          min(default, state.remaining)
        else
          Process.put(@key, %{state | limited: true})
          0
        end
    end
  end

  def delete_all(query) do
    if available?() do
      {count, _rows} = result = Repo.delete_all(query)

      if state = Process.get(@key),
        do:
          Process.put(@key, %{
            state
            | remaining: state.remaining - count,
              deleted: state.deleted + count
          })

      result
    else
      {0, nil}
    end
  end
end
