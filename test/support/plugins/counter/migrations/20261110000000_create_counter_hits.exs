defmodule Fyrlet.TestPlugins.Counter.Migrations.CreateHits do
  use Ecto.Migration

  def change do
    create table(:counter_hits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, :binary_id, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:counter_hits, [:project_id, :subject_id])
  end
end
