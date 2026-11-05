defmodule Fyrlet.Auth do
  import Ecto.Query
  alias Fyrlet.{Actor, Error, Project, Repo, Schema, ServiceKey, Session, Subject}

  def create_project(name) when is_binary(name) and byte_size(name) in 1..200 do
    case Repo.transaction(fn ->
           project = Repo.insert!(%Project{name: name})
           token = random_token("rtk_")
           key = Repo.insert!(%ServiceKey{project_id: project.id, token_hash: hash(token)})
           %{project: project, key_id: key.id, service_key: token}
         end) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  def issue_session(service_token, parameters) do
    schema =
      Schema.object(
        %{
          "external_subject" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
          "issuer" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 200,
            "default" => "customer"
          },
          "ttl_seconds" => %{
            "type" => "integer",
            "minimum" => 60,
            "maximum" => 900,
            "default" => Application.fetch_env!(:fyrlet, :session_ttl)
          }
        },
        ["external_subject"]
      )

    with {:ok, input} <- Schema.validate(schema, parameters) do
      Repo.transaction(fn ->
        key = unwrap!(authenticate_key(service_token, true))

        Repo.insert!(
          %Subject{
            project_id: key.project_id,
            issuer: input["issuer"],
            external_id: input["external_subject"]
          },
          on_conflict: :nothing,
          conflict_target: [:project_id, :issuer, :external_id]
        )

        subject =
          Repo.get_by!(Subject,
            project_id: key.project_id,
            issuer: input["issuer"],
            external_id: input["external_subject"]
          )

        token = random_token("rts_")
        expires_at = DateTime.add(now(), input["ttl_seconds"], :second)

        session =
          Repo.insert!(%Session{
            project_id: key.project_id,
            subject_id: subject.id,
            service_key_id: key.id,
            token_hash: hash(token),
            expires_at: expires_at
          })

        %{
          "token" => token,
          "project_id" => key.project_id,
          "subject_id" => subject.id,
          "session_id" => session.id,
          "expires_at" => DateTime.to_iso8601(expires_at)
        }
      end)
    end
  end

  def authenticate_key(token, locked \\ false) do
    if is_binary(token) and byte_size(token) < 200 and String.starts_with?(token, "rtk_") do
      query =
        from(key in ServiceKey, where: key.token_hash == ^hash(token) and is_nil(key.revoked_at))

      query = if locked, do: from(key in query, lock: "FOR SHARE"), else: query

      case Repo.one(query) do
        nil -> {:error, Error.unauthorized()}
        key -> {:ok, key}
      end
    else
      {:error, Error.unauthorized()}
    end
  end

  def authenticate(token, project_id) do
    if valid_uuid?(project_id) and is_binary(token) and byte_size(token) < 200 and
         String.starts_with?(token, "rts_") do
      query =
        from(session in Session,
          where: session.token_hash == ^hash(token) and session.project_id == ^project_id
        )

      case Repo.one(query) do
        nil -> {:error, Error.unauthorized()}
        session -> actor_from_session(session)
      end
    else
      {:error, Error.unauthorized()}
    end
  end

  def revalidate(%Actor{} = actor, locked \\ false) do
    query =
      from(session in Session,
        where:
          session.id == ^actor.session_id and session.project_id == ^actor.project_id and
            session.subject_id == ^actor.subject_id
      )

    query = if locked, do: from(session in query, lock: "FOR SHARE"), else: query

    case Repo.one(query) do
      nil -> {:error, Error.unauthorized()}
      session -> actor_from_session(session)
    end
  end

  def revoke_session(service_token, session_id) do
    with {:ok, _uuid} <- cast_uuid(session_id) do
      result =
        Repo.transaction(fn ->
          key = unwrap!(authenticate_key(service_token, true))

          session =
            Repo.one(
              from(entry in Session,
                where: entry.id == ^session_id and entry.project_id == ^key.project_id,
                lock: "FOR UPDATE"
              )
            )

          if is_nil(session), do: Repo.rollback(Error.not_found())
          Repo.update!(Ecto.Changeset.change(session, revoked_at: now()))
        end)

      case result do
        {:ok, session} ->
          disconnect(session.id)
          {:ok, %{"revoked" => true}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def revoke_own_session(%Actor{} = actor) do
    Repo.update_all(
      from(session in Session,
        where: session.id == ^actor.session_id and session.project_id == ^actor.project_id
      ),
      set: [revoked_at: now()]
    )

    disconnect(actor.session_id)
    {:ok, %{"revoked" => true}}
  end

  def revoke_key(key_id) do
    with {:ok, _uuid} <- cast_uuid(key_id) do
      Repo.update_all(from(key in ServiceKey, where: key.id == ^key_id), set: [revoked_at: now()])
      :ok
    end
  end

  def now, do: DateTime.utc_now()
  def hash(value), do: :crypto.hash(:sha256, value)

  def random_token(prefix),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp actor_from_session(session) do
    if is_nil(session.revoked_at) and DateTime.compare(session.expires_at, now()) == :gt do
      {:ok,
       %Actor{
         project_id: session.project_id,
         subject_id: session.subject_id,
         session_id: session.id,
         expires_at: session.expires_at
       }}
    else
      {:error, Error.unauthorized()}
    end
  end

  defp disconnect(session_id),
    do: FyrletWeb.Endpoint.broadcast("sessions:" <> session_id, "disconnect", %{})

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp cast_uuid(value),
    do: if(valid_uuid?(value), do: Ecto.UUID.cast(value), else: {:error, Error.not_found()})

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: Repo.rollback(error)
end
