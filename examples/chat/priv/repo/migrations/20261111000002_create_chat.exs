defmodule ChatExample.Repo.Migrations.CreateChat do
  use Ecto.Migration

  def change do
    create table(:chat_rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :code, :text, null: false
      add :status, :text, null: false, default: "open"
      add :assigned_subject_id, references(:subjects, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:chat_rooms, [:project_id, :code])
    create unique_index(:chat_rooms, [:id, :project_id])
    create index(:chat_rooms, [:assigned_subject_id])

    for table_name <- [:chat_members, :chat_messages] do
      create table(table_name, primary_key: false) do
        add :id, :binary_id, primary_key: true

        add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

        add :room_id, references(:chat_rooms, type: :binary_id, on_delete: :delete_all),
          null: false

        add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
          null: false

        if table_name == :chat_messages, do: add(:text, :text, null: false)
        timestamps(type: :utc_datetime_usec)
      end

      create index(table_name, [:subject_id])

      execute(
        "ALTER TABLE #{table_name} ADD CONSTRAINT #{table_name}_subject_project_fk FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)",
        "ALTER TABLE #{table_name} DROP CONSTRAINT #{table_name}_subject_project_fk"
      )

      execute(
        "ALTER TABLE #{table_name} ADD CONSTRAINT #{table_name}_room_project_fk FOREIGN KEY (room_id, project_id) REFERENCES chat_rooms(id, project_id)",
        "ALTER TABLE #{table_name} DROP CONSTRAINT #{table_name}_room_project_fk"
      )
    end

    create unique_index(:chat_members, [:room_id, :subject_id])
    create index(:chat_messages, [:project_id, :room_id, :inserted_at, :id])
  end
end
