defmodule Fyrlet.Bench.FootprintDefinition do
  @behaviour Fyrlet.Definition
  alias Fyrlet.Schema

  @impl true
  def contract do
    specification = %{
      "input" =>
        Schema.object(
          %{"bytes" => %{"type" => "integer", "minimum" => 1024, "maximum" => 262_144}},
          ["bytes"]
        ),
      "output" => %{
        "type" => "array",
        "items" =>
          Schema.object(%{"id" => %{"type" => "string"}, "text" => %{"type" => "string"}}, [
            "id",
            "text"
          ])
      }
    }

    %{
      "operations" => %{},
      "subscriptions" => %{
        "footprint.private" => specification,
        "footprint.shared" => Map.put(specification, "shared", true)
      }
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok
  @impl true
  def scope(_name, actor, _input), do: "footprint:#{actor.project_id}:#{actor.subject_id}"
  @impl true
  def execute(_name, _actor, %{"bytes" => bytes}) do
    empty = for index <- 1..32, do: %{"id" => to_string(index), "text" => ""}
    payload = bytes - byte_size(Jason.encode!(empty))
    version = Application.get_env(:fyrlet, :footprint_version, 0)

    data =
      for {record, index} <- Enum.with_index(empty) do
        size = div(payload, 32) + if(index < rem(payload, 32), do: 1, else: 0)
        Map.put(record, "text", String.pad_trailing("#{version}:#{index}", size, "x"))
      end

    {:ok, data, []}
  end
end
