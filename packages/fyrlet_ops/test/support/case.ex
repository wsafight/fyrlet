defmodule FyrletOps.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Fyrlet.Testing
      import FyrletOps.Case
      alias Fyrlet.Repo
      alias Fyrlet.Runs.Run
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Fyrlet.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  import Ecto.Query

  def start_run!(user) do
    {:ok, %{"run_id" => id}} =
      Fyrlet.Runtime.call(user.actor, "ops.hold", %{}, Ecto.UUID.generate(),
        capabilities: %{"runs" => 1}
      )

    id
  end

  def steps(run_id),
    do: Fyrlet.Repo.all(from(s in Fyrlet.Runs.Step, where: s.run_id == ^run_id, order_by: s.seq))
end
