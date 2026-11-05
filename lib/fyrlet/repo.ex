defmodule Fyrlet.Repo do
  use Ecto.Repo, otp_app: :fyrlet, adapter: Ecto.Adapters.Postgres
end
