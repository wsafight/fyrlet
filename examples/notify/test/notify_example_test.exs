defmodule MailProvider do
  @moduledoc "A stand-in e-mail provider the tests steer."
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/send" do
    behavior = Application.get_env(:notify_example, :provider, :ok)

    send(
      Application.get_env(:notify_example, :test_pid),
      {:provider, Plug.Conn.get_req_header(conn, "idempotency-key")}
    )

    case behavior do
      :ok -> send_resp(conn, 200, "{}")
      :accept -> send_resp(conn, 202, "{}")
      :refuse -> send_resp(conn, 422, "{}")
      :broken -> send_resp(conn, 500, "{}")
    end
  end
end

defmodule NotifyExampleTest do
  @moduledoc """
  The first real domain loop: a separate application that uses only Fyrlet's public
  surface (config, migrations, Definition, Runs, Effects, Scope, HTTP, receipts).
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Fyrlet.Repo
  alias Fyrlet.{Effects, Repo}
  alias Fyrlet.Testing
  alias NotifyExample.Notification

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    {:ok, server} =
      Bandit.start_link(plug: MailProvider, port: 0, ip: {127, 0, 0, 1}, startup_log: false)

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:notify_example, :test_pid, self())
    Application.put_env(:notify_example, :provider, :ok)
    Application.put_env(:notify_example, :delivery_adapter, "http")
    Application.put_env(:notify_example, :mail_url, "http://127.0.0.1:#{port}/send")

    for {k, v} <- [allowed_hosts: ["127.0.0.1"], allow_http: true, timeout_ms: 500],
        do: Application.put_env(:fyrlet_effect_http, k, v)

    Application.put_env(:fyrlet, :effect_secrets, %{"mail_provider" => "provider-token"})

    Application.put_env(:fyrlet, :effects,
      retry_base_seconds: 0,
      retry_max_seconds: 0,
      reconcile_delay_seconds: 0
    )

    Application.put_env(:fyrlet, :runs, retry_base_seconds: 0, retry_max_seconds: 0)

    {:ok, project} = Fyrlet.Auth.create_project("notify")

    {:ok, session} =
      Fyrlet.Auth.issue_session(project.service_key, %{"external_subject" => "alice"})

    {:ok, actor} = Fyrlet.Auth.authenticate(session["token"], project.project.id)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)

      for k <- [:effect_secrets, :effects, :runs], do: Application.delete_env(:fyrlet, k)

      for k <- [:allowed_hosts, :allow_http, :timeout_ms],
          do: Application.delete_env(:fyrlet_effect_http, k)
    end)

    %{actor: actor, project: project}
  end

  defp send_notification(actor, event \\ "evt-1", extra \\ %{}) do
    input =
      Map.merge(
        %{
          "event_id" => event,
          "recipient" => "bob@example.com",
          "title" => "Hello",
          "body" => "World"
        },
        extra
      )

    Fyrlet.Runtime.call(actor, "notify.send", input, "req-" <> event <> inspect(extra),
      capabilities: %{"runs" => 1}
    )
  end

  defp drive(id), do: Testing.drive(id)

  defp effect(id), do: hd(Testing.effects(id))

  test "a notification is recorded, delivered and marked", %{actor: actor} do
    {:ok, %{"run_id" => id, "existing" => false}} = send_notification(actor)

    assert drive(id) == "waiting"
    assert [%{delivery: "pending", title: "Hello"}] = Repo.all(Notification)
    assert Testing.run(id).wait_reason == "effect"

    assert Effects.dispatch(effect(id).id) == :succeeded
    assert_received {:provider, [key]}
    assert key == effect(id).operation_id

    assert drive(id) == "completed"
    assert [%{delivery: "delivered"}] = Repo.all(Notification)
    assert Testing.run(id).output == %{"delivered" => true}
  end

  test "the same event is notified once however often it is submitted", %{actor: actor} do
    {:ok, %{"run_id" => id}} = send_notification(actor, "evt-7")

    assert {:ok, %{"run_id" => ^id, "existing" => true}} =
             send_notification(actor, "evt-7", %{"title" => "Changed"})

    drive(id)
    Effects.dispatch(effect(id).id)
    drive(id)

    assert {:ok, %{"run_id" => ^id, "existing" => true}} =
             send_notification(actor, "evt-7", %{"body" => "Other"})

    assert Repo.aggregate(Notification, :count) == 1
    assert Testing.run_count() == 1
  end

  test "a provider that only accepts is confirmed by its receipt", %{
    actor: actor,
    project: project
  } do
    Application.put_env(:notify_example, :provider, :accept)
    {:ok, %{"run_id" => id}} = send_notification(actor)
    drive(id)
    assert Effects.dispatch(effect(id).id) == :accepted
    assert drive(id) == "waiting"

    assert {:ok, %{"status" => "applied"}} =
             Effects.receipt(effect(id).id, "evt-delivered", "succeeded", %{"mailbox" => "ok"})

    assert drive(id) == "completed"
    assert [%{delivery: "delivered"}] = Repo.all(Notification)
    _ = project
  end

  test "a refused message fails the run and leaves the in-app copy as pending", %{actor: actor} do
    Application.put_env(:notify_example, :provider, :refuse)
    {:ok, %{"run_id" => id}} = send_notification(actor)
    drive(id)
    assert Effects.dispatch(effect(id).id) == :failed
    assert Testing.run(id).status == "failed"
    assert [%{delivery: "pending"}] = Repo.all(Notification)
  end

  test "a provider error leaves the outcome unknown: held for a person, resent with the same key when allowed",
       %{actor: actor} do
    Application.put_env(:notify_example, :provider, :broken)
    {:ok, %{"run_id" => id}} = send_notification(actor)
    drive(id)

    # The HTTP adapter declares idempotency, so an unknown outcome is retried with the same key.
    assert Effects.dispatch(effect(id).id) == :retry
    assert_received {:provider, [first]}
    Application.put_env(:notify_example, :provider, :ok)
    assert Effects.dispatch(effect(id).id) == :succeeded
    assert_received {:provider, [second]}
    assert first == second
    assert drive(id) == "completed"
  end

  test "cancelling before delivery sends nothing and keeps the in-app copy", %{actor: actor} do
    {:ok, %{"run_id" => id}} = send_notification(actor)
    drive(id)
    {:ok, %{"status" => "cancelled"}} = Fyrlet.Runs.cancel(actor, id)
    assert effect(id).status == "cancelled"
    assert Effects.dispatch(effect(id).id) == :noop
    refute_received {:provider, _}
    assert [%{delivery: "pending"}] = Repo.all(Notification)
  end

  test "a crash between steps recovers without duplicating the in-app copy", %{actor: actor} do
    {:ok, %{"run_id" => id}} = send_notification(actor)

    Application.put_env(:fyrlet, :run_faults, fn
      :after_claim -> exit(:crash)
      _ -> :ok
    end)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:inject, true)
        Testing.step(id)
      end)

    Application.put_env(:fyrlet, :run_faults, fn point ->
      if Process.get(:inject), do: if(point == :after_claim, do: exit(:crash)), else: :ok
    end)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    Application.delete_env(:fyrlet, :run_faults)

    Testing.expire_leases(id)

    assert Testing.recover().expired_leases == 1
    assert drive(id) == "waiting"
    assert Repo.aggregate(Notification, :count) == 1
  end

  test "each person sees only their own notifications", %{actor: actor, project: project} do
    {:ok, %{"run_id" => id}} = send_notification(actor)
    drive(id)

    {:ok, session} =
      Fyrlet.Auth.issue_session(project.service_key, %{"external_subject" => "mallory"})

    {:ok, mallory} = Fyrlet.Auth.authenticate(session["token"], project.project.id)

    assert {:ok, [%{"title" => "Hello"}], _} =
             NotifyExample.Definition.execute("notify.inbox", actor, %{"limit" => 10})

    assert {:ok, [], _} =
             NotifyExample.Definition.execute("notify.inbox", mallory, %{"limit" => 10})

    assert {:error, %Fyrlet.Error{code: "FORBIDDEN"}} = Fyrlet.Runs.get(mallory, id)
    assert {:ok, %{"status" => "waiting"}} = Fyrlet.Runs.get(actor, id)
  end
end
