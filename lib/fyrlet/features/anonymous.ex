defmodule Fyrlet.Features.Anonymous do
  @moduledoc """
  A restricted public entry (temp spec §7.1, `fyrlet_anonymous`).

  A project opts in explicitly:

      config :fyrlet, :anonymous, %{"<project id>" => %{ttl: 600, per_minute: 60, max_active: 5000}}

  An anonymous caller gets a short-lived session as a fresh, empty subject. It is read-only
  and fail-closed:

    * a subscription or read operation is reachable only if its contract says `"public" => true`
      (and the definition's own `authorize/3` still decides, seeing `actor.kind == "anonymous"`);
    * writes, runs, signals, cancels, the contract and everything else are refused;
    * it connects only after negotiating `anonymous_read`;
    * it has its own, lower, limits.

  Marking something public is the application's statement that every viewer may see exactly
  what it returns. Fyrlet cannot check that for arbitrary business code.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Capabilities, Error, Repo, Session, Subject}

  @capability "anonymous_read"
  def capability, do: @capability

  def anonymous?(%{kind: "anonymous"}), do: true
  def anonymous?(_actor), do: false

  @doc "Whether an anonymous caller may use this operation specification."
  def operation_allowed?(specification),
    do: specification["public"] == true and specification["kind"] == "read"

  @doc "Whether an anonymous caller may use this subscription specification."
  def subscription_allowed?(specification), do: specification["public"] == true

  def max_subscriptions, do: Application.get_env(:fyrlet, :anonymous_max_subscriptions, 3)

  @doc "Issues a session for a project that has enabled the public entry."
  def issue(project_id) do
    with true <- Capabilities.enabled?(@capability),
         true <- is_binary(project_id),
         {:ok, _uuid} <- Ecto.UUID.cast(project_id),
         %{} = config <- Application.get_env(:fyrlet, :anonymous, %{})[project_id] do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "anonymous:" <> project_id
        ])

        check_limits!(project_id, config)

        subject =
          Repo.insert!(%Subject{
            project_id: project_id,
            issuer: "anonymous",
            external_id: Ecto.UUID.generate()
          })

        token = Auth.random_token("rts_")
        expires_at = DateTime.add(Auth.now(), Map.get(config, :ttl, 600), :second)

        session =
          Repo.insert!(%Session{
            project_id: project_id,
            subject_id: subject.id,
            service_key_id: nil,
            token_hash: Auth.hash(token),
            kind: "anonymous",
            expires_at: expires_at
          })

        %{
          "token" => token,
          "project_id" => project_id,
          "subject_id" => subject.id,
          "session_id" => session.id,
          "expires_at" => DateTime.to_iso8601(expires_at)
        }
      end)
    else
      _disabled -> {:error, Error.not_found()}
    end
  end

  defp check_limits!(project_id, config) do
    now = Auth.now()
    base = from(s in Session, where: s.project_id == ^project_id and s.kind == "anonymous")

    recent =
      Repo.aggregate(
        from(s in base, where: s.inserted_at > ^DateTime.add(now, -60, :second)),
        :count
      )

    active =
      Repo.aggregate(from(s in base, where: s.expires_at > ^now and is_nil(s.revoked_at)), :count)

    cond do
      recent >= Map.get(config, :per_minute, 60) ->
        Repo.rollback(
          Error.new("LIMIT_EXCEEDED", "Too many anonymous sessions; try again shortly", %{}, true)
        )

      active >= Map.get(config, :max_active, 5_000) ->
        Repo.rollback(Error.new("LIMIT_EXCEEDED", "The public entry is at capacity", %{}, true))

      true ->
        :ok
    end
  end

  @doc "Removes anonymous subjects (and with them their sessions) that expired before `before`."
  def prune(before) do
    Repo.delete_all(
      from(s in Subject,
        as: :subject,
        where: s.issuer == "anonymous",
        where:
          not exists(
            from(session in Session,
              where:
                session.subject_id == parent_as(:subject).id and session.expires_at >= ^before
            )
          )
      )
    )
  end
end
