defmodule Fyrlet.RegistryFixtures.Dynamic do
  @behaviour Fyrlet.Definition

  @impl true
  def contract, do: Application.fetch_env!(:fyrlet, :registry_test_contract)

  @impl true
  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def execute(_name, _actor, _input), do: {:ok, "ok", []}

  @impl true
  def scope(_name, _actor, _input), do: "test:dynamic"
end

defmodule Fyrlet.RegistryFixtures.MissingCallback do
  # Intentionally does not declare @behaviour: the registry must detect the
  # missing execute/3 callback at runtime instead of relying on the compiler.
  def contract, do: %{"operations" => %{}, "subscriptions" => %{}}

  def authorize(_name, _actor, _input), do: :ok

  def scope(_name, _actor, _input), do: "test:missing"
end
