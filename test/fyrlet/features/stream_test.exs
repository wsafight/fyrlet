defmodule Fyrlet.StreamTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.Features.Stream

  setup do
    %{project: project().project.id}
  end

  defp append(project, items, name \\ "room") do
    {:ok, result} = Repo.transaction(fn -> unwrap(Stream.append(project, name, items)) end)
    result
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, error}), do: Repo.rollback(error)

  test "append must run inside a transaction", %{project: project} do
    assert_raise ArgumentError, fn -> Stream.append(project, "room", [%{"a" => 1}]) end
    assert_raise ArgumentError, fn -> Stream.reset(project, "room") end
  end

  test "an empty stream and the stream after its first append share an epoch", %{project: project} do
    {:ok, %{cursor: empty, items: []}} = Stream.snapshot(project, "room", 10)
    assert Stream.after_cursor(project, "room", empty) == :none

    append(project, [%{"n" => 1}])
    assert {:ok, ^empty, to, [%{"n" => 1}]} = Stream.after_cursor(project, "room", empty)
    assert to != empty
  end

  test "batches continue exactly where the cursor was and cover every item", %{project: project} do
    cursor = append(project, for(n <- 1..5, do: %{"n" => n}))
    {:ok, %{cursor: start}} = Stream.snapshot(project, "room", 10)
    assert start == cursor

    append(project, for(n <- 6..12, do: %{"n" => n}))

    assert {:ok, ^start, middle, first} = Stream.after_cursor(project, "room", start, items: 3)
    assert Enum.map(first, & &1["n"]) == [6, 7, 8]
    assert {:ok, ^middle, last, second} = Stream.after_cursor(project, "room", middle, items: 100)
    assert Enum.map(second, & &1["n"]) == [9, 10, 11, 12]
    assert Stream.after_cursor(project, "room", last) == :none
  end

  test "the byte budget shortens a batch but always yields at least one item", %{project: project} do
    start = append(project, [%{"n" => 0}])
    append(project, for(n <- 1..4, do: %{"n" => n, "pad" => String.duplicate("x", 100)}))

    assert {:ok, _, _, items} = Stream.after_cursor(project, "room", start, bytes: 250)
    assert length(items) == 2
    assert {:ok, _, _, [_one]} = Stream.after_cursor(project, "room", start, bytes: 1)
  end

  test "a snapshot is the newest window and ends at the head", %{project: project} do
    append(project, for(n <- 1..8, do: %{"n" => n}))
    {:ok, %{cursor: cursor, items: items}} = Stream.snapshot(project, "room", 3)
    assert Enum.map(items, & &1["n"]) == [6, 7, 8]
    assert Stream.after_cursor(project, "room", cursor) == :none
  end

  test "a rolled-back append leaves no trace and gives its positions back", %{project: project} do
    keep = append(project, [%{"n" => 1}])

    assert {:error, :boom} =
             Repo.transaction(fn ->
               Stream.append(project, "room", [%{"n" => 2}, %{"n" => 3}])
               Repo.rollback(:boom)
             end)

    assert Stream.after_cursor(project, "room", keep) == :none
    append(project, [%{"n" => 4}])
    assert {:ok, ^keep, _, [%{"n" => 4}]} = Stream.after_cursor(project, "room", keep)
  end

  test "cursors that cannot be continued are refused", %{project: project} do
    cursor = append(project, [%{"n" => 1}, %{"n" => 2}])
    [epoch, _] = String.split(cursor, ":")

    for bad <- [
          "other:1",
          "#{epoch}:99",
          "#{epoch}:-1",
          "#{epoch}:x",
          "#{epoch}",
          ":1",
          "",
          nil,
          5,
          String.duplicate("a", 200)
        ] do
      assert Stream.after_cursor(project, "room", bad) == :reset, inspect(bad)
    end

    # The same position on another stream or project is not this stream's position.
    assert Stream.after_cursor(project, "elsewhere", cursor) == :reset
  end

  test "reset starts a new epoch: old cursors are refused, new items are not mixed with old", %{
    project: project
  } do
    old = append(project, [%{"n" => 1}])

    {:ok, fresh} = Repo.transaction(fn -> unwrap(Stream.reset(project, "room")) end)

    assert Stream.after_cursor(project, "room", old) == :reset
    assert {:ok, %{items: []}} = Stream.snapshot(project, "room", 10)
    append(project, [%{"n" => 9}])
    assert {:ok, ^fresh, _, [%{"n" => 9}]} = Stream.after_cursor(project, "room", fresh)
  end

  test "pruning drops old entries and refuses cursors into the dropped part", %{project: project} do
    early = append(project, [%{"n" => 1}])
    append(project, for(n <- 2..10, do: %{"n" => n}))
    assert Stream.prune(4) == 1
    assert Stream.prune(4) == 0

    assert Stream.after_cursor(project, "room", early) == :reset
    {:ok, %{cursor: head, items: items}} = Stream.snapshot(project, "room", 100)
    assert Enum.map(items, & &1["n"]) == [7, 8, 9, 10]

    # The boundary cursor (just before the oldest kept entry) is still continuable.
    [epoch, _] = String.split(head, ":")
    assert {:ok, _, _, [%{"n" => 7} | _]} = Stream.after_cursor(project, "room", "#{epoch}:6")
    assert Stream.after_cursor(project, "room", "#{epoch}:5") == :reset
  end

  test "invalid names and items are rejected", %{project: project} do
    for name <- ["", "UPPER", "a b", String.duplicate("a", 129), nil] do
      assert {:error, %{code: "VALIDATION_FAILED"}} =
               Repo.transaction(fn -> Stream.append(project, name, [%{}]) end) |> elem(1)
    end

    for items <- [
          [],
          ["text"],
          [%{"big" => String.duplicate("x", 20_000)}],
          [%URI{}],
          for(_ <- 1..101, do: %{})
        ] do
      assert {:error, %{code: code}} =
               Repo.transaction(fn -> Stream.append(project, "room", items) end) |> elem(1)

      assert code in ["VALIDATION_FAILED", "LIMIT_EXCEEDED"]
    end
  end
end

defmodule Fyrlet.StreamConcurrencyTest do
  @moduledoc """
  No sandbox: every append commits on its own connection, so the position lock is contended
  for real. A reader polls while writers run and must never see a hole or a repeat.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Fyrlet.Repo
  alias Fyrlet.Features.Stream

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
  end

  setup do
    project = Fyrlet.Fixtures.project().project.id

    on_exit(fn ->
      Repo.delete_all(from(e in Stream.Entry, where: e.project_id == ^project))
      Repo.delete_all(from(p in Fyrlet.Project, where: p.id == ^project))
    end)

    %{project: project}
  end

  test "concurrent appenders and a polling reader never produce holes, repeats or losses", %{
    project: project
  } do
    writers = 8
    per_writer = 25
    {:ok, %{cursor: start}} = Stream.snapshot(project, "room", 10)
    parent = self()

    reader =
      Task.async(fn ->
        poll(project, start, [], parent)
      end)

    tasks =
      for writer <- 1..writers do
        Task.async(fn ->
          for n <- 1..per_writer do
            {:ok, _} =
              Repo.transaction(fn ->
                # Two small appends in one transaction: they must stay adjacent.
                Stream.append(project, "room", [%{"w" => writer, "n" => n, "part" => 1}])
                if rem(n, 5) == 0, do: Process.sleep(2)
                Stream.append(project, "room", [%{"w" => writer, "n" => n, "part" => 2}])
              end)
          end
        end)
      end

    Task.await_many(tasks, 30_000)
    send(reader.pid, :stop)
    seen = Task.await(reader, 30_000)

    expected = writers * per_writer * 2
    assert length(seen) == expected

    # Every (writer, n) pair appears once, its two parts adjacent and in order.
    pairs = seen |> Enum.chunk_every(2)

    assert Enum.all?(pairs, fn [a, b] ->
             {a["w"], a["n"], a["part"], b["part"]} == {a["w"], a["n"], 1, 2} and b["w"] == a["w"] and
               b["n"] == a["n"]
           end)

    # Each writer's own items are in the order it wrote them.
    for writer <- 1..writers do
      mine = for %{"w" => ^writer, "part" => 1, "n" => n} <- seen, do: n
      assert mine == Enum.to_list(1..per_writer)
    end
  end

  defp poll(project, cursor, acc, parent) do
    case Stream.after_cursor(project, "room", cursor, items: 7) do
      {:ok, ^cursor, next, items} -> poll(project, next, acc ++ items, parent)
      :none -> drain(project, cursor, acc, parent)
      :reset -> flunk("a reset appeared during appends")
    end
  end

  defp drain(project, cursor, acc, parent) do
    receive do
      :stop -> finish(project, cursor, acc)
    after
      1 -> poll(project, cursor, acc, parent)
    end
  end

  defp finish(project, cursor, acc) do
    case Stream.after_cursor(project, "room", cursor, items: 7) do
      {:ok, ^cursor, next, items} -> finish(project, next, acc ++ items)
      :none -> acc
    end
  end
end
