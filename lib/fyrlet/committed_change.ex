defmodule Fyrlet.CommittedChange do
  @enforce_keys [:change, :output, :schema, :bytes]
  defstruct [:change, :output, :schema, :bytes]
end
