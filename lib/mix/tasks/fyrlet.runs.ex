defmodule Mix.Tasks.Fyrlet.Runs do
  use Mix.Task
  import Ecto.Query
  @shortdoc "Lists runs that stopped making progress"

  @moduledoc """
  Lists unfinished runs that have not changed for a while, with where they are stuck.

      mix fyrlet.runs [--stuck-after SECONDS] [--limit N]

  Output is one JSON object per line. Defaults: 300 seconds, 100 runs.
  """

  def run(arguments) do
    {options, _rest} =
      OptionParser.parse!(arguments, strict: [stuck_after: :integer, limit: :integer])

    Mix.Task.run("app.start")
    cutoff = DateTime.add(Fyrlet.Auth.now(), -Keyword.get(options, :stuck_after, 300), :second)

    runs =
      Fyrlet.Repo.all(
        from(r in Fyrlet.Runs.Run,
          where:
            r.status in ["pending", "running", "waiting", "cancelling"] and r.updated_at < ^cutoff,
          order_by: [asc: r.updated_at],
          limit: ^Keyword.get(options, :limit, 100)
        )
      )

    for run <- runs do
      step = Fyrlet.Repo.get_by(Fyrlet.Runs.Step, run_id: run.id, seq: run.current_step_seq)

      Mix.shell().info(
        Jason.encode!(%{
          run_id: run.id,
          project_id: run.project_id,
          operation: run.operation,
          status: run.status,
          wait_reason: run.wait_reason,
          step:
            step &&
              %{
                name: step.name,
                type: step.type,
                status: step.status,
                attempt: step.current_attempt
              },
          idle_seconds: DateTime.diff(Fyrlet.Auth.now(), run.updated_at),
          expires_at: run.expires_at
        })
      )
    end

    Mix.shell().info("#{length(runs)} stuck run(s)")
  end
end
