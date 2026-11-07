defmodule FyrletWebhooks.TestHandler do
  @moduledoc "Translates the test payload `{event, run, wait, name, data}` into a signal."
  def translate(%{"event" => event, "run" => run, "wait" => wait, "name" => name} = payload),
    do:
      {:ok,
       %{
         event_id: event,
         run_id: run,
         wait_id: wait,
         name: name,
         payload: Map.get(payload, "data", %{})
       }}

  def translate(_other), do: {:error, Fyrlet.Error.new("VALIDATION_FAILED", "unrecognised event")}
end
