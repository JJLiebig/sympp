Code.require_file("../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.OwnershipTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases

  setup %{repo: repo} do
    work_request = create_work_request!(repo, %{"title" => "Ownership", "status" => "ready_for_slicing"})
    on_exit(fn -> Application.put_env(:symphony_elixir, :sympp_herdr_core, nil) end)
    {:ok, work_request: work_request}
  end

  defp set_report(repo, terminal, work_request_id, brief) do
    mcp_tool(repo, terminal, "set_report", %{"work_request_id" => work_request_id, "brief" => brief})
  end

  defp error_reason(response), do: get_in(response, ["error", "data", "reason"])

  defp live_owner_rows(repo, work_request_id) do
    repo.all(from(row in WorkedOn, where: row.subject_id == ^work_request_id and row.state == "live"))
  end

  # The factory's herdr-core sees the test core and lists these terminals.
  defp factory_core(terminals) do
    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn ->
      {:ok, %{core_id: MCPHarness.test_core_id(), terminals: terminals}}
    end)
  end

  test "the first owner-gated write takes the WorkRequest; the same terminal keeps writing", %{repo: repo, work_request: work_request} do
    assert %{"result" => _} = set_report(repo, "t1", work_request.id, "Started")
    assert %{"result" => _} = set_report(repo, "t1", work_request.id, "Still going")

    assert [%WorkedOn{display_address: "testbox/t1", role: "architect", state: "live"}] = live_owner_rows(repo, work_request.id)
    assert %{"brief" => %{"text" => "Still going"}} = repo.get!(WorkRequest, work_request.id).report
  end

  test "a write from another terminal is refused, naming the owner and what to do", %{repo: repo, work_request: work_request} do
    assert %{"result" => _} = set_report(repo, "t1", work_request.id, "Mine")

    response = set_report(repo, "t2", work_request.id, "Taking over")

    assert error_reason(response) == "owned_by_other_terminal"
    assert get_in(response, ["error", "data", "owner", "address"]) == "testbox/t1"
    assert get_in(response, ["error", "data", "owner", "status_state"]) == "unknown"
    assert get_in(response, ["error", "data", "next_action"]) == "ask testbox/t1, or wait until it finishes"
    assert %{"brief" => %{"text" => "Mine"}} = repo.get!(WorkRequest, work_request.id).report
  end

  test "two terminals racing for one WorkRequest end with exactly one live owner", %{repo: repo, work_request: work_request} do
    results =
      ["t1", "t2", "t3", "t4"]
      |> Enum.map(fn address -> Task.async(fn -> Ownership.acquire(repo, work_request.id, test_terminal(address)) end) end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert [{:ok, _row, :acquired}] = Enum.filter(results, &match?({:ok, _row, _how}, &1))
    assert Enum.count(results, &match?({:error, {:owned_by_other_terminal, _owner}}, &1)) == 3
    assert [_one] = live_owner_rows(repo, work_request.id)
  end

  test "an owner whose heartbeat lapsed without detach is not taken over", %{repo: repo, work_request: work_request} do
    own!(repo, work_request.id, "t1")
    # The factory's core is unreachable and no bridge heartbeat names t1.
    refute ClientLeases.terminal_live?(test_terminal("t1").key)

    assert error_reason(set_report(repo, "t2", work_request.id, "Taking over")) == "owned_by_other_terminal"
    assert [%WorkedOn{display_address: "testbox/t1"}] = live_owner_rows(repo, work_request.id)
    assert Ownership.public(Ownership.owner(repo, work_request.id))["liveness"] == "unknown"
  end

  test "a terminal the factory's core reports finished is taken over", %{repo: repo, work_request: work_request} do
    own!(repo, work_request.id, "t1")
    factory_core(%{"t1" => %{"address" => "t1", "state" => "finished"}, "t2" => %{"address" => "t2", "state" => "live"}})

    assert %{"result" => _} = set_report(repo, "t2", work_request.id, "Mine now")

    rows = repo.all(from(row in WorkedOn, where: row.subject_id == ^work_request.id, order_by: row.started_at))
    assert [%WorkedOn{display_address: "testbox/t1", state: "finished", finish_reason: "taken_over"}, %WorkedOn{display_address: "testbox/t2", state: "live"}] = rows
  end

  test "a terminal the factory's core sees live keeps ownership", %{repo: repo, work_request: work_request} do
    own!(repo, work_request.id, "t1")
    factory_core(%{"t1" => %{"address" => "t1", "state" => "live", "status" => %{"state" => "idle"}}, "t2" => %{"address" => "t2", "state" => "live"}})

    response = set_report(repo, "t2", work_request.id, "Taking over")

    assert error_reason(response) == "owned_by_other_terminal"
    assert get_in(response, ["error", "data", "owner", "status_state"]) == "idle"
    assert Ownership.public(Ownership.owner(repo, work_request.id))["liveness"] == "live"
  end

  test "operator Release lets another terminal take the WorkRequest", %{repo: repo, work_request: work_request} do
    own!(repo, work_request.id, "t1")

    assert {:ok, %WorkedOn{state: "finished", finish_reason: "released_by_operator"}} = Ownership.release(repo, work_request.id)
    assert {:error, :not_owned} = Ownership.release(repo, work_request.id)
    assert %{"result" => _} = set_report(repo, "t2", work_request.id, "Mine now")
    assert [%WorkedOn{display_address: "testbox/t2"}] = live_owner_rows(repo, work_request.id)
  end

  test "a clean detach ends ownership unless the factory's core still sees the terminal live", %{repo: repo, work_request: work_request} do
    other = create_work_request!(repo, %{"title" => "Other", "status" => "ready_for_slicing"})
    own!(repo, work_request.id, "t1")
    own!(repo, other.id, "t9")

    factory_core(%{"t9" => %{"address" => "t9", "state" => "live"}})
    # t1 is on this core but not listed (gone); t9 is live here.
    assert :ok = Ownership.detached(repo, test_terminal("t9").key)
    assert [%WorkedOn{state: "live"}] = live_owner_rows(repo, other.id)

    Application.put_env(:symphony_elixir, :sympp_herdr_core, nil)
    assert :ok = Ownership.detached(repo, test_terminal("t1").key)
    assert [] = live_owner_rows(repo, work_request.id)
    assert %{"result" => _} = set_report(repo, "t2", work_request.id, "Mine now")
  end

  test "restarting the agent in the same terminal keeps ownership", %{repo: repo, work_request: work_request} do
    assert %{"result" => _} = set_report(repo, "t1", work_request.id, "Before restart")
    # A new agent process in the same terminal asserts the same core and address.
    assert %{"result" => _} = set_report(repo, "t1", work_request.id, "After restart")
    assert [_one] = live_owner_rows(repo, work_request.id)
  end

  test "a caller outside Herdr can read but not write", %{repo: repo, work_request: work_request} do
    assert %{"result" => _} = mcp_tool(repo, nil, "read_work_request", %{"work_request_id" => work_request.id})
    assert error_reason(set_report(repo, nil, work_request.id, "Hello")) == "read_only_outside_herdr"
    assert error_reason(mcp_tool(repo, nil, "record_decision", %{"work_request_id" => work_request.id, "decision" => "x", "rationale" => "y", "scope_impact" => "z", "source_type" => "architect"})) == "read_only_outside_herdr"
    assert [] = live_owner_rows(repo, work_request.id)
  end

  test "a terminal the factory's core reports finished cannot write as itself", %{repo: repo, work_request: work_request} do
    factory_core(%{"t5" => %{"address" => "t5", "state" => "finished"}})
    assert error_reason(set_report(repo, "t5", work_request.id, "Ghost")) == "terminal_not_live"
  end

  test "decisions stay open to any Herdr terminal on an owned WorkRequest", %{repo: repo, work_request: work_request} do
    own!(repo, work_request.id, "t1")

    response =
      mcp_tool(
        repo,
        "t7",
        "record_decision",
        %{"work_request_id" => work_request.id, "decision" => "Ship it", "rationale" => "Product call", "scope_impact" => "none", "source_type" => "architect"},
        labels: %{"sympp.role" => "chief", "sympp.domain" => "Kraken"}
      )

    assert %{"result" => _} = response
    assert [%WorkedOn{display_address: "testbox/t1"}] = live_owner_rows(repo, work_request.id)
  end

  test "a failed write does not take ownership", %{repo: repo, work_request: work_request} do
    response = mcp_tool(repo, "t1", "set_report", %{"work_request_id" => work_request.id, "parking" => %{"reason" => "  "}})

    assert error_reason(response) == "invalid_operator_report_parking"
    assert [] = live_owner_rows(repo, work_request.id)
  end

  test "create_work_request owns by default and hands off with own: false", %{repo: repo} do
    args = %{"repo" => "nextide/demo", "base_branch" => "main", "title" => "Owned", "request_kind" => "feature", "description" => "x"}

    owned = mcp_tool(repo, "t1", "create_work_request", args, config: local_mcp_config(repo))
    assert %{"address" => "testbox/t1"} = get_in(owned, ["result", "structuredContent", "worked_on"])

    handed = mcp_tool(repo, "t1", "create_work_request", Map.merge(args, %{"title" => "Handed", "own" => false}), config: local_mcp_config(repo))
    handed_id = get_in(handed, ["result", "structuredContent", "work_request", "id"])
    assert get_in(handed, ["result", "structuredContent", "next_action"]) =~ "architect"
    assert [] = live_owner_rows(repo, handed_id)
  end

  test "chief labels attribute new WorkRequests", %{repo: repo} do
    args = %{"repo" => "nextide/demo", "base_branch" => "main", "title" => "From chief", "request_kind" => "feature", "description" => "x", "own" => false}
    response = mcp_tool(repo, "t3", "create_work_request", args, config: local_mcp_config(repo), labels: %{"sympp.role" => "chief", "sympp.domain" => "Kraken"})

    id = get_in(response, ["result", "structuredContent", "work_request", "id"])
    assert %{"kind" => "chief", "domain" => "Kraken"} = repo.get!(WorkRequest, id).dispatched_by
  end

  test "health reports the caller's terminal and what it owns", %{repo: repo, work_request: work_request} do
    own!(repo, work_request.id, "t1")

    caller = get_in(mcp_tool(repo, "t1", "sympp.health", %{}), ["result", "structuredContent", "caller"])
    assert %{"access" => "write", "terminal" => "testbox/t1", "owns" => [%{"work_request_id" => id}]} = caller
    assert id == work_request.id

    assert %{"access" => "read_only"} = get_in(mcp_tool(repo, nil, "sympp.health", %{}), ["result", "structuredContent", "caller"])
  end

  test "archiving a WorkRequest ends its ownership", %{repo: repo, work_request: work_request} do
    own!(repo, work_request.id, "t1")
    Ownership.end_subject(repo, "work_request", work_request.id)
    assert [] = live_owner_rows(repo, work_request.id)
  end

  test "the factory core view never treats an unseen or unreachable terminal as finished" do
    Application.put_env(:symphony_elixir, :sympp_herdr_core, nil)
    assert HerdrCore.view("any-core", "t1") == :unknown

    factory_core(%{})
    assert HerdrCore.view("another-core", "t1") == :unseen
    assert HerdrCore.view(MCPHarness.test_core_id(), "t1") == :finished
  end
end
