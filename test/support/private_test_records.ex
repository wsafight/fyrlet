defmodule Fyrlet.PrivateTestRecords do
  @behaviour Fyrlet.Definition

  @impl true
  def contract do
    specification =
      Fyrlet.TestRecords.contract()["subscriptions"]["records.recent"] |> Map.delete("shared")

    specification =
      case Application.get_env(:fyrlet, :private_snapshot_bytes) do
        nil -> specification
        limit -> Map.put(specification, "max_snapshot_bytes", limit)
      end

    %{"operations" => %{}, "subscriptions" => %{"private.recent" => specification}}
  end

  @impl true
  def authorize(_name, actor, _input) do
    if Application.get_env(:fyrlet, :private_deny) == actor.subject_id,
      do: {:error, Fyrlet.Error.forbidden()},
      else: :ok
  end

  @impl true
  def scope(_name, actor, input), do: Fyrlet.TestRecords.scope("records.recent", actor, input)

  @impl true
  def execute(_name, actor, input) do
    result = Fyrlet.TestRecords.execute("records.recent", actor, input)

    if Application.get_env(:fyrlet, :private_revoke_on_load),
      do: Fyrlet.Auth.revoke_own_session(actor)

    result
  end

  @impl true
  def update_subscription(name, actor, parameters, view, change),
    do: Fyrlet.TestRecords.update_subscription(name, actor, parameters, view, change)
end
