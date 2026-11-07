defmodule FlowExample.Flow do
  @moduledoc "A saved flow, owned by its author."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "flow_definitions" do
    field(:project_id, :binary_id)
    field(:subject_id, :binary_id)
    field(:flow_id, :string)
    field(:nodes_json, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
