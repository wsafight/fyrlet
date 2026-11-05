defmodule Fyrlet.Repo.Migrations.CreateFyrlet do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:service_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token_hash, :binary, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:service_keys, [:token_hash])
    create unique_index(:service_keys, [:id, :project_id])

    create table(:subjects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issuer, :text, null: false
      add :external_id, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subjects, [:project_id, :issuer, :external_id])
    create unique_index(:subjects, [:id, :project_id])

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :service_key_id, references(:service_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:project_id, :subject_id])

    create table(:inbox_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :text, :text, null: false
      add :content_type, :text, null: false
      add :archived, :boolean, null: false, default: false
      add :version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create index(:inbox_items, [:project_id, :subject_id, :inserted_at, :id])

    create table(:idempotency_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :operation, :text, null: false
      add :key, :text, null: false
      add :input_hash, :binary, null: false
      add :result, :map, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:idempotency_results, [:project_id, :subject_id, :operation, :key])

    for table_name <- ["sessions", "inbox_items", "idempotency_results"] do
      execute(
        "ALTER TABLE #{table_name} ADD CONSTRAINT #{table_name}_subject_project_fk " <>
          "FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)",
        "ALTER TABLE #{table_name} DROP CONSTRAINT #{table_name}_subject_project_fk"
      )
    end

    execute(
      "ALTER TABLE sessions ADD CONSTRAINT sessions_key_project_fk " <>
        "FOREIGN KEY (service_key_id, project_id) REFERENCES service_keys(id, project_id)",
      "ALTER TABLE sessions DROP CONSTRAINT sessions_key_project_fk"
    )
  end
end
