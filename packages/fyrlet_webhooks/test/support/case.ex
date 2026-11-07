defmodule FyrletWebhooks.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Fyrlet.Testing
      import FyrletWebhooks.Case
      alias Fyrlet.{Error, Repo}
      alias Fyrlet.Runs.Signal
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Fyrlet.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  def status(run_id), do: Fyrlet.Testing.run(run_id).status

  def start_run!(user) do
    {:ok, %{"run_id" => id}} =
      Fyrlet.Runtime.call(user.actor, "webhooks.demo", %{}, Ecto.UUID.generate(),
        capabilities: %{"runs" => 1}
      )

    id
  end
end
