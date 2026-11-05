defmodule Fyrlet.Schema do
  alias Fyrlet.Error

  def validate(schema, value) do
    case check(schema, value, "$", %{}) do
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

  defp check(%{"type" => "object"} = schema, value, path, errors) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    normalized =
      Enum.reduce(properties, value, fn {name, property}, result ->
        if not Map.has_key?(result, name) and Map.has_key?(property, "default") do
          Map.put(result, name, property["default"])
        else
          result
        end
      end)

    errors =
      Enum.reduce(Map.get(schema, "required", []), errors, fn name, result ->
        if Map.has_key?(normalized, name),
          do: result,
          else: Map.put(result, path <> "." <> name, "is required")
      end)

    Enum.reduce(normalized, {normalized, errors}, fn {name, entry}, {result, problems} ->
      case Map.fetch(properties, name) do
        {:ok, property} ->
          {checked, next_errors} = check(property, entry, path <> "." <> name, problems)
          {Map.put(result, name, checked), next_errors}

        :error ->
          if schema["additionalProperties"] == false do
            {result, Map.put(problems, path <> "." <> to_string(name), "is not allowed")}
          else
            {result, problems}
          end
      end
    end)
  end

  defp check(%{"type" => "string"} = schema, value, path, errors) when is_binary(value) do
    length = String.length(value)

    errors =
      cond do
        length < Map.get(schema, "minLength", 0) ->
          Map.put(errors, path, "is too short")

        length > Map.get(schema, "maxLength", 1_000_000) ->
          Map.put(errors, path, "is too long")

        schema["format"] == "uuid" and not valid_uuid?(value) ->
          Map.put(errors, path, "must be a UUID")

        schema["format"] == "date-time" and not valid_datetime?(value) ->
          Map.put(errors, path, "must be an ISO 8601 timestamp")

        is_list(schema["enum"]) and value not in schema["enum"] ->
          Map.put(errors, path, "is not an allowed value")

        true ->
          errors
      end

    {value, errors}
  end

  defp check(%{"type" => "integer"} = schema, value, path, errors) when is_integer(value) do
    valid =
      value >= Map.get(schema, "minimum", -9_007_199_254_740_991) and
        value <= Map.get(schema, "maximum", 9_007_199_254_740_991)

    {value, if(valid, do: errors, else: Map.put(errors, path, "is outside the allowed range"))}
  end

  defp check(%{"type" => "boolean"}, value, _path, errors) when is_boolean(value),
    do: {value, errors}

  defp check(%{"type" => "null"}, nil, _path, errors), do: {nil, errors}

  defp check(%{"type" => "array"} = schema, value, path, errors) when is_list(value) do
    errors =
      if length(value) > Map.get(schema, "maxItems", 100),
        do: Map.put(errors, path, "contains too many entries"),
        else: errors

    value
    |> Enum.with_index()
    |> Enum.map_reduce(errors, fn {entry, index}, problems ->
      check(schema["items"], entry, "#{path}[#{index}]", problems)
    end)
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
      nil -> {value, Map.put(errors, path, "does not match an allowed type")}
    end
  end

  defp check(_schema, value, path, errors),
    do: {value, Map.put(errors, path, "has an invalid type")}

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp valid_datetime?(value), do: match?({:ok, _time, _offset}, DateTime.from_iso8601(value))
end
