defmodule Fyrlet.ReadinessTest do
  use Fyrlet.DataCase, async: true
  import Phoenix.ConnTest
  @endpoint FyrletWeb.Endpoint

  defmodule FailedRepo do
    def query("SELECT 1", [], timeout: 1_000, pool_timeout: 1_000),
      do: {:error, %RuntimeError{message: "secret database connection details"}}
  end

  defmodule ExitedRepo do
    def query(_query, _parameters, _options), do: exit(:noproc)
  end

  test "readiness checks the database and returns an uncached public response" do
    conn = build_conn() |> get("/ready")
    assert json_response(conn, 200)["data"] == %{"status" => "ready"}
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert json_response(build_conn() |> get("/health"), 200)["data"] == %{"status" => "ok"}
  end

  test "database errors and unavailable pools produce sanitized retryable 503 errors" do
    for repo <- [FailedRepo, ExitedRepo, NotRunningRepo] do
      assert {:error, error} = Fyrlet.Readiness.check(repo)
      assert Fyrlet.Error.status(error) == 503
      assert error.retryable
      refute inspect(error) =~ "secret"
    end
  end

  test "the HTTP readiness route returns 503 when its process cannot check out a connection" do
    owner = self()

    spawn(fn ->
      response = build_conn() |> get("/ready") |> json_response(503)
      send(owner, {:not_ready, response})
    end)

    assert_receive {:not_ready, %{"error" => %{"code" => "UNAVAILABLE", "retryable" => true}}},
                   2_000
  end
end
