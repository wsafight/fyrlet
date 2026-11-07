defmodule FyrletWeb.RunsHTTPTest do
  use Fyrlet.RunsCase
  import Plug.Conn
  import Phoenix.ConnTest
  @endpoint FyrletWeb.Endpoint

  setup do
    project = project()
    %{project: project, alice: user(project, "alice"), bob: user(project, "bob")}
  end

  defp api(user, project, capabilities \\ "runs") do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> user.token)
      |> put_req_header("x-project-id", project.project.id)

    if capabilities, do: put_req_header(conn, "x-fyrlet-capabilities", capabilities), else: conn
  end

  defp start(user, project, input \\ %{}) do
    conn =
      api(user, project)
      |> put_req_header("idempotency-key", key())
      |> post("/api/v1/operations/runs.demo", %{"input" => input})

    json_response(conn, 200)["data"]
  end

  test "start, observe, signal and cancel over HTTP", %{alice: alice, project: project} do
    assert %{"run_id" => id, "status" => "pending"} = start(alice, project, %{"source" => "x"})
    assert drive(id) == "waiting"

    shown = api(alice, project) |> get("/api/v1/runs/#{id}") |> json_response(200)
    assert %{"status" => "waiting", "wait_reason" => "signal", "steps" => steps} = shown["data"]

    assert [
             %{"name" => "prepare", "status" => "succeeded"},
             %{"type" => "wait", "id" => wait_id},
             _
           ] = steps

    assert shown["data"]["events_truncated"] == false

    receipt =
      api(alice, project)
      |> post("/api/v1/runs/#{id}/signals", %{
        "wait_id" => wait_id,
        "name" => "user_approval",
        "idempotency_key" => "s1"
      })
      |> json_response(200)

    assert receipt["data"]["status"] == "consumed"

    cancelled =
      api(alice, project) |> post("/api/v1/runs/#{id}/cancel", %{}) |> json_response(200)

    assert cancelled["data"]["status"] == "cancelled"
  end

  test "runs need the capability header and a visible run", %{
    alice: alice,
    bob: bob,
    project: project
  } do
    %{"run_id" => id} = start(alice, project)

    for conn <- [
          api(alice, project, nil) |> get("/api/v1/runs/#{id}"),
          api(alice, project, "other") |> get("/api/v1/runs/#{id}"),
          api(alice, project, nil) |> post("/api/v1/runs/#{id}/cancel", %{}),
          api(alice, project, nil)
          |> put_req_header("idempotency-key", key())
          |> post("/api/v1/operations/runs.demo", %{"input" => %{}})
        ] do
      assert json_response(conn, 400)["error"]["code"] == "UNSUPPORTED_CAPABILITY"
    end

    assert json_response(api(bob, project) |> get("/api/v1/runs/#{id}"), 403)["error"]["code"] ==
             "FORBIDDEN"

    assert json_response(api(alice, project) |> get("/api/v1/runs/not-a-uuid"), 404)["error"][
             "code"
           ] == "NOT_FOUND"

    assert json_response(api(alice, project, "runs=zero") |> get("/api/v1/runs/#{id}"), 422)[
             "error"
           ]["code"] == "VALIDATION_FAILED"

    stranger_project = project()
    stranger = user(stranger_project, "eve")

    assert json_response(api(stranger, stranger_project) |> get("/api/v1/runs/#{id}"), 404)[
             "error"
           ]["code"] == "NOT_FOUND"

    assert json_response(build_conn() |> get("/api/v1/runs/#{id}"), 401)["error"]["code"] ==
             "UNAUTHENTICATED"
  end

  test "the contract lists runs when the capability is enabled", %{alice: alice, project: project} do
    contract = api(alice, project, nil) |> get("/api/v1/contract") |> json_response(200)

    assert contract["data"]["protocol_version"] == 1 and
             contract["data"]["capabilities"]["runs"] == 1

    assert %{"kind" => "run"} = contract["data"]["operations"]["runs.demo"]
    assert Map.has_key?(contract["data"]["subscriptions"], "fyrlet.run")
    assert Map.has_key?(contract["data"]["subscriptions"], "fyrlet.runs.recent")
  end
end
