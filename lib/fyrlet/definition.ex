defmodule Fyrlet.Definition do
  @callback contract() :: map()
  @callback authorize(String.t(), Fyrlet.Actor.t(), map()) :: :ok | {:error, Fyrlet.Error.t()}
  @callback execute(String.t(), Fyrlet.Actor.t(), map()) ::
              {:ok, term(), [String.t()]} | {:error, Fyrlet.Error.t()}
  @callback scope(String.t(), Fyrlet.Actor.t(), map()) :: String.t()
  @callback change(String.t(), Fyrlet.Actor.t(), map(), term()) :: map() | nil
  @callback load_subscription(String.t(), Fyrlet.Actor.t(), map()) ::
              {:ok, term(), map()} | {:error, Fyrlet.Error.t()}
  @callback update_subscription(String.t(), Fyrlet.Actor.t(), map(), Fyrlet.View.t(), map()) ::
              {:replace, String.t(), term()}
              | {:reset, term(), map()}
              | {:context, map()}
              | :unchanged
              | :reload
  @optional_callbacks change: 4, update_subscription: 5, load_subscription: 3
end
