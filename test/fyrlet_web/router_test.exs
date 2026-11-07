defmodule FyrletWeb.RouterTest do
  use Fyrlet.DataCase, async: true
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  alias Fyrlet.Auth
  @endpoint FyrletWeb.Endpoint

  setup do
    project = project()
    %{project: project, alice: user(project, "alice"), bob: user(project, "bob")}
  end

  defp api(user, project) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> user.token)
    |> put_req_header("x-project-id", project.project.id)
  end

  defp service(project) do
    build_conn() |> put_req_header("authorization", "Bearer " <> project.service_key)
  end

  test "health is public and structured" do
    conn = build_conn() |> get("/health")

    assert %{"data" => %{"status" => "ok"}, "request_id" => request_id} =
             json_response(conn, 200)

    assert is_binary(request_id)
  end

  test "unknown routes answer a structured 404" do
    conn = build_conn() |> get("/definitely/not/here")

    assert json_response(conn, 404)["error"]["code"] == "NOT_FOUND"
  end

  test "identity reports the authenticated actor, never another project", %{
    project: project,
    alice: alice,
    bob: bob
  } do
    assert %{"project_id" => project_id, "subject_id" => subject_id} =
             api(alice, project)
             |> get("/api/v1/identity")
             |> json_response(200)
             |> Map.fetch!("data")

    assert project_id == alice.actor.project_id
    assert subject_id == alice.actor.subject_id
    assert bob.actor.subject_id != subject_id

    assert build_conn()
           |> get("/api/v1/identity")
           |> json_response(401)
           |> Map.fetch!("error")
           |> Map.fetch!("code") == "UNAUTHENTICATED"
  end

  test "a user can revoke their own session over HTTP", %{project: project, alice: alice} do
    assert json_response(api(alice, project) |> delete("/api/v1/session"), 200)["data"] == %{
             "revoked" => true
           }

    assert {:error, %Fyrlet.Error{code: "UNAUTHENTICATED"}} =
             Auth.authenticate(alice.token, project.project.id)
  end

  test "a backend key revokes sessions only inside its own project", %{
    project: project,
    alice: alice
  } do
    other = project()

    assert json_response(
             service(other) |> delete("/api/v1/sessions/#{alice.actor.session_id}"),
             404
           )["error"]["code"] == "NOT_FOUND"

    assert json_response(
             service(project) |> delete("/api/v1/sessions/#{alice.actor.session_id}"),
             200
           )["data"] == %{"revoked" => true}

    assert {:error, %Fyrlet.Error{code: "UNAUTHENTICATED"}} =
             Auth.revalidate(alice.actor)
  end

  test "revoking an unknown or malformed session id is a 404", %{project: project} do
    assert json_response(
             service(project) |> delete("/api/v1/sessions/#{Ecto.UUID.generate()}"),
             404
           )["error"]["code"] == "NOT_FOUND"

    assert json_response(service(project) |> delete("/api/v1/sessions/not-a-uuid"), 404)[
             "error"
           ]["code"] == "NOT_FOUND"
  end

  test "the contract states the protocol version and the schema dialect", %{
    project: project,
    alice: alice
  } do
    data = json_response(api(alice, project) |> get("/api/v1/contract"), 200)["data"]
    assert data["protocol_version"] == 1
    assert data["schema_dialect"] == "fyrlet-subset"
  end

  test "an operation request must carry an input object", %{project: project, alice: alice} do
    conn =
      api(alice, project)
      |> put_req_header("idempotency-key", Ecto.UUID.generate())
      |> post("/api/v1/operations/records.add", %{})

    assert json_response(conn, 422)["error"]["code"] == "VALIDATION_FAILED"
  end

  test "capability-gated routes refuse an unnegotiated capability", %{
    project: project,
    alice: alice
  } do
    id = Ecto.UUID.generate()

    assert json_response(api(alice, project) |> get("/api/v1/runs/#{id}"), 400)["error"][
             "code"
           ] == "UNSUPPORTED_CAPABILITY"

    assert json_response(api(alice, project) |> get("/api/v1/ingest/batches/#{id}"), 400)[
             "error"
           ]["code"] == "UNSUPPORTED_CAPABILITY"
  end

  test "with the capability negotiated, missing resources are 404s", %{
    project: project,
    alice: alice
  } do
    id = Ecto.UUID.generate()

    with_runs =
      api(alice, project)
      |> put_req_header("x-fyrlet-capabilities", "runs,ingest")

    assert json_response(with_runs |> get("/api/v1/runs/#{id}"), 404)["error"]["code"] ==
             "NOT_FOUND"

    assert json_response(with_runs |> post("/api/v1/runs/#{id}/cancel", %{}), 404)["error"][
             "code"
           ] == "NOT_FOUND"

    assert json_response(with_runs |> get("/api/v1/ingest/batches/#{id}"), 404)["error"][
             "code"
           ] == "NOT_FOUND"
  end

  test "malformed capability headers are rejected before any work happens", %{
    project: project,
    alice: alice
  } do
    conn =
      api(alice, project)
      |> put_req_header("x-fyrlet-capabilities", "runs=0")
      |> get("/api/v1/runs/#{Ecto.UUID.generate()}")

    assert json_response(conn, 422)["error"]["code"] == "VALIDATION_FAILED"
  end
end
