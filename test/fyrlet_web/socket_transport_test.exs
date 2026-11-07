defmodule FyrletWeb.SocketTransportTest do
  use ExUnit.Case, async: false
  alias FyrletWeb.SocketTransport

  setup do
    previous =
      Map.new([:socket_batch_max_messages, :socket_batch_max_bytes], fn key ->
        {key, Application.fetch_env!(:fyrlet, key)}
      end)

    on_exit(fn ->
      for {key, value} <- previous, do: Application.put_env(:fyrlet, key, value)
    end)

    :ok
  end

  test "queued text frames batch in order without a waiting timer" do
    state = %{socket: :unused, frames: [], count: 0, bytes: 0}
    first = Jason.encode!(["1", nil, "subscription:a", "delta", %{"s" => 2}])
    second = Jason.encode!(["2", nil, "subscription:b", "snapshot", %{"seq" => 2}])
    send(self(), :queued_work)
    assert {:ok, state} = SocketTransport.handle_info({:socket_push, :text, first}, state)
    assert_receive :flush_socket_batch
    assert {:ok, state} = SocketTransport.handle_info({:socket_push, :text, second}, state)

    assert {:push, {:text, encoded}, cleared} =
             SocketTransport.handle_info(:flush_socket_batch, state)

    assert Jason.decode!(IO.iodata_to_binary(encoded)) == %{
             "batch" => [Jason.decode!(first), Jason.decode!(second)]
           }

    assert cleared.count == 0
    assert {:ok, ^cleared} = SocketTransport.handle_info(:flush_socket_batch, cleared)
  end

  test "single frames are not wrapped and batches never exceed the message bound" do
    state = %{socket: :unused, frames: [], count: 0, bytes: 0}
    frame = Jason.encode!([nil, nil, "subscription:a", "delta", %{}])

    assert {:push, {:text, ^frame}, ^state} =
             SocketTransport.handle_info({:socket_push, :text, frame}, state)

    send(self(), :queued_work)
    {:ok, single} = SocketTransport.handle_info({:socket_push, :text, frame}, state)

    assert {:push, {:text, ^frame}, _cleared} =
             SocketTransport.handle_info(:flush_socket_batch, single)

    full =
      Enum.reduce(1..64, state, fn _index, current ->
        {:ok, next} = SocketTransport.handle_info({:socket_push, :text, frame}, current)
        next
      end)

    assert {:push, {:text, encoded}, next} =
             SocketTransport.handle_info({:socket_push, :text, frame}, full)

    assert length(Jason.decode!(IO.iodata_to_binary(encoded))["batch"]) == 64
    assert next.count == 1
  end

  test "the byte bound flushes queued data before accepting another frame" do
    Application.put_env(:fyrlet, :socket_batch_max_bytes, 80)
    state = %{socket: :unused, frames: [], count: 0, bytes: 0}
    frame = Jason.encode!([nil, nil, "subscription:a", "delta", %{"seq" => 2}])
    send(self(), :queued_work)
    {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, frame}, state)

    assert {:push, {:text, ^frame}, next} =
             SocketTransport.handle_info({:socket_push, :text, frame}, queued)

    assert next.count == 1
  end

  test "disabling batching flushes pending frames before the current frame" do
    state = transport_state()
    first = Jason.encode!([nil, nil, "subscription:a", "delta", %{"s" => 1}])
    second = Jason.encode!([nil, nil, "subscription:a", "delta", %{"s" => 2}])
    send(self(), :queued_work)
    assert {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, first}, state)
    Application.put_env(:fyrlet, :socket_batch_max_messages, 1)

    assert {:push, [{:text, ^first}, {:text, ^second}], cleared} =
             SocketTransport.handle_info({:socket_push, :text, second}, queued)

    assert cleared == state
    assert {:ok, ^state} = SocketTransport.handle_info(:flush_socket_batch, cleared)
  end

  test "a frame at the byte limit bypasses batching after draining older frames" do
    state = transport_state()
    first = Jason.encode!([nil, nil, "subscription:a", "delta", %{}])
    large = Jason.encode!([nil, nil, "subscription:a", "snapshot", %{"text" => "更新更新"}])
    Application.put_env(:fyrlet, :socket_batch_max_bytes, byte_size(large))
    send(self(), :queued_work)
    assert {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, first}, state)

    assert {:push, [{:text, ^first}, {:text, ^large}], ^state} =
             SocketTransport.handle_info({:socket_push, :text, large}, queued)
  end

  test "byte limits include the batch envelope, separators and multibyte characters" do
    state = transport_state()
    first = Jason.encode!([nil, nil, "subscription:a", "delta", %{"text" => "更新"}])
    second = Jason.encode!([nil, nil, "subscription:b", "delta", %{"text" => "你好"}])
    limit = byte_size(first) + byte_size(second) + 13
    Application.put_env(:fyrlet, :socket_batch_max_bytes, limit)
    send(self(), :queued_work)
    assert {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, first}, state)
    assert {:ok, full} = SocketTransport.handle_info({:socket_push, :text, second}, queued)

    assert {:push, {:text, encoded}, ^state} =
             SocketTransport.handle_info(:flush_socket_batch, full)

    assert IO.iodata_length(encoded) == limit

    assert Jason.decode!(IO.iodata_to_binary(encoded))["batch"] == [
             Jason.decode!(first),
             Jason.decode!(second)
           ]

    Application.put_env(:fyrlet, :socket_batch_max_bytes, limit - 1)

    assert {:push, {:text, ^first}, next} =
             SocketTransport.handle_info({:socket_push, :text, second}, queued)

    assert next.frames == [second]
    assert next.bytes == byte_size(second)
    assert next.count == 1
  end

  test "heartbeat replies drain queued data first and do not duplicate it on the scheduled flush" do
    state = transport_state()
    frame = Jason.encode!([nil, nil, "subscription:a", "delta", %{"s" => 1}])
    send(self(), :queued_work)
    assert {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, frame}, state)
    heartbeat = Jason.encode!([nil, "heartbeat-ref", "phoenix", "heartbeat", %{}])

    assert {:reply, :ok, [{:text, ^frame}, {:text, reply}], cleared} =
             SocketTransport.handle_in({heartbeat, opcode: :text}, queued)

    assert Jason.decode!(IO.iodata_to_binary(reply)) ==
             [
               nil,
               "heartbeat-ref",
               "phoenix",
               "phx_reply",
               %{"status" => "ok", "response" => %{}}
             ]

    assert cleared.count == 0
    assert {:ok, ^cleared} = SocketTransport.handle_info(:flush_socket_batch, cleared)
  end

  test "disconnect discards pending data and preserves the transport stop reason" do
    state = transport_state()
    send(self(), :queued_work)
    assert {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, "[]"}, state)

    assert {:stop, {:shutdown, :disconnected}, ^state} =
             SocketTransport.handle_info(%Phoenix.Socket.Broadcast{event: "disconnect"}, queued)

    assert :ok = SocketTransport.terminate(:normal, state)
  end

  test "binary frames drain queued text while unrelated messages preserve the queue" do
    state = transport_state()
    send(self(), :queued_work)
    assert {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, "[]"}, state)
    assert {:ok, ^queued} = SocketTransport.handle_info(:unrelated, queued)

    assert {:push, [{:text, "[]"}, {:binary, <<1, 2, 3>>}], ^state} =
             SocketTransport.handle_info({:socket_push, :binary, <<1, 2, 3>>}, queued)
  end

  defp transport_state do
    socket = %Phoenix.Socket{
      endpoint: FyrletWeb.Endpoint,
      handler: FyrletWeb.UserSocket,
      serializer: Phoenix.Socket.V2.JSONSerializer
    }

    {:ok, state} = SocketTransport.init({%{channels: %{}, channels_inverse: %{}}, socket})
    state
  end
end
