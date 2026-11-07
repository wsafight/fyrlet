defmodule Fyrlet.Bench.LeaseCount do
  @moduledoc """
  Cost of the per-project concurrency check as the whole system fills up: P projects with R
  running runs each (every one holding a lease). Sandboxed; nothing is left behind.

      PROJECTS=200 RUNS=100 mix test test/bench/lease_count.exs
  """
  use Fyrlet.RunsCase
  alias Fyrlet.Runs.{Attempt, Run}

  @tag timeout: 600_000
  test "lease count" do
    projects = String.to_integer(System.get_env("PROJECTS", "200"))
    per = String.to_integer(System.get_env("RUNS", "100"))
    now = DateTime.utc_now()

    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
    })

    template_owner = user(project(), "alice")
    template = start_run!(template_owner)

    # Real projects and users (runs reference them), then bulk-cloned running runs.
    pairs =
      for _ <- 1..projects do
        p = project()
        u = user(p, "u")
        {Ecto.UUID.dump!(p.project.id), Ecto.UUID.dump!(u.actor.subject_id)}
      end

    {project_ids, subject_ids} = Enum.unzip(pairs)

    Repo.query!(
      """
      INSERT INTO fyrlet_runs (id, project_id, subject_id, operation, status, version, plan, input,
                               definition_version, definition_module, execution_epoch, event_seq,
                               current_step_seq, inserted_at, updated_at, expires_at, execution_grant_id)
      SELECT gen_random_uuid(), pr.project_id, pr.subject_id, r.operation, 'running', 1, r.plan, r.input,
             r.definition_version, r.definition_module, 1, 0, 0, now(), now(), r.expires_at, r.execution_grant_id
      FROM unnest($1::uuid[], $2::uuid[]) AS pr(project_id, subject_id)
      CROSS JOIN generate_series(1, $3) g
      CROSS JOIN (SELECT * FROM fyrlet_runs WHERE id = $4) r
      """,
      [project_ids, subject_ids, per, Ecto.UUID.dump!(template)]
    )

    Repo.query!(
      """
      INSERT INTO fyrlet_run_steps (id, run_id, type, name, seq, status, input, current_attempt,
                                    max_attempts, inserted_at, updated_at)
      SELECT gen_random_uuid(), r.id, 'step', 'a', 0, 'running', '{}'::jsonb, 1, 3, now(), now()
      FROM fyrlet_runs r WHERE r.status = 'running'
      """,
      []
    )

    Repo.query!(
      """
      INSERT INTO fyrlet_run_attempts (id, run_id, project_id, step_id, attempt, execution_epoch, lease_id,
                                       lease_expires_at, status, started_at, inserted_at, updated_at)
      SELECT gen_random_uuid(), s.run_id, r.project_id, s.id, 1, 1, gen_random_uuid(), now() + interval '10 minutes',
             'leased', now(), now(), now()
      FROM fyrlet_run_steps s JOIN fyrlet_runs r ON r.id = s.run_id WHERE s.status = 'running'
      """,
      []
    )

    for table <- ~w(fyrlet_runs fyrlet_run_attempts fyrlet_run_steps),
        do: Repo.query!("ANALYZE #{table}")

    total = Repo.aggregate(from(a in Attempt, where: a.status == "leased"), :count)
    mine = project_ids |> hd() |> Ecto.UUID.load!()

    # Before: attempts joined to their runs to find the project. After: the project is on the
    # attempt itself.
    joined =
      from(a in Attempt,
        join: r in Run,
        on: r.id == a.run_id,
        where:
          r.project_id == ^mine and a.status == "leased" and a.lease_expires_at > ^now and
            r.id != ^template,
        select: count(a.id)
      )

    direct =
      from(a in Attempt,
        where:
          a.project_id == ^mine and a.status == "leased" and a.lease_expires_at > ^now and
            a.run_id != ^template,
        select: count(a.id)
      )

    assert Repo.one(joined) == Repo.one(direct)
    IO.puts("\nLEASED ATTEMPTS system-wide: #{total}; this project holds #{Repo.one(direct)}")

    for {label, query} <- [{"join (before)", joined}, {"project_id (after)", direct}] do
      {sql, params} = Repo.to_sql(:all, query)
      %{rows: plan} = Repo.query!("EXPLAIN (ANALYZE, FORMAT TEXT) " <> sql, params)
      lines = Enum.map(plan, &hd/1)

      scan =
        Enum.find(lines, &(&1 =~ "Scan on fyrlet_run_attempts")) ||
          Enum.find(lines, &(&1 =~ "Scan"))

      execution = Enum.find(lines, &(&1 =~ "Execution Time"))

      for _ <- 1..30, do: Repo.one(query)

      samples =
        for _ <- 1..5 do
          {t, _} = :timer.tc(fn -> for _ <- 1..100, do: Repo.one(query) end)
          t / 100
        end

      IO.puts(
        "  #{String.pad_trailing(label, 20)} #{samples |> Enum.sort() |> Enum.at(2) |> Float.round(0) |> trunc() |> Integer.to_string() |> String.pad_leading(5)} µs   #{String.trim(scan)}   #{String.trim(execution)}"
      )
    end

    IO.puts("")
  end
end
