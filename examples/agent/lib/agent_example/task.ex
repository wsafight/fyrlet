defmodule AgentExample.Task do
  @moduledoc "A bounded tool task and its human decision."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agent_tasks" do
    field(:project_id, :binary_id)
    field(:subject_id, :binary_id)
    field(:run_id, :binary_id)
    field(:goal, :string)
    field(:tool, :string)
    field(:result_json, :string)
    field(:status, :string, default: "awaiting_approval")
    timestamps(type: :utc_datetime_usec)
  end
end
