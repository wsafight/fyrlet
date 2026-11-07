defmodule AgentExample.Repo.Migrations.CreateAgentTasks do
  use Ecto.Migration

  def change do
    create table(:agent_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, :binary_id, null: false
      add :goal, :text, null: false
      add :tool, :text, null: false
      add :result_json, :text, null: false
      add :status, :text, null: false, default: "awaiting_approval"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_tasks, [:run_id])
    create index(:agent_tasks, [:project_id, :subject_id, :inserted_at])

    execute(
      "ALTER TABLE agent_tasks ADD CONSTRAINT agent_tasks_subject_project_fk FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)",
      "ALTER TABLE agent_tasks DROP CONSTRAINT agent_tasks_subject_project_fk"
    )
  end
end
