defmodule Fyrlet.Scope do
  @moduledoc """
  Managed data access (temp spec §6.2).

  A definition declares who may see and change which rows with `data_scope/3`:

      def data_scope(_action, _actor, _input), do: {:ok, project: :project_id, subject: :subject_id}

  Options: `:project` (field holding the project, required), `:subject` (field holding the
  owner, optional) and `:members` (`{field, ids}`, restricts to rows whose field is one of
  `ids`). Returning `:unsupported` - or having no callback - makes every managed call refuse.

  What is guaranteed, and what is not:

    * Queries and writes made **through this module** always carry the project (and subject)
      constraint, built from the trusted actor and not from the input.
    * A query shape this module cannot verify (joins, fragments, subqueries, unions, CTEs) is
      refused, never run unfiltered.
    * Code that calls `Fyrlet.Repo` directly is not covered. This is a tool that prevents
      forgotten filters, not a sandbox, and not database row-level security.
  """
  import Ecto.Query
  alias Fyrlet.Repo

  defmodule Violation do
    defexception [:message]
  end

  @doc "Adds the policy's constraints to `query`. Returns `{:ok, query}` or `{:error, %Violation{}}`."
  def apply(%Ecto.Query{} = query, actor, module, action, input) when action in [:read, :write] do
    with {:ok, policy} <- policy(module, action, actor, input),
         :ok <- supported_shape(query),
         {:ok, schema} <- schema(query),
         :ok <- fields_exist(schema, policy) do
      {:ok, constrain(query, actor, policy)}
    end
  end

  def apply(queryable, actor, module, action, input) when not is_struct(queryable, Ecto.Query),
    do: __MODULE__.apply(from(queryable), actor, module, action, input)

  @doc "Like `apply/5`, raising `Fyrlet.Scope.Violation`."
  def apply!(query, actor, module, action, input) do
    case __MODULE__.apply(query, actor, module, action, input) do
      {:ok, scoped} -> scoped
      {:error, violation} -> raise violation
    end
  end

  # ---- managed repo functions ---------------------------------------------------------

  def all(query, actor, module, input),
    do: query |> apply!(actor, module, :read, input) |> Repo.all()

  def one(query, actor, module, input),
    do: query |> apply!(actor, module, :read, input) |> Repo.one()

  def update_all(query, updates, actor, module, input) do
    {:ok, policy} = policy(module, :write, actor, input)
    forbid_ownership_updates!(updates, policy)
    query |> apply!(actor, module, :write, input) |> Repo.update_all(updates)
  end

  def delete_all(query, actor, module, input),
    do: query |> apply!(actor, module, :write, input) |> Repo.delete_all()

  @doc "Inserts a struct after stamping its ownership fields from the trusted actor."
  def insert!(%{__struct__: _} = struct, actor, module, input) do
    struct |> stamp!(actor, module, input) |> Repo.insert!()
  end

  @doc "Sets the project (and subject) from the actor, overriding whatever the struct held."
  def stamp!(%{__struct__: _} = struct, actor, module, input) do
    case policy(module, :write, actor, input) do
      {:ok, policy} ->
        struct = Map.put(struct, policy.project, actor.project_id)
        if policy.subject, do: Map.put(struct, policy.subject, actor.subject_id), else: struct

      {:error, violation} ->
        raise violation
    end
  end

  # ---- internals ----------------------------------------------------------------------

  defp policy(module, action, actor, input) do
    Code.ensure_loaded(module)

    if function_exported?(module, :data_scope, 3) do
      case module.data_scope(action, actor, input) do
        {:ok, options} when is_list(options) -> normalise(options)
        :unsupported -> violation("#{inspect(module)} does not support managed #{action}s")
        _other -> violation("data_scope/3 must return {:ok, options} or :unsupported")
      end
    else
      violation("#{inspect(module)} defines no data_scope/3")
    end
  end

  defp normalise(options) do
    case Keyword.get(options, :project) do
      project when is_atom(project) and not is_nil(project) ->
        {:ok,
         %{
           project: project,
           subject: Keyword.get(options, :subject),
           members: Keyword.get(options, :members)
         }}

      _other ->
        violation("data_scope/3 must name the project field")
    end
  end

  defp supported_shape(%Ecto.Query{} = query) do
    cond do
      query.joins != [] ->
        violation("Joins are not supported by managed access")

      query.combinations != [] ->
        violation("Combined queries are not supported by managed access")

      query.with_ctes != nil ->
        violation("CTEs are not supported by managed access")

      query.windows != [] ->
        violation("Window clauses are not supported by managed access")

      has_unverifiable?(query) ->
        violation("Fragments and subqueries are not supported by managed access")

      true ->
        :ok
    end
  end

  defp has_unverifiable?(query) do
    parts = [
      query.wheres,
      query.havings,
      query.order_bys,
      query.group_bys,
      query.distinct,
      query.select,
      query.updates
    ]

    parts |> List.flatten() |> Enum.any?(&unverifiable?/1)
  end

  defp unverifiable?(%{expr: expr}), do: unverifiable?(expr)
  defp unverifiable?({:fragment, _, _}), do: true
  defp unverifiable?({:subquery, _}), do: true
  defp unverifiable?(%Ecto.SubQuery{}), do: true
  defp unverifiable?(%Ecto.Query{}), do: true

  defp unverifiable?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&unverifiable?/1)

  defp unverifiable?(list) when is_list(list), do: Enum.any?(list, &unverifiable?/1)

  defp unverifiable?(map) when is_map(map) and not is_struct(map),
    do: map |> Map.values() |> Enum.any?(&unverifiable?/1)

  defp unverifiable?(_other), do: false

  defp schema(%Ecto.Query{from: %{source: {_table, schema}}})
       when is_atom(schema) and not is_nil(schema),
       do: {:ok, schema}

  defp schema(_query), do: violation("Managed access needs a query over a schema")

  defp fields_exist(schema, policy) do
    fields = schema.__schema__(:fields)

    needed =
      Enum.reject(
        [policy.project, policy.subject, policy.members && elem(policy.members, 0)],
        &is_nil/1
      )

    case Enum.reject(needed, &(&1 in fields)) do
      [] ->
        :ok

      missing ->
        violation("#{inspect(schema)} has no field(s) #{inspect(missing)} named by the policy")
    end
  end

  defp constrain(query, actor, policy) do
    query = where(query, [q], field(q, ^policy.project) == ^actor.project_id)

    query =
      if policy.subject,
        do: where(query, [q], field(q, ^policy.subject) == ^actor.subject_id),
        else: query

    case policy.members do
      {field, ids} when is_list(ids) -> where(query, [q], field(q, ^field) in ^ids)
      _none -> query
    end
  end

  defp forbid_ownership_updates!(updates, policy) do
    owned = Enum.reject([policy.project, policy.subject], &is_nil/1)
    touched = updates |> Enum.flat_map(fn {_op, fields} -> Keyword.keys(List.wrap(fields)) end)

    if Enum.any?(touched, &(&1 in owned)),
      do: raise(Violation, "Ownership fields cannot be updated through managed access")
  end

  defp violation(message), do: {:error, %Violation{message: message}}
end
