defmodule FyrletOps.Bench.StatusScale do
  @moduledoc """
  Cost of FyrletOps.Status.status/1 as history accumulates: H finished runs and A active ones.
  Sandboxed; nothing is left behind.

      cd packages/fyrlet_ops && HISTORY=200000 ACTIVE=2000 mix test test/bench/status_scale.exs
  """
  use FyrletOps.Case
  alias FyrletOps.Status

  @tag timeout: 900_000
  test "status at scale" do
    history = String.to_integer(System.get_env("HISTORY", "100000"))
    active = String.to_integer(System.get_env("ACTIVE", "1000"))
    projects = 20

    pairs =
      for _ <- 1..projects do
        p = project()
        u = user(p, "u")
        {Ecto.UUID.dump!(p.project.id), Ecto.UUID.dump!(u.actor.subject_id)}
      end

    {project_ids, subject_ids} = Enum.unzip(pairs)
    template = start_run!(user(project(), "template"))

    clone = fn status, count ->
      Repo.query!(
        """
        INSERT INTO fyrlet_runs (id, project_id, subject_id, operation, status, version, plan, input,
                                 definition_version, definition_module, execution_epoch, event_seq,
                                 current_step_seq, inserted_at, updated_at, finished_at, expires_at,
                                 execution_grant_id, wait_reason)
        SELECT gen_random_uuid(), pr.project_id, pr.subject_id, r.operation, $4, 1, r.plan, r.input,
               r.definition_version, r.definition_module, 1, 0, 0,
               now() - (random() * interval '20 days'), now() - (random() * interval '20 days'),
               CASE WHEN $4 IN ('completed', 'failed') THEN now() - interval '1 day' END,
               r.expires_at, r.execution_grant_id, CASE WHEN $4 = 'waiting' THEN 'signal' END
        FROM unnest($1::uuid[], $2::uuid[]) AS pr(project_id, subject_id)
        CROSS JOIN generate_series(1, $3) g
        CROSS JOIN (SELECT * FROM fyrlet_runs WHERE id = $5) r
        """,
        [project_ids, subject_ids, div(count, projects), status, Ecto.UUID.dump!(template)]
      )
    end

    clone.("completed", div(history * 9, 10))
    clone.("failed", div(history, 10))
    clone.("running", div(active, 2))
    clone.("waiting", div(active, 4))
    clone.("pending", div(active, 4))

    for table <- ~w(fyrlet_runs fyrlet_effects fyrlet_run_steps),
        do: Repo.query!("ANALYZE #{table}")

    total = Repo.aggregate(Fyrlet.Runs.Run, :count)
    IO.puts("\nruns in table: #{total} (history #{history}, active #{active})")

    for scope <- [:all, hd(project_ids) |> Ecto.UUID.load!()] do
      for _ <- 1..3, do: Status.status(scope)

      samples =
        for _ <- 1..5 do
          {t, _} = :timer.tc(fn -> for _ <- 1..5, do: Status.status(scope) end)
          t / 5
        end

      label = if scope == :all, do: "status(:all)", else: "status(one project)"

      IO.puts(
        "  #{String.pad_trailing(label, 22)} #{Float.round(Enum.at(Enum.sort(samples), 2) / 1000, 1)} ms"
      )
    end

    IO.puts("")
  end
end
