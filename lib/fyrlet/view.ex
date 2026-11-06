defmodule Fyrlet.View do
  alias Fyrlet.{Delta, RecordIndex}

  defstruct [
    :records,
    :value,
    order: [],
    sizes: %{},
    bytes: 0,
    context: %{},
    patch: nil,
    unchanged: false
  ]

  @type t :: %__MODULE__{}

  # `previous` lets a rebuilt view reuse the encoded size of records that did not change,
  # so only added or modified records are JSON-encoded again.
  def new(data, context \\ %{}, previous \\ nil) do
    case RecordIndex.build(data) do
      indexed when is_map(indexed) ->
        records = Map.new(data, &{&1["id"], &1})
        sizes = Map.new(data, &{&1["id"], record_size(&1, previous)})

        %__MODULE__{
          records: records,
          order: Enum.map(data, & &1["id"]),
          sizes: sizes,
          bytes: 2 + max(map_size(records) - 1, 0) + Enum.sum(Map.values(sizes)),
          context: context
        }

      nil ->
        %__MODULE__{value: data, bytes: byte_size(Jason.encode!(data)), context: context}
    end
  end

  def data(%__MODULE__{records: records, order: order}) when is_map(records),
    do: Enum.map(order, &Map.fetch!(records, &1))

  def data(%__MODULE__{value: value}), do: value

  def replace(view, identifier, record, bytes) do
    old = Map.fetch!(view.records, identifier)
    {:ok, patch} = Delta.diff([old], [record])

    %{
      view
      | records: Map.put(view.records, identifier, record),
        sizes: Map.put(view.sizes, identifier, bytes),
        bytes: view.bytes - Map.fetch!(view.sizes, identifier) + bytes,
        patch: patch,
        unchanged: old == record
    }
  end

  defp record_size(%{"id" => identifier} = record, %__MODULE__{records: records, sizes: sizes})
       when is_map(records) do
    case records do
      %{^identifier => ^record} -> Map.fetch!(sizes, identifier)
      _changed -> byte_size(Jason.encode!(record))
    end
  end

  defp record_size(record, _previous), do: byte_size(Jason.encode!(record))

  def reset(previous, data, context) do
    next = new(data, context, previous)

    unchanged =
      previous != nil and previous.records == next.records and
        previous.order == next.order and previous.value == next.value

    patch =
      if previous && not unchanged do
        case Delta.diff(data(previous), data) do
          {:ok, patch} -> patch
          :snapshot -> nil
        end
      end

    %{next | unchanged: unchanged, patch: patch}
  end
end
