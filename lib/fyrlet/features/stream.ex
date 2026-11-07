defmodule Fyrlet.Features.Stream do
  @moduledoc """
  Append-only streams behind `mode: "append"` subscriptions.

  A stream is a named, ordered log of JSON objects inside one project. Items are only ever
  appended; a correction or deletion is a `reset/2`, which gives the stream a new epoch so
  that every cursor taken earlier is refused and subscribers fall back to a fresh snapshot.

  ## Why positions have no holes

  `append/3` takes positions from a counter on the stream's own row and holds that row's lock
  until the caller's transaction commits. Two appenders to one stream therefore commit in the
  order they took positions, and a rolled-back append gives its positions back. A reader that
  sees `head = H` is guaranteed that every entry up to `H` is committed. Source IDs, timestamps
  or commit order are never compared: the position is the only thing a cursor means.

  ## Cursors

  A cursor is an opaque string. Clients may only store it and compare it for equality.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Error, Repo}

  defmodule Head do
    use Ecto.Schema
    @primary_key false
    @foreign_key_type :binary_id
    schema "fyrlet_streams" do
      field(:project_id, :binary_id, primary_key: true)
      field(:name, :string, primary_key: true)
      field(:head, :integer, default: 0)
      field(:trimmed_before, :integer, default: 1)
      field(:epoch, :string, default: "0")
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule Entry do
    use Ecto.Schema
    @primary_key false
    schema "fyrlet_stream_entries" do
      field(:project_id, :binary_id, primary_key: true)
      field(:stream, :string, primary_key: true)
      field(:pos, :integer, primary_key: true)
      field(:data, :map)
      field(:bytes, :integer)
      field(:inserted_at, :utc_datetime_usec)
    end
  end

  @name ~r/\A[a-z0-9][a-z0-9_.:-]{0,127}\z/
  @max_items_per_append 100
  @max_item_bytes 16_384

  @doc "Bounds used by readers; override with `config :fyrlet, :streams`."
  def limit(key) do
    defaults = [
      batch_items: 100,
      batch_bytes: 262_144,
      retention_items: 10_000,
      # Unacknowledged data a subscriber may be ahead by before it is reset to a snapshot.
      window_batches: 200,
      window_bytes: 262_144,
      # How long a batch read for one subscriber is reused for the others of the same stream.
      shared_read_ttl_ms: 1_000
    ]

    :fyrlet
    |> Application.get_env(:streams, [])
    |> Keyword.get(key, Keyword.fetch!(defaults, key))
  end

  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  # ---- writing ---------------------------------------------------------------------------

  @doc """
  Appends items to a stream. Must run inside the transaction that records the business
  change (an operation's `execute/3` already does), because the position lock is only worth
  anything while that transaction is open. Returns the cursor after the last item.

  Items must be maps that encode to at most #{@max_item_bytes} bytes; at most
  #{@max_items_per_append} per call.
  """
  def append(project_id, name, items) when is_list(items) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Fyrlet.Features.Stream.append/3 must run inside a transaction")

    with :ok <- valid_stream?(name),
         {:ok, encoded} <- encode(items) do
      count = length(encoded)
      now = Auth.now()

      {1, [%Head{head: head, epoch: epoch}]} =
        Repo.insert_all(
          Head,
          [%{project_id: project_id, name: name, head: count, updated_at: now}],
          on_conflict: [inc: [head: count], set: [updated_at: now]],
          conflict_target: [:project_id, :name],
          returning: [:head, :epoch]
        )

      first = head - count + 1

      rows =
        for {{data, bytes}, offset} <- Enum.with_index(encoded) do
          %{
            project_id: project_id,
            stream: name,
            pos: first + offset,
            data: data,
            bytes: bytes,
            inserted_at: now
          }
        end

      {^count, _} = Repo.insert_all(Entry, rows)
      {:ok, cursor(epoch, head)}
    end
  end

  @doc """
  Starts the stream over: every entry is deleted and the epoch changes, so no earlier cursor
  is valid any more. Use it when published items are corrected or removed.
  """
  def reset(project_id, name) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Fyrlet.Features.Stream.reset/2 must run inside a transaction")

    with :ok <- valid_stream?(name) do
      epoch = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

      Repo.insert_all(
        Head,
        [%{project_id: project_id, name: name, head: 0, epoch: epoch, updated_at: Auth.now()}],
        on_conflict: {:replace, [:head, :trimmed_before, :epoch, :updated_at]},
        conflict_target: [:project_id, :name]
      )

      Repo.delete_all(from(e in Entry, where: e.project_id == ^project_id and e.stream == ^name))
      Fyrlet.Features.Stream.Reader.drop(project_id, name)
      {:ok, cursor(epoch, 0)}
    end
  end

  defp valid_stream?(name) do
    if valid_name?(name),
      do: :ok,
      else: {:error, Error.new("VALIDATION_FAILED", "Invalid stream name")}
  end

  defp encode([]), do: {:error, Error.new("VALIDATION_FAILED", "Nothing to append")}

  defp encode(items) when length(items) > @max_items_per_append,
    do: {:error, Error.new("LIMIT_EXCEEDED", "Too many items in one append")}

  defp encode(items) do
    Enum.reduce_while(items, {:ok, []}, fn
      item, {:ok, acc} when is_map(item) and not is_struct(item) ->
        case Jason.encode(item) do
          {:ok, json} when byte_size(json) <= @max_item_bytes ->
            {:cont, {:ok, [{item, byte_size(json)} | acc]}}

          _too_large_or_invalid ->
            {:halt, {:error, Error.new("VALIDATION_FAILED", "An item is invalid or too large")}}
        end

      _item, _acc ->
        {:halt, {:error, Error.new("VALIDATION_FAILED", "Items must be JSON objects")}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # ---- reading ---------------------------------------------------------------------------

  @doc """
  The newest `max_items` items and the cursor they end at, read consistently: the head is read
  first, and nothing above it is considered.
  """
  def snapshot(project_id, name, max_items) when max_items > 0 do
    {epoch, head, floor} = head(project_id, name)
    from_position = max(head - max_items, floor - 1)

    case entries(project_id, name, from_position, head) do
      rows when length(rows) == head - from_position ->
        {:ok, %{cursor: cursor(epoch, head), items: Enum.map(rows, & &1.data)}}

      _missing ->
        {:error, Error.new("INTERNAL_ERROR", "The stream is inconsistent", %{}, true)}
    end
  end

  @doc """
  Everything appended after `cursor`, as one bounded batch.

    * `{:ok, from_cursor, to_cursor, items}` - a batch that continues exactly at `cursor`;
    * `:none` - nothing new;
    * `:reset` - the cursor cannot be continued from: other epoch, a position the stream never
      reached, or history that was trimmed away. The caller must send a fresh snapshot.
  """
  def after_cursor(project_id, name, cursor, options \\ []) do
    case read_after(project_id, name, cursor, options) do
      {:ok, from, to, items, _more?} -> {:ok, from, to, items}
      other -> other
    end
  end

  @doc """
  Like `after_cursor/4`, but for many readers of one stream (the subscribers of a room): the
  batch that continues at a cursor is the same for all of them and never changes once
  written, so it is read from the database once and shared for a moment. Returns
  `{:ok, from_cursor, to_cursor, %{json: encoded_items, count: n}, more?}` (the items are
  encoded once, for everyone); `more?` is false when the batch reached the
  head that was read, so the caller needs no confirming read - the next append announces
  itself with its own notification.

  Only batches are shared. `:none` and `:reset` are never cached: a stale `:none` would hide
  an append that was just announced.
  """
  def after_cursor_shared(project_id, name, cursor, options \\ []) do
    Fyrlet.Features.Stream.Reader.batch(project_id, name, cursor, options, fn ->
      case read_after(project_id, name, cursor, options) do
        {:ok, from, to, items, more?} ->
          {:ok, from, to, %{json: Jason.encode!(items), count: length(items)}, more?}

        other ->
          other
      end
    end)
  end

  @doc false
  def read_after(project_id, name, cursor, options) do
    with {:ok, {epoch, position}} <- parse(cursor),
         {current, head, floor} = head(project_id, name),
         true <- epoch == current and position <= head and position >= floor - 1 do
      if position == head do
        :none
      else
        read_batch(project_id, name, epoch, position, head, options)
      end
    else
      _cannot_continue -> :reset
    end
  end

  defp read_batch(project_id, name, epoch, position, head, options) do
    batch_items = Keyword.get(options, :items, limit(:batch_items))
    batch_bytes = Keyword.get(options, :bytes, limit(:batch_bytes))
    upper = min(head, position + batch_items)

    rows = entries(project_id, name, position, upper)
    rows = take_within(rows, batch_bytes)

    if rows != [] and
         Enum.map(rows, & &1.pos) == Enum.to_list((position + 1)..(position + length(rows))) do
      {:ok, cursor(epoch, position), cursor(epoch, position + length(rows)),
       Enum.map(rows, & &1.data), position + length(rows) < head}
    else
      :reset
    end
  end

  # At least one item, then as many as fit.
  defp take_within([first | rest], limit) do
    {taken, _bytes} =
      Enum.reduce_while(rest, {[first], first.bytes}, fn row, {acc, bytes} ->
        if bytes + row.bytes <= limit,
          do: {:cont, {[row | acc], bytes + row.bytes}},
          else: {:halt, {acc, bytes}}
      end)

    Enum.reverse(taken)
  end

  defp take_within([], _limit), do: []

  defp entries(project_id, name, after_position, up_to) do
    Repo.all(
      from(e in Entry,
        where:
          e.project_id == ^project_id and e.stream == ^name and e.pos > ^after_position and
            e.pos <= ^up_to,
        order_by: [asc: e.pos],
        select: %{pos: e.pos, data: e.data, bytes: e.bytes}
      )
    )
  end

  # A stream nobody has appended to yet is epoch "0", head 0: the same state it will be in
  # when its row is created, so a subscriber of an empty stream continues with a delta.
  defp head(project_id, name) do
    case Repo.get_by(Head, project_id: project_id, name: name) do
      nil -> {"0", 0, 1}
      %Head{epoch: epoch, head: head, trimmed_before: floor} -> {epoch, head, floor}
    end
  end

  # ---- retention -------------------------------------------------------------------------

  @doc """
  Drops all but the newest `keep` entries of streams that hold more. Cursors that point into
  the dropped part are refused (`:reset`), never silently continued. Returns the number of
  streams trimmed. Called by the prune job.
  """
  def prune(keep \\ limit(:retention_items), batch \\ 100) do
    candidates =
      Repo.all(
        from(h in Head,
          where: h.head - h.trimmed_before + 1 > ^keep,
          order_by: [asc: h.updated_at],
          limit: ^batch,
          select: {h.project_id, h.name}
        )
      )

    Enum.count(candidates, fn {project_id, name} -> trim(project_id, name, keep) end)
  end

  defp trim(project_id, name, keep) do
    {:ok, trimmed?} =
      Repo.transaction(fn ->
        head =
          Repo.one(
            from(h in Head,
              where: h.project_id == ^project_id and h.name == ^name,
              lock: "FOR UPDATE"
            )
          )

        new_floor = head && max(head.head - keep + 1, head.trimmed_before)

        if head && new_floor > head.trimmed_before do
          Repo.delete_all(
            from(e in Entry,
              where: e.project_id == ^project_id and e.stream == ^name and e.pos < ^new_floor
            )
          )

          Repo.update_all(
            from(h in Head, where: h.project_id == ^project_id and h.name == ^name),
            set: [trimmed_before: new_floor]
          )

          Fyrlet.Features.Stream.Reader.drop(project_id, name)

          true
        else
          false
        end
      end)

    trimmed?
  end

  # ---- cursors ---------------------------------------------------------------------------

  @doc false
  def cursor(epoch, position), do: "#{epoch}:#{position}"

  defp parse(cursor) when is_binary(cursor) and byte_size(cursor) < 100 do
    with [epoch, position] <- String.split(cursor, ":", parts: 2),
         {position, ""} when position >= 0 <- Integer.parse(position),
         true <- epoch != "" do
      {:ok, {epoch, position}}
    else
      _invalid -> :error
    end
  end

  defp parse(_cursor), do: :error
end
