defmodule FyrletWeb.OperationChannel do
  use Phoenix.Channel,
    log_join: false,
    log_handle_in: false,
    hibernate_after: Application.compile_env(:fyrlet, :channel_hibernate_after, 15_000)

  alias Fyrlet.{Auth, Capabilities, Error, Runtime}
  import FyrletWeb.ChannelSupport, only: [anonymous_entry: 2, cancel_timers: 2, expiry_timer: 1]

  @impl true
  def join("operations", %{"protocol_version" => 1} = options, socket) do
    with {:ok, capabilities} <- Capabilities.negotiate(options["capabilities"]),
         :ok <- anonymous_entry(socket.assigns.actor, capabilities),
         {:ok, actor} <- Auth.revalidate(socket.assigns.actor) do
      reply = %{
        "protocol_version" => Capabilities.protocol_version(),
        "capabilities" => capabilities
      }

      {:ok, reply,
       socket
       |> assign(:capabilities, capabilities)
       |> assign(:expiry_timer, expiry_timer(actor))}
    else
      {:error, error} -> {:error, response(error)}
    end
  end

  def join(_topic, _parameters, _socket),
    do: {:error, response(Error.new("UNSUPPORTED_VERSION", "Expected protocol_version 1"))}

  @impl true
  def handle_in(event, %{"name" => name, "input" => input} = parameters, socket)
      when event in ["call", "recover"] and is_binary(name) do
    {:message_queue_len, length} = Process.info(self(), :message_queue_len)
    perform = if event == "call", do: &Runtime.call_with_outcome/5, else: &Runtime.recover/5

    result =
      if length > Application.fetch_env!(:fyrlet, :max_channel_queue),
        do: {:error, Error.new("LIMIT_EXCEEDED", "Too many pending operations")},
        else:
          perform.(socket.assigns.actor, name, input, parameters["idempotency_key"],
            capabilities: socket.assigns.capabilities
          )

    case result do
      {:ok, envelope} -> {:reply, {:ok, envelope}, socket}
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
  def terminate(_reason, socket), do: cancel_timers(socket, [:expiry_timer])

  defp response(error), do: %{"error" => Error.to_map(error), "status" => Error.status(error)}
end
