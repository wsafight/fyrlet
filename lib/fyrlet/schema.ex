defmodule Fyrlet.Schema do
  alias Fyrlet.Error

  @doc """
  Validates `value` against `schema` and returns it with defaults applied.

  This runs on every operation call and every subscription refresh, so the success path is the
  one that matters: it allocates nothing that only an error needs. Paths are kept as a reversed
  list of segments (a cons per level) and rendered to "$.a[0].b" only when a problem is
  reported; strings are not grapheme-counted unless a bound could actually be violated; maps
  are rebuilt only for the entries that changed.
  """
  def validate(schema, value) do
    case check(schema, value, [], %{}) do
      {normalized, errors} when map_size(errors) == 0 ->
        {:ok, normalized}

      {_normalized, errors} ->
        {:error,
         Error.new("VALIDATION_FAILED", "The value does not match the contract", %{
           "fields" => errors
         })}
    end
  end

  def object(properties, required \\ []) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  def validate_definition!(%{"anyOf" => _options, "type" => _type}),
    do: raise(ArgumentError, "Ambiguous schema type")

  def validate_definition!(%{"anyOf" => options} = schema)
      when is_list(options) and options != [] do
    Enum.each(options, &validate_definition!/1)
    validate_default!(schema)
  end

  def validate_definition!(
        %{"type" => "object", "properties" => properties, "additionalProperties" => false} =
          schema
      )
      when is_map(properties) do
    required = Map.get(schema, "required", [])

    unless is_list(required) and Enum.all?(required, &Map.has_key?(properties, &1)),
      do: raise(ArgumentError, "Invalid required fields")

    Enum.each(properties, fn {name, property} ->
      unless is_binary(name), do: raise(ArgumentError, "Property names must be strings")
      validate_definition!(property)
    end)

    validate_default!(schema)
  end

  def validate_definition!(%{"type" => "array", "items" => items} = schema) do
    validate_definition!(items)
    validate_bound!(schema, "maxItems", 100)

    if Map.get(schema, "maxItems", 100) > 100,
      do: raise(ArgumentError, "Array bounds cannot exceed 100 items")

    validate_default!(schema)
  end

  def validate_definition!(%{"type" => "string"} = schema) do
    validate_bound!(schema, "minLength", 0)
    validate_bound!(schema, "maxLength", 1_000_000)

    if Map.get(schema, "minLength", 0) > Map.get(schema, "maxLength", 1_000_000),
      do: raise(ArgumentError, "Invalid string bounds")

    if schema["format"] not in [nil, "uuid", "date-time"],
      do: raise(ArgumentError, "Unsupported string format")

    if Map.has_key?(schema, "enum") do
      unless is_list(schema["enum"]) and schema["enum"] != [] and
               Enum.all?(schema["enum"], &is_binary/1),
             do: raise(ArgumentError, "Invalid string enum")
    end

    validate_default!(schema)
  end

  def validate_definition!(%{"type" => "integer"} = schema) do
    minimum = Map.get(schema, "minimum", -9_007_199_254_740_991)
    maximum = Map.get(schema, "maximum", 9_007_199_254_740_991)

    unless is_integer(minimum) and is_integer(maximum) and minimum <= maximum and
             minimum >= -9_007_199_254_740_991 and maximum <= 9_007_199_254_740_991,
           do: raise(ArgumentError, "Invalid safe integer bounds")

    validate_default!(schema)
  end

  def validate_definition!(%{"type" => type} = schema) when type in ["boolean", "null"],
    do: validate_default!(schema)

  def validate_definition!(_schema), do: raise(ArgumentError, "Unsupported contract schema")

  defp validate_bound!(schema, name, fallback) do
    value = Map.get(schema, name, fallback)
    unless is_integer(value) and value >= 0, do: raise(ArgumentError, "Invalid #{name}")
  end

  defp validate_default!(schema) do
    allowed =
      case schema["type"] do
        "object" -> ["type", "properties", "required", "additionalProperties", "default"]
        "string" -> ["type", "minLength", "maxLength", "enum", "format", "default"]
        "integer" -> ["type", "minimum", "maximum", "default"]
        "array" -> ["type", "items", "maxItems", "default"]
        nil -> ["anyOf", "default"]
        _type -> ["type", "default"]
      end

    unless Enum.all?(Map.keys(schema), &(&1 in allowed)),
      do: raise(ArgumentError, "Unsupported schema keyword")

    if Map.has_key?(schema, "default") and
         not match?({:ok, _value}, validate(schema, schema["default"])),
       do: raise(ArgumentError, "Invalid schema default")

    :ok
  end

  # ---- checking -------------------------------------------------------------------------

  defp check(%{"type" => "object"} = schema, value, path, errors) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    normalized = with_defaults(properties, value)

    errors =
      case schema do
        %{"required" => required} -> missing(required, normalized, path, errors)
        _no_required -> errors
      end

    forbid? = Map.get(schema, "additionalProperties") == false

    :maps.fold(
      fn name, entry, {result, problems} ->
        case properties do
          %{^name => property} ->
            {checked, next} = check(property, entry, [name | path], problems)
            # Nested defaults are the only thing that can change an entry.
            {if(checked === entry, do: result, else: Map.put(result, name, checked)), next}

          _unknown when forbid? ->
            {result, Map.put(problems, render([name | path]), "is not allowed")}

          _unknown ->
            {result, problems}
        end
      end,
      {normalized, errors},
      normalized
    )
  end

  defp check(%{"type" => "string"} = schema, value, path, errors) when is_binary(value),
    do: {value, check_string(schema, value, path, errors)}

  defp check(%{"type" => "integer"} = schema, value, path, errors) when is_integer(value) do
    if value >= Map.get(schema, "minimum", -9_007_199_254_740_991) and
         value <= Map.get(schema, "maximum", 9_007_199_254_740_991),
       do: {value, errors},
       else: {value, Map.put(errors, render(path), "is outside the allowed range")}
  end

  defp check(%{"type" => "boolean"}, value, _path, errors) when is_boolean(value),
    do: {value, errors}

  defp check(%{"type" => "null"}, nil, _path, errors), do: {nil, errors}

  defp check(%{"type" => "array"} = schema, value, path, errors) when is_list(value) do
    errors =
      if length(value) > Map.get(schema, "maxItems", 100),
        do: Map.put(errors, render(path), "contains too many entries"),
        else: errors

    check_items(value, Map.get(schema, "items"), 0, path, errors, [])
  end

  defp check(%{"anyOf" => options}, value, path, errors) do
    result =
      Enum.find_value(options, fn option ->
        case check(option, value, path, %{}) do
          {normalized, problems} when map_size(problems) == 0 -> {:ok, normalized}
          _invalid -> nil
        end
      end)

    case result do
      {:ok, normalized} -> {normalized, errors}
      nil -> {value, Map.put(errors, render(path), "does not match an allowed type")}
    end
  end

  defp check(_schema, value, path, errors),
    do: {value, Map.put(errors, render(path), "has an invalid type")}

  # Properties that declare a default and are absent from the value.
  defp with_defaults(properties, value) do
    :maps.fold(
      fn name, property, acc ->
        case property do
          %{"default" => default} when not is_map_key(acc, name) -> Map.put(acc, name, default)
          _no_default_or_present -> acc
        end
      end,
      value,
      properties
    )
  end

  defp missing([], _value, _path, errors), do: errors

  defp missing([name | rest], value, path, errors) do
    if is_map_key(value, name),
      do: missing(rest, value, path, errors),
      else: missing(rest, value, path, Map.put(errors, render([name | path]), "is required"))
  end

  defp check_items([], _items, _index, _path, errors, acc), do: {:lists.reverse(acc), errors}

  defp check_items([entry | rest], items, index, path, errors, acc) do
    {checked, errors} = check(items, entry, [index | path], errors)
    check_items(rest, items, index + 1, path, errors, [checked | acc])
  end

  # A string of N bytes has at most N graphemes. So it can only be too long if it has more
  # bytes than the maximum, and counting is only needed when a minimum is set. Counting is
  # what String.length/1 spends its time on, and most strings never need it.
  defp check_string(schema, value, path, errors) do
    size = byte_size(value)
    min = Map.get(schema, "minLength", 0)
    max = Map.get(schema, "maxLength", 1_000_000)

    # `schema["x"]` on a map is Access.get/2 -> Access.get/3: two remote calls per read, and a
    # string is checked for several keys. One Map.get each is a single call.
    format = Map.get(schema, "format")
    enum = Map.get(schema, "enum")

    cond do
      min > 0 and String.length(value) < min ->
        Map.put(errors, render(path), "is too short")

      size > max and String.length(value) > max ->
        Map.put(errors, render(path), "is too long")

      format == "uuid" and not valid_uuid?(value) ->
        Map.put(errors, render(path), "must be a UUID")

      format == "date-time" and not valid_datetime?(value) ->
        Map.put(errors, render(path), "must be an ISO 8601 timestamp")

      is_list(enum) and value not in enum ->
        Map.put(errors, render(path), "is not an allowed value")

      true ->
        errors
    end
  end

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  # The canonical form every Fyrlet timestamp has is checked by pattern matching. Anything
  # else (offsets, odd precisions, a year 0, ...) goes to DateTime.from_iso8601/1, which stays
  # the authority: the fast path only answers "yes" when that parser would too.
  defp valid_datetime?(
         <<year::binary-size(4), ?-, month::binary-size(2), ?-, day::binary-size(2), ?T,
           hour::binary-size(2), ?:, minute::binary-size(2), ?:, second::binary-size(2),
           rest::binary>> = value
       ) do
    with y when is_integer(y) and y >= 1 <- four(year),
         m when m in 1..12 <- two(month),
         d when is_integer(d) and d >= 1 <- two(day),
         true <- d <= :calendar.last_day_of_the_month(y, m),
         h when is_integer(h) and h <= 23 <- two(hour),
         mi when is_integer(mi) and mi <= 59 <- two(minute),
         s when is_integer(s) and s <= 59 <- two(second),
         true <- zone?(rest) do
      true
    else
      _not_canonical -> slow_datetime?(value)
    end
  end

  defp valid_datetime?(value), do: slow_datetime?(value)

  defp slow_datetime?(value), do: match?({:ok, _time, _offset}, DateTime.from_iso8601(value))

  defp zone?("Z"), do: true
  defp zone?(<<".", fraction::binary>>), do: fraction?(fraction, 0)
  defp zone?(_other), do: false

  # 1 to 6 digits, then Z.
  defp fraction?("Z", digits), do: digits in 1..6
  defp fraction?(<<c, rest::binary>>, digits) when c in ?0..?9, do: fraction?(rest, digits + 1)
  defp fraction?(_other, _digits), do: false

  # Fixed-width decimal fields; nil if any byte is not a digit.
  defp two(<<a, b>>) when a in ?0..?9 and b in ?0..?9, do: (a - ?0) * 10 + (b - ?0)
  defp two(_other), do: nil

  defp four(<<a, b, c, d>>) when a in ?0..?9 and b in ?0..?9 and c in ?0..?9 and d in ?0..?9,
    do: (a - ?0) * 1000 + (b - ?0) * 100 + (c - ?0) * 10 + (d - ?0)

  defp four(_other), do: nil

  # "$", "$.a.b", "$[0].c": only built for a problem that is actually reported.
  defp render([]), do: "$"

  defp render(path) do
    path |> :lists.reverse() |> Enum.map(&segment/1) |> then(&IO.iodata_to_binary(["$" | &1]))
  end

  defp segment(index) when is_integer(index), do: ["[", Integer.to_string(index), "]"]
  defp segment(name), do: [".", to_string(name)]
end
