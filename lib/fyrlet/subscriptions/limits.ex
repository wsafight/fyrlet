defmodule Fyrlet.Subscriptions.Limits do
  @moduledoc false

  def snapshot_bytes(specification) do
    maximum = Application.fetch_env!(:fyrlet, :max_snapshot_bytes)
    min(Map.get(specification, "max_snapshot_bytes", maximum), maximum)
  end

  def check_snapshot(bytes, specification) do
    limit = snapshot_bytes(specification)

    if bytes <= limit,
      do: :ok,
      else:
        {:error,
         Fyrlet.Error.new("LIMIT_EXCEEDED", "The snapshot exceeds the response size limit", %{
           "limit" => limit
         })}
  end
end
