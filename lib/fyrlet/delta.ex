defmodule Fyrlet.Delta do
  def diff(previous, current) when is_list(previous) and is_list(current) do
    with {:ok, before} <- index(previous), {:ok, after_index} <- index(current) do
      added = Enum.reject(current, &Map.has_key?(before, &1["id"]))

      removed =
        for record <- previous, not Map.has_key?(after_index, record["id"]), do: record["id"]

      changed =
        Enum.flat_map(current, fn record ->
          case before[record["id"]] do
            nil ->
              []

            ^record ->
              []

            old ->
              fields =
                Map.reject(record, fn {key, value} ->
                  Map.get(old, key) == value and Map.has_key?(old, key)
                end)

              cleared = Map.keys(old) -- Map.keys(record)
              patch = [record["id"], fields]
              [if(cleared == [], do: patch, else: patch ++ [cleared])]
          end
        end)

      patch = %{}
      patch = if added == [], do: patch, else: Map.put(patch, "a", added)
      patch = if removed == [], do: patch, else: Map.put(patch, "r", removed)
      patch = if changed == [], do: patch, else: Map.put(patch, "c", changed)
      order = Enum.map(current, & &1["id"])

      patch =
        if order == Enum.map(previous, & &1["id"]),
          do: patch,
          else: Map.put(patch, "o", order)

      {:ok, patch}
    end
  end

  def diff(_previous, _current), do: :snapshot

  defp index(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn
      %{"id" => identifier} = record, {:ok, indexed} when is_binary(identifier) ->
        if Map.has_key?(indexed, identifier),
          do: {:halt, :snapshot},
          else: {:cont, {:ok, Map.put(indexed, identifier, record)}}

      _record, _indexed ->
        {:halt, :snapshot}
    end)
  end
end
