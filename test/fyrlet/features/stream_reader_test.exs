defmodule Fyrlet.Features.StreamReaderTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.Features.Stream
  alias Fyrlet.Features.Stream.Reader

  setup do
    previous = Application.get_env(:fyrlet, :streams)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fyrlet, :streams, previous),
        else: Application.delete_env(:fyrlet, :streams)
    end)

    %{project: project().project.id}
  end

  defp append(project, items, name \\ "room") do
    {:ok, cursor} = Repo.transaction(fn -> elem(Stream.append(project, name, items), 1) end)
    cursor
  end

  defp entry_reads(fun) do
    test = self()
    id = {:reads, make_ref()}
    counter = :counters.new(1, [])

    :telemetry.attach(
      id,
      [:fyrlet, :repo, :query],
      fn _, _, meta, _ ->
        if meta.query =~ "fyrlet_stream_entries" and meta.query =~ "SELECT",
          do: :counters.add(counter, 1, 1)
      end,
      test
    )

    result = fun.()
    :telemetry.detach(id)
    {result, :counters.get(counter, 1)}
  end

  defp texts(%{json: json}), do: json |> Jason.decode!() |> Enum.map(& &1["text"])

  test "the shared answer is the same batch the plain read returns, plus how to continue", %{
    project: p
  } do
    start = append(p, [%{"text" => "a"}])
    append(p, [%{"text" => "b"}, %{"text" => "c"}])

    assert {:ok, ^start, to, payload, false} = Stream.after_cursor_shared(p, "room", start)
    assert texts(payload) == ["b", "c"] and payload.count == 2

    assert {:ok, ^start, ^to, [%{"text" => "b"}, %{"text" => "c"}]} =
             Stream.after_cursor(p, "room", start)
  end

  test "more? says whether the batch stopped short of the head", %{project: p} do
    start = append(p, [%{"text" => "0"}])
    append(p, for(n <- 1..5, do: %{"text" => "#{n}"}))
    opts = [items: 2]
    assert {:ok, ^start, middle, _, true} = Stream.after_cursor_shared(p, "room", start, opts)
    assert {:ok, ^middle, _, _, true} = Stream.after_cursor_shared(p, "room", middle, opts)
    {:ok, _, last, _, true} = Stream.after_cursor_shared(p, "room", middle, opts)
    assert {:ok, ^last, _, payload, false} = Stream.after_cursor_shared(p, "room", last, opts)
    assert texts(payload) == ["5"]
  end

  test "many readers at the same cursor cost one read of the entries", %{project: p} do
    start = append(p, [%{"text" => "a"}])
    append(p, [%{"text" => "b"}])

    {results, reads} =
      entry_reads(fn ->
        1..60
        |> Task.async_stream(fn _ -> Stream.after_cursor_shared(p, "room", start) end,
          max_concurrency: 60
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    assert reads == 1
    assert results |> Enum.uniq() |> length() == 1
    assert {:ok, ^start, _, %{count: 1}, false} = hd(results)
  end

  test "different cursors do not block each other's reads", %{project: p} do
    test = self()

    controlled = fn result ->
      fn ->
        send(test, {:read_started, result, self()})

        receive do
          :finish_read -> result
        after
          1_000 -> :timeout
        end
      end
    end

    first = Task.async(fn -> Reader.batch(p, "room", "one", [], controlled.(:first)) end)
    assert_receive {:read_started, :first, first_reader}
    second = Task.async(fn -> Reader.batch(p, "room", "two", [], controlled.(:second)) end)
    assert_receive {:read_started, :second, second_reader}, 100
    send(first_reader, :finish_read)
    send(second_reader, :finish_read)
    assert Task.await(first) == :first
    assert Task.await(second) == :second
  end

  test "empty results are not shared with a queued caller", %{project: p} do
    test = self()

    read = fn ->
      send(test, {:empty_read, self()})

      receive do
        :finish_read -> :none
      after
        1_000 -> :timeout
      end
    end

    first = Task.async(fn -> Reader.batch(p, "room", "same", [], read) end)
    assert_receive {:empty_read, first_reader}
    second = Task.async(fn -> Reader.batch(p, "room", "same", [], read) end)
    send(first_reader, :finish_read)
    assert Task.await(first) == :none
    assert_receive {:empty_read, second_reader}
    send(second_reader, :finish_read)
    assert Task.await(second) == :none
  end

  test "simultaneous snapshots share one read but are never retained", %{project: p} do
    append(p, [%{"text" => "a"}, %{"text" => "b"}])

    {results, reads} =
      entry_reads(fn ->
        1..30
        |> Task.async_stream(fn _ -> Stream.snapshot_shared(p, "room", 5) end,
          max_concurrency: 30
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    assert reads == 1
    assert Enum.uniq(results) |> length() == 1
    assert {:ok, %{encoded: ~s([{"text":"a"},{"text":"b"}])}} = hd(results)
    {_, next} = entry_reads(fn -> Stream.snapshot_shared(p, "room", 5) end)
    assert next == 1
  end

  test "different cursors, streams, projects and limits never share an answer", %{project: p} do
    c1 = append(p, [%{"text" => "a"}])
    c2 = append(p, [%{"text" => "b"}])
    c3 = append(p, [%{"text" => "c"}])
    other = project().project.id
    append(other, [%{"text" => "x"}, %{"text" => "y"}], "room")
    append(p, [%{"text" => "s"}], "side")

    assert {:ok, _, _, a, _} = Stream.after_cursor_shared(p, "room", c1)
    assert {:ok, _, _, b, _} = Stream.after_cursor_shared(p, "room", c2)
    assert texts(a) == ["b", "c"] and texts(b) == ["c"]
    assert {:ok, _, _, one, true} = Stream.after_cursor_shared(p, "room", c1, items: 1)
    assert texts(one) == ["b"]
    # "side" has one entry, so a position of 3 in "room" is beyond its head.
    assert :reset = Stream.after_cursor_shared(p, "side", c3)
    {:ok, %{cursor: oc}} = Stream.snapshot(other, "room", 1)
    assert Stream.after_cursor_shared(other, "room", oc) == :none
  end

  test "nothing-new is never cached: an append right after is seen at once", %{project: p} do
    start = append(p, [%{"text" => "a"}])
    assert Stream.after_cursor_shared(p, "room", start) == :none
    append(p, [%{"text" => "b"}])
    assert {:ok, ^start, _, payload, false} = Stream.after_cursor_shared(p, "room", start)
    assert texts(payload) == ["b"]
  end

  test "a rewritten or trimmed stream is not served from the cache", %{project: p} do
    start = append(p, [%{"text" => "a"}])
    append(p, for(n <- 1..6, do: %{"text" => "#{n}"}))
    assert {:ok, _, _, _, _} = Stream.after_cursor_shared(p, "room", start)

    Stream.prune(2)
    assert Stream.after_cursor_shared(p, "room", start) == :reset

    cursor = append(p, [%{"text" => "z"}])
    append(p, [%{"text" => "zz"}])
    assert {:ok, _, _, _, _} = Stream.after_cursor_shared(p, "room", cursor)
    {:ok, _} = Repo.transaction(fn -> Stream.reset(p, "room") end)
    assert Stream.after_cursor_shared(p, "room", cursor) == :reset
  end

  test "an answer is reused only for the TTL", %{project: p} do
    Application.put_env(:fyrlet, :streams, shared_read_ttl_ms: 50)
    start = append(p, [%{"text" => "a"}])
    append(p, [%{"text" => "b"}])

    {_, first} = entry_reads(fn -> Stream.after_cursor_shared(p, "room", start) end)
    {_, second} = entry_reads(fn -> Stream.after_cursor_shared(p, "room", start) end)
    assert {first, second} == {1, 0}

    Process.sleep(80)
    {_, third} = entry_reads(fn -> Stream.after_cursor_shared(p, "room", start) end)
    assert third == 1
  end

  test "when the shared path cannot answer, the caller reads for itself", %{project: p} do
    start = append(p, [%{"text" => "a"}])
    append(p, [%{"text" => "b"}])

    # No table at all (the capability is off): plain read.
    table = Process.whereis(Reader.Table)
    assert table
    Supervisor.terminate_child(Fyrlet.Supervisor, Reader.Supervisor)
    refute :ets.whereis(Reader) != :undefined
    assert {:ok, ^start, _, %{count: 1}, false} = Stream.after_cursor_shared(p, "room", start)
    {:ok, _} = Supervisor.restart_child(Fyrlet.Supervisor, Reader.Supervisor)
  end

  test "a reader that raises is not fatal: the caller gets its own read", %{project: p} do
    start = append(p, [%{"text" => "a"}])
    append(p, [%{"text" => "b"}])
    test = self()

    # Fails in the reader process (any process but the test's) and works in the caller's own.
    result =
      Reader.batch(p, "room", start, [], fn ->
        if self() == test,
          do: Stream.read_after(p, "room", start, []),
          else: raise("database hiccup")
      end)

    assert {:ok, ^start, _, _, false} = result
    # Nothing was cached from the failed attempt, so a later call still reads fresh.
    assert {_, 1} = entry_reads(fn -> Stream.after_cursor_shared(p, "room", start) end)
  end
end
