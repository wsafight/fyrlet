defmodule FyrletWeb.SocketTransport do
  @behaviour Phoenix.Socket.Transport
  alias FyrletWeb.UserSocket

  @impl true
  defdelegate child_spec(options), to: UserSocket
  @impl true
  defdelegate drainer_spec(options), to: UserSocket
  @impl true
  defdelegate connect(config), to: UserSocket

  @impl true
  def init(socket) do
    {:ok, socket} = UserSocket.init(socket)
    {:ok, %{socket: socket, frames: [], count: 0, bytes: 0}}
  end

  @impl true
  def handle_in(message, state), do: wrap(UserSocket.handle_in(message, state.socket), state)

  @impl true
  def handle_info({:socket_push, :text, frame}, state) do
    bytes = IO.iodata_length(frame)
    limit = min(Application.fetch_env!(:fyrlet, :socket_batch_max_messages), 64)
    byte_limit = Application.fetch_env!(:fyrlet, :socket_batch_max_bytes)

    cond do
      state.count == 0 and elem(Process.info(self(), :message_queue_len), 1) == 0 ->
        {:push, {:text, frame}, state}

      limit == 1 or bytes >= byte_limit ->
        {:push, prepend(state, {:text, frame}), clear(state)}

      state.count > 0 and
          (state.count == limit or state.bytes + bytes + state.count + 12 > byte_limit) ->
        send(self(), :flush_socket_batch)
        {:push, {:text, encode(state)}, %{state | frames: [frame], count: 1, bytes: bytes}}

      true ->
        if state.count == 0, do: send(self(), :flush_socket_batch)

        {:ok,
         %{
           state
           | frames: [frame | state.frames],
             count: state.count + 1,
             bytes: state.bytes + bytes
         }}
    end
  end

  def handle_info(:flush_socket_batch, %{count: 0} = state), do: {:ok, state}
  def handle_info(:flush_socket_batch, state), do: {:push, {:text, encode(state)}, clear(state)}
  def handle_info(message, state), do: wrap(UserSocket.handle_info(message, state.socket), state)

  @impl true
  def terminate(reason, state), do: UserSocket.terminate(reason, state.socket)

  defp wrap({:ok, socket}, state), do: {:ok, %{state | socket: socket}}
  defp wrap({:stop, reason, socket}, state), do: {:stop, reason, %{clear(state) | socket: socket}}

  defp wrap({:push, frame, socket}, state),
    do: {:push, prepend(state, frame), %{clear(state) | socket: socket}}

  defp wrap({:reply, status, frame, socket}, state),
    do: {:reply, status, prepend(state, frame), %{clear(state) | socket: socket}}

  defp prepend(%{count: 0}, frame), do: frame
  defp prepend(state, frame), do: [{:text, encode(state)}, frame]
  defp clear(state), do: %{state | frames: [], count: 0, bytes: 0}

  defp encode(%{frames: [frame]}), do: frame

  defp encode(state) do
    :telemetry.execute(
      [:fyrlet, :transport, :batch],
      %{messages: state.count, bytes: state.bytes},
      %{}
    )

    ["{\"batch\":[", state.frames |> Enum.reverse() |> Enum.intersperse(","), "]}"]
  end
end
