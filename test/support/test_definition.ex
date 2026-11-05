defmodule Fyrlet.TestDefinition do
  @behaviour Fyrlet.Definition

  @impl true
  def contract do
    operation = fn kind ->
      %{
        "kind" => kind,
        "input" => Fyrlet.Schema.object(%{}),
        "output" => %{"type" => "string"}
      }
    end

    %{
      "operations" => %{
        "test.bad_output" => operation.("write"),
        "test.denied" => operation.("write"),
        "test.raise" => operation.("write"),
        "test.revoke" => operation.("read"),
        "test.echo" => operation.("read")
      },
      "subscriptions" => %{
        "test.denied_sub" => %{
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def authorize("test.denied", _actor, _input), do: {:error, Fyrlet.Error.forbidden()}
  def authorize("test.denied_sub", _actor, _input), do: {:error, Fyrlet.Error.forbidden()}
  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def scope(_name, actor, _input), do: "test:#{actor.subject_id}"

  @impl true
  def execute("test.bad_output", actor, _input) do
    Fyrlet.Repo.insert!(%Fyrlet.InboxItem{
      project_id: actor.project_id,
      subject_id: actor.subject_id,
      text: "rolled back",
      content_type: "text"
    })

    {:ok, 123, [scope("test.bad_output", actor, %{})]}
  end

  def execute("test.raise", _actor, _input), do: raise("business failure")

  def execute("test.revoke", actor, _input) do
    {:ok, _revoked} = Fyrlet.Auth.revoke_own_session(actor)
    {:ok, "revoked", []}
  end

  def execute("test.echo", _actor, _input), do: {:ok, "ok", []}

  def execute("test.denied_sub", _actor, _input), do: {:ok, "ok", []}
end
