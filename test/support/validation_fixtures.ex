defmodule Fyrlet.ValidationFixtures.Base do
  defmacro __using__(_options) do
    quote do
      @behaviour Fyrlet.Definition
      @impl true
      def contract, do: Application.fetch_env!(:fyrlet, :validation_test_contract)
      @impl true
      def authorize(_name, _actor, _input), do: :ok
      @impl true
      def execute(_name, _actor, _input), do: {:ok, "ok", []}
      @impl true
      def scope(_name, _actor, _input), do: "test:validation"
    end
  end
end

defmodule Fyrlet.ValidationFixtures.Core do
  use Fyrlet.ValidationFixtures.Base
end

defmodule Fyrlet.ValidationFixtures.Versioned do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def definition_version("demo.numeric"), do: 2
  def definition_version("demo.named"), do: "release-3"
end

defmodule Fyrlet.ValidationFixtures.StaticRun do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def run(_name, _actor, _input), do: {:ok, steps: []}
  @impl true
  def step(_name, _input, _context), do: {:ok, %{}}
end

defmodule Fyrlet.ValidationFixtures.DynamicRun do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def advance(_name, _state, _context), do: {:done, %{}}
  @impl true
  def step(_name, _input, _context), do: {:ok, %{}}
end

defmodule Fyrlet.ValidationFixtures.RunWithoutStep do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def run(_name, _actor, _input), do: {:ok, steps: []}
end

defmodule Fyrlet.ValidationFixtures.Ingest do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def ingest(_name, _actor, _items), do: :ok
end

defmodule Fyrlet.ValidationFixtures.Append do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def stream(_name, _actor, _input), do: {:ok, "test:stream"}
end

defmodule Fyrlet.ValidationFixtures.SharedWithoutMembership do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def shared_query(_name, _actor, _input), do: {:ok, [], %{}}
end

defmodule Fyrlet.ValidationFixtures.Shared do
  use Fyrlet.ValidationFixtures.Base
  @impl true
  def shared_query(_name, _actor, _input), do: {:ok, [], %{}}
  @impl true
  def membership(_name, _actor, _input), do: :member
  @impl true
  def stream(_name, _actor, _input), do: {:ok, "test:stream"}
end
