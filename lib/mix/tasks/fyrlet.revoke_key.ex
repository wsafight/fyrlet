defmodule Mix.Tasks.Fyrlet.RevokeKey do
  use Mix.Task
  @shortdoc "Revokes a backend service key by ID"

  def run([identifier]) do
    Mix.Task.run("app.start")

    case Fyrlet.Auth.revoke_key(identifier) do
      :ok -> Mix.shell().info("Service key revoked")
      {:error, error} -> Mix.raise(error.message)
    end
  end

  def run(_arguments), do: Mix.raise("Usage: mix fyrlet.revoke_key KEY_ID")
end
