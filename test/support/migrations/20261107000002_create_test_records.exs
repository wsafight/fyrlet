defmodule Fyrlet.TestMigrations.CreateTestRecords do
  use Ecto.Migration

  def change do
    create table(:fyrlet_test_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :text, :text, null: false
      add :content_type, :text, null: false
      add :version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create index(:fyrlet_test_records, [:project_id, :subject_id, :inserted_at, :id])

    execute(
      "ALTER TABLE fyrlet_test_records ADD CONSTRAINT test_records_subject_project_fk FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)",
      "ALTER TABLE fyrlet_test_records DROP CONSTRAINT test_records_subject_project_fk"
    )
  end
end
