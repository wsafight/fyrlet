import Ecto.Query

name = "bench:" <> System.fetch_env!("BENCH_RUN_ID")
started = System.monotonic_time(:millisecond)

{count, _entries} =
  Fyrlet.Repo.delete_all(from(project in Fyrlet.Project, where: project.name == ^name))

duration = System.monotonic_time(:millisecond) - started
IO.puts("Removed #{count} benchmark project(s) in #{duration} ms")
