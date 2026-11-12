defmodule SymphonyElixir.SymphonyPlusPlus.HerdrCoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard.Signals

  @moduletag skip: match?({:win32, _}, :os.type())

  test "a worker can publish, replace and clear a preview after discovery through one list per refresh" do
    dir = Path.join(System.tmp_dir!(), "sympp-preview-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    command = Path.join(dir, "hc")
    data = Path.join(dir, "terminals.json")
    previous = Application.get_env(:symphony_elixir, :sympp_herdr_core)
    cache_key = {HerdrCore, :snapshot}
    previous_cache = :persistent_term.get(cache_key, nil)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :sympp_herdr_core, previous)
      if previous_cache, do: :persistent_term.put(cache_key, previous_cache), else: :persistent_term.erase(cache_key)
      File.rm_rf!(dir)
    end)

    File.write!(command, """
    #!/usr/bin/env python3
    import json, pathlib, sys
    data = pathlib.Path(__file__).with_name("terminals.json")
    if sys.argv[1:] == ["server", "status", "--json"]:
        print(json.dumps({"core": {"id": "test-core", "name": "test-host"}}))
    elif sys.argv[1:] == ["connect"]:
        request = json.loads(sys.stdin.readline())
        assert request["method"] == "terminal.list" and request["params"]["all"]
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": json.loads(data.read_text())}), flush=True)
        sys.stdin.read()
    else:
        sys.exit(1)
    """)

    File.chmod!(command, 0o755)
    Application.put_env(:symphony_elixir, :sympp_herdr_core, command)
    worker = %WorkedOn{terminal_key: "test-core/t1", display_address: "test-host/t1", state: "live"}
    :ok = DashboardPubSub.subscribe()

    for {url, state, expected} <- [
          {nil, "live", nil},
          {"http://dev-host:3000/design?mode=demo", "live", "http://dev-host:3000/design?mode=demo"},
          {"https://dev-host/other", "live", "https://dev-host/other"},
          {nil, "live", nil},
          {"javascript:alert(1)", "live", nil},
          {"http://dev-host:3000", "finished", nil}
        ] do
      labels = %{"sympp.role" => "worker"}
      labels = if url, do: Map.put(labels, "sympp.preview_url", url), else: labels
      File.write!(data, Jason.encode!(%{terminals: [%{address: "t1", state: state, labels: labels}]}))
      assert {:ok, _snapshot} = HerdrCore.refresh()
      assert_receive :operator_dashboard_changed
      assert Signals.worker_terminal(worker).preview_url == expected
    end
  end
end
