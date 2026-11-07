defmodule Fyrlet.Effects.Worker do
  @moduledoc false
  use Oban.Worker, queue: :fyrlet, max_attempts: 5

  @impl true
  def perform(%Oban.Job{args: %{"kind" => "reconcile", "effect_id" => id}}) do
    Fyrlet.Effects.reconcile(id)
    :ok
  end

  def perform(%Oban.Job{args: %{"kind" => "cancel", "effect_id" => id}}) do
    Fyrlet.Effects.cancel_external(id)
    :ok
  end

  def perform(%Oban.Job{args: %{"effect_id" => id}}) do
    Fyrlet.Effects.dispatch(id)
    :ok
  end

  def enqueue(kind, effect_id, options \\ []) do
    %{"kind" => kind, "effect_id" => effect_id}
    |> new(Keyword.merge([unique: [period: 30, states: [:available, :retryable]]], options))
    |> Oban.insert!()
  end
end
