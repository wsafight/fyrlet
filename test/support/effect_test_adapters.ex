defmodule Fyrlet.EffectTest.Base do
  @moduledoc """
  Shared behaviour of the test adapters: every call is reported to the test process and
  answered by a handler the test installs with `Application.put_env(:fyrlet, :effect_handlers, ...)`.
  """
  def call(action, effect, default) do
    if pid = Application.get_env(:fyrlet, :effect_test_pid),
      do: send(pid, {:adapter, action, effect})

    case Application.get_env(:fyrlet, :effect_handlers, %{})[action] do
      nil -> default
      handler -> handler.(effect)
    end
  end
end

defmodule Fyrlet.EffectTest.Idempotent do
  @behaviour Fyrlet.Effects.Adapter
  alias Fyrlet.EffectTest.Base

  @impl true
  def capabilities,
    do: %{
      "idempotency" => %{"window_seconds" => 3_600},
      "queryable" => true,
      "cancellable" => true,
      "acceptance" => "final",
      "version" => "1"
    }

  @impl true
  def dispatch(effect), do: Base.call(:dispatch, effect, {:succeeded, %{"sent" => true}})
  @impl true
  def query(effect), do: Base.call(:query, effect, :not_found)
  @impl true
  def cancel(effect), do: Base.call(:cancel, effect, :ok)
end

defmodule Fyrlet.EffectTest.QueryOnly do
  @behaviour Fyrlet.Effects.Adapter
  alias Fyrlet.EffectTest.Base

  @impl true
  def capabilities,
    do: %{
      "idempotency" => nil,
      "queryable" => true,
      "cancellable" => false,
      "acceptance" => "provider_accepted",
      "version" => "1"
    }

  @impl true
  def dispatch(effect), do: Base.call(:dispatch, effect, {:succeeded, %{"sent" => true}})
  @impl true
  def query(effect), do: Base.call(:query, effect, :not_found)
end

defmodule Fyrlet.EffectTest.Manual do
  @behaviour Fyrlet.Effects.Adapter
  alias Fyrlet.EffectTest.Base

  @impl true
  def capabilities,
    do: %{
      "idempotency" => nil,
      "queryable" => false,
      "cancellable" => false,
      "acceptance" => "final",
      "version" => "1"
    }

  @impl true
  def dispatch(effect), do: Base.call(:dispatch, effect, {:succeeded, %{"sent" => true}})
end
