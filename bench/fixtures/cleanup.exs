import Ecto.Query

name = "bench:" <> System.fetch_env!("BENCH_RUN_ID")

{count, _entries} =
  Fyrlet.Repo.delete_all(from(project in Fyrlet.Project, where: project.name == ^name))

IO.puts("Removed #{count} benchmark project(s)")
