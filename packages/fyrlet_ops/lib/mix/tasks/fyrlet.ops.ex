defmodule Mix.Tasks.Fyrlet.Ops do
  use Mix.Task
  @shortdoc "Prints the operational status and firing alerts"

  @moduledoc """
  Prints the installation-wide status and the alerts that are firing, as JSON.

      mix fyrlet.ops [--fail-on-alert] [--project PROJECT_ID]

  With `--fail-on-alert` the task exits non-zero while any alert fires, so it can serve as a
  cron job or deploy gate. Alerts carry no run or effect IDs; use `mix fyrlet.runs` and
  `mix fyrlet.effects` to find what is behind them.
  """

  def run(arguments) do
    {options, _rest} =
      OptionParser.parse!(arguments, strict: [fail_on_alert: :boolean, project: :string])

    Mix.Task.run("app.start")
    status = FyrletOps.Status.status(Keyword.get(options, :project, :all))
    alerts = FyrletOps.Status.alerts(status)
    Mix.shell().info(Jason.encode!(%{status: status, alerts: alerts}, pretty: true))

    if options[:fail_on_alert] && alerts != [] do
      Mix.raise("#{length(alerts)} alert(s) firing")
    end
  end
end
