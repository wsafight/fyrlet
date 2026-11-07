defmodule FyrletWeb.SocketTransportTest do
  use ExUnit.Case, async: false
  alias FyrletWeb.SocketTransport

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
    previous = Application.fetch_env!(:fyrlet, :socket_batch_max_bytes)
    Application.put_env(:fyrlet, :socket_batch_max_bytes, 80)
    on_exit(fn -> Application.put_env(:fyrlet, :socket_batch_max_bytes, previous) end)
    state = %{socket: :unused, frames: [], count: 0, bytes: 0}
    frame = Jason.encode!([nil, nil, "subscription:a", "delta", %{"seq" => 2}])
    send(self(), :queued_work)
    {:ok, queued} = SocketTransport.handle_info({:socket_push, :text, frame}, state)

    assert {:push, {:text, ^frame}, next} =
             SocketTransport.handle_info({:socket_push, :text, frame}, queued)

    assert next.count == 1
  end
end
