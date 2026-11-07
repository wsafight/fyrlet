defmodule Fyrlet.Transaction do
  @moduledoc """
  Composes managed Fyrlet calls and host writes in one transaction. The callback's value
  is returned directly; `Fyrlet.Repo.rollback(reason)` returns `{:error, reason}`.
  Nested calls join the outer transaction. Run notifications and telemetry are published
  only after that transaction commits. Use this as the outer boundary instead of wrapping
  it in a separate `Repo.transaction/1`.
  """
  alias Fyrlet.{AfterCommit, Repo}
  @owner :fyrlet_transaction_owner

  def run(callback) when is_function(callback, 0) do
    if Process.get(@owner) do
      callback.()
    else
      Process.put(@owner, true)
      AfterCommit.reset()

      try do
        case Repo.transaction(callback) do
          {:ok, result} ->
            AfterCommit.flush()
            result

          {:error, reason} ->
            {:error, reason}
        end
      after
        Process.delete(@owner)
        AfterCommit.reset()
      end
    end
  end
end
