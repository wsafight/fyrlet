defmodule Fyrlet.SchemaTest do
  use ExUnit.Case, async: true
  alias Fyrlet.{Error, Schema}

  describe "validate_definition!/1" do
    test "accepts every supported schema shape" do
      schemas = [
        %{"type" => "boolean", "default" => true},
        %{"type" => "null"},
        %{"type" => "string"},
        %{"type" => "string", "minLength" => 1, "maxLength" => 5, "format" => "uuid"},
        %{"type" => "string", "enum" => ["a", "b"], "default" => "a"},
        %{"type" => "string", "format" => "date-time"},
        %{"type" => "integer", "minimum" => 0, "maximum" => 10, "default" => 5},
        %{"type" => "array", "items" => %{"type" => "string"}},
        %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 0},
        %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 2},
        %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 100},
        %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"],
          "additionalProperties" => false,
          "default" => %{"name" => "x"}
        },
        %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}], "default" => nil}
      ]

      for schema <- schemas do
        assert :ok = Schema.validate_definition!(schema)
      end
    end

    test "rejects ambiguous, empty and unsupported schemas" do
      for schema <- [
            %{"type" => "number"},
            %{"type" => "object", "properties" => %{}},
            %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
            %{"anyOf" => []},
            %{"anyOf" => [%{"type" => "string"}], "type" => "string"},
            %{"type" => "string", "pattern" => "^a$"},
            %{"type" => "boolean", "minimum" => 1}
          ] do
        assert_raise ArgumentError, fn -> Schema.validate_definition!(schema) end
      end
    end

    test "rejects unsupported and unbounded array keywords" do
      for schema <- [
            %{"type" => "array"},
            %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => -1},
            %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 101},
            %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 1},
            %{"type" => "array", "items" => %{"type" => "number"}}
          ] do
        assert_raise ArgumentError, fn -> Schema.validate_definition!(schema) end
      end
    end

    test "rejects invalid object declarations" do
      for schema <- [
            %{
              "type" => "object",
              "properties" => %{"a" => %{"type" => "string"}},
              "required" => "a",
              "additionalProperties" => false
            },
            %{
              "type" => "object",
              "properties" => %{"a" => %{"type" => "string"}},
              "required" => ["b"],
              "additionalProperties" => false
            },
            %{
              "type" => "object",
              "properties" => %{1 => %{"type" => "string"}},
              "additionalProperties" => false
            },
            %{
              "type" => "object",
              "properties" => %{"a" => %{"type" => "number"}},
              "additionalProperties" => false
            }
          ] do
        assert_raise ArgumentError, fn -> Schema.validate_definition!(schema) end
      end
    end

    test "rejects invalid string declarations" do
      for schema <- [
            %{"type" => "string", "minLength" => -1},
            %{"type" => "string", "maxLength" => -1},
            %{"type" => "string", "minLength" => 5, "maxLength" => 2},
            %{"type" => "string", "format" => "email"},
            %{"type" => "string", "enum" => []},
            %{"type" => "string", "enum" => [1]},
            %{"type" => "string", "default" => 1}
          ] do
        assert_raise ArgumentError, fn -> Schema.validate_definition!(schema) end
      end
    end

    test "rejects unsafe or inverted integer bounds" do
      safe = 9_007_199_254_740_991

      for schema <- [
            %{"type" => "integer", "minimum" => safe + 1},
            %{"type" => "integer", "maximum" => -safe - 1},
            %{"type" => "integer", "minimum" => 2, "maximum" => 1},
            %{"type" => "integer", "minimum" => "0"},
            %{"type" => "integer", "maximum" => 1.5},
            %{"type" => "integer", "default" => "invalid"}
          ] do
        assert_raise ArgumentError, fn -> Schema.validate_definition!(schema) end
      end

      assert :ok = Schema.validate_definition!(%{"type" => "integer", "minimum" => -safe})
      assert :ok = Schema.validate_definition!(%{"type" => "integer", "maximum" => safe})
    end

    test "rejects invalid defaults recursively" do
      assert_raise ArgumentError, fn ->
        Schema.validate_definition!(%{
          "type" => "object",
          "properties" => %{"count" => %{"type" => "integer", "default" => "one"}},
          "additionalProperties" => false
        })
      end

      assert_raise ArgumentError, fn ->
        Schema.validate_definition!(%{
          "anyOf" => [%{"type" => "string"}, %{"type" => "null"}],
          "default" => 42
        })
      end
    end
  end

  describe "validate/2" do
    test "normalizes defaults at the top level and in nested objects" do
      schema =
        Schema.object(
          %{
            "enabled" => %{"type" => "boolean", "default" => true},
            "nested" => Schema.object(%{"count" => %{"type" => "integer", "default" => 3}})
          },
          []
        )

      assert {:ok, %{"enabled" => true, "nested" => %{"count" => 3}}} =
               Schema.validate(schema, %{"nested" => %{}})
    end

    test "explicit values override defaults" do
      schema = Schema.object(%{"enabled" => %{"type" => "boolean", "default" => true}}, [])
      assert {:ok, %{"enabled" => false}} = Schema.validate(schema, %{"enabled" => false})
    end

    test "closed objects reject unexpected properties and report every error" do
      schema =
        Schema.object(
          %{
            "enabled" => %{"type" => "boolean", "default" => true},
            "text" => %{"type" => "string", "minLength" => 1}
          },
          ["text"]
        )

      assert {:error,
              %Error{
                code: "VALIDATION_FAILED",
                message: "The value does not match the contract",
                details: %{
                  "fields" => %{
                    "$.unexpected" => "is not allowed",
                    "$.text" => "is required"
                  }
                }
              }} = Schema.validate(schema, %{"unexpected" => true})
    end

    test "open objects accept additional properties when directly validated" do
      schema = %{"type" => "object", "properties" => %{"known" => %{"type" => "string"}}}

      assert {:ok, %{"known" => "a", "extra" => 1}} =
               Schema.validate(schema, %{"known" => "a", "extra" => 1})
    end

    test "required nested fields use JSON-path style keys" do
      schema =
        Schema.object(
          %{
            "outer" => Schema.object(%{"inner" => %{"type" => "string"}}, ["inner"])
          },
          ["outer"]
        )

      assert {:error, %Error{details: %{"fields" => fields}}} =
               Schema.validate(schema, %{"outer" => %{}})

      assert fields == %{"$.outer.inner" => "is required"}
    end

    test "strings enforce length, format and enum constraints" do
      assert {:ok, "é"} =
               Schema.validate(%{"type" => "string", "minLength" => 1}, "é")

      assert {:error, %Error{details: %{"fields" => %{"$" => "is too short"}}}} =
               Schema.validate(%{"type" => "string", "minLength" => 2}, "a")

      assert {:error, %Error{details: %{"fields" => %{"$" => "is too long"}}}} =
               Schema.validate(%{"type" => "string", "maxLength" => 1}, "ab")

      assert {:ok, "123e4567-e89b-12d3-a456-426614174000"} =
               Schema.validate(
                 %{"type" => "string", "format" => "uuid"},
                 "123e4567-e89b-12d3-a456-426614174000"
               )

      assert {:error, %Error{details: %{"fields" => %{"$" => "must be a UUID"}}}} =
               Schema.validate(%{"type" => "string", "format" => "uuid"}, "not-a-uuid")

      assert {:ok, "2026-11-06T10:30:00Z"} =
               Schema.validate(
                 %{"type" => "string", "format" => "date-time"},
                 "2026-11-06T10:30:00Z"
               )

      assert {:error, %Error{details: %{"fields" => %{"$" => "must be an ISO 8601 timestamp"}}}} =
               Schema.validate(%{"type" => "string", "format" => "date-time"}, "2026-11-06")

      assert {:ok, "b"} =
               Schema.validate(%{"type" => "string", "enum" => ["a", "b"]}, "b")

      assert {:error, %Error{details: %{"fields" => %{"$" => "is not an allowed value"}}}} =
               Schema.validate(%{"type" => "string", "enum" => ["a", "b"]}, "c")
    end

    test "integers enforce inclusive ranges and reject floats and strings" do
      schema = %{"type" => "integer", "minimum" => 2, "maximum" => 4}
      assert {:ok, 2} = Schema.validate(schema, 2)
      assert {:ok, 4} = Schema.validate(schema, 4)

      for value <- [1, 5] do
        assert {:error, %Error{details: %{"fields" => %{"$" => "is outside the allowed range"}}}} =
                 Schema.validate(schema, value)
      end

      for value <- [2.0, "2", nil, true] do
        assert {:error, %Error{details: %{"fields" => %{"$" => "has an invalid type"}}}} =
                 Schema.validate(schema, value)
      end
    end

    test "booleans, nulls and unsafe integers are validated" do
      assert {:ok, true} = Schema.validate(%{"type" => "boolean"}, true)
      assert {:ok, false} = Schema.validate(%{"type" => "boolean"}, false)
      assert {:ok, nil} = Schema.validate(%{"type" => "null"}, nil)

      for {schema, value} <- [
            {%{"type" => "boolean"}, nil},
            {%{"type" => "null"}, false},
            {%{"type" => "integer"}, 9_007_199_254_740_992},
            {%{"type" => "integer"}, -9_007_199_254_740_992}
          ] do
        assert {:error, %Error{code: "VALIDATION_FAILED"}} = Schema.validate(schema, value)
      end
    end

    test "arrays validate bounds and each indexed entry" do
      schema = %{"type" => "array", "items" => %{"type" => "integer"}, "maxItems" => 2}

      assert {:ok, [1, 2]} = Schema.validate(schema, [1, 2])

      assert {:error, %Error{details: %{"fields" => %{"$" => "contains too many entries"}}}} =
               Schema.validate(schema, [1, 2, 3])

      assert {:error, %Error{details: %{"fields" => fields}}} =
               Schema.validate(schema, [1, "two"])

      assert fields == %{"$[1]" => "has an invalid type"}
    end

    test "anyOf accepts the first matching alternative and rejects mismatches" do
      schema = %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}

      assert {:ok, "text"} = Schema.validate(schema, "text")
      assert {:ok, nil} = Schema.validate(schema, nil)

      assert {:error, %Error{details: %{"fields" => %{"$" => "does not match an allowed type"}}}} =
               Schema.validate(schema, 1)
    end

    test "anyOf normalizes defaults from the matched alternative" do
      schema = %{
        "anyOf" => [
          Schema.object(%{"enabled" => %{"type" => "boolean", "default" => true}}, []),
          %{"type" => "null"}
        ]
      }

      assert {:ok, %{"enabled" => true}} = Schema.validate(schema, %{})
    end

    test "object schema with an array of errors returns all problems" do
      schema =
        Schema.object(
          %{
            "a" => %{"type" => "integer", "minimum" => 1},
            "b" => %{"type" => "string", "minLength" => 2}
          },
          ["a", "b"]
        )

      assert {:error, %Error{details: %{"fields" => fields}}} =
               Schema.validate(schema, %{"a" => 0, "b" => "x"})

      assert fields == %{
               "$.a" => "is outside the allowed range",
               "$.b" => "is too short"
             }
    end
  end
end
