defmodule Fyrlet.Subscriptions.RecordIndex do
  def build(records) when is_list(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn
      {%{"id" => identifier}, position}, indexed when is_binary(identifier) ->
        if Map.has_key?(indexed, identifier),
          do: {:halt, nil},
          else: {:cont, Map.put(indexed, identifier, position)}

      _record, _indexed ->
        {:halt, nil}
    end)
  end

  def build(_data), do: nil
end
