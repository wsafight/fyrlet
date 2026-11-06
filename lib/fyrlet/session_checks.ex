defmodule Fyrlet.SessionChecks do
  use Supervisor
  alias Fyrlet.{Error, SessionChecks.Worker}

  @servers for index <- 0..7, do: Module.concat(__MODULE__, "Shard#{index}")

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  def server(actor), do: Enum.at(@servers, :erlang.phash2(actor.session_id, length(@servers)))

  def revalidate(actor) do
    GenServer.call(server(actor), {:revalidate, actor}, 15_000)
  catch
    :exit, _reason ->
      {:error, Error.new("INTERNAL_ERROR", "Session validation is unavailable", %{}, true)}
  end

  @impl true
  def init(_options) do
    children = for name <- @servers, do: Supervisor.child_spec({Worker, name: name}, id: name)
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Fyrlet.SessionChecks.Worker do
  use GenServer
  import Ecto.Query
  require Logger
  alias Fyrlet.{Auth, Error, Repo, Session}

  @batch_size 128

  def start_link(options),
    do: GenServer.start_link(__MODULE__, %{requests: [], size: 0}, options)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:revalidate, actor}, from, state) do
    if state.size == 0, do: send(self(), :flush)
    state = %{requests: [{from, actor} | state.requests], size: state.size + 1}
    {:noreply, if(state.size == @batch_size, do: flush(state), else: state)}
  end

  @impl true
  def handle_info(:flush, %{size: 0} = state), do: {:noreply, state}
  def handle_info(:flush, state), do: {:noreply, flush(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp flush(state) do
    started = System.monotonic_time()

    identifiers =
      state.requests |> Enum.map(fn {_from, actor} -> actor.session_id end) |> Enum.uniq()

    result = load(identifiers)

    :telemetry.execute(
      [:fyrlet, :auth, :batch],
      %{
        duration: System.monotonic_time() - started,
        requests: state.size,
        sessions: length(identifiers)
      },
      %{result: elem(result, 0)}
    )

    for {from, actor} <- state.requests do
      response =
        case result do
          {:ok, sessions} ->
            case Map.get(sessions, actor.session_id) do
              {project, subject, expires_at, revoked_at}
              when project == actor.project_id and subject == actor.subject_id ->
                Auth.validate_session(actor, expires_at, revoked_at)

              _missing ->
                {:error, Error.unauthorized()}
            end

          {:error, error} ->
            {:error, error}
        end

      GenServer.reply(from, response)
    end

    %{requests: [], size: 0}
  end

  defp load(identifiers) do
    sessions =
      Repo.all(
        from(session in Session,
          where: session.id in ^identifiers,
          select:
            {session.id, session.project_id, session.subject_id, session.expires_at,
             session.revoked_at}
        )
      )

    {:ok,
     Map.new(sessions, fn {identifier, project, subject, expires_at, revoked_at} ->
       {identifier, {project, subject, expires_at, revoked_at}}
     end)}
  rescue
    error ->
      Logger.error("Session batch failed: #{inspect(error.__struct__)}")
      {:error, Error.new("INTERNAL_ERROR", "Session validation is unavailable", %{}, true)}
  end
end
