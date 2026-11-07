defmodule FyrletWeb.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  import Plug.Test
  alias FyrletWeb.CacheBodyReader

  defmodule FailingAdapter do
    def read_req_body(_state, _options), do: {:error, :timeout}
  end

  test "plugin bodies retain their exact signed bytes before JSON parsing" do
    body = "{ \"text\": \"更新\\n\\u0061\", \"value\": 1 }\n"
    conn = conn(:post, "/api/v1/plugins/webhooks/provider", body)

    assert {:ok, ^body, read} = CacheBodyReader.read_body(conn, [])
    assert read.assigns.raw_body == body
    assert {:ok, "", _conn} = Plug.Conn.read_body(read)
  end

  test "ordinary routes and similar prefixes do not retain the request body" do
    for path <- ["/api/v1/sessions", "/api/v1/plugins", "/api/v1/plugins-other/provider"] do
      assert {:ok, "{}", read} = CacheBodyReader.read_body(conn(:post, path, "{}"), [])
      refute Map.has_key?(read.assigns, :raw_body)
    end
  end

  test "incomplete reads preserve the remaining bytes without caching a partial signature body" do
    conn = conn(:post, "/api/v1/plugins/webhooks/provider", "abcdefgh")
    assert {:more, "abc", read} = CacheBodyReader.read_body(conn, length: 3)
    refute Map.has_key?(read.assigns, :raw_body)
    assert {:ok, "defgh", _conn} = Plug.Conn.read_body(read)
  end

  test "body read failures are returned to the parser unchanged" do
    conn = %{conn(:post, "/api/v1/plugins/webhooks/provider") | adapter: {FailingAdapter, %{}}}
    assert {:error, :timeout} = CacheBodyReader.read_body(conn, [])
  end
end
