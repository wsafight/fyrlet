defmodule FyrletWebhooks.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:webhooks_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source, :text, null: false
      add :event_id, :text, null: false
      add :outcome, :text, null: false
      add :received_at, :utc_datetime_usec, null: false
    end

    create unique_index(:webhooks_events, [:project_id, :source, :event_id])
    create index(:webhooks_events, [:received_at])
  end
end
