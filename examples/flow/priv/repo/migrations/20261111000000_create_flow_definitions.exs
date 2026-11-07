defmodule FlowExample.Repo.Migrations.CreateFlowDefinitions do
  use Ecto.Migration

  def change do
    create table(:flow_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :flow_id, :text, null: false
      add :nodes_json, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flow_definitions, [:project_id, :subject_id, :flow_id])

    execute(
      "ALTER TABLE flow_definitions ADD CONSTRAINT flow_definitions_subject_project_fk FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)",
      "ALTER TABLE flow_definitions DROP CONSTRAINT flow_definitions_subject_project_fk"
    )
  end
end
