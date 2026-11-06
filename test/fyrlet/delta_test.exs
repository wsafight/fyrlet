defmodule Fyrlet.DeltaTest do
  use ExUnit.Case, async: true
  alias Fyrlet.Delta

  test "sends changed fields, preserves explicit nulls and clears removed fields" do
    previous = [%{"id" => "a", "text" => "before", "version" => 1, "optional" => true}]
    current = [%{"id" => "a", "text" => nil, "version" => 2}]

    assert {:ok,
            %{
              "c" => [["a", %{"text" => nil, "version" => 2}, ["optional"]]]
            }} = Delta.diff(previous, current)
  end

  test "additions, removals and reordering describe the complete view" do
    previous = [%{"id" => "a"}, %{"id" => "b"}, %{"id" => "c"}]
    current = [%{"id" => "c"}, %{"id" => "d", "text" => "new"}, %{"id" => "b"}]

    assert {:ok,
            %{
              "a" => [%{"id" => "d", "text" => "new"}],
              "r" => ["a"],
              "o" => ["c", "d", "b"]
            }} = Delta.diff(previous, current)

    assert {:ok, %{}} = Delta.diff(current, current)
    assert {:ok, %{"r" => ["c", "d", "b"], "o" => []}} = Delta.diff(current, [])
  end

  test "ambiguous IDs and arbitrary JSON results fall back to full snapshots" do
    for {previous, current} <- [
          {[%{"id" => "a"}, %{"id" => "a"}], []},
          {[], [%{"id" => "a"}, %{"id" => "a"}]},
          {[], [%{"id" => 1}]},
          {[], ["value"]},
          {%{"count" => 1}, %{"count" => 2}}
        ] do
      assert :snapshot = Delta.diff(previous, current)
    end
  end

  test "compact patches preserve escaping and omit the optional clearing tuple when absent" do
    previous = [%{"id" => "same", "text" => "before"}]
    current = [%{"id" => "same", "text" => "更新\n\"\\"}]

    assert {:ok, %{"c" => [["same", %{"text" => "更新\n\"\\"}]]} = patch} =
             Delta.diff(previous, current)

    assert Jason.decode!(Jason.encode!(patch)) == patch
  end
end
