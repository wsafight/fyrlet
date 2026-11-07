defmodule InboxExample.Item do
  @moduledoc "A personal inbox record, owned by one project and subject."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "inbox_items" do
    belongs_to(:project, Fyrlet.Project)
    belongs_to(:subject, Fyrlet.Subject)
    field(:text, :string)
    field(:content_type, :string, default: "text")
    field(:archived, :boolean, default: false)
    field(:version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
