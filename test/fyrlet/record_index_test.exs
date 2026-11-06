defmodule Fyrlet.RecordIndexTest do
  use ExUnit.Case, async: true
  alias Fyrlet.RecordIndex

  test "indexes exact positions including zero and empty arrays" do
    assert RecordIndex.build([%{"id" => "last"}, %{"id" => "first"}]) == %{
             "last" => 0,
             "first" => 1
           }

    assert RecordIndex.build([]) == %{}
  end

  test "duplicate or non-string IDs and non-record results disable indexed updates" do
    for data <- [
          [%{"id" => "same"}, %{"id" => "same"}],
          [%{"id" => 1}],
          [%{"text" => "missing"}],
          [nil],
          %{"id" => "not-an-array"}
        ] do
      assert RecordIndex.build(data) == nil
    end
  end
end
