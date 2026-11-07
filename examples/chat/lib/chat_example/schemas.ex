defmodule ChatExample.Room do
  @moduledoc "A project-scoped conversation; its invitation is shared only with members."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "chat_rooms" do
    field(:project_id, :binary_id)
    field(:title, :string)
    field(:code, :string)
    field(:status, :string, default: "open")
    field(:assigned_subject_id, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule ChatExample.Member do
  @moduledoc "Durable membership in one conversation."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "chat_members" do
    field(:project_id, :binary_id)
    field(:room_id, :binary_id)
    field(:subject_id, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule ChatExample.Message do
  @moduledoc "Persistent message history, independent of the bounded live stream."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "chat_messages" do
    field(:project_id, :binary_id)
    field(:room_id, :binary_id)
    field(:subject_id, :binary_id)
    field(:text, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
