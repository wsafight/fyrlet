defmodule Fyrlet.InvalidationWorker do
  use Oban.Worker, queue: :fyrlet, max_attempts: 10

  @impl true
  def perform(job), do: broadcast(job)

  @doc """
  A job that is never persisted, for broadcasting an invalidation without the durable fallback.

  The identifier only de-duplicates deliveries to a subscriber, so it needs to be unique, not
  ordered. It is a random negative integer: it cannot collide with a database job id, and
  nodes cannot hand out the same one (unlike a node-local counter).
  """
  def transient(scopes, project_id) do
    %{"scopes" => scopes, "project_id" => project_id}
    |> new()
    |> Ecto.Changeset.apply_changes()
    |> Map.put(:id, -:rand.uniform(1_152_921_504_606_846_976))
  end

  def broadcast(%Oban.Job{id: identifier, args: %{"scopes" => scopes}}, change \\ nil) do
    message =
      if is_nil(change), do: {:invalidated, identifier}, else: {:invalidated, identifier, change}

    Enum.each(scopes, fn scope ->
      :ok = Phoenix.PubSub.broadcast(Fyrlet.PubSub, scope, message)
    end)

    :ok
  end

  def broadcast_local(%Oban.Job{id: identifier, args: %{"scopes" => scopes}}) do
    Enum.each(scopes, fn scope ->
      :ok = Phoenix.PubSub.local_broadcast(Fyrlet.PubSub, scope, {:invalidated, identifier})
    end)

    :ok
  end
end
