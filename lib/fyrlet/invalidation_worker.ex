defmodule Fyrlet.InvalidationWorker do
  use Oban.Worker, queue: :fyrlet, max_attempts: 10

  @impl true
  def perform(job), do: broadcast(job)

  def broadcast(%Oban.Job{id: identifier, args: %{"scopes" => scopes}}, change \\ nil) do
    message =
      if is_nil(change), do: {:invalidated, identifier}, else: {:invalidated, identifier, change}

    Enum.each(scopes, fn scope ->
      :ok = Phoenix.PubSub.broadcast(Fyrlet.PubSub, scope, message)
    end)

    :ok
  end
end
