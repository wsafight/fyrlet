defmodule Fyrlet.Actor do
  @enforce_keys [:project_id, :subject_id, :session_id, :expires_at]
  defstruct [:project_id, :subject_id, :session_id, :expires_at]

  @type t :: %__MODULE__{}
end
