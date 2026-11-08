defmodule Fyrlet.Repo.Migrations.IndexSessionExpiry do
  use Ecto.Migration

  def change do
    create index(:sessions, [:expires_at])
  end
end
