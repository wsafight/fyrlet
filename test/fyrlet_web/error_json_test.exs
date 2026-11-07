defmodule FyrletWeb.ErrorJSONTest do
  use ExUnit.Case, async: true
  alias FyrletWeb.ErrorJSON

  test "renders a structured internal error for any template" do
    for template <- ["404.json", "500.json", :error] do
      assert %{
               "error" => %{
                 "code" => "INTERNAL_ERROR",
                 "message" => "The request could not be completed",
                 "details" => %{},
                 "retryable" => false
               }
             } = ErrorJSON.render(template, %{})
    end
  end
end
