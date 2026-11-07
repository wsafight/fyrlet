defmodule Mix.Tasks.Fyrlet.ContractTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Fyrlet.Contract

  setup context do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      if context[:tmp_dir], do: File.rm_rf!(context.tmp_dir)
    end)

    :ok
  end

  test "prints the contract with the enabled capabilities and their operations" do
    Contract.run([])

    assert_received {:mix_shell, :info, [json]}
    contract = Jason.decode!(json)
    assert contract["protocol_version"] == 1
    assert contract["schema_dialect"] == "fyrlet-subset"
    assert contract["capabilities"]["runs"] == 1
    assert contract["operations"]["records.add"]["kind"] == "write"
    assert contract["operations"]["runs.demo"]["kind"] == "run"
    assert contract["subscriptions"]["records.recent"]
    assert String.ends_with?(json, "\n")
  end

  @tag :tmp_dir
  test "creates parent directories and writes valid JSON to the requested path", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join([tmp_dir, "nested", "contract.json"])
    Contract.run([path])

    json = File.read!(path)
    assert Jason.decode!(json)["protocol_version"] == 1
    assert String.ends_with?(json, "\n")
    refute_received {:mix_shell, :info, _}
  end

  @tag :tmp_dir
  test "replaces an existing export", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "contract.json")
    File.write!(path, "stale export")

    Contract.run([path])

    assert Jason.decode!(File.read!(path))["protocol_version"] == 1
  end

  test "rejects multiple output paths" do
    assert_raise Mix.Error, ~r/Usage: mix fyrlet.contract/, fn ->
      Contract.run(["first.json", "second.json"])
    end
  end

  test "rejects options, including the removed projection" do
    for arguments <- [["--unknown"], ["--projection", "2"]] do
      assert_raise OptionParser.ParseError, fn -> Contract.run(arguments) end
    end
  end
end
