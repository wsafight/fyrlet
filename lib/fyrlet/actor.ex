defmodule Fyrlet.Actor do
  @enforce_keys [:project_id, :subject_id, :session_id, :expires_at]
  # `kind` is "user" for sessions a backend issued and "anonymous" for the restricted public
  # principal. Anything that is not explicitly allowed for anonymous callers is refused.
  defstruct [:project_id, :subject_id, :session_id, :expires_at, kind: "user"]

  @type t :: %__MODULE__{}
end
