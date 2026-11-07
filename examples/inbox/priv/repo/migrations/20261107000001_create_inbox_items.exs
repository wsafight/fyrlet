defmodule InboxExample.Repo.Migrations.CreateInboxItems do
  use Ecto.Migration

  # `if_not_exists` keeps databases that created this table before it moved out of
  # Fyrlet's own migrations working.
  def change do
    create_if_not_exists table(:inbox_items, primary_key: false) do
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

    create_if_not_exists index(:inbox_items, [:project_id, :subject_id, :inserted_at, :id])
    create_if_not_exists index(:inbox_items, [:subject_id, :project_id])

    # Tenant integrity: a record's subject must belong to the same project. Business
    # tables should carry this composite key like Fyrlet's own tables do.
    execute(
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = 'inbox_items_subject_project_fk' AND conrelid = 'inbox_items'::regclass
        ) THEN
          ALTER TABLE inbox_items ADD CONSTRAINT inbox_items_subject_project_fk
            FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id);
        END IF;
      END $$
      """,
      "ALTER TABLE inbox_items DROP CONSTRAINT IF EXISTS inbox_items_subject_project_fk"
    )
  end
end
