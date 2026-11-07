defmodule Fyrlet.EffectsReceiptEndpointTest do
  use Fyrlet.RunsCase
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  @endpoint FyrletWeb.Endpoint

  describe "receipt endpoint" do
    setup do
      project = project()
      alice = user(project, "alice")

      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "send", input: %{}}]} end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "send" => fn _, _ -> {:effect, %{adapter: "query", key: "mail", payload: %{}}} end
      })

      id = start_run!(alice)
      drive(id)
      [effect] = Repo.all(Fyrlet.Effects.Effect)

      Application.put_env(:fyrlet, :effect_handlers, %{dispatch: fn _ -> {:accepted, "ext-1"} end})

      on_exit(fn -> Application.delete_env(:fyrlet, :effect_handlers) end)
      Fyrlet.Effects.dispatch(effect.id)
      %{project: project, effect: effect, run_id: id, alice: alice}
    end

    defp post_receipt(key, id, body) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> key)
      |> post("/api/v1/effects/#{id}/receipts", body)
    end

    test "a service key confirms delivery once; a repeat is a duplicate", %{
      project: project,
      effect: effect,
      run_id: id
    } do
      body = %{"receipt_id" => "r1", "outcome" => "succeeded", "result" => %{"ok" => true}}

      assert json_response(post_receipt(project.service_key, effect.id, body), 200)["data"][
               "status"
             ] == "applied"

      assert json_response(post_receipt(project.service_key, effect.id, body), 200)["data"][
               "status"
             ] == "duplicate"

      assert drive(id) == "completed"
    end

    test "other projects, user tokens and bad bodies are refused", %{
      project: project,
      effect: effect,
      alice: alice
    } do
      other = project()

      assert json_response(
               post_receipt(other.service_key, effect.id, %{
                 "receipt_id" => "r",
                 "outcome" => "succeeded"
               }),
               404
             )

      assert json_response(
               post_receipt(alice.token, effect.id, %{
                 "receipt_id" => "r",
                 "outcome" => "succeeded"
               }),
               401
             )

      assert json_response(
               post_receipt(project.service_key, effect.id, %{"outcome" => "maybe"}),
               422
             )

      assert json_response(
               post_receipt(project.service_key, "nope", %{
                 "receipt_id" => "r",
                 "outcome" => "failed"
               }),
               404
             )

      assert Repo.get!(Fyrlet.Effects.Effect, effect.id).status == "accepted"
    end
  end
end
