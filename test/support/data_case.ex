defmodule Fyrlet.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Fyrlet.Fixtures
      alias Fyrlet.{Auth, Error, Repo, Runtime}
      alias InboxExample.Item, as: InboxItem
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Fyrlet.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end
end
