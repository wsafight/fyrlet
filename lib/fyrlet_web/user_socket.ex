defmodule FyrletWeb.UserSocket do
  use Phoenix.Socket, log: false
  channel "subscription:*", FyrletWeb.SubscriptionChannel
  channel "operations", FyrletWeb.OperationChannel

  @impl true
  def connect(%{"project_id" => project_id}, socket, %{auth_token: token}) do
    case Fyrlet.Auth.authenticate(token, project_id) do
      {:ok, actor} -> {:ok, assign(socket, :actor, actor)}
      {:error, _error} -> :error
    end
  end

  def connect(_parameters, _socket, _info), do: :error

  @impl true
  def id(socket), do: "sessions:" <> socket.assigns.actor.session_id
end
