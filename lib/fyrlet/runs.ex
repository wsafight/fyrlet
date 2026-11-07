defmodule Fyrlet.Runs do
  @moduledoc """
  Durable runs: work that outlives a request, is observable, can wait for a signal, be
  cancelled, and resumes after a crash from what was committed.

  A run is accepted inside the same transaction as its idempotency record, so "accepted"
  means "will be executed", not "has finished". Plain reads, writes and subscriptions never
  create runs.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Capabilities, Error, Repo}

  alias Fyrlet.Runs.{
    Engine,
    Grant,
    Limits,
    Plan,
    Resolver,
    Run,
    Signal,
    Step,
    Store,
    View,
    Worker
  }

  @conflict_policies ~w(return_existing reject_if_active)

  # ---- contract helpers ---------------------------------------------------------------

  @doc "The fixed result of starting a run."
  def start_output do
    Fyrlet.Schema.object(
      %{
        "run_id" => %{"type" => "string", "format" => "uuid"},
        "status" => %{"type" => "string"},
        "existing" => %{"type" => "boolean"}
      },
      ["run_id", "status", "existing"]
    )
  end

  @doc """
  Builds a `run` operation specification.

  Options: `:on_conflict` (`:return_existing` | `:reject_if_active`), `:steps` (a map of
  step name to `%{"input" => schema, "output" => schema}`) and `:signals` (a map of
  signal name to a payload schema).
  """
  def operation(input, options \\ []) do
    %{"kind" => "run", "input" => input, "output" => start_output()}
    |> put_option("on_conflict", options[:on_conflict] && to_string(options[:on_conflict]))
    |> put_option("steps", options[:steps])
    |> put_option("signals", options[:signals])
    |> put_option("planning", options[:planning] && to_string(options[:planning]))
    |> put_option("executor", options[:executor])
    |> put_option("sensitive", options[:sensitive])
  end

  defp put_option(spec, _key, nil), do: spec
  defp put_option(spec, key, value), do: Map.put(spec, key, value)

  def conflict_policies, do: @conflict_policies

  @doc "Subscription scope invalidated whenever this person's runs change."
  def scope(actor), do: "projects:#{actor.project_id}:subjects:#{actor.subject_id}:runs"

  # ---- starting -----------------------------------------------------------------------

  @doc """
  Creates a run. Called inside the write transaction by `Fyrlet.Runtime` after the
  idempotency check; rolls the transaction back with a `Fyrlet.Error` on refusal.
  Returns `{result, scopes}`.
  """
  def create(module, name, actor, input, specification) do
    lock_project(actor.project_id)

    with :ok <- start_authorized(module, name, actor, input),
         {:ok, plan} <- Plan.build(module, name, actor, input, specification),
         :ok <- queue_has_room(actor.project_id) do
      case existing(actor, name, plan["business_key"]) do
        nil -> insert(module, name, actor, input, plan)
        run -> conflict(run, specification, module, name, actor, input, plan)
      end
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
    end
  end

  defp start_authorized(module, name, actor, input) do
    Code.ensure_loaded(module)

    if function_exported?(module, :run_authorize, 4),
      do: module.run_authorize(name, :start, actor, input),
      else: :ok
  end

  defp lock_project(project_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "fyrlet_runs:" <> project_id
    ])
  end

  defp queue_has_room(project_id) do
    pending =
      Repo.one(
        from(r in Run,
          where: r.project_id == ^project_id and r.status == "pending",
          select: count(r.id)
        )
      )

    if pending < Limits.get(:max_pending_per_project),
      do: :ok,
      else: {:error, Error.new("LIMIT_EXCEEDED", "Too many runs are waiting to start", %{}, true)}
  end

  defp existing(_actor, _name, nil), do: nil

  defp existing(actor, name, key) do
    Repo.one(
      from(r in Run,
        where:
          r.project_id == ^actor.project_id and r.operation == ^name and r.business_key == ^key,
        order_by: [desc: r.inserted_at],
        limit: 1
      )
    )
  end

  defp conflict(run, specification, module, name, actor, input, plan) do
    case specification["on_conflict"] || "return_existing" do
      "return_existing" ->
        {%{"run_id" => run.id, "status" => run.status, "existing" => true}, []}

      "reject_if_active" ->
        if Fyrlet.Runs.StateMachine.active?(run.status),
          do:
            Repo.rollback(Error.new("CONFLICT", "A run with this business key is still active")),
          else: insert(module, name, actor, input, plan)
    end
  end

  defp insert(module, name, actor, input, plan) do
    now = Auth.now()
    expires_at = DateTime.add(now, plan["ttl_seconds"], :second)

    grant_expires =
      Enum.min([expires_at, DateTime.add(now, Limits.get(:grant_cap), :second)], DateTime)

    if DateTime.diff(grant_expires, now, :millisecond) < plan["total_wait_ms"] do
      Repo.rollback(
        Error.new(
          "VALIDATION_FAILED",
          "The execution authority would expire before the plan's waits end"
        )
      )
    end

    {:ok, input} = Plan.payload(input, "input") |> normalise_input()

    grant =
      Repo.insert!(%Grant{
        project_id: actor.project_id,
        initiator_subject_id: actor.subject_id,
        execution_subject_id: actor.subject_id,
        operation: name,
        resource_scope: %{},
        expires_at: grant_expires
      })

    run =
      Repo.insert!(%Run{
        project_id: actor.project_id,
        subject_id: actor.subject_id,
        operation: name,
        business_key: plan["business_key"],
        definition_module: inspect(module),
        definition_version: Resolver.current_version(module, name),
        plan: plan,
        execution_grant_id: grant.id,
        status: "pending",
        input: input,
        expires_at: expires_at
      })

    for node <- plan["nodes"], do: insert_step(run.id, node)

    Store.event(run.id, "run.created", nil, %{"nodes" => length(plan["nodes"])})
    Worker.wake(run.id)

    {%{"run_id" => run.id, "status" => "pending", "existing" => false},
     Fyrlet.Runs.Definition.scopes_for(run)}
  end

  @doc false
  def insert_step(run_id, node) do
    Repo.insert!(%Step{
      run_id: run_id,
      type: node["type"],
      name: node["name"],
      seq: node["seq"],
      status: "pending",
      input: node["input"],
      signal_name: node["signal"],
      wait_timeout_action: node["on_timeout"],
      max_attempts: node["max_attempts"] || 1,
      queue: node["queue"]
    })
  end

  defp normalise_input({:ok, value}), do: {:ok, value}
  defp normalise_input({:error, error}), do: Repo.rollback(error)

  # ---- authorization ------------------------------------------------------------------

  @doc """
  Authorizes `action` (`:view`, `:signal`, `:cancel`) on a run. The definition's
  `run_authorize/4` decides; without one only the subject that started the run may act.
  """
  def authorize_run(actor, %Run{} = run, action) do
    module = Resolver.definition(run)

    cond do
      actor.project_id != run.project_id ->
        {:error, Error.not_found()}

      Fyrlet.Features.Anonymous.anonymous?(actor) ->
        {:error, Error.forbidden()}

      module != nil and function_exported?(module, :run_authorize, 4) ->
        module.run_authorize(run.operation, action, actor, %{
          "id" => run.id,
          "operation" => run.operation,
          "owner_subject_id" => run.subject_id,
          "status" => run.status
        })

      actor.subject_id == run.subject_id ->
        :ok

      true ->
        {:error, Error.forbidden()}
    end
  end

  # ---- reading ------------------------------------------------------------------------

  def get(actor, run_id) do
    with {:ok, _uuid} <- cast(run_id),
         {:ok, actor} <- Auth.revalidate(actor),
         %Run{} = run <- Repo.get(Run, run_id) || {:error, Error.not_found()},
         :ok <- authorize_run(actor, run, :view) do
      {:ok, View.build(run)}
    end
  end

  # ---- signals ------------------------------------------------------------------------

  @doc """
  Records a signal for a wait node. Accepting and consuming are separate: a signal that
  arrives before the run reaches its wait is stored and consumed on arrival at the node.
  """
  def signal(actor, run_id, params) do
    with {:ok, _uuid} <- cast(run_id),
         {:ok, actor} <- Auth.revalidate(actor),
         {:ok, params} <- signal_params(params) do
      result =
        Engine.transact(fn ->
          case Store.lock_run(run_id) do
            nil ->
              Repo.rollback(Error.not_found())

            %Run{project_id: project} when project != actor.project_id ->
              Repo.rollback(Error.not_found())

            run ->
              deliver_signal(actor, run, params)
          end
        end)

      emit_signal(result)
      result
    end
  end

  defp signal_params(%{"wait_id" => wait_id, "name" => name, "idempotency_key" => key} = params)
       when is_binary(name) and is_binary(key) and byte_size(key) in 1..200 do
    with {:ok, _uuid} <- cast(wait_id),
         {:ok, payload} <- Plan.payload(Map.get(params, "payload", %{}), "signal payload"),
         true <-
           is_map(payload) ||
             {:error, Error.new("VALIDATION_FAILED", "The signal payload must be an object")} do
      {:ok, %{wait_id: wait_id, name: name, key: key, payload: payload}}
    end
  end

  defp signal_params(_params),
    do:
      {:error, Error.new("VALIDATION_FAILED", "A signal needs wait_id, name and idempotency_key")}

  @doc """
  Delivers a signal on behalf of a verified integration (for example a webhook). The principal
  is the project, not a person: it may signal any run of that project and do nothing else.
  Everything after authorization - state checks, de-duplication, limits - is the same.
  """
  def signal_from_integration(project_id, run_id, params) do
    with {:ok, _uuid} <- cast(run_id),
         {:ok, params} <- signal_params(params) do
      Engine.transact(fn ->
        case Store.lock_run(run_id) do
          %Run{project_id: ^project_id} = run -> deliver_signal(:integration, run, params)
          _other -> Repo.rollback(Error.not_found())
        end
      end)
    end
  end

  defp deliver_signal(actor, run, params) do
    if actor != :integration do
      case authorize_run(actor, run, :signal) do
        :ok -> :ok
        {:error, error} -> Repo.rollback(error)
      end
    end

    hash = Auth.hash(Jason.encode!([params.wait_id, params.name, params.payload]))
    now = Auth.now()

    case Repo.one(
           from(s in Signal, where: s.run_id == ^run.id and s.idempotency_key == ^params.key)
         ) do
      %Signal{input_hash: ^hash} = previous ->
        {:ok, receipt(previous)}

      %Signal{} ->
        Repo.rollback(
          Error.new("CONFLICT", "The idempotency key was used with a different signal")
        )

      nil ->
        accept_signal(run, params, hash, now)
    end
  end

  defp accept_signal(run, params, hash, now) do
    unless Fyrlet.Runs.StateMachine.active?(run.status) and run.status != "cancelling",
      do: Repo.rollback(Error.new("CONFLICT", "The run is no longer accepting signals"))

    step =
      case Repo.one(
             from(s in Step,
               where: s.run_id == ^run.id and s.id == ^params.wait_id,
               lock: "FOR UPDATE"
             )
           ) do
        %Step{type: "wait"} = step -> step
        _other -> Repo.rollback(Error.new("VALIDATION_FAILED", "Unknown wait"))
      end

    if step.signal_name != params.name,
      do: Repo.rollback(Error.new("VALIDATION_FAILED", "The signal name does not match the wait"))

    if step.status not in ["pending", "waiting"],
      do: Repo.rollback(Error.new("CONFLICT", "The wait is already closed"))

    check_signal_limits(run, now)
    check_signal_contract(run, params)

    signal =
      Repo.insert!(%Signal{
        run_id: run.id,
        wait_id: step.id,
        name: params.name,
        payload: params.payload,
        idempotency_key: params.key,
        input_hash: hash,
        status: "received",
        received_at: now
      })

    Store.event(run.id, "signal.received", step.id, %{"signal" => params.name})

    if step.status == "waiting" do
      Engine.consume_signal(run, step, signal, now)
      {:ok, %{"signal_id" => signal.id, "status" => "consumed"}}
    else
      {:ok, receipt(signal)}
    end
  end

  defp check_signal_limits(run, now) do
    recent =
      Repo.one(
        from(s in Signal,
          where: s.run_id == ^run.id and s.received_at > ^DateTime.add(now, -60, :second),
          select: count(s.id)
        )
      )

    inbox =
      Repo.one(
        from(s in Signal,
          where: s.run_id == ^run.id and s.status == "received",
          select: count(s.id)
        )
      )

    cond do
      recent >= Limits.get(:signals_per_minute) ->
        Repo.rollback(Error.new("LIMIT_EXCEEDED", "Too many signals for this run", %{}, true))

      inbox >= Limits.get(:signal_inbox) ->
        Repo.rollback(Error.new("LIMIT_EXCEEDED", "The run has too many unconsumed signals"))

      true ->
        :ok
    end
  end

  defp check_signal_contract(run, params) do
    with {:ok, _module, specification} <- Fyrlet.Registry.fetch("operations", run.operation),
         {:error, _} <-
           Plan.contract(
             specification,
             ["signals", params.name],
             params.payload,
             "signal payload"
           ) do
      Repo.rollback(
        Error.new("VALIDATION_FAILED", "The signal payload does not match its contract")
      )
    else
      _ok_or_unknown -> :ok
    end
  end

  defp receipt(%Signal{} = signal),
    do: %{"signal_id" => signal.id, "status" => signal_status(signal)}

  defp signal_status(%Signal{status: "consumed"}), do: "consumed"
  defp signal_status(_signal), do: "accepted"

  defp emit_signal(result) do
    outcome =
      case result do
        {:ok, %{"status" => status}} -> status
        {:error, %Error{code: code}} -> "rejected:" <> code
        {:error, _other} -> "rejected"
      end

    :telemetry.execute([:fyrlet, :run, :signal], %{count: 1}, %{outcome: outcome})
  end

  # ---- cancelling ---------------------------------------------------------------------

  def cancel(actor, run_id) do
    with {:ok, _uuid} <- cast(run_id),
         {:ok, actor} <- Auth.revalidate(actor),
         %Run{} = run <- Repo.get(Run, run_id) || {:error, Error.not_found()},
         :ok <- authorize_run(actor, run, :cancel) do
      case Engine.request_cancel(run_id) do
        %Run{} = cancelled ->
          :telemetry.execute([:fyrlet, :run, :cancel], %{count: 1}, %{
            outcome: cancelled.cancellation_outcome || "accepted"
          })

          {:ok,
           %{
             "run_id" => cancelled.id,
             "status" => cancelled.status,
             "cancel_deadline" =>
               cancelled.cancel_deadline && DateTime.to_iso8601(cancelled.cancel_deadline),
             "cancellation_outcome" => cancelled.cancellation_outcome
           }}

        {:error, :not_found} ->
          {:error, Error.not_found()}
      end
    end
  end

  # ---- authority ----------------------------------------------------------------------

  @doc "Revokes a run's execution authority. New work is refused and the run fails."
  def revoke_grant(project_id, run_id) do
    Engine.transact(fn ->
      with %Run{project_id: ^project_id} = run <- Store.lock_run(run_id),
           true <- Fyrlet.Runs.StateMachine.active?(run.status) do
        Repo.update_all(
          from(g in Grant, where: g.id == ^run.execution_grant_id and is_nil(g.revoked_at)),
          set: [revoked_at: Auth.now()]
        )

        if run.status != "cancelling", do: Engine.fail_for_grant(run)
        :ok
      else
        _other -> :noop
      end
    end)
  end

  defp cast(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Error.not_found()}
    end
  end

  def enabled?, do: Capabilities.enabled?("runs")
end
