defmodule FyrletWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fyrlet

  socket "/socket", FyrletWeb.UserSocket,
    auth_token: true,
    websocket: [max_frame_size: 65_536, timeout: 45_000],
    longpoll: false

  plug Plug.RequestId
  plug FyrletWeb.CORS
  plug FyrletWeb.HTTP
end
