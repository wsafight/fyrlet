defmodule Fyrlet.QuotaTest do
  use Fyrlet.DataCase, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  alias Fyrlet.{Quota, Runtime}
  alias Fyrlet.Subscriptions.Tracker
  @endpoint FyrletWeb.Endpoint

  setup do
    previous = Application.get_env(:fyrlet, :quotas)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fyrlet, :quotas, previous),
        else: Application.delete_env(:fyrlet, :quotas)
    end)

    project = project()
    %{project: project, alice: user(project), bob: user(project, "bob")}
  end

  defp quotas(value), do: Application.put_env(:fyrlet, :quotas, value)

  defp write(user, text),
    do: Runtime.call(user.actor, "records.add", %{"text" => text}, Ecto.UUID.generate())

  test "nothing is limited unless configured", %{alice: alice} do
    Application.delete_env(:fyrlet, :quotas)
    for n <- 1..30, do: assert({:ok, _} = write(alice, "m#{n}"))
  end

  test "writes beyond the per-second limit are refused with a retry hint", %{alice: alice} do
    quotas(default: [writes_per_second: 3])

    # A window boundary can fall inside the loop; the limit holds for any whole second.
    results = for n <- 1..8, do: write(alice, "m#{n}")
    accepted = Enum.count(results, &match?({:ok, _}, &1))
    assert accepted in 3..6

    assert {:error, %Fyrlet.Error{code: "LIMIT_EXCEEDED", retryable: true, details: details}} =
             Enum.find(results, &match?({:error, _}, &1))

    assert details["scope"] == "project" and details["class"] == "write"
    assert details["limit"] == 3
    assert details["retry_after_ms"] in 1..1000
  end

  test "the budget returns in the next window", %{alice: alice} do
    quotas(default: [writes_per_second: 1])
    Enum.find(1..20, fn _ -> match?({:error, _}, write(alice, "x")) end)
    Process.sleep(1_050)
    assert {:ok, _} = write(alice, "after the wait")
  end

  test "reads and writes are counted separately", %{alice: alice} do
    quotas(default: [writes_per_second: 1, reads_per_second: 50])
    Enum.find(1..20, fn _ -> match?({:error, _}, write(alice, "x")) end)

    for _ <- 1..5, do: assert({:ok, _} = Runtime.call(alice.actor, "records.list", %{}))
  end

  test "projects do not share a budget, and an override replaces the default key by key", %{
    alice: alice
  } do
    other = user(project(), "carol")

    quotas(
      default: [writes_per_second: 1],
      projects: %{alice.actor.project_id => [writes_per_second: 100]}
    )

    for n <- 1..10, do: assert({:ok, _} = write(alice, "m#{n}"))
    assert Enum.any?(1..20, fn _ -> match?({:error, _}, write(other, "x")) end)

    # The override sets only writes; the default's other keys still apply.
    assert Quota.max_subscriptions(alice.actor.project_id) == nil

    quotas(
      default: [max_subscriptions: 7],
      projects: %{alice.actor.project_id => [writes_per_second: 2]}
    )

    assert Quota.max_subscriptions(alice.actor.project_id) == 7
  end

  test "a refused call is reported over HTTP as 429 with Retry-After", %{project: project} do
    quotas(default: [writes_per_second: 1])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> project.service_key)
      |> post("/api/v1/sessions", %{"external_subject" => "http-user"})

    session = json_response(conn, 200)["data"]

    call = fn n ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> put_req_header("x-project-id", session["project_id"])
      |> put_req_header("idempotency-key", "k#{n}-#{System.unique_integer([:positive])}")
      |> post("/api/v1/operations/records.add", %{"input" => %{"text" => "t#{n}"}})
    end

    refused = Enum.find_value(1..10, fn n -> (c = call.(n)).status == 429 && c end)
    assert refused, "expected a 429"
    assert json_response(refused, 429)["error"]["code"] == "LIMIT_EXCEEDED"
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..1
  end

  test "the subscription cap counts per project and is released when a channel ends", %{
    alice: alice
  } do
    other_project_id = user(project(), "dave").actor.project_id
    quotas(default: [max_subscriptions: 2])
    project_id = alice.actor.project_id
    transport = spawn(fn -> Process.sleep(:infinity) end)
    channels = for _ <- 1..3, do: spawn(fn -> Process.sleep(:infinity) end)
    [a, b, c] = channels

    assert :ok = Tracker.claim(transport, a, 20, project_id)
    assert :ok = Tracker.claim(transport, b, 20, project_id)

    assert {:error, %Fyrlet.Error{code: "LIMIT_EXCEEDED", details: %{"scope" => "project"}}} =
             Tracker.claim(transport, c, 20, project_id)

    # Another project is unaffected, and a claim without a project is only per connection.
    assert :ok = Tracker.claim(transport, c, 20, other_project_id)
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Tracker.claim(transport, other, 20)

    Process.exit(a, :kill)

    wait_until(fn ->
      match?(
        :ok,
        Tracker.claim(transport, spawn(fn -> Process.sleep(:infinity) end), 20, project_id)
      )
    end)

    for pid <- [transport, other | channels], do: Process.exit(pid, :kill)
  end

  test "malformed quota configuration is refused when the application starts" do
    for bad <- [
          [default: [writes_per_second: 0]],
          [default: [writes_per_second: "5"]],
          [default: [typo_per_second: 5]],
          [default: :nope],
          [projects: %{42 => [writes_per_second: 1]}],
          [projects: %{"p" => [max_subscriptions: -1]}]
        ] do
      quotas(bad)
      assert_raise ArgumentError, fn -> Quota.validate!() end
    end

    quotas(
      default: [reads_per_second: nil, writes_per_second: 5],
      projects: %{"p" => [max_subscriptions: 9]}
    )

    assert :ok = Quota.validate!()
  end

  test "defaults can come from the environment" do
    settings =
      Fyrlet.RuntimeConfig.settings(
        :dev,
        fn
          "FYRLET_PROJECT_WRITES_PER_SECOND" -> "40"
          "FYRLET_PROJECT_MAX_SUBSCRIPTIONS" -> "900"
          _other -> nil
        end
      )

    assert settings[:quotas] == [default: [writes_per_second: 40, max_subscriptions: 900]]
    refute Keyword.has_key?(Fyrlet.RuntimeConfig.settings(:dev, fn _ -> nil end), :quotas)

    assert_raise ArgumentError, ~r/FYRLET_PROJECT_READS_PER_SECOND/, fn ->
      Fyrlet.RuntimeConfig.settings(:dev, fn
        "FYRLET_PROJECT_READS_PER_SECOND" -> "0"
        _other -> nil
      end)
    end
  end

  defp wait_until(fun, tries \\ 40) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end
end
