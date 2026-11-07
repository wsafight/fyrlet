defmodule FyrletWeb.OperationChannel do
  use Phoenix.Channel,
    log_join: false,
    log_handle_in: false,
    hibernate_after: Application.compile_env(:fyrlet, :channel_hibernate_after, 15_000)

  alias Fyrlet.{Auth, Capabilities, Error, Runtime}

  @impl true
  def join("operations", %{"protocol_version" => 1} = options, socket) do
    with {:ok, capabilities} <- Capabilities.negotiate(options["capabilities"]),
         :ok <- anonymous_entry(socket.assigns.actor, capabilities),
         {:ok, actor} <- Auth.revalidate(socket.assigns.actor) do
      remaining = max(DateTime.diff(actor.expires_at, Auth.now(), :millisecond), 1)

      reply = %{
        "protocol_version" => Capabilities.protocol_version(),
        "capabilities" => capabilities
      }

      {:ok, reply,
       socket
       |> assign(:capabilities, capabilities)
       |> assign(:expiry_timer, Process.send_after(self(), :expired, remaining))}
    else
      {:error, error} -> {:error, response(error)}
    end
  end

  def join(_topic, _parameters, _socket),
    do: {:error, response(Error.new("UNSUPPORTED_VERSION", "Expected protocol_version 1"))}

  defp anonymous_entry(actor, capabilities) do
    if Fyrlet.Features.Anonymous.anonymous?(actor),
      do: Capabilities.require(capabilities, Fyrlet.Features.Anonymous.capability()),
      else: :ok
  end

  @impl true
  def handle_in("call", %{"name" => name, "input" => input} = parameters, socket)
      when is_binary(name) do
    {:message_queue_len, length} = Process.info(self(), :message_queue_len)

    result =
      if length > Application.fetch_env!(:fyrlet, :max_channel_queue),
        do: {:error, Error.new("LIMIT_EXCEEDED", "Too many pending operations")},
        else:
          Runtime.call(socket.assigns.actor, name, input, parameters["idempotency_key"],
            capabilities: socket.assigns.capabilities
          )

    case result do
      {:ok, data} -> {:reply, {:ok, %{"data" => data}}, socket}
      {:error, error} -> {:reply, {:error, response(error)}, socket}
    end
  end

  def handle_in(_event, _parameters, socket),
    do:
      {:reply,
       {:error, response(Error.new("VALIDATION_FAILED", "Expected a named operation and input"))},
       socket}

  @impl true
  def handle_info(:expired, socket) do
    push(socket, "status", response(Error.unauthorized()))
    {:stop, :normal, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if is_reference(socket.assigns[:expiry_timer]),
      do: Process.cancel_timer(socket.assigns.expiry_timer)

    :ok
  end

  defp response(error), do: %{"error" => Error.to_map(error), "status" => Error.status(error)}
end
