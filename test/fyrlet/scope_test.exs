defmodule Fyrlet.ScopeTest do
  use Fyrlet.DataCase, async: true
  alias Fyrlet.Scope
  alias Fyrlet.Scope.Violation
  alias Fyrlet.TestRecord, as: Item

  defmodule Policy do
    def data_scope(_action, _actor, _input), do: {:ok, project: :project_id, subject: :subject_id}
  end

  defmodule ProjectOnly do
    def data_scope(_action, _actor, _input), do: {:ok, project: :project_id}
  end

  defmodule Members do
    def data_scope(_action, _actor, input),
      do: {:ok, project: :project_id, members: {:content_type, input["types"]}}
  end

  defmodule Unsupported do
    def data_scope(_action, _actor, _input), do: :unsupported
  end

  defmodule NoCallback do
  end

  defmodule BadField do
    def data_scope(_action, _actor, _input), do: {:ok, project: :tenant}
  end

  defmodule Malformed do
    def data_scope(_action, _actor, _input), do: {:ok, subject: :subject_id}
  end

  setup do
    project = project()
    alice = user(project, "alice")
    bob = user(project, "bob")
    other = user(project(), "carol")

    insert = fn who, text, type ->
      Repo.insert!(%Item{
        project_id: who.actor.project_id,
        subject_id: who.actor.subject_id,
        text: text,
        content_type: type
      })
    end

    %{alice: alice, bob: bob, other: other, insert: insert}
  end

  test "reads see only the actor's project and subject, whatever the input says", %{
    alice: alice,
    bob: bob,
    other: other,
    insert: insert
  } do
    insert.(alice, "mine", "text")
    insert.(bob, "bobs", "text")
    insert.(other, "foreign", "text")

    hostile = %{"project_id" => other.actor.project_id, "subject_id" => bob.actor.subject_id}
    assert ["mine"] = Item |> Scope.all(alice.actor, Policy, hostile) |> Enum.map(& &1.text)

    assert %Item{text: "bobs"} =
             Scope.one(from(i in Item, where: i.text == "bobs"), bob.actor, Policy, %{})

    assert nil == Scope.one(from(i in Item, where: i.text == "bobs"), alice.actor, Policy, %{})
  end

  test "a project-only policy lets the whole project in, never another one", %{
    alice: alice,
    bob: bob,
    other: other,
    insert: insert
  } do
    insert.(alice, "a", "text")
    insert.(bob, "b", "text")
    insert.(other, "c", "text")

    assert ["a", "b"] =
             Item
             |> Scope.all(alice.actor, ProjectOnly, %{})
             |> Enum.map(& &1.text)
             |> Enum.sort()
  end

  test "an extra filter cannot be widened with or_where", %{
    alice: alice,
    bob: bob,
    insert: insert
  } do
    insert.(alice, "mine", "text")
    insert.(bob, "bobs", "text")
    query = from(i in Item, where: i.text == "mine") |> or_where([i], true)
    assert ["mine"] = query |> Scope.all(alice.actor, Policy, %{}) |> Enum.map(& &1.text)
  end

  test "member constraints restrict to the allowed values", %{alice: alice, insert: insert} do
    insert.(alice, "t", "text")
    insert.(alice, "l", "link")

    assert ["l"] =
             Item
             |> Scope.all(alice.actor, Members, %{"types" => ["link"]})
             |> Enum.map(& &1.text)

    assert [] = Item |> Scope.all(alice.actor, Members, %{"types" => []})
  end

  test "writes are scoped and cannot touch other owners' rows", %{
    alice: alice,
    bob: bob,
    insert: insert
  } do
    insert.(alice, "a", "text")
    insert.(bob, "b", "text")

    assert {1, _} = Scope.update_all(Item, [set: [text: "changed"]], alice.actor, Policy, %{})
    assert {1, _} = Scope.delete_all(Item, alice.actor, Policy, %{})
    assert [%{text: "b"}] = Repo.all(Item)
  end

  test "ownership fields are stamped from the actor and cannot be updated", %{
    alice: alice,
    bob: bob
  } do
    forged = %Item{project_id: Ecto.UUID.generate(), subject_id: bob.actor.subject_id, text: "x"}
    item = Scope.insert!(forged, alice.actor, Policy, %{})
    assert item.project_id == alice.actor.project_id and item.subject_id == alice.actor.subject_id

    assert_raise Violation, ~r/Ownership/, fn ->
      Scope.update_all(Item, [set: [subject_id: bob.actor.subject_id]], alice.actor, Policy, %{})
    end

    assert Repo.get!(Item, item.id).subject_id == alice.actor.subject_id
  end

  test "unsupported policies and query shapes are refused, never run unfiltered", %{
    alice: alice,
    insert: insert
  } do
    insert.(alice, "a", "text")

    for module <- [Unsupported, NoCallback, BadField, Malformed] do
      assert {:error, %Violation{}} = Scope.apply(Item, alice.actor, module, :read, %{})
      assert_raise Violation, fn -> Scope.all(Item, alice.actor, module, %{}) end
    end

    refused = [
      from(i in Item, join: o in Item, on: o.id == i.id),
      from(i in Item, where: fragment("true")),
      from(i in Item, where: i.id in subquery(from(o in Item, select: o.id))),
      from(i in Item) |> union_all(^from(o in Item)),
      from(i in Item) |> windows([i], w: [partition_by: i.id]),
      from(i in Item, order_by: fragment("random()")),
      "fyrlet_test_records"
    ]

    for query <- refused do
      assert {:error, %Violation{}} = Scope.apply(query, alice.actor, Policy, :read, %{}),
             inspect(query)
    end
  end

  test "the inbox definition itself runs on the managed path", %{
    alice: alice,
    bob: bob,
    insert: insert
  } do
    insert.(alice, "mine", "text")
    insert.(bob, "bobs", "text")

    assert {:ok, [%{"text" => "mine"}], _} =
             (fn ->
                {:ok, data, scopes} =
                  Fyrlet.TestRecords.execute("records.recent", alice.actor, %{"limit" => 10})

                {:ok, data, scopes}
              end).()
  end
end
