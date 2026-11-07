defmodule Fyrlet.Features.Executors do
  @moduledoc """
  Credentials for external executors (temp spec §3.7).

  An executor is not a user: its token only lets it claim work from the queues it was
  granted, in its own project, and report on the attempts it holds. It carries no business
  authority of its own and can be revoked on its own.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Error, Repo}

  defmodule Executor do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "fyrlet_executors" do
      field(:project_id, :binary_id)
      field(:name, :string)
      field(:token_hash, :binary)
      field(:queues, {:array, :string}, default: [])
      field(:revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end
  end

  @queue ~r/^[a-z][a-z0-9_.-]{0,63}$/

  @doc "Creates an executor. The token is returned once and only its hash is stored."
  def create(project_id, name, queues) when is_binary(name) and is_list(queues) do
    if queues != [] and Enum.all?(queues, &(is_binary(&1) and Regex.match?(@queue, &1))) do
      token = Auth.random_token("rtx_")

      executor =
        Repo.insert!(%Executor{
          project_id: project_id,
          name: name,
          token_hash: Auth.hash(token),
          queues: Enum.uniq(queues)
        })

      {:ok, %{executor: executor, token: token}}
    else
      {:error, Error.new("VALIDATION_FAILED", "An executor needs one or more valid queue names")}
    end
  end

  def revoke(executor_id) do
    Repo.update_all(from(e in Executor, where: e.id == ^executor_id and is_nil(e.revoked_at)),
      set: [revoked_at: Auth.now()]
    )

    :ok
  end

  def authenticate("rtx_" <> _ = token) when byte_size(token) < 200 do
    case Repo.one(
           from(e in Executor, where: e.token_hash == ^Auth.hash(token) and is_nil(e.revoked_at))
         ) do
      nil -> {:error, Error.unauthorized()}
      executor -> {:ok, executor}
    end
  end

  def authenticate(_token), do: {:error, Error.unauthorized()}
end
