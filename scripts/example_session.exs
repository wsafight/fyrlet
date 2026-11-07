if Mix.env() != :dev do
  raise "Example sessions are only available in the development environment"
end

domain = Application.fetch_env!(:fyrlet, :example_domain)
subject = List.first(System.argv()) || "alice"
path = Path.expand("../.local/examples/#{domain}.json", __DIR__)

credentials =
  if File.exists?(path) do
    path |> File.read!() |> Jason.decode!()
  else
    {:ok, result} = Fyrlet.Auth.create_project("#{domain} demo")
    credentials = %{"project_id" => result.project.id, "service_key" => result.service_key}
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(credentials))
    File.chmod!(path, 0o600)
    credentials
  end

{:ok, session} =
  Fyrlet.Auth.issue_session(credentials["service_key"], %{
    "external_subject" => subject,
    "ttl_seconds" => 900
  })

IO.puts(
  Jason.encode!(Map.take(session, ~w(project_id subject_id token expires_at)), pretty: true)
)
