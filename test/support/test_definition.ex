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
        "test.echo" => operation.("read"),
        "test.public_read" => Map.put(operation.("read"), "public", true),
        "test.public_write" => Map.put(operation.("write"), "public", true)
      },
      "subscriptions" => %{
        "test.public_feed" => %{
          "public" => true,
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        },
        "test.private_feed" => %{
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        },
        "test.denied_sub" => %{
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        },
        # Loading it revokes the viewer's own session: the data must never be sent.
        "test.revoking_feed" => %{
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        },
        # Counts how often its data is loaded.
        "test.counting_feed" => %{
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
    Fyrlet.Repo.insert!(%Fyrlet.TestRecord{
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
  def execute("test.public_read", actor, _input), do: {:ok, "public:" <> actor.kind, []}
  def execute("test.public_write", _actor, _input), do: {:ok, "written", []}
  def execute("test.public_feed", _actor, _input), do: {:ok, "feed", []}
  def execute("test.private_feed", _actor, _input), do: {:ok, "secret", []}

  def execute("test.denied_sub", _actor, _input) do
    send(Application.get_env(:fyrlet, :load_probe, self()), :loaded)
    {:ok, "ok", []}
  end

  def execute("test.revoking_feed", actor, _input) do
    {:ok, _revoked} = Fyrlet.Auth.revoke_own_session(actor)
    {:ok, "secret", []}
  end

  def execute("test.counting_feed", _actor, _input) do
    send(Application.get_env(:fyrlet, :load_probe, self()), :loaded)
    {:ok, "counted", []}
  end
end
