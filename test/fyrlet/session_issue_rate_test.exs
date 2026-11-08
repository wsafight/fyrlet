defmodule Fyrlet.SessionIssueRateTest do
  # Changes global configuration, so it must not run alongside other session-issuing tests.
  use Fyrlet.DataCase, async: false

  setup do
    previous = Application.get_env(:fyrlet, :session_issue_per_minute, :unset)

    on_exit(fn ->
      if previous == :unset,
        do: Application.delete_env(:fyrlet, :session_issue_per_minute),
        else: Application.put_env(:fyrlet, :session_issue_per_minute, previous)
    end)

    %{project: project()}
  end

  test "issuing beyond the per-minute limit is a retryable refusal", %{project: project} do
    Application.put_env(:fyrlet, :session_issue_per_minute, 2)

    assert {:ok, _} = Auth.issue_session(project.service_key, %{"external_subject" => "a"})
    assert {:ok, _} = Auth.issue_session(project.service_key, %{"external_subject" => "b"})

    assert {:error, %Error{code: "LIMIT_EXCEEDED", retryable: true}} =
             Auth.issue_session(project.service_key, %{"external_subject" => "c"})

    # The refused attempt stored no session.
    assert Repo.aggregate(Fyrlet.Session, :count) == 2
  end

  test "another key has its own allowance, and nil disables the limit", %{project: project} do
    Application.put_env(:fyrlet, :session_issue_per_minute, 1)
    other = project()
    assert {:ok, _} = Auth.issue_session(project.service_key, %{"external_subject" => "a"})
    assert {:ok, _} = Auth.issue_session(other.service_key, %{"external_subject" => "a"})

    Application.put_env(:fyrlet, :session_issue_per_minute, nil)
    assert {:ok, _} = Auth.issue_session(project.service_key, %{"external_subject" => "b"})
  end
end
