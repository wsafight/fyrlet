projects = for name <- ["Integration A", "Integration B"] do
  {:ok, result} = Fyrlet.Auth.create_project(name)
  %{project_id: result.project.id, service_key: result.service_key}
end

path = System.fetch_env!("INTEGRATION_FIXTURES")
File.mkdir_p!(Path.dirname(path))
File.write!(path, Jason.encode!(projects))
File.chmod!(path, 0o600)
IO.puts("Integration projects created; credentials saved in the ignored local directory")
