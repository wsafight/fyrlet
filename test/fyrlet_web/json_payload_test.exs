defmodule FyrletWeb.JSONPayloadTest do
  use ExUnit.Case, async: true

  test "preencoded payloads preserve Phoenix frames and JSON values" do
    payload = %{
      "g" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "b" => 1,
      "s" => 2,
      "p" => %{"c" => [["record", %{"text" => "更新\n\"\\", "optional" => nil}]]}
    }

    message = %Phoenix.Socket.Message{
      join_ref: "1",
      ref: nil,
      topic: "subscription:test",
      event: "delta",
      payload: Jason.Fragment.new(Jason.encode!(payload))
    }

    assert {:socket_push, :text, encoded} = Phoenix.Socket.V2.JSONSerializer.encode!(message)

    assert Jason.decode!(IO.iodata_to_binary(encoded)) ==
             ["1", nil, "subscription:test", "delta", payload]
  end
end
