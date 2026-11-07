defmodule NotifyExample.Definition do
  @moduledoc """
  A notification service built only on Fyrlet's public surface: one `run` operation whose
  plan is record -> deliver -> mark, an in-app list, and the e-mail provider behind the HTTP
  effect adapter.

    * `notify.send` is idempotent per event (`event_id` is the business key: the same event
      is notified once, however often it is submitted);
    * recording the in-app copy is atomic with the step's result (managed commit);
    * delivery is an effect, so an unknown outcome is held for a person rather than resent
      blindly, and the provider confirms with a receipt.
  """
  @behaviour Fyrlet.Definition
  import Ecto.Query
  alias Fyrlet.{Error, Repo, Runs, Schema, Scope}
  alias NotifyExample.Notification

  @recipient %{"type" => "string", "minLength" => 3, "maxLength" => 200}
  @item Schema.object(
          %{
            "id" => %{"type" => "string", "format" => "uuid"},
            "run_id" => %{"type" => "string", "format" => "uuid"},
            "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
            "body" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_000},
            "delivery" => %{"type" => "string"},
            "inserted_at" => %{"type" => "string", "format" => "date-time"}
          },
          ~w(id run_id title body delivery inserted_at)
        )

  @impl true
  def contract do
    %{
      "operations" => %{
        "notify.send" =>
          Runs.operation(
            Schema.object(
              %{
                "event_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
                "recipient" => @recipient,
                "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
                "body" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_000}
              },
              ~w(event_id recipient title body)
            ),
            on_conflict: :return_existing
          )
      },
      "subscriptions" => %{
        "notify.inbox" => %{
          "input" =>
            Schema.object(%{
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 20}
            }),
          "output" => %{"type" => "array", "items" => @item, "maxItems" => 50}
        }
      }
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def data_scope(_action, _actor, _input), do: {:ok, project: :project_id, subject: :subject_id}

  @impl true
  def scope(_name, actor, _input),
    do: Runs.scope(actor)

  @impl true
  def execute("notify.inbox", actor, %{"limit" => limit}) do
    rows =
      from(n in Notification, order_by: [desc: n.inserted_at, desc: n.id], limit: ^limit)
      |> Scope.all(actor, __MODULE__, %{})

    {:ok, Enum.map(rows, &serialize(&1, actor)), []}
  end

  def execute(_name, _actor, _input), do: {:error, Error.not_found()}

  # ---- the run ------------------------------------------------------------------------

  @impl true
  def run("notify.send", actor, input) do
    {:ok,
     business_key: "notify:#{actor.subject_id}:" <> input["event_id"],
     steps: [
       %{type: :step, name: "record", input: Map.take(input, ~w(title body))},
       %{type: :step, name: "deliver", input: Map.take(input, ~w(recipient title body))},
       %{type: :step, name: "mark", input: %{}}
     ]}
  end

  @impl true
  def step("record", input, context) do
    # Atomic with the step's own result: either the copy exists and the step succeeded, or neither.
    {:ok, %{"recorded" => true},
     commit: fn ->
       Repo.insert!(%Notification{
         project_id: context.project_id,
         subject_id: context.initiator_subject_id,
         run_id: context.run_id,
         title: input["title"],
         body: input["body"]
       })
     end}
  end

  def step("deliver", input, _context),
    do: delivery(input, Application.get_env(:notify_example, :delivery_adapter, "email"))

  def step("mark", _input, context) do
    {:ok, %{"delivered" => true},
     commit: fn ->
       from(notification in Notification, where: notification.run_id == ^context.run_id)
       |> Repo.update_all(set: [delivery: "delivered"])
     end}
  end

  defp delivery(input, "email") do
    {:effect,
     %{
       adapter: "email",
       key: "email",
       secret_ref: "mail_provider",
       payload: %{
         "from" => Application.get_env(:notify_example, :sender),
         "to" => [input["recipient"]],
         "subject" => input["title"],
         "text" => input["body"]
       }
     }}
  end

  defp delivery(input, "http") do
    {:effect,
     %{
       adapter: "http",
       key: "email",
       secret_ref: "mail_provider",
       payload: %{
         "url" => Application.get_env(:notify_example, :mail_url),
         "body" => %{
           "to" => input["recipient"],
           "subject" => input["title"],
           "text" => input["body"]
         }
       }
     }}
  end

  @impl true
  def run_authorize(_name, _action, actor, %{"owner_subject_id" => owner}) when is_binary(owner),
    do: if(actor.subject_id == owner, do: :ok, else: {:error, Error.forbidden()})

  def run_authorize(_name, :start, _actor, _input), do: :ok

  defp serialize(n, actor) do
    delivery =
      case Runs.get(actor, n.run_id) do
        {:ok, %{"status" => status}} when status in ["failed", "cancelled", "expired"] -> status
        _active -> n.delivery
      end

    %{
      "id" => n.id,
      "run_id" => n.run_id,
      "title" => n.title,
      "body" => n.body,
      "delivery" => delivery,
      "inserted_at" => DateTime.to_iso8601(n.inserted_at)
    }
  end
end
