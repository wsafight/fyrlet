defmodule FyrletEffectEmailTest.Provider do
  @behaviour FyrletEffectEmail.Provider

  def capabilities, do: Application.get_env(:fyrlet, :email_test_caps)

  def deliver(message, context) do
    send(Application.fetch_env!(:fyrlet, :email_test_pid), {:deliver, message, context})
    Application.fetch_env!(:fyrlet, :email_test_answer).()
  end

  def status(id, _context), do: Application.fetch_env!(:fyrlet, :email_test_status).(id)
end

defmodule FyrletEffectEmailTest.NoStatus do
  @behaviour FyrletEffectEmail.Provider
  def capabilities, do: %{"idempotency" => nil, "queryable" => true}
  def deliver(_message, _context), do: {:accepted, "x"}
end

defmodule FyrletEffectEmailTest do
  use ExUnit.Case, async: false
  alias FyrletEffectEmail, as: Email
  alias FyrletEffectEmailTest.Provider

  setup do
    Application.put_env(:fyrlet, :email_test_pid, self())
    Application.put_env(:fyrlet, :email_test_caps, %{"idempotency" => nil, "queryable" => false})
    Application.put_env(:fyrlet, :email_test_answer, fn -> {:accepted, "msg-1"} end)
    Application.put_env(:fyrlet, :effect_secrets, %{"mail" => "key-123"})

    configure(
      provider: Provider,
      allowed_senders: ["noreply@example.com"]
    )

    on_exit(fn ->
      configure([])

      for key <- [
            :email_test_pid,
            :email_test_caps,
            :email_test_answer,
            :email_test_status,
            :effect_secrets
          ],
          do: Application.delete_env(:fyrlet, key)
    end)
  end

  defp effect(payload \\ %{}) do
    base = %{
      "from" => "noreply@example.com",
      "to" => ["a@example.org"],
      "subject" => "Hello",
      "text" => "Body"
    }

    %{
      operation_id: "run:0:mail",
      secret_ref: "mail",
      external_ref: "msg-1",
      payload: Map.merge(base, payload)
    }
  end

  test "an accepted message is accepted, not delivered, and carries the key and credential" do
    assert {:accepted, "msg-1"} = Email.dispatch(effect())
    assert_receive {:deliver, message, context}
    assert context == %{idempotency_key: "run:0:mail", secret: "key-123"}
    assert message["to"] == ["a@example.org"]
    assert message["reply_to"] == nil
    assert Email.capabilities()["acceptance"] == "provider_accepted"
  end

  test "provider answers map to what they prove" do
    for {answer, expected} <- [
          {{:rejected, "mailbox"}, {:failed, "mailbox"}},
          {{:transient, :throttled}, {:retryable, :throttled}},
          {:unknown, :unknown},
          {:ok, :unknown},
          {{:accepted, ""}, :unknown}
        ] do
      Application.put_env(:fyrlet, :email_test_answer, fn -> answer end)
      assert Email.dispatch(effect()) == expected
    end
  end

  test "a provider that raises or exits after the call is unknown, never failed" do
    Application.put_env(:fyrlet, :email_test_answer, fn -> raise "connection reset" end)
    assert Email.dispatch(effect()) == :unknown
    Application.put_env(:fyrlet, :email_test_answer, fn -> exit(:timeout) end)
    assert Email.dispatch(effect()) == :unknown
  end

  test "invalid messages fail without reaching the provider" do
    invalid = [
      %{"from" => "other@example.com"},
      %{"from" => "noreply@example.com\n"},
      %{"to" => []},
      %{"to" => "a@example.org"},
      %{"to" => ["a@example.org\r\nBcc: victim@example.net"]},
      %{"to" => ["not-an-address"]},
      %{"to" => ["a@example.org\n"]},
      %{"to" => ["a b@example.org"]},
      %{"to" => for(n <- 1..51, do: "u#{n}@example.org")},
      %{"reply_to" => "x@y"},
      %{"subject" => "Hi\r\nBcc: victim@example.net"},
      %{"subject" => ""},
      %{"subject" => String.duplicate("s", 999)},
      %{"text" => nil},
      %{"text" => String.duplicate("b", 256 * 1024 + 1)},
      %{"html" => ""}
    ]

    for patch <- invalid do
      payload = if patch == %{"text" => nil}, do: %{"text" => nil, "html" => nil}, else: patch
      assert {:failed, reason} = Email.dispatch(effect(payload)), inspect(patch)
      assert is_binary(reason)
    end

    assert {:failed, _} = Email.dispatch(%{effect() | payload: "nope"})
    refute_received {:deliver, _, _}
  end

  test "custom headers are dropped and recipients are de-duplicated" do
    Email.dispatch(
      effect(%{
        "headers" => %{"Bcc" => "x@example.net"},
        "to" => ["a@example.org", "a@example.org"]
      })
    )

    assert_receive {:deliver, message, _}
    refute Map.has_key?(message, "headers")
    assert message["to"] == ["a@example.org"]
  end

  test "recipient domains can be confined" do
    configure(
      provider: Provider,
      allowed_senders: ["noreply@example.com"],
      allowed_recipient_domains: ["example.org"]
    )

    assert {:accepted, _} = Email.dispatch(effect(%{"to" => ["a@EXAMPLE.org"]}))

    assert {:failed, "recipient domain is not allowed"} =
             Email.dispatch(effect(%{"to" => ["a@example.net"]}))
  end

  test "without a usable provider nothing is sent and it is a definite failure" do
    for provider <- [nil, Missing.Module] do
      configure(
        provider: provider,
        allowed_senders: ["noreply@example.com"]
      )

      assert {:failed, "no email provider is configured"} = Email.dispatch(effect())
      assert Email.capabilities()["queryable"] == false
      assert Email.capabilities()["idempotency"] == nil
    end

    refute_received {:deliver, _, _}
  end

  test "queries report delivery and bounces only when the provider declares them" do
    assert Email.query(effect()) == :unknown

    Application.put_env(:fyrlet, :email_test_caps, %{
      "idempotency" => %{"window_seconds" => 3600},
      "queryable" => true
    })

    assert Email.capabilities()["idempotency"] == %{"window_seconds" => 3600}
    assert Email.capabilities()["queryable"] == true

    for {status, expected} <- [
          {{:delivered, "250"}, {:succeeded, %{"delivered" => true, "detail" => "250"}}},
          {{:bounced, "550"}, {:failed, {:bounced, "550"}}},
          {:pending, :pending},
          {:not_found, :not_found},
          {:garbage, :unknown}
        ] do
      Application.put_env(:fyrlet, :email_test_status, fn "msg-1" -> status end)
      assert Email.query(effect()) == expected
    end

    Application.put_env(:fyrlet, :email_test_status, fn _ -> raise "down" end)
    assert Email.query(effect()) == :unknown
    assert Email.query(%{effect() | external_ref: nil}) == :unknown
  end

  test "a provider that claims to be queryable but has no status/2 is not queryable" do
    configure(
      provider: FyrletEffectEmailTest.NoStatus,
      allowed_senders: ["noreply@example.com"]
    )

    assert Email.capabilities()["queryable"] == false
    assert Email.query(effect()) == :unknown
  end

  @settings [:provider, :allowed_senders, :allowed_recipient_domains, :max_recipients]

  defp configure(options) do
    Enum.each(@settings, &Application.delete_env(:fyrlet_effect_email, &1))

    Enum.each(options, fn {key, value} ->
      Application.put_env(:fyrlet_effect_email, key, value)
    end)
  end
end
