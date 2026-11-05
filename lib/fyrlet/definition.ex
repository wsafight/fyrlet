defmodule Fyrlet.Definition do
  @callback contract() :: map()
  @callback authorize(String.t(), Fyrlet.Actor.t(), map()) :: :ok | {:error, Fyrlet.Error.t()}
  @callback execute(String.t(), Fyrlet.Actor.t(), map()) ::
              {:ok, term(), [String.t()]} | {:error, Fyrlet.Error.t()}
  @callback scope(String.t(), Fyrlet.Actor.t(), map()) :: String.t()
end
