defmodule Fyrlet.Subscriptions.View do
  @moduledoc """
  A subscription snapshot plus its delta bookkeeping.

  Each record's JSON is encoded once, when the view is built: the binary backs both the
  byte-size accounting and `encode/1`, so pushing a snapshot never re-encodes records that
  did not change. Unchanged records reuse the previous view's binary. The cache costs one
  reference-counted binary per record (off-heap for larger ones), bounded by the snapshot
  size limit.

  Deltas are lazy: `reset/3` only remembers the previous view and `patch/1` diffs on demand,
  so observers without a `delta-v1` client never pay for a diff.
  """
  alias Fyrlet.Subscriptions.Delta
  alias Fyrlet.Subscriptions.RecordIndex

  defstruct [
    :records,
    :value,
    :encoded_value,
    :previous,
    order: [],
    sizes: %{},
    encoded: %{},
    bytes: 0,
    context: %{},
    patch: nil,
    unchanged: false
  ]

  @type t :: %__MODULE__{}

  def new(data, context \\ %{}, previous \\ nil) do
    case RecordIndex.build(data) do
      indexed when is_map(indexed) ->
        records = Map.new(data, &{&1["id"], &1})

        {sizes, encoded} =
          Enum.reduce(data, {%{}, %{}}, fn record, {sizes, encoded} ->
            {bytes, json} = encode_record(record, previous)
            id = record["id"]
            {Map.put(sizes, id, bytes), Map.put(encoded, id, json)}
          end)

        %__MODULE__{
          records: records,
          order: Enum.map(data, & &1["id"]),
          sizes: sizes,
          encoded: encoded,
          bytes: 2 + max(map_size(records) - 1, 0) + Enum.sum(Map.values(sizes)),
          context: context
        }

      nil ->
        json = Jason.encode!(data)

        %__MODULE__{
          value: data,
          encoded_value: json,
          bytes: byte_size(json),
          context: context
        }
    end
  end

  def data(%__MODULE__{records: records, order: order}) when is_map(records),
    do: Enum.map(order, &Map.fetch!(records, &1))

  def data(%__MODULE__{value: value}), do: value

  @doc "The snapshot as one JSON binary, assembled from the cached per-record encodings."
  def encode(%__MODULE__{records: records, order: order, encoded: encoded})
      when is_map(records) do
    order
    |> Enum.map(&Map.fetch!(encoded, &1))
    |> Enum.intersperse(",")
    |> then(&IO.iodata_to_binary(["[", &1, "]"]))
  end

  def encode(%__MODULE__{encoded_value: json}), do: json

  @doc """
  The delta from the previous view, or nil when a full snapshot is the right answer.
  Computed on demand; a view built by `replace/4` already carries its one-record patch.
  """
  def patch(%__MODULE__{patch: patch}) when patch != nil, do: patch

  def patch(%__MODULE__{previous: %__MODULE__{} = previous} = view) do
    case Delta.diff(data(previous), data(view)) do
      {:ok, patch} -> patch
      :snapshot -> nil
    end
  end

  def patch(%__MODULE__{}), do: nil

  def replace(view, identifier, record) do
    encoded = Jason.encode!(record)
    replace_encoded(view, identifier, record, byte_size(encoded), encoded)
  end

  def replace(view, identifier, record, bytes),
    do: replace_encoded(view, identifier, record, bytes, Jason.encode!(record))

  defp replace_encoded(view, identifier, record, bytes, encoded) do
    old = Map.fetch!(view.records, identifier)
    {:ok, patch} = Delta.diff([old], [record])

    %{
      view
      | records: Map.put(view.records, identifier, record),
        sizes: Map.put(view.sizes, identifier, bytes),
        encoded: Map.put(view.encoded, identifier, encoded),
        bytes: view.bytes - Map.fetch!(view.sizes, identifier) + bytes,
        patch: patch,
        previous: nil,
        unchanged: old == record
    }
  end

  defp encode_record(%{"id" => identifier} = record, %__MODULE__{} = previous) do
    case previous do
      %{records: %{^identifier => ^record}, sizes: sizes, encoded: encoded}
      when is_map(sizes) and is_map(encoded) ->
        {Map.fetch!(sizes, identifier), Map.fetch!(encoded, identifier)}

      _changed_or_absent ->
        json = Jason.encode!(record)
        {byte_size(json), json}
    end
  end

  defp encode_record(record, _previous) do
    json = Jason.encode!(record)
    {byte_size(json), json}
  end

  def reset(previous, data, context) do
    next = new(data, context, previous)

    unchanged =
      previous != nil and previous.records == next.records and
        previous.order == next.order and previous.value == next.value

    %{next | unchanged: unchanged, previous: previous}
  end
end
