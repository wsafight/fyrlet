defmodule Fyrlet.ViewTest do
  use ExUnit.Case, async: true
  alias Fyrlet.View

  defp record(index, text, version \\ 1) do
    %{
      "id" => "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0"),
      "text" => text,
      "version" => version
    }
  end

  defp assert_same_as_fresh(reset, data) do
    fresh = View.new(data, reset.context)
    assert reset.records == fresh.records
    assert reset.order == fresh.order
    assert reset.sizes == fresh.sizes
    assert reset.bytes == fresh.bytes
  end

  test "reset reuses sizes for unchanged records and recomputes the rest" do
    previous = View.new([record(3, "ccc"), record(2, "bb"), record(1, "a")])

    # added at the head, tail dropped, one record changed in place (different byte length)
    data = [record(4, "dddd"), record(3, "ccc"), record(2, "a much longer body", 2)]
    reset = View.reset(previous, data, %{})

    assert_same_as_fresh(reset, data)
    assert reset.sizes[List.first(data)["id"]] == byte_size(Jason.encode!(hd(data)))
    refute reset.sizes[Enum.at(data, 2)["id"]] == previous.sizes[Enum.at(data, 2)["id"]]
    assert reset.sizes[Enum.at(data, 1)["id"]] == previous.sizes[Enum.at(data, 1)["id"]]
    refute reset.unchanged
  end

  test "reset detects an unchanged view and keeps its size accounting" do
    data = [record(2, "bb"), record(1, "a")]
    previous = View.new(data)
    reset = View.reset(previous, data, %{})

    assert reset.unchanged
    assert_same_as_fresh(reset, data)
  end

  test "reset from a non-indexed previous value falls back to full encoding" do
    previous = View.new(%{"not" => "a list"})
    data = [record(1, "a")]

    assert_same_as_fresh(View.reset(previous, data, %{}), data)
  end
end
