defmodule Fyrlet.TestRecord do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fyrlet_test_records" do
    belongs_to(:project, Fyrlet.Project)
    belongs_to(:subject, Fyrlet.Subject)
    field(:text, :string)
    field(:content_type, :string, default: "text")
    field(:version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
