defmodule Fyrlet.Repo.Migrations.AddForeignKeyIndexes do
  use Ecto.Migration

  def change do
    create index(:service_keys, [:project_id])
    create index(:sessions, [:subject_id, :project_id])
    create index(:sessions, [:service_key_id, :project_id])
    create index(:inbox_items, [:subject_id, :project_id])
    create index(:idempotency_results, [:subject_id, :project_id])
  end
end
