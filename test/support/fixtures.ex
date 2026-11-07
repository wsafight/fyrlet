defmodule Fyrlet.Fixtures do
  def project do
    {:ok, project} = Fyrlet.Auth.create_project("test")
    project
  end

  def user(project, external_id \\ "alice") do
    {:ok, session} =
      Fyrlet.Auth.issue_session(project.service_key, %{"external_subject" => external_id})

    {:ok, actor} = Fyrlet.Auth.authenticate(session["token"], project.project.id)
    %{session: session, actor: actor, token: session["token"]}
  end

  def add(actor, text \\ "hello") do
    Fyrlet.Runtime.call(actor, "records.add", %{"text" => text}, Ecto.UUID.generate())
  end

  # Test-only reference that also reports a content fingerprint and record index for a
  # view, optionally recomputed incrementally from a previous result and a change.
  def snapshot_with_metadata(actor, subscription, previous \\ nil, change \\ nil) do
    alias Fyrlet.Runtime
    alias Fyrlet.Subscriptions.RecordIndex
    alias Fyrlet.Subscriptions.View

    previous_view =
      case previous do
        %{view: %View{} = view, data: data, record_index: indexed} ->
          if View.data(view) == data and RecordIndex.build(data) == indexed, do: view

        _other ->
          nil
      end

    with {:ok, view} <- Runtime.view(actor, subscription, previous_view, change) do
      data = View.data(view)

      {:ok,
       %{
         data: data,
         view: view,
         bytes: view.bytes,
         fingerprint: :crypto.hash(:sha256, Jason.encode!(data)),
         record_index: RecordIndex.build(data),
         unchanged: view.unchanged,
         patch: view.patch
       }}
    end
  end
end
