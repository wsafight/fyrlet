defmodule Fyrlet.InvalidationWorker do
  use Oban.Worker, queue: :fyrlet, max_attempts: 10

  @impl true
  def perform(job), do: broadcast(job)

  def broadcast(%Oban.Job{id: identifier, args: %{"scopes" => scopes}}, change \\ nil) do
    message =
      cond do
        is_integer(identifier) and not is_nil(change) -> {:invalidated, identifier, change}
        is_integer(identifier) -> {:invalidated, identifier}
        true -> :invalidated
      end

    Enum.each(scopes, fn scope ->
      :ok = Phoenix.PubSub.broadcast(Fyrlet.PubSub, scope, message)
    end)

    :ok
  end
end
