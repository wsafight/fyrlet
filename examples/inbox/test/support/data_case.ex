defmodule InboxExample.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Fyrlet.Testing, only: [project: 0, user: 1, user: 2]
      import InboxExample.DataCase, only: [add: 1, add: 2]
      alias Fyrlet.{Auth, Error, Repo, Runtime}
      alias InboxExample.Item, as: InboxItem
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Fyrlet.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  def add(actor, text \\ "hello"),
    do: Fyrlet.Runtime.call(actor, "inbox.add", %{"text" => text}, Ecto.UUID.generate())
end
