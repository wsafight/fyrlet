defmodule Fyrlet.Repo.Migrations.SessionIssueRate do
  use Ecto.Migration

  def change do
    # Auth.check_issue_rate!/1 counts a key's sessions from the last minute on every issue.
    create index(:sessions, [:service_key_id, :inserted_at])
  end
end
