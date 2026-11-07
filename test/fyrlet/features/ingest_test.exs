defmodule Fyrlet.IngestTest do
  use Fyrlet.RunsCase
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  alias Fyrlet.Features.Ingest
  alias Fyrlet.Features.Ingest.Item, as: IngestItem
  alias InboxExample.Item, as: Row
  @endpoint FyrletWeb.Endpoint

  setup do
    on_exit(fn ->
      Application.delete_env(:fyrlet, :ingest_handler)
      Application.delete_env(:fyrlet, :ingest_deny)
    end)

    project = project()
    %{project: project, alice: user(project, "alice"), bob: user(project, "bob")}
  end

  defp submit(user, items, extra \\ %{}),
    do:
      Fyrlet.Runtime.call(user.actor, "events.ingest", Map.merge(%{"items" => items}, extra), nil,
        capabilities: %{"ingest" => 1}
      )

  defp item(key, n \\ 1, text \\ "t"), do: %{"key" => key, "data" => %{"n" => n, "text" => text}}

  defp statuses(batch),
    do:
      Repo.all(
        from(i in IngestItem,
          where: i.batch_id == ^batch,
          order_by: i.seq,
          select: {i.item_key, i.status}
        )
      )

  defp rows, do: Repo.aggregate(Row, :count)

  test "accepted items are stored first and processed afterwards, each applied once", %{
    alice: alice
  } do
    assert {:ok,
            %{
              "batch_id" => batch,
              "accepted" => 2,
              "results" => [%{"status" => "accepted"}, %{"status" => "accepted"}]
            }} = submit(alice, [item("a"), item("b", 2, "x")])

    assert rows() == 0 and statuses(batch) == [{"a", "pending"}, {"b", "pending"}]
    assert_enqueued worker: Fyrlet.Features.Ingest.Worker, args: %{"batch_id" => batch}

    Ingest.process(batch)
    assert statuses(batch) == [{"a", "done"}, {"b", "done"}] and rows() == 2
    Ingest.process(batch)
    assert rows() == 2
  end

  test "each item reports its own result; valid ones are kept unless the batch is atomic", %{
    alice: alice
  } do
    items = [
      item("ok"),
      %{"key" => "bad", "data" => %{"n" => -1, "text" => "x"}},
      %{"key" => "has space", "data" => %{"n" => 1, "text" => "x"}}
    ]

    assert {:ok, %{"accepted" => 1, "results" => results}} = submit(alice, items)

    assert [
             %{"index" => 0, "status" => "accepted"},
             %{"index" => 1, "key" => "bad", "status" => "invalid", "error" => e1},
             %{"index" => 2, "status" => "invalid"}
           ] = results

    assert is_binary(e1)
    assert Repo.aggregate(IngestItem, :count) == 1

    assert {:error, %Error{code: "VALIDATION_FAILED", details: %{"items" => report}}} =
             submit(alice, [item("fresh") | tl(items)], %{"atomic" => true})

    assert Enum.map(report, & &1["status"]) == ["valid", "invalid", "invalid"]
    assert Repo.aggregate(IngestItem, :count) == 1
    assert Repo.aggregate(Ingest.Batch, :count) == 1
  end

  test "resending a batch is harmless; the same key with other data is a conflict", %{
    alice: alice
  } do
    {:ok, %{"batch_id" => first}} = submit(alice, [item("k1", 1, "one")])
    Ingest.process(first)

    assert {:ok, %{"accepted" => 0, "results" => [%{"status" => "duplicate:done"}]}} =
             submit(alice, [item("k1", 1, "one")])

    assert {:ok, %{"accepted" => 0, "results" => [%{"status" => "conflict"}]}} =
             submit(alice, [item("k1", 2, "other")])

    assert {:ok,
            %{
              "accepted" => 1,
              "results" => [%{"status" => "duplicate:done"}, %{"status" => "accepted"}]
            }} = submit(alice, [item("k1", 1, "one"), item("k2")])

    assert Repo.aggregate(IngestItem, :count) == 2 and rows() == 1
  end

  test "keys are scoped to the sender", %{alice: alice, bob: bob} do
    assert {:ok, %{"accepted" => 1}} = submit(alice, [item("same")])
    assert {:ok, %{"accepted" => 1}} = submit(bob, [item("same")])
  end

  test "a failing handler's database writes are rolled back with it", %{alice: alice} do
    Application.put_env(:fyrlet, :ingest_handler, fn
      7 -> {:error, Error.new("BAD", "no", %{}, false)}
      _ -> :ok
    end)

    {:ok, %{"batch_id" => batch}} =
      submit(alice, [item("good", 1), item("bad", 7), item("also", 2)])

    Ingest.process(batch)

    assert statuses(batch) == [{"good", "done"}, {"bad", "dead"}, {"also", "done"}]
    assert rows() == 2
    assert Repo.get_by!(IngestItem, item_key: "bad").error["code"] == "BAD"
  end

  test "a retryable failure is retried, then given up on", %{alice: alice} do
    counter = :counters.new(1, [])

    Application.put_env(:fyrlet, :ingest_handler, fn _ ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) < 3, do: {:error, Error.new("BUSY", "x", %{}, true)}, else: :ok
    end)

    {:ok, %{"batch_id" => batch}} = submit(alice, [item("flaky")])
    for _ <- 1..3, do: Ingest.process(batch)

    assert statuses(batch) == [{"flaky", "done"}] and rows() == 1 and
             Repo.get_by!(IngestItem, item_key: "flaky").attempts == 3

    Application.put_env(:fyrlet, :ingest_handler, fn _ ->
      {:error, Error.new("BUSY", "x", %{}, true)}
    end)

    {:ok, %{"batch_id" => other}} = submit(alice, [item("hopeless")])
    for _ <- 1..6, do: Ingest.process(other)
    assert statuses(other) == [{"hopeless", "dead"}]
    assert rows() == 1
  end

  test "an exception in the handler leaves nothing half-applied and is retried", %{alice: alice} do
    Application.put_env(:fyrlet, :ingest_handler, fn _ -> raise "boom secret-1" end)
    {:ok, %{"batch_id" => batch}} = submit(alice, [item("x")])
    Ingest.process(batch)
    assert statuses(batch) == [{"x", "pending"}] and rows() == 0
    refute inspect(Repo.get_by!(IngestItem, item_key: "x").error) =~ "secret-1"

    Application.delete_env(:fyrlet, :ingest_handler)
    Ingest.process(batch)
    assert statuses(batch) == [{"x", "done"}] and rows() == 1
  end

  test "too many waiting items make the sender back off, and nothing is stored", %{alice: alice} do
    put_runs(ingest_max_pending: 3)
    assert {:ok, _} = submit(alice, [item("a"), item("b")])

    assert {:error, %Error{code: "LIMIT_EXCEEDED", retryable: true}} =
             submit(alice, [item("c"), item("d")])

    assert Repo.aggregate(IngestItem, :count) == 2 and Repo.aggregate(Ingest.Batch, :count) == 1
    assert {:ok, _} = submit(alice, [item("c")])
  end

  test "it needs the capability, authorization, and a sane batch", %{alice: alice} do
    assert {:error, %Error{code: "UNSUPPORTED_CAPABILITY"}} =
             Fyrlet.Runtime.call(alice.actor, "events.ingest", %{"items" => [item("a")]}, nil,
               capabilities: %{}
             )

    Application.put_env(:fyrlet, :ingest_deny, alice.actor.subject_id)
    assert {:error, %Error{code: "FORBIDDEN"}} = submit(alice, [item("a")])
    Application.delete_env(:fyrlet, :ingest_deny)

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             submit(alice, Enum.map(1..6, &item("k#{&1}")))

    assert {:error, %Error{code: "VALIDATION_FAILED"}} = submit(alice, [])
    assert Repo.aggregate(Ingest.Batch, :count) == 0
  end

  test "batch status is readable by its sender only", %{alice: alice, bob: bob, project: project} do
    {:ok, %{"batch_id" => batch}} = submit(alice, [item("a"), item("b")])
    Ingest.process(batch)

    assert {:ok,
            %{"total" => 2, "items" => [%{"key" => "a", "status" => "done"}, %{"key" => "b"}]}} =
             Ingest.batch(alice.actor, batch)

    assert {:error, %Error{code: "NOT_FOUND"}} = Ingest.batch(bob.actor, batch)
    assert {:error, %Error{code: "NOT_FOUND"}} = Ingest.batch(alice.actor, "nope")

    api = fn user ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> user.token)
      |> put_req_header("x-project-id", project.project.id)
      |> put_req_header("x-fyrlet-capabilities", "ingest")
    end

    assert json_response(api.(alice) |> get("/api/v1/ingest/batches/#{batch}"), 200)["data"][
             "total"
           ] == 2

    assert json_response(api.(bob) |> get("/api/v1/ingest/batches/#{batch}"), 404)

    posted =
      api.(alice)
      |> post("/api/v1/operations/events.ingest", %{"input" => %{"items" => [item("http")]}})
      |> json_response(200)

    assert posted["data"]["accepted"] == 1
  end

  test "the contract lists the ingest operation when the capability is enabled", %{
    alice: alice,
    project: project
  } do
    contract =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> alice.token)
      |> put_req_header("x-project-id", project.project.id)
      |> get("/api/v1/contract")
      |> json_response(200)

    assert %{"kind" => "ingest"} = contract["data"]["operations"]["events.ingest"]
    assert contract["data"]["capabilities"]["ingest"] == 1
  end
end
