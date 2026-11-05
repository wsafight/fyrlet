defmodule Fyrlet.InvalidationWorker do
  use Oban.Worker, queue: :fyrlet, max_attempts: 10

  @impl true
  def perform(job), do: broadcast(job)

  def broadcast(%Oban.Job{id: identifier, args: %{"scopes" => scopes}}) do
    message = if is_integer(identifier), do: {:invalidated, identifier}, else: :invalidated

    Enum.each(scopes, fn scope ->
      Phoenix.PubSub.broadcast(Fyrlet.PubSub, scope, message)
    end)

    :ok
  end
end
