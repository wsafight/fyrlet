defmodule InboxExample.IncrementalViewTest do
  use InboxExample.DataCase, async: false
  alias Fyrlet.Subscriptions.View
  alias InboxExample.Inbox

  setup do
    alice = user(project())

    {:ok, subscription} =
      Runtime.prepare_subscription(alice.actor, "inbox.recent", %{"limit" => 2})

    %{alice: alice, subscription: subscription}
  end

  test "add, archive, unarchive and delete maintain the ordered window", %{
    alice: alice,
    subscription: subscription
  } do
    for index <- 1..12, do: add(alice.actor, "record #{index}")
    {:ok, view} = Runtime.view(alice.actor, subscription)
    assert map_size(view.context.reserve) == 8
    refute view.context.complete

    operations = [
      {"inbox.add", %{"text" => "new"}},
      {"inbox.archive", fn current -> %{"id" => hd(current.order), "expected_version" => 1} end},
      {"inbox.delete", fn current -> %{"id" => hd(current.order), "expected_version" => 1} end}
    ]

    final =
      Enum.reduce(operations, view, fn {name, input}, previous ->
        input = if is_function(input), do: input.(previous), else: input
        {:ok, record} = Runtime.call(alice.actor, name, input, Ecto.UUID.generate())
        change = Inbox.change(name, alice.actor, input, record)
        assert {:ok, next} = Runtime.view(alice.actor, subscription, previous, change)
        assert {:ok, expected} = Runtime.snapshot(alice.actor, subscription)
        assert View.data(next) == expected
        assert next.bytes == byte_size(Jason.encode!(expected))
        assert map_size(next.context.reserve) <= 8
        next
      end)

    archived = Repo.one!(from(item in InboxItem, where: item.archived, limit: 1))
    input = %{"id" => archived.id, "expected_version" => archived.version, "archived" => false}
    {:ok, record} = Runtime.call(alice.actor, "inbox.archive", input, Ecto.UUID.generate())
    change = Inbox.change("inbox.archive", alice.actor, input, record)
    assert {:ok, restored} = Runtime.view(alice.actor, subscription, final, change)
    assert {:ok, expected} = Runtime.snapshot(alice.actor, subscription)
    assert View.data(restored) == expected
  end

  test "reserve exhaustion reloads safely and reserve memory stays bounded", %{
    alice: alice,
    subscription: subscription
  } do
    for index <- 1..20, do: add(alice.actor, "record #{index}")
    {:ok, initial} = Runtime.view(alice.actor, subscription)

    final =
      Enum.reduce(1..11, initial, fn _index, previous ->
        input = %{"id" => hd(previous.order), "expected_version" => 1}
        {:ok, record} = Runtime.call(alice.actor, "inbox.delete", input, Ecto.UUID.generate())
        change = Inbox.change("inbox.delete", alice.actor, input, record)
        assert {:ok, next} = Runtime.view(alice.actor, subscription, previous, change)
        assert length(next.order) == 2
        assert map_size(next.context.reserve) <= 8
        next
      end)

    assert {:ok, expected} = Runtime.snapshot(alice.actor, subscription)
    assert View.data(final) == expected
  end

  test "delayed insertion cannot resurrect an already deleted record", %{
    alice: alice,
    subscription: subscription
  } do
    {:ok, initial} = Runtime.view(alice.actor, subscription)
    {:ok, record} = add(alice.actor)
    insertion = Inbox.change("inbox.add", alice.actor, %{}, record)
    input = %{"id" => record["id"], "expected_version" => 1}
    {:ok, deleted} = Runtime.call(alice.actor, "inbox.delete", input, Ecto.UUID.generate())
    deletion = Inbox.change("inbox.delete", alice.actor, input, deleted)
    assert {:ok, empty} = Runtime.view(alice.actor, subscription, initial, deletion)
    assert {:ok, still_empty} = Runtime.view(alice.actor, subscription, empty, insertion)
    assert View.data(still_empty) == []
  end

  test "hidden record updates maintain reserve without changing the public view", %{
    alice: alice,
    subscription: subscription
  } do
    for index <- 1..5, do: add(alice.actor, "record #{index}")
    {:ok, initial} = Runtime.view(alice.actor, subscription)
    {identifier, old} = Enum.at(initial.context.reserve, 0)
    input = %{"id" => identifier, "expected_version" => old["version"], "text" => "hidden update"}
    {:ok, record} = Runtime.call(alice.actor, "inbox.update", input, Ecto.UUID.generate())
    change = Inbox.change("inbox.update", alice.actor, input, record)
    assert {:ok, updated} = Runtime.view(alice.actor, subscription, initial, change)
    assert updated.unchanged
    assert updated.context.reserve[identifier] == record
    assert View.data(updated) == View.data(initial)
  end

  test "updates below the visible and reserve windows do not query business data", %{
    alice: alice,
    subscription: subscription
  } do
    records =
      for index <- 1..15 do
        {:ok, record} = add(alice.actor, "record #{index}")
        record
      end

    {:ok, initial} = Runtime.view(alice.actor, subscription)
    old = hd(records)
    input = %{"id" => old["id"], "expected_version" => 1, "text" => "outside both windows"}
    {:ok, record} = Runtime.call(alice.actor, "inbox.update", input, Ecto.UUID.generate())
    change = Inbox.change("inbox.update", alice.actor, input, record)
    handler = "outside-window-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if metadata[:source] == "inbox_items", do: send(owner, :business_query)
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, updated} = Runtime.view(alice.actor, subscription, initial, change)
    assert updated.unchanged
    refute_receive :business_query, 20
  end
end
