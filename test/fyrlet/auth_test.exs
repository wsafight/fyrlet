defmodule Fyrlet.AuthTest do
  use Fyrlet.DataCase, async: true

  test "service keys and user tokens are distinct and project scoped" do
    first = project()
    second = project()
    alice = user(first)
    assert {:ok, _actor} = Auth.authenticate(alice.token, first.project.id)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.authenticate(alice.token, second.project.id)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.authenticate(first.service_key, first.project.id)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.issue_session(alice.token, %{"external_subject" => "bob"})

    assert Repo.get_by!(Fyrlet.ServiceKey, id: first.key_id).token_hash ==
             Auth.hash(first.service_key)

    refute Repo.get_by!(Fyrlet.Session, id: alice.actor.session_id).token_hash == alice.token
  end

  test "external subjects are stable within an issuer and isolated by project" do
    first = project()
    second = project()
    alice = user(first)
    again = user(first)
    other = user(second)
    assert alice.actor.subject_id == again.actor.subject_id
    refute alice.actor.subject_id == other.actor.subject_id

    {:ok, issued} =
      Auth.issue_session(first.service_key, %{"external_subject" => "alice", "issuer" => "other"})

    refute issued["subject_id"] == alice.actor.subject_id

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Auth.issue_session(first.service_key, %{
               "external_subject" => "alice",
               "subject_id" => alice.actor.subject_id
             })
  end

  test "revocation rejects foreign project credentials and invalidates an actor" do
    first = project()
    second = project()
    alice = user(first)

    assert {:error, %Error{code: "NOT_FOUND"}} =
             Auth.revoke_session(second.service_key, alice.actor.session_id)

    assert {:ok, _result} = Auth.revoke_session(first.service_key, alice.actor.session_id)
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.revalidate(alice.actor)
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = add(alice.actor)
  end

  test "key revocation stops exchanges and existing sessions have independent lifetime" do
    first = project()
    alice = user(first)
    assert :ok = Auth.revoke_key(first.key_id)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.issue_session(first.service_key, %{"external_subject" => "bob"})

    assert {:ok, _actor} = Auth.revalidate(alice.actor)

    Repo.update_all(
      from(session in Fyrlet.Session, where: session.id == ^alice.actor.session_id),
      set: [expires_at: DateTime.add(Auth.now(), -1, :second)]
    )

    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.revalidate(alice.actor)
  end

  test "session TTL and unexpected authentication fields are validated" do
    first = project()

    for seconds <- [0, 59, 901, "600"] do
      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Auth.issue_session(first.service_key, %{
                 "external_subject" => "alice",
                 "ttl_seconds" => seconds
               })
    end

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.authenticate("rts_invalid", "not-a-uuid")
  end

  test "projects enforce name bounds and each project gets its own credential" do
    for name <- ["", String.duplicate("x", 201)] do
      assert_raise FunctionClauseError, fn -> Auth.create_project(name) end
    end

    assert_raise FunctionClauseError, fn -> Auth.create_project(:atom) end

    assert {:ok, first} = Auth.create_project("Project One")
    assert {:ok, second} = Auth.create_project("Project One")
    assert first.project.name == "Project One"
    assert first.project.id != second.project.id
    assert first.key_id != second.key_id
    assert first.service_key != second.service_key
    assert String.starts_with?(first.service_key, "rtk_")

    stored = Repo.get_by!(Fyrlet.ServiceKey, id: first.key_id)
    assert stored.project_id == first.project.id
    assert stored.token_hash == Auth.hash(first.service_key)
    assert is_nil(stored.revoked_at)
  end

  test "service key authentication rejects invalid shapes and unknown or revoked keys" do
    first = project()

    for token <- [nil, "", "abc", "rtk_", String.duplicate("x", 200), "rts_" <> "a"] do
      assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.authenticate_key(token)
    end

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.authenticate_key("rtk_" <> String.duplicate("a", 40))

    assert {:ok, key} = Auth.authenticate_key(first.service_key)
    assert key.project_id == first.project.id

    Auth.revoke_key(first.key_id)
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.authenticate_key(first.service_key)
  end

  test "session authentication rejects malformed tokens, project ids and mismatched actors" do
    first = project()
    second = project()
    alice = user(first)

    for {token, project_id} <- [
          {nil, first.project.id},
          {"rts_bogus", first.project.id},
          {"rtk_" <> "x", first.project.id},
          {alice.token, nil},
          {alice.token, "not-a-uuid"},
          {alice.token, second.project.id}
        ] do
      assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.authenticate(token, project_id)
    end

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.revalidate(%{alice.actor | project_id: second.project.id})

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.revalidate(%{alice.actor | subject_id: Ecto.UUID.generate()})

    assert {:ok, actor} = Auth.revalidate(alice.actor)
    assert actor == alice.actor
  end

  test "issued sessions apply issuer and TTL defaults and expose expiry" do
    first = project()

    assert {:ok, session} =
             Auth.issue_session(first.service_key, %{"external_subject" => "default-user"})

    assert session["project_id"] == first.project.id
    assert String.starts_with?(session["token"], "rts_")
    assert byte_size(session["token"]) > 32
    assert {:ok, expires_at, _offset} = DateTime.from_iso8601(session["expires_at"])
    ttl = DateTime.diff(expires_at, Auth.now(), :second)
    assert ttl in 590..600

    subject =
      Repo.get_by!(Fyrlet.Subject,
        project_id: first.project.id,
        issuer: "customer",
        external_id: "default-user"
      )

    assert subject.id == session["subject_id"]

    assert {:ok, short} =
             Auth.issue_session(first.service_key, %{
               "external_subject" => "default-user",
               "issuer" => "custom",
               "ttl_seconds" => 60
             })

    assert {:ok, short_expiry, _offset} = DateTime.from_iso8601(short["expires_at"])
    assert DateTime.diff(short_expiry, Auth.now(), :second) in 55..60
    refute short["subject_id"] == session["subject_id"]
  end

  test "session payload bounds are validated" do
    first = project()

    for parameters <- [
          %{},
          %{"external_subject" => ""},
          %{"external_subject" => String.duplicate("x", 201)},
          %{"external_subject" => "alice", "issuer" => ""},
          %{"external_subject" => "alice", "issuer" => String.duplicate("x", 201)},
          %{"external_subject" => 1}
        ] do
      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Auth.issue_session(first.service_key, parameters)
    end
  end

  test "users can revoke their own session" do
    first = project()
    alice = user(first)

    assert {:ok, %{"revoked" => true}} = Auth.revoke_own_session(alice.actor)
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.revalidate(alice.actor)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.authenticate(alice.token, first.project.id)

    assert Repo.get_by!(Fyrlet.Session, id: alice.actor.session_id).revoked_at
  end

  test "revocation entry points reject malformed and unknown identifiers" do
    first = project()
    alice = user(first)

    for identifier <- ["not-a-uuid", Ecto.UUID.generate()] do
      assert {:error, %Error{code: "NOT_FOUND"}} =
               Auth.revoke_session(first.service_key, identifier)
    end

    assert {:error, %Error{code: "NOT_FOUND"}} = Auth.revoke_key("not-a-uuid")
    assert :ok = Auth.revoke_key(Ecto.UUID.generate())

    assert {:ok, _actor} = Auth.revalidate(alice.actor)
  end

  test "tokens are random and deterministic hashing is used for storage" do
    first = Auth.random_token("rtk_")
    second = Auth.random_token("rtk_")
    assert String.starts_with?(first, "rtk_")
    assert first != second

    assert Auth.hash("value") == :crypto.hash(:sha256, "value")
    assert Auth.now().time_zone == "Etc/UTC"
  end
end
