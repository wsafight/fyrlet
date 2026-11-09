defmodule Fyrlet.CommittedChange do
  @enforce_keys [:change, :output, :schema]
  defstruct [:change, :output, :schema]
end
