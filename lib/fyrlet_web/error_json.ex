defmodule FyrletWeb.ErrorJSON do
  def render(_template, _assigns) do
    %{
      "error" =>
        Fyrlet.Error.to_map(
          Fyrlet.Error.new("INTERNAL_ERROR", "The request could not be completed")
        )
    }
  end
end
