defmodule Mix.Tasks.Fyrlet.Prune do
  use Mix.Task
  import Ecto.Query
  @shortdoc "Removes expired idempotency results and old sessions"

  def run(_arguments) do
    Mix.Task.run("app.start")
    now = Fyrlet.Auth.now()
    cutoff = DateTime.add(now, -86_400, :second)

    {results, _entries} =
      Fyrlet.Repo.delete_all(from(entry in Fyrlet.Idempotency, where: entry.expires_at < ^now))

    {sessions, _entries} =
      Fyrlet.Repo.delete_all(from(entry in Fyrlet.Session, where: entry.expires_at < ^cutoff))

    Mix.shell().info(Jason.encode!(%{idempotency_results: results, sessions: sessions}))
  end
end
