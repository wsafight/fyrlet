defmodule Fyrlet.Repo.Migrations.CreateFyrlet do
  @moduledoc """
  Fyrlet's whole schema: projects and identities, idempotency, durable runs, effects, executors,
  ingest and streams, plus Oban's tables.

  The design behind the tables (constraints, indexes, retention) is in docs/DATABASE.md.

  Written as `up`/`down` because `Oban.Migration` is not reversible inside `change`.
  """
  use Ecto.Migration

  def up do
    Oban.Migration.up()

    # ---- projects and identities ------------------------------------------------------------

    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:service_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token_hash, :binary, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:service_keys, [:token_hash])
    create unique_index(:service_keys, [:id, :project_id])
    create index(:service_keys, [:project_id])

    create table(:subjects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issuer, :text, null: false
      add :external_id, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subjects, [:project_id, :issuer, :external_id])
    create unique_index(:subjects, [:id, :project_id])

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      # Null for anonymous sessions: they are not issued by a service key.
      add :service_key_id, references(:service_keys, type: :binary_id, on_delete: :delete_all)

      add :kind, :text, null: false, default: "user"
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:project_id, :subject_id])
    create index(:sessions, [:subject_id, :project_id])
    create index(:sessions, [:service_key_id, :project_id])
    create index(:sessions, [:expires_at])
    # Auth.check_issue_rate!/1 counts a key's sessions from the last minute on every issue.
    create index(:sessions, [:service_key_id, :inserted_at])

    create index(:sessions, [:project_id, :inserted_at],
             where: "kind = 'anonymous'",
             name: :sessions_anonymous_index
           )

    create table(:idempotency_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, references(:subjects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :operation, :text, null: false
      add :key, :text, null: false
      add :input_hash, :binary, null: false
      add :result, :map, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:idempotency_results, [:project_id, :subject_id, :operation, :key])
    create index(:idempotency_results, [:subject_id, :project_id])
    create index(:idempotency_results, [:expires_at])

    # A row's subject (and a session's key) must belong to the same project as the row.
    for table_name <- ["sessions", "idempotency_results"] do
      execute(
        "ALTER TABLE #{table_name} ADD CONSTRAINT #{table_name}_subject_project_fk " <>
          "FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)"
      )
    end

    execute(
      "ALTER TABLE sessions ADD CONSTRAINT sessions_key_project_fk " <>
        "FOREIGN KEY (service_key_id, project_id) REFERENCES service_keys(id, project_id)"
    )

    # ---- durable runs -----------------------------------------------------------------------

    create table(:fyrlet_execution_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :initiator_subject_id, :binary_id, null: false
      add :execution_subject_id, :binary_id, null: false
      add :operation, :text, null: false
      add :resource_scope, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:fyrlet_execution_grants, [:project_id, :initiator_subject_id])

    create table(:fyrlet_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, :binary_id, null: false
      add :operation, :text, null: false
      add :business_key, :text
      add :definition_module, :text, null: false
      add :definition_version, :text, null: false
      add :plan, :map, null: false
      add :execution_grant_id, references(:fyrlet_execution_grants, type: :binary_id), null: false
      add :status, :text, null: false
      add :wait_reason, :text
      add :version, :integer, null: false, default: 1
      add :input, :map, null: false
      add :output, :map
      add :error, :map
      add :current_step_seq, :integer, null: false, default: 0
      add :execution_epoch, :integer, null: false, default: 0
      add :event_seq, :integer, null: false, default: 0
      add :cancel_deadline, :utc_datetime_usec
      add :cancellation_outcome, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :purged_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE fyrlet_runs ADD CONSTRAINT fyrlet_runs_subject_project_fk " <>
        "FOREIGN KEY (subject_id, project_id) REFERENCES subjects(id, project_id)"
    )

    create index(:fyrlet_runs, [:project_id, :subject_id, :inserted_at])
    # Grant pruning and recovery both join runs through their execution grant.
    create index(:fyrlet_runs, [:execution_grant_id])

    create index(:fyrlet_runs, [:status, :updated_at],
             where: "status NOT IN ('completed','failed','cancelled','expired')",
             name: :fyrlet_runs_active_index
           )

    create index(:fyrlet_runs, [:expires_at],
             where: "status NOT IN ('completed','failed','cancelled','expired')",
             name: :fyrlet_runs_active_expiry_index
           )

    create index(:fyrlet_runs, [:finished_at], where: "finished_at IS NOT NULL")

    # One active run per business key; a finished run no longer blocks a new one (the
    # operation's `on_conflict` decides whether that is allowed).
    create unique_index(:fyrlet_runs, [:project_id, :operation, :business_key],
             where:
               "business_key IS NOT NULL AND status NOT IN ('completed','failed','cancelled','expired')",
             name: :fyrlet_runs_active_business_key_index
           )

    create table(:fyrlet_run_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:fyrlet_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :text, null: false
      add :name, :text, null: false
      add :seq, :integer, null: false
      add :status, :text, null: false
      add :input, :map
      add :output, :map
      add :signal_name, :text
      add :wait_deadline, :utc_datetime_usec
      add :wait_timeout_action, :text
      add :current_attempt, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 1
      add :not_before, :utc_datetime_usec
      # Work for an external executor lands in this queue instead of running in-process.
      add :queue, :text
      add :error, :map
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fyrlet_run_steps, [:run_id, :seq])

    create index(:fyrlet_run_steps, [:queue, :inserted_at],
             where: "queue IS NOT NULL AND status = 'pending'",
             name: :fyrlet_run_steps_queue_index
           )

    create index(:fyrlet_run_steps, [:wait_deadline],
             where: "status = 'waiting'",
             name: :fyrlet_run_steps_waiting_index
           )

    create table(:fyrlet_run_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:fyrlet_runs, type: :binary_id, on_delete: :delete_all), null: false

      add :step_id, references(:fyrlet_run_steps, type: :binary_id, on_delete: :delete_all),
        null: false

      # "How many leases does this project hold?" is asked before every step is claimed; with
      # the project on the attempt that needs no join against the run.
      add :project_id, :binary_id, null: false
      add :attempt, :integer, null: false
      add :execution_epoch, :integer, null: false
      add :lease_id, :binary_id, null: false
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :executor_id, :binary_id
      add :result_hash, :binary
      add :status, :text, null: false
      add :error, :map
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fyrlet_run_attempts, [:step_id, :attempt])

    # Store.leased_attempts/1 and abandon_leases/1 run on every step claim and run close.
    create index(:fyrlet_run_attempts, [:run_id],
             where: "status = 'leased'",
             name: :fyrlet_run_attempts_leased_run_index
           )

    create index(:fyrlet_run_attempts, [:lease_expires_at],
             where: "status = 'leased'",
             name: :fyrlet_run_attempts_leased_index
           )

    create index(:fyrlet_run_attempts, [:project_id, :lease_expires_at],
             where: "status = 'leased'",
             name: :fyrlet_run_attempts_project_leased_index
           )

    create table(:fyrlet_run_signals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:fyrlet_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :wait_id, :binary_id, null: false
      add :name, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :idempotency_key, :text, null: false
      add :input_hash, :binary, null: false
      add :status, :text, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
    end

    create unique_index(:fyrlet_run_signals, [:run_id, :idempotency_key])
    create index(:fyrlet_run_signals, [:run_id, :wait_id, :status])
    # Runs.check_signal_limits/2 counts recent signals per run on every signal.
    create index(:fyrlet_run_signals, [:run_id, :received_at])
    create index(:fyrlet_run_signals, [:received_at])

    create table(:fyrlet_run_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:fyrlet_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :step_id, :binary_id
      add :type, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :seq, :integer, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:fyrlet_run_events, [:run_id, :seq])

    # ---- effects ----------------------------------------------------------------------------

    create table(:fyrlet_effects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:fyrlet_runs, type: :binary_id, on_delete: :delete_all), null: false

      add :step_id, references(:fyrlet_run_steps, type: :binary_id, on_delete: :delete_all),
        null: false

      add :effect_key, :text, null: false
      # Stable per effect; sent to the receiver as its idempotency key on every retry.
      add :operation_id, :text, null: false
      add :adapter, :text, null: false
      add :adapter_version, :text, null: false
      add :delivery_policy, :text, null: false
      add :payload, :map, null: false
      add :payload_hash, :binary, null: false
      add :status, :text, null: false
      add :lease_id, :binary_id
      add :execution_epoch, :integer, null: false, default: 0
      add :lease_expires_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 5
      add :claimed_at, :utc_datetime_usec
      add :first_dispatched_at, :utc_datetime_usec
      add :next_attempt_at, :utc_datetime_usec
      add :secret_ref, :text
      add :external_ref, :text
      add :result, :map
      add :last_error, :map
      add :resolution_required, :boolean, null: false, default: false
      add :reconcile_attempts, :integer, null: false, default: 0
      add :event_seq, :integer, null: false, default: 0
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fyrlet_effects, [:step_id, :effect_key])
    create index(:fyrlet_effects, [:run_id])
    # Effects.over_rate?/2 counts claims per project within the last second on every dispatch.
    create index(:fyrlet_effects, [:project_id, :claimed_at], where: "claimed_at IS NOT NULL")

    create index(:fyrlet_effects, [:status, :next_attempt_at],
             where: "status IN ('pending','claimed','accepted','unknown')",
             name: :fyrlet_effects_open_index
           )

    create index(:fyrlet_effects, [:adapter, :external_ref], where: "external_ref IS NOT NULL")

    # Attempts and decisions are an append-only record: nothing here is ever rewritten.
    create table(:fyrlet_effect_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :effect_id, references(:fyrlet_effects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :seq, :integer, null: false
      add :type, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :receipt_id, :text
      add :at, :utc_datetime_usec, null: false
    end

    create unique_index(:fyrlet_effect_events, [:effect_id, :seq])

    create unique_index(:fyrlet_effect_events, [:effect_id, :receipt_id],
             where: "receipt_id IS NOT NULL",
             name: :fyrlet_effect_events_receipt_index
           )

    # ---- external executors -----------------------------------------------------------------

    create table(:fyrlet_executors, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :token_hash, :binary, null: false
      add :queues, {:array, :text}, null: false, default: []
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fyrlet_executors, [:token_hash])
    create index(:fyrlet_executors, [:project_id])

    # ---- batch ingest -----------------------------------------------------------------------

    create table(:fyrlet_ingest_batches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, :binary_id, null: false
      add :operation, :text, null: false
      add :atomic, :boolean, null: false, default: false
      add :total, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:fyrlet_ingest_batches, [:project_id, :subject_id, :inserted_at])

    create table(:fyrlet_ingest_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :batch_id, references(:fyrlet_ingest_batches, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_id, :binary_id, null: false
      add :operation, :text, null: false
      add :seq, :integer, null: false
      add :item_key, :text, null: false
      add :payload_hash, :binary, null: false
      add :payload, :map, null: false
      add :status, :text, null: false
      add :attempts, :integer, null: false, default: 0
      add :error, :map
      add :processed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # One key, one item: this is what makes a resent batch harmless.
    create unique_index(:fyrlet_ingest_items, [:project_id, :subject_id, :operation, :item_key])
    create index(:fyrlet_ingest_items, [:batch_id, :seq])

    create index(:fyrlet_ingest_items, [:project_id, :inserted_at],
             where: "status = 'pending'",
             name: :fyrlet_ingest_pending_index
           )

    # Finished items by age: what the retention pass scans.
    create index(:fyrlet_ingest_items, [:processed_at],
             where: "status <> 'pending'",
             name: :fyrlet_ingest_finished_index
           )

    # ---- streams ----------------------------------------------------------------------------

    # One row per stream. `head` is the last assigned position; appenders lock this row until
    # they commit, so positions become visible in order and never with a hole. `epoch` changes
    # when a stream is rewritten, which invalidates every cursor taken before.
    create table(:fyrlet_streams, primary_key: false) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :name, :text, null: false, primary_key: true
      add :head, :bigint, null: false, default: 0
      add :trimmed_before, :bigint, null: false, default: 1
      add :epoch, :text, null: false, default: "0"
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:fyrlet_stream_entries, primary_key: false) do
      add :project_id, :binary_id, null: false, primary_key: true
      add :stream, :text, null: false, primary_key: true
      add :pos, :bigint, null: false, primary_key: true
      add :data, :map, null: false
      add :bytes, :integer, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    for table_name <- [
          :fyrlet_stream_entries,
          :fyrlet_streams,
          :fyrlet_ingest_items,
          :fyrlet_ingest_batches,
          :fyrlet_executors,
          :fyrlet_effect_events,
          :fyrlet_effects,
          :fyrlet_run_events,
          :fyrlet_run_signals,
          :fyrlet_run_attempts,
          :fyrlet_run_steps,
          :fyrlet_runs,
          :fyrlet_execution_grants,
          :idempotency_results,
          :sessions,
          :subjects,
          :service_keys,
          :projects
        ] do
      drop table(table_name)
    end

    Oban.Migration.down()
  end
end
