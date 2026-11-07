defmodule InboxExample.IncrementalSequenceTest do
  use InboxExample.DataCase, async: false
  alias Fyrlet.Subscriptions.View
  alias InboxExample.Inbox

  for limit <- [1, 2, 10], include_archived <- [false, true] do
    test "mixed mutations match a model with limit #{limit} and include_archived #{include_archived}" do
      alice = user(project())
      limit = unquote(limit)
      include_archived = unquote(include_archived)
      parameters = %{"limit" => limit, "include_archived" => include_archived}
      {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", parameters)

      model =
        for index <- 1..24, into: %{} do
          {:ok, record} = add(alice.actor, "initial #{index}")
          {record["id"], record}
        end

      {:ok, initial} = Runtime.view(alice.actor, subscription)
      assert_matches(initial, model, limit, include_archived)

      Enum.reduce(1..60, {initial, model}, fn index, {previous, model} ->
        {name, input} = mutation(index, model)
        {:ok, record} = Runtime.call(alice.actor, name, input, Ecto.UUID.generate())
        change = Inbox.change(name, alice.actor, input, record)

        model =
          if name == "inbox.delete" do
            Map.delete(model, record["id"])
          else
            if name != "inbox.add", do: assert(record["version"] == input["expected_version"] + 1)
            Map.put(model, record["id"], record)
          end

        assert {:ok, next} = Runtime.view(alice.actor, subscription, previous, change)
        assert_matches(next, model, limit, include_archived)
        assert {:ok, snapshot} = Runtime.snapshot(alice.actor, subscription)
        assert View.data(next) == snapshot

        if rem(index, 9) == 0 do
          assert {:ok, replayed} = Runtime.view(alice.actor, subscription, next, change)
          assert_matches(replayed, model, limit, include_archived)
        end

        {next, model}
      end)
    end
  end

  test "a delayed older update cannot replace the latest visible or reserved version" do
    alice = user(project())
    records = for index <- 1..4, do: elem(add(alice.actor, "initial #{index}"), 1)

    {:ok, subscription} =
      Runtime.prepare_subscription(alice.actor, "inbox.recent", %{"limit" => 2})

    {:ok, initial} = Runtime.view(alice.actor, subscription)

    final =
      Enum.reduce([hd(records), List.last(records)], initial, fn original, previous ->
        first_input = %{"id" => original["id"], "expected_version" => 1, "text" => "version two"}

        {:ok, second} =
          Runtime.call(alice.actor, "inbox.update", first_input, Ecto.UUID.generate())

        second_input = %{first_input | "expected_version" => 2, "text" => "version three"}

        {:ok, third} =
          Runtime.call(alice.actor, "inbox.update", second_input, Ecto.UUID.generate())

        latest = Inbox.change("inbox.update", alice.actor, second_input, third)
        delayed = Inbox.change("inbox.update", alice.actor, first_input, second)
        assert {:ok, current} = Runtime.view(alice.actor, subscription, previous, latest)
        assert {:ok, after_delayed} = Runtime.view(alice.actor, subscription, current, delayed)
        assert {:ok, snapshot} = Runtime.snapshot(alice.actor, subscription)
        assert View.data(after_delayed) == snapshot
        retained = Map.merge(after_delayed.records, after_delayed.context.reserve)
        assert retained[original["id"]]["version"] == 3
        after_delayed
      end)

    assert Enum.all?(
             Map.values(Map.merge(final.records, final.context.reserve)),
             &(&1["version"] in [1, 3])
           )
  end

  test "changes belonging to another subject or project cannot enter the current view" do
    tenant = project()
    alice = user(tenant)
    bob = user(tenant, "bob")
    other_tenant = user(project())
    assert alice.actor.subject_id != bob.actor.subject_id
    assert alice.actor.project_id != other_tenant.actor.project_id
    {:ok, own} = add(alice.actor, "private")

    {:ok, subscription} =
      Runtime.prepare_subscription(alice.actor, "inbox.recent", %{"limit" => 2})

    {:ok, initial} = Runtime.view(alice.actor, subscription)

    Enum.reduce([bob, other_tenant], initial, fn foreign, previous ->
      {:ok, record} = add(foreign.actor, "foreign")
      change = Inbox.change("inbox.add", foreign.actor, %{}, record)
      assert {:ok, next} = Runtime.view(alice.actor, subscription, previous, change)
      assert View.data(next) == [own]
      assert map_size(next.context.reserve) == 0
      next
    end)
  end

  defp mutation(index, model) do
    records = model |> Map.values() |> Enum.sort_by(&{&1["inserted_at"], &1["id"]}, :desc)

    case rem(index, 6) do
      0 -> {"inbox.add", %{"text" => "new #{index}"}}
      1 -> update_input(hd(records), "visible #{index}")
      2 -> archive(Enum.find(records, &(not &1["archived"])), true)
      3 -> archive(Enum.find(records, & &1["archived"]), false)
      4 -> {"inbox.delete", version_input(hd(records))}
      5 -> update_input(List.last(records), "hidden #{index}")
    end
  end

  defp update_input(record, text),
    do: {"inbox.update", Map.put(version_input(record), "text", text)}

  defp archive(record, archived),
    do: {"inbox.archive", Map.put(version_input(record), "archived", archived)}

  defp version_input(record), do: %{"id" => record["id"], "expected_version" => record["version"]}

  defp assert_matches(view, model, limit, include_archived) do
    expected =
      model
      |> Map.values()
      |> Enum.filter(&(include_archived or not &1["archived"]))
      |> Enum.sort_by(&{&1["inserted_at"], &1["id"]}, :desc)
      |> Enum.take(limit)

    assert View.data(view) == expected
    assert view.order == Enum.map(expected, & &1["id"])
    assert view.bytes == byte_size(Jason.encode!(expected))
    assert map_size(view.context.reserve) <= 8
    assert MapSet.disjoint?(MapSet.new(view.order), MapSet.new(Map.keys(view.context.reserve)))
    for {identifier, record} <- view.context.reserve, do: assert(model[identifier] == record)
  end
end
