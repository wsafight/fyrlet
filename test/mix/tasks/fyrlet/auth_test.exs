defmodule Mix.Tasks.Fyrlet.AuthTest do
  use Fyrlet.DataCase, async: false

  alias Fyrlet.{Idempotency, ServiceKey, Session}
  alias Mix.Tasks.Fyrlet.{Prune, RevokeKey}

  setup context do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      if context[:tmp_dir], do: File.rm_rf!(context.tmp_dir)
    end)

    :ok
  end

  describe "fyrlet.project" do
    test "creates a named project and prints usable backend credentials" do
      Mix.Tasks.Fyrlet.Project.run(["My", "Project"])

      assert_received {:mix_shell, :info, [json]}
      credentials = Jason.decode!(json)
      assert Repo.get!(Fyrlet.Project, credentials["project_id"]).name == "My Project"
      assert {:ok, key} = Auth.authenticate_key(credentials["service_key"])
      assert key.id == credentials["key_id"]
      assert key.project_id == credentials["project_id"]
      refute key.token_hash == credentials["service_key"]
    end

    @tag :tmp_dir
    test "writes credentials to a private file without printing the secret", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "credentials.json"])
      Mix.Tasks.Fyrlet.Project.run(["--output", path, "private"])

      contents = File.read!(path)
      credentials = Jason.decode!(contents)
      assert String.ends_with?(contents, "\n")
      assert {:ok, _key} = Auth.authenticate_key(credentials["service_key"])
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert_received {:mix_shell, :info, [message]}
      assert message =~ path
      refute message =~ credentials["service_key"]
      refute_received {:mix_shell, :info, _}
    end

    @tag :tmp_dir
    test "refuses to overwrite a credential file before creating a project", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "credentials.json")
      File.write!(path, "existing credentials")
      before_count = Repo.aggregate(Fyrlet.Project, :count)

      assert_raise Mix.Error, ~r/Output file already exists/, fn ->
        Mix.Tasks.Fyrlet.Project.run(["--output", path, "duplicate"])
      end

      assert File.read!(path) == "existing credentials"
      assert Repo.aggregate(Fyrlet.Project, :count) == before_count
      refute_received {:mix_shell, :info, _}
    end

    test "rejects missing names, oversized names and invalid options without creating rows" do
      before_count = Repo.aggregate(Fyrlet.Project, :count)

      for arguments <- [[], [""], [String.duplicate("a", 201)], ["--unknown", "name"]] do
        assert_raise Mix.Error, ~r/Usage: mix fyrlet.project/, fn ->
          Mix.Tasks.Fyrlet.Project.run(arguments)
        end
      end

      assert Repo.aggregate(Fyrlet.Project, :count) == before_count
      refute_received {:mix_shell, :info, _}
    end

    test "accepts a project name at the 200-byte limit" do
      name = String.duplicate("a", 200)
      Mix.Tasks.Fyrlet.Project.run([name])

      assert_received {:mix_shell, :info, [json]}
      assert Repo.get!(Fyrlet.Project, Jason.decode!(json)["project_id"]).name == name
    end
  end

  describe "fyrlet.revoke_key" do
    test "revokes only the selected credential" do
      selected = project()
      other = project()

      RevokeKey.run([selected.key_id])

      assert_received {:mix_shell, :info, ["Service key revoked"]}
      assert Repo.get!(ServiceKey, selected.key_id).revoked_at

      assert {:error, %Error{code: "UNAUTHENTICATED"}} =
               Auth.authenticate_key(selected.service_key)

      assert {:ok, _key} = Auth.authenticate_key(other.service_key)
    end

    test "reports malformed key identifiers as command errors" do
      assert_raise Mix.Error, "The requested resource does not exist", fn ->
        RevokeKey.run(["not-a-uuid"])
      end

      refute_received {:mix_shell, :info, _}
    end

    test "requires exactly one key identifier" do
      for arguments <- [[], [Ecto.UUID.generate(), Ecto.UUID.generate()]] do
        assert_raise Mix.Error, "Usage: mix fyrlet.revoke_key KEY_ID", fn ->
          RevokeKey.run(arguments)
        end
      end
    end
  end

  describe "fyrlet.prune" do
    test "reports zero removals when there is nothing to prune" do
      Prune.run([])

      assert_received {:mix_shell, :info, [json]}
      assert Jason.decode!(json) == %{"idempotency_results" => 0, "sessions" => 0}
    end

    test "deletes expired idempotency results while preserving live results" do
      alice = user(project())
      assert {:ok, _result} = add(alice.actor, "expired")
      assert {:ok, _result} = add(alice.actor, "live")
      [expired, live] = Repo.all(from(entry in Idempotency, order_by: entry.inserted_at))
      past = DateTime.add(Auth.now(), -60, :second)

      Repo.update_all(from(entry in Idempotency, where: entry.id == ^expired.id),
        set: [expires_at: past]
      )

      Prune.run([])

      assert_received {:mix_shell, :info, [json]}
      assert Jason.decode!(json) == %{"idempotency_results" => 1, "sessions" => 0}
      refute Repo.get(Idempotency, expired.id)
      assert Repo.get!(Idempotency, live.id).result == live.result
      assert Repo.aggregate(InboxItem, :count) == 2
    end

    test "keeps recently expired sessions and removes sessions expired for over a day" do
      project = project()
      old = user(project, "old")
      recent = user(project, "recent")
      active = user(project, "active")
      now = Auth.now()

      for {session, seconds} <- [{old, -172_800}, {recent, -3_600}] do
        expires_at = DateTime.add(now, seconds, :second)

        Repo.update_all(from(entry in Session, where: entry.id == ^session.actor.session_id),
          set: [expires_at: expires_at]
        )
      end

      Prune.run([])

      assert_received {:mix_shell, :info, [json]}
      assert Jason.decode!(json) == %{"idempotency_results" => 0, "sessions" => 1}
      refute Repo.get(Session, old.actor.session_id)
      assert Repo.get(Session, recent.actor.session_id)
      assert {:ok, _actor} = Auth.authenticate(active.token, project.project.id)
    end
  end
end
