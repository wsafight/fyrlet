defmodule FyrletWeb.Router do
  use Plug.Router
  alias Fyrlet.{Auth, Error, Registry, Runtime, Schema}
  alias FyrletWeb.Response

  plug :match
  plug :dispatch

  get "/health" do
    Response.success(conn, %{"status" => "ok"})
  end

  get "/metrics" do
    if Fyrlet.Metrics.enabled?() and scrape_authorized?(conn) do
      conn
      |> put_resp_content_type("text/plain; version=0.0.4")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Fyrlet.Metrics.render())
    else
      # The same answer whether metrics are off or the token is wrong.
      Response.error(conn, Error.not_found())
    end
  end

  post "/api/v1/sessions" do
    Response.result(conn, Auth.issue_session(bearer(conn), conn.body_params))
  end

  delete "/api/v1/sessions/:id" do
    Response.result(conn, Auth.revoke_session(bearer(conn), id))
  end

  delete "/api/v1/session" do
    result = with {:ok, actor} <- actor(conn), do: Auth.revoke_own_session(actor)
    Response.result(conn, result)
  end

  post "/api/v1/anonymous/sessions" do
    project_id = conn.body_params["project_id"]
    Response.result(conn, Fyrlet.Features.Anonymous.issue(project_id))
  end

  get "/api/v1/contract" do
    result =
      with {:ok, actor} <- actor(conn),
           :ok <- not_anonymous(actor),
           do: {:ok, Registry.export()}

    Response.result(conn, result)
  end

  get "/api/v1/identity" do
    result =
      with {:ok, actor} <- actor(conn),
           do: {:ok, %{"project_id" => actor.project_id, "subject_id" => actor.subject_id}}

    Response.result(conn, result)
  end

  post "/api/v1/operations/:name" do
    operation(conn, name, &Runtime.call_with_outcome/5)
  end

  post "/api/v1/operations/:name/recover" do
    operation(conn, name, &Runtime.recover/5)
  end

  get "/api/v1/runs/:id" do
    result =
      with {:ok, actor} <- actor(conn),
           :ok <- run_capability(conn),
           do: Fyrlet.Runs.get(actor, id)

    Response.result(conn, result)
  end

  post "/api/v1/runs/:id/signals" do
    result =
      with {:ok, actor} <- actor(conn),
           :ok <- run_capability(conn),
           do: Fyrlet.Runs.signal(actor, id, conn.body_params)

    Response.result(conn, result)
  end

  get "/api/v1/ingest/batches/:id" do
    result =
      with {:ok, actor} <- actor(conn),
           {:ok, capabilities} <- capabilities(conn),
           :ok <- Fyrlet.Capabilities.require(capabilities, "ingest"),
           do: Fyrlet.Features.Ingest.batch(actor, id)

    Response.result(conn, result)
  end

  post "/api/v1/runs/:id/cancel" do
    result =
      with {:ok, actor} <- actor(conn),
           :ok <- run_capability(conn),
           do: Fyrlet.Runs.cancel(actor, id)

    Response.result(conn, result)
  end

  # Receivers confirm delivery with the project's service key (a backend credential,
  # never a user token). The effect must belong to the key's project.
  post "/api/v1/effects/:id/receipts" do
    result =
      with {:ok, key} <- Auth.authenticate_key(bearer(conn)),
           {:ok, _uuid} <- Ecto.UUID.cast(id) |> receipt_id(),
           %Fyrlet.Effects.Effect{project_id: project} <-
             Fyrlet.Repo.get(Fyrlet.Effects.Effect, id),
           true <- project == key.project_id,
           {:ok, params} <- receipt_params(conn.body_params) do
        Fyrlet.Effects.receipt(id, params.receipt_id, params.outcome, params.result)
      else
        {:error, %Error{} = error} -> {:error, error}
        _other -> {:error, Error.not_found()}
      end

    Response.result(conn, result)
  end

  match "/api/v1/plugins/:plugin/*rest" do
    Fyrlet.Plugins.dispatch(conn, plugin, rest)
  end

  # ---- external executors (server-to-server; an executor credential, never a user token) ----

  post "/api/v1/executor/claim" do
    result =
      with {:ok, executor} <- executor(conn),
           queues when is_list(queues) <-
             conn.body_params["queues"] || {:error, bad_executor_request()} do
        Fyrlet.Runs.Executor.claim(executor, Enum.filter(queues, &is_binary/1))
      else
        {:error, %Error{} = error} -> {:error, error}
        _other -> {:error, bad_executor_request()}
      end

    Response.result(conn, result)
  end

  post "/api/v1/executor/attempts/:id/heartbeat" do
    result =
      with {:ok, executor} <- executor(conn),
           {:ok, lease, epoch} <- lease(conn.body_params),
           do: Fyrlet.Runs.Executor.heartbeat(executor, id, lease, epoch)

    Response.result(conn, result)
  end

  get "/api/v1/executor/attempts/:id" do
    conn = fetch_query_params(conn)
    query = conn.query_params

    result =
      with {:ok, executor} <- executor(conn),
           {:ok, lease, epoch} <- lease(query) do
        wait =
          with value when is_binary(value) <- query["wait"],
               {n, ""} <- Integer.parse(value),
               do: n,
               else: (_ -> 0)

        Fyrlet.Runs.Executor.status(executor, id, lease, epoch, wait)
      end

    Response.result(conn, result)
  end

  post "/api/v1/executor/attempts/:id/result" do
    result =
      with {:ok, executor} <- executor(conn),
           {:ok, lease, epoch} <- lease(conn.body_params),
           do: Fyrlet.Runs.Executor.report(executor, id, lease, epoch, conn.body_params)

    Response.result(conn, result)
  end

  match _ do
    Fyrlet.HTTP.fallback(conn)
  end

  defp executor(conn) do
    if Fyrlet.Capabilities.enabled?("executors"),
      do: Fyrlet.Features.Executors.authenticate(bearer(conn) || ""),
      else: {:error, Error.not_found()}
  end

  defp lease(%{"lease_id" => lease, "epoch" => epoch}) when is_binary(lease) do
    case Integer.parse(to_string(epoch)) do
      {number, ""} -> {:ok, lease, number}
      _other -> {:error, bad_executor_request()}
    end
  end

  defp lease(_params), do: {:error, bad_executor_request()}

  defp bad_executor_request,
    do: Error.new("VALIDATION_FAILED", "A request needs lease_id and epoch")

  defp receipt_id({:ok, uuid}), do: {:ok, uuid}
  defp receipt_id(:error), do: {:error, Error.not_found()}

  defp receipt_params(%{"receipt_id" => receipt, "outcome" => outcome} = params)
       when is_binary(receipt) and byte_size(receipt) in 1..200 and
              outcome in ["succeeded", "failed"] do
    result = Map.get(params, "result", %{})

    if is_map(result) or is_binary(result),
      do: {:ok, %{receipt_id: receipt, outcome: outcome, result: result}},
      else: invalid_receipt()
  end

  defp receipt_params(_params), do: invalid_receipt()

  defp invalid_receipt,
    do:
      {:error,
       Error.new("VALIDATION_FAILED", "A receipt needs receipt_id and outcome succeeded|failed")}

  defp run_capability(conn) do
    with {:ok, capabilities} <- capabilities(conn),
         do: Fyrlet.Capabilities.require(capabilities, "runs")
  end

  defp not_anonymous(actor),
    do:
      if(Fyrlet.Features.Anonymous.anonymous?(actor), do: {:error, Error.forbidden()}, else: :ok)

  defp capabilities(conn),
    do:
      Fyrlet.Capabilities.negotiate_header(
        List.first(get_req_header(conn, "x-fyrlet-capabilities"))
      )

  defp operation(conn, name, perform) do
    envelope = Schema.object(%{"input" => %{"type" => "object"}}, ["input"])

    result =
      with {:ok, actor} <- actor(conn),
           {:ok, capabilities} <- capabilities(conn),
           {:ok, body} <- Schema.validate(envelope, conn.body_params) do
        perform.(actor, name, body["input"], List.first(get_req_header(conn, "idempotency-key")),
          capabilities: capabilities
        )
      end

    Response.operation(conn, result)
  end

  defp actor(conn),
    do: Auth.authenticate(bearer(conn), List.first(get_req_header(conn, "x-project-id")))

  defp scrape_authorized?(conn) do
    case bearer(conn) do
      token when is_binary(token) -> Plug.Crypto.secure_compare(token, Fyrlet.Metrics.token())
      _missing -> false
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _missing -> nil
    end
  end
end
