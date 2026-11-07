defmodule FyrletOps.AlertHandler do
  @moduledoc """
  Receives alert transitions from `FyrletOps.Status.evaluate/0`. Configure with
  `config :fyrlet, :ops, alert_handlers: [MyApp.PagerHandler]`.

  `alert` is `%{"name", "severity", "value", "threshold", "message"}`. Called once when an
  alert starts firing and once when it stops - never on every scan. Keep it quick and do
  not raise: a failing handler is logged and skipped, it does not stop the others.
  """
  @callback handle_alert(:firing | :resolved, alert :: map()) :: any()
end
