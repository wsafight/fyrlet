defmodule Fyrlet.Runs.Grant do
  @moduledoc "Execution authority recorded when a run is accepted (never the user token)."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_execution_grants" do
    field(:project_id, :binary_id)
    field(:initiator_subject_id, :binary_id)
    field(:execution_subject_id, :binary_id)
    field(:operation, :string)
    field(:resource_scope, :map, default: %{})
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Runs.Run do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_runs" do
    field(:project_id, :binary_id)
    field(:subject_id, :binary_id)
    field(:operation, :string)
    field(:business_key, :string)
    field(:definition_module, :string)
    field(:definition_version, :string)
    field(:plan, Fyrlet.EncryptedMap)
    field(:execution_grant_id, :binary_id)
    field(:status, :string)
    field(:wait_reason, :string)
    field(:version, :integer, default: 1)
    field(:input, Fyrlet.EncryptedMap)
    field(:output, Fyrlet.EncryptedMap)
    field(:error, :map)
    field(:current_step_seq, :integer, default: 0)
    field(:execution_epoch, :integer, default: 0)
    field(:event_seq, :integer, default: 0)
    field(:cancel_deadline, :utc_datetime_usec)
    field(:cancellation_outcome, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:purged_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Runs.Step do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_run_steps" do
    field(:run_id, :binary_id)
    field(:type, :string)
    field(:name, :string)
    field(:seq, :integer)
    field(:status, :string)
    field(:input, Fyrlet.EncryptedMap)
    field(:output, Fyrlet.EncryptedMap)
    field(:signal_name, :string)
    field(:wait_deadline, :utc_datetime_usec)
    field(:wait_timeout_action, :string)
    field(:current_attempt, :integer, default: 0)
    field(:max_attempts, :integer, default: 1)
    field(:not_before, :utc_datetime_usec)
    field(:queue, :string)
    field(:error, :map)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Runs.Attempt do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_run_attempts" do
    field(:run_id, :binary_id)
    # Denormalised from the run: lets "leases held by this project" be answered from one index.
    field(:project_id, :binary_id)
    field(:step_id, :binary_id)
    field(:attempt, :integer)
    field(:execution_epoch, :integer)
    field(:lease_id, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:executor_id, :binary_id)
    field(:result_hash, :binary)
    field(:status, :string)
    field(:error, :map)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Fyrlet.Runs.Signal do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_run_signals" do
    field(:run_id, :binary_id)
    field(:wait_id, :binary_id)
    field(:name, :string)
    field(:payload, Fyrlet.EncryptedMap, default: %{})
    field(:idempotency_key, :string)
    field(:input_hash, :binary)
    field(:status, :string)
    field(:received_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
  end
end

defmodule Fyrlet.Runs.Event do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "fyrlet_run_events" do
    field(:run_id, :binary_id)
    field(:step_id, :binary_id)
    field(:type, :string)
    field(:payload, :map, default: %{})
    field(:seq, :integer)
    field(:created_at, :utc_datetime_usec)
  end
end
