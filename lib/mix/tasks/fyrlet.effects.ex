defmodule Mix.Tasks.Fyrlet.Effects do
  use Mix.Task
  import Ecto.Query
  @shortdoc "Lists external effects that need attention"

  @moduledoc """
  Lists effects whose outcome is unknown, that wait for a person, or that were due to be
  sent and were not.

      mix fyrlet.effects [--overdue-after SECONDS]

  One JSON object per line. Decisions are made with `Fyrlet.Effects.resolve/5`.
  """

  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: [overdue_after: :integer])
    Mix.Task.run("app.start")
    cutoff = DateTime.add(Fyrlet.Auth.now(), -Keyword.get(options, :overdue_after, 300), :second)

    effects =
      Fyrlet.Repo.all(
        from(e in Fyrlet.Effects.Effect,
          where:
            e.status == "unknown" or e.resolution_required or
              (e.status == "pending" and e.next_attempt_at < ^cutoff) or
              (e.status == "claimed" and e.lease_expires_at < ^cutoff),
          order_by: [asc: e.inserted_at],
          limit: 200
        )
      )

    for e <- effects do
      Mix.shell().info(
        Jason.encode!(%{
          effect_id: e.id,
          run_id: e.run_id,
          adapter: e.adapter,
          status: e.status,
          policy: e.delivery_policy,
          attempts: e.attempts,
          resolution_required: e.resolution_required,
          external_ref: e.external_ref,
          since: e.updated_at
        })
      )
    end

    Mix.shell().info("#{length(effects)} effect(s) need attention")
  end
end
