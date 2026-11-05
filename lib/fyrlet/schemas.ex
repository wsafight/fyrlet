defmodule Fyrlet.Project do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "projects" do
    field(:name, :string)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.ServiceKey do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "service_keys" do
    belongs_to(:project, Fyrlet.Project)
    field(:token_hash, :binary)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Subject do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "subjects" do
    belongs_to(:project, Fyrlet.Project)
    field(:issuer, :string)
    field(:external_id, :string)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Session do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sessions" do
    belongs_to(:project, Fyrlet.Project)
    belongs_to(:subject, Fyrlet.Subject)
    belongs_to(:service_key, Fyrlet.ServiceKey)
    field(:token_hash, :binary)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Idempotency do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "idempotency_results" do
    belongs_to(:project, Fyrlet.Project)
    belongs_to(:subject, Fyrlet.Subject)
    field(:operation, :string)
    field(:key, :string)
    field(:input_hash, :binary)
    field(:result, :map)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.InboxItem do
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
