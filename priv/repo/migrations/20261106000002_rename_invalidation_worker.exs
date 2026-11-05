defmodule Fyrlet.Repo.Migrations.RenameInvalidationWorker do
  use Ecto.Migration

  def change do
    execute(
      "UPDATE oban_jobs SET worker = 'Fyrlet.InvalidationWorker', queue = 'fyrlet' " <>
        "WHERE worker = 'Realtime.InvalidationWorker'",
      "UPDATE oban_jobs SET worker = 'Realtime.InvalidationWorker', queue = 'realtime' " <>
        "WHERE worker = 'Fyrlet.InvalidationWorker'"
    )
  end
end
