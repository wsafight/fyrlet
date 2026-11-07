defmodule NotifyExample.Notification do
  @moduledoc "The in-app copy of a notification, owned by the person it is for."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notify_notifications" do
    belongs_to(:project, Fyrlet.Project)
    belongs_to(:subject, Fyrlet.Subject)
    field(:run_id, :binary_id)
    field(:title, :string)
    field(:body, :string)
    field(:delivery, :string, default: "pending")
    timestamps(type: :utc_datetime_usec)
  end
end
