defmodule Fyrlet.Readiness do
  alias Fyrlet.{Error, Repo}

  def check(repo \\ Repo) do
    case repo.query("SELECT 1", [], timeout: 1_000, pool_timeout: 1_000) do
      {:ok, _result} -> {:ok, %{"status" => "ready"}}
      {:error, _reason} -> unavailable()
    end
  rescue
    _exception -> unavailable()
  catch
    :exit, _reason -> unavailable()
  end

  defp unavailable,
    do: {:error, Error.new("UNAVAILABLE", "The database is not ready", %{}, true)}
end
