defmodule NotifyExample.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notify_notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, :binary_id, null: false
      add :title, :text, null: false
      add :body, :text, null: false
      add :delivery, :text, null: false, default: "pending"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:notify_notifications, [:project_id, :subject_id, :inserted_at])
    create unique_index(:notify_notifications, [:run_id])

    execute(
      "ALTER TABLE notify_notifications ADD CONSTRAINT notify_notifications_subject_project_fk " <>
        "FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)",
      "ALTER TABLE notify_notifications DROP CONSTRAINT notify_notifications_subject_project_fk"
    )
  end
end
