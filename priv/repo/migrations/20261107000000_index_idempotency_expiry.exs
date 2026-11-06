defmodule Fyrlet.Repo.Migrations.IndexIdempotencyExpiry do
  use Ecto.Migration

  def change do
    create index(:idempotency_results, [:expires_at])
  end
end
