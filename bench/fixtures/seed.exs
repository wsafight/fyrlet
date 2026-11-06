alias Fyrlet.{Auth, InboxItem, Repo}

{:ok, project} = Auth.create_project("bench:" <> System.fetch_env!("BENCH_RUN_ID"))
rows = String.to_integer(System.fetch_env!("BENCH_ROWS"))
payload_bytes = String.to_integer(System.fetch_env!("BENCH_PAYLOAD_BYTES"))
users = String.to_integer(System.fetch_env!("BENCH_USERS"))
devices = String.to_integer(System.get_env("BENCH_DEVICES", "1"))
session_model = System.get_env("BENCH_SESSION_MODEL", "shared")

fixtures =
  for index <- 1..users do
    {:ok, session} =
      Auth.issue_session(project.service_key, %{
        "external_subject" => "bench-user-#{index}",
        "issuer" => "benchmark",
        "ttl_seconds" => 900
      })

    now = Auth.now()

    records =
      for row <- 1..rows do
        %{
          id: Ecto.UUID.generate(),
          project_id: project.project.id,
          subject_id: session["subject_id"],
          text: String.pad_trailing("seed:#{row}:", payload_bytes, "x"),
          content_type: "text",
          archived: false,
          version: 1,
          inserted_at: DateTime.add(now, row, :microsecond),
          updated_at: DateTime.add(now, row, :microsecond)
        }
      end

    Repo.insert_all(InboxItem, records)

    observer_tokens =
      if session_model == "device" do
        for _device <- 1..devices do
          {:ok, device_session} =
            Auth.issue_session(project.service_key, %{
              "external_subject" => "bench-user-#{index}",
              "issuer" => "benchmark",
              "ttl_seconds" => 900
            })

          true = device_session["subject_id"] == session["subject_id"]
          device_session["token"]
        end
      else
        []
      end

    %{token: session["token"], observer_tokens: observer_tokens, ids: Enum.map(records, & &1.id)}
  end

fixture = %{
  target: "fyrlet",
  run_id: System.fetch_env!("BENCH_RUN_ID"),
  project_id: project.project.id,
  rows: rows,
  payload_bytes: payload_bytes,
  session_model: session_model,
  users: fixtures
}

path = System.fetch_env!("BENCH_FIXTURES")
File.mkdir_p!(Path.dirname(path))
File.write!(path, Jason.encode!(fixture))
File.chmod!(path, 0o600)
IO.puts("Benchmark fixtures written to the private run directory")
