defmodule Fyrlet.SchemaDifferentialTest do
  @moduledoc """
  `Fyrlet.Schema.validate/2` was rewritten for speed. The rewrite must be indistinguishable:
  for random schemas and random values - valid, invalid and hostile - it must return exactly
  what the original did, including the normalised value and every error path and message.
  """
  use ExUnit.Case, async: true
  alias Fyrlet.{Schema, SchemaReference}

  @cases 6_000

  # ---- the reference returns {:error, {:validation_failed, errors}}; Schema wraps in Error --
  defp same?(schema, value) do
    expected = SchemaReference.validate(schema, value)

    case {Schema.validate(schema, value), expected} do
      {{:ok, a}, {:ok, b}} -> a === b
      {{:error, %{details: %{"fields" => a}}}, {:error, {:validation_failed, b}}} -> a == b
      _different -> false
    end
  end

  # ---- generators (seeded, so a failure is reproducible) ---------------------------------
  defp pick(list), do: Enum.random(list)

  defp scalar_schema(depth) do
    case :rand.uniform(7) do
      1 ->
        base = %{"type" => "string"}

        base
        |> maybe("minLength", pick([0, 1, 3, 10]))
        |> maybe("maxLength", pick([0, 2, 5, 40, 1_000]))
        |> maybe("format", pick(["uuid", "date-time"]))
        |> maybe("enum", pick([["a", "b"], ["héllo", "x"]]))

      2 ->
        %{"type" => "integer"}
        |> maybe("minimum", pick([-5, 0, 3]))
        |> maybe("maximum", pick([0, 10, 100]))

      3 ->
        %{"type" => "boolean"}

      4 ->
        %{"type" => "null"}

      5 ->
        %{"anyOf" => [scalar_schema(depth), scalar_schema(depth)]}

      6 when depth > 0 ->
        %{
          "type" => "array",
          "items" => scalar_schema(depth - 1),
          "maxItems" => pick([0, 1, 3, 100])
        }

      _ ->
        %{"type" => "string"}
    end
  end

  defp maybe(map, key, value),
    do: if(:rand.uniform(2) == 1, do: Map.put(map, key, value), else: map)

  defp schema(depth) when depth > 0 do
    if :rand.uniform(3) == 1 do
      names = Enum.take_random(~w(a b c d e), :rand.uniform(4))

      properties =
        Map.new(names, fn name ->
          property = schema(depth - 1)

          {name,
           if(:rand.uniform(4) == 1 and is_map_key(property, "type"),
             do: default_for(property),
             else: property
           )}
        end)

      required = Enum.filter(names, fn _ -> :rand.uniform(2) == 1 end)
      object = %{"type" => "object", "properties" => properties, "required" => required}
      if :rand.uniform(5) == 1, do: object, else: Map.put(object, "additionalProperties", false)
    else
      scalar_schema(depth)
    end
  end

  defp schema(_depth), do: scalar_schema(0)

  defp default_for(%{"type" => "string"} = s), do: Map.put(s, "default", pick(["a", "zzz", ""]))
  defp default_for(%{"type" => "integer"} = s), do: Map.put(s, "default", pick([0, 7, 1_000]))
  defp default_for(%{"type" => "boolean"} = s), do: Map.put(s, "default", pick([true, false]))
  defp default_for(%{"type" => "object"} = s), do: s
  defp default_for(s), do: s

  @timestamps [
    "2026-11-07T05:43:36.320000Z",
    "2026-11-07T05:43:36Z",
    "2026-02-29T00:00:00Z",
    "2024-02-29T23:59:59.9Z",
    "2026-13-01T00:00:00Z",
    "2026-00-10T00:00:00Z",
    "2026-11-31T00:00:00Z",
    "2026-11-07T24:00:00Z",
    "2026-11-07T23:60:00Z",
    "2026-11-07T23:59:60Z",
    "2026-11-07T05:43:36+02:00",
    "2026-11-07T05:43:36.1234567Z",
    "2026-11-07T05:43:36.Z",
    "2026-11-07 05:43:36Z",
    "2026-11-07t05:43:36z",
    "0000-01-01T00:00:00Z",
    "0001-01-01T00:00:00Z",
    "9999-12-31T23:59:59.999999Z",
    "20261107T054336Z",
    "+2026-11-07T05:43:36Z",
    "2026-1-7T5:43:36Z",
    "",
    "Z",
    "garbage"
  ]

  defp value_for(schema, depth) do
    if :rand.uniform(6) == 1, do: hostile(), else: conforming(schema, depth)
  end

  defp hostile,
    do:
      pick([
        nil,
        true,
        false,
        0,
        -1,
        1.5,
        "",
        "x",
        "héllo",
        String.duplicate("é", 6),
        [],
        %{},
        [1, "a", nil],
        %{"a" => 1},
        :atom
      ])

  defp conforming(%{"anyOf" => options}, depth), do: conforming(pick(options), depth)

  defp conforming(%{"type" => "string"} = s, _depth) do
    cond do
      s["format"] == "uuid" ->
        pick([Ecto.UUID.generate(), "not-a-uuid", String.upcase(Ecto.UUID.generate())])

      s["format"] == "date-time" ->
        pick(@timestamps)

      is_list(s["enum"]) ->
        pick(s["enum"] ++ ["other"])

      true ->
        pick([
          "",
          "a",
          "ab",
          "abcdef",
          "héllo",
          String.duplicate("é", 7),
          String.duplicate("x", 50),
          "éé"
        ])
    end
  end

  defp conforming(%{"type" => "integer"}, _depth), do: pick([-10, -5, 0, 3, 10, 100, 101, 1.0])
  defp conforming(%{"type" => "boolean"}, _depth), do: pick([true, false, "true"])
  defp conforming(%{"type" => "null"}, _depth), do: pick([nil, nil, false])

  defp conforming(%{"type" => "array", "items" => items}, depth),
    do: for(_ <- List.duplicate(nil, pick([0, 1, 2, 4])), do: value_for(items, depth - 1))

  defp conforming(%{"type" => "object", "properties" => properties}, depth) do
    present =
      for {name, property} <- properties,
          :rand.uniform(4) != 1,
          into: %{},
          do: {name, value_for(property, depth - 1)}

    # Unknown keys, including a non-string one.
    present =
      if :rand.uniform(5) == 1, do: Map.put(present, pick(["zz", :atom_key]), 1), else: present

    present
  end

  test "random schemas and values behave exactly as the original validator" do
    :rand.seed(:exsss, {101, 202, 303})

    for n <- 1..@cases do
      schema = schema(3)
      value = value_for(schema, 3)

      assert same?(schema, value),
             "case #{n} differs\nschema: #{inspect(schema, limit: :infinity)}\nvalue: #{inspect(value, limit: :infinity)}\n" <>
               "old: #{inspect(SchemaReference.validate(schema, value), limit: :infinity)}\nnew: #{inspect(Schema.validate(schema, value), limit: :infinity)}"
    end
  end

  test "every schema in the registered contracts validates a real value the same way" do
    for kind <- ["operations", "subscriptions"],
        {_name, spec} <- Fyrlet.Registry.export()[kind],
        key <- ["input", "output"] do
      assert same?(spec[key], %{})
      assert same?(spec[key], [])
      assert same?(spec[key], nil)
    end
  end

  describe "the timestamp fast path" do
    test "agrees with the standard parser on every listed form" do
      schema = %{"type" => "string", "format" => "date-time"}

      for stamp <- @timestamps do
        assert match?({:ok, _}, Schema.validate(schema, stamp)) ==
                 match?({:ok, _, _}, DateTime.from_iso8601(stamp)),
               inspect(stamp)
      end
    end

    test "agrees with the standard parser on randomly mutated timestamps" do
      :rand.seed(:exsss, {7, 8, 9})
      schema = %{"type" => "string", "format" => "date-time"}
      alphabet = ~c"0123456789-:TZ.+ t"

      for _ <- 1..20_000 do
        base = pick(@timestamps)
        position = :rand.uniform(max(byte_size(base), 1)) - 1

        mutated =
          case :rand.uniform(3) do
            1 ->
              binary_part(base, 0, position) <>
                <<pick(alphabet)>> <>
                binary_part(
                  base,
                  min(position + 1, byte_size(base)),
                  byte_size(base) - min(position + 1, byte_size(base))
                )

            2 ->
              binary_part(base, 0, position)

            _ ->
              base <> <<pick(alphabet)>>
          end

        expected = match?({:ok, _, _}, DateTime.from_iso8601(mutated))
        assert match?({:ok, _}, Schema.validate(schema, mutated)) == expected, inspect(mutated)
      end
    end
  end
end
