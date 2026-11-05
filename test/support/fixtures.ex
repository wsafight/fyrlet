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
    Fyrlet.Runtime.call(actor, "inbox.add", %{"text" => text}, Ecto.UUID.generate())
  end
end
