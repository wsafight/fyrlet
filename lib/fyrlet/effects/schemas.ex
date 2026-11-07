defmodule Fyrlet.Effects.Effect do
  @moduledoc "An external side effect a run intends to cause, with its delivery state."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_effects" do
    field(:project_id, :binary_id)
    field(:run_id, :binary_id)
    field(:step_id, :binary_id)
    field(:effect_key, :string)
    field(:operation_id, :string)
    field(:adapter, :string)
    field(:adapter_version, :string)
    field(:delivery_policy, :string)
    field(:payload, Fyrlet.EncryptedMap)
    field(:payload_hash, :binary)
    field(:status, :string)
    field(:lease_id, :binary_id)
    field(:execution_epoch, :integer, default: 0)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:max_attempts, :integer, default: 5)
    field(:claimed_at, :utc_datetime_usec)
    field(:first_dispatched_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:secret_ref, :string)
    field(:external_ref, :string)
    field(:result, Fyrlet.EncryptedMap)
    field(:last_error, :map)
    field(:resolution_required, :boolean, default: false)
    field(:reconcile_attempts, :integer, default: 0)
    field(:event_seq, :integer, default: 0)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Effects.Event do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_effect_events" do
    field(:effect_id, :binary_id)
    field(:seq, :integer)
    field(:type, :string)
    field(:payload, :map, default: %{})
    field(:receipt_id, :string)
    field(:at, :utc_datetime_usec)
  end
end
