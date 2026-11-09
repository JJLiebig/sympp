Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.AskToolsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry

  @prompt %{
    "tl_dr" => "Pick a region",
    "details" => "Pricing differs by region.",
    "options" => [%{"id" => "eu", "label" => "Europe", "answer" => "Ship to Europe first."}, %{"id" => "us", "label" => "US", "answer" => "Ship to the US first."}]
  }

  test "any Herdr terminal asks; only the asker or the owner resolves, optionally with a decision", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-ASK-TOOLS")

    asked = mcp_tool(repo, "t3", "ask", %{"work_request_id" => work_request.id, "question" => "Which region first?", "decision_prompt" => @prompt})

    assert %{"state" => "open", "asked_by" => "testbox/t3", "question" => "Which region first?", "decision_prompt" => %{"tl_dr" => "Pick a region"}} =
             ask = get_in(asked, ["result", "structuredContent", "ask"])

    # Asking takes no ownership.
    assert Ownership.owner(repo, work_request.id) == nil

    refute mcp_tool(repo, "t1", "set_report", %{"work_request_id" => work_request.id, "brief" => "Planning"})["error"]

    stranger = mcp_tool(repo, "t2", "resolve_ask", %{"ask_id" => ask["id"], "to" => "answered", "answer" => "US"})
    assert %{"reason" => "not_asker_or_owner", "state" => "open"} = get_in(stranger, ["error", "data"])

    # A decision that fails validation rolls the answer back.
    bad_decision = %{"source_type" => "bot", "decision" => "Europe", "rationale" => "Cheaper", "scope_impact" => "None"}
    rejected = mcp_tool(repo, "t1", "resolve_ask", %{"ask_id" => ask["id"], "to" => "answered", "answer" => "Europe", "decision" => bad_decision})
    assert get_in(rejected, ["error", "data", "reason"]) == "invalid_decision"
    assert %Ask{state: "open", answer: nil} = repo.get!(Ask, ask["id"])
    assert repo.aggregate(DecisionLogEntry, :count) == 0

    decision = %{bad_decision | "source_type" => "human"}
    answered = mcp_tool(repo, "t3", "resolve_ask", %{"ask_id" => ask["id"], "to" => "answered", "answer" => "Europe, said in chat.", "decision" => decision})
    assert %{"state" => "answered", "answer" => "Europe, said in chat.", "answered_by" => "testbox/t3"} = get_in(answered, ["result", "structuredContent", "ask"])
    assert %{"source_id" => source_id, "decision" => "Europe"} = get_in(answered, ["result", "structuredContent", "decision_log_entry"])
    assert source_id == ask["id"]

    again = mcp_tool(repo, "t1", "resolve_ask", %{"ask_id" => ask["id"], "to" => "withdrawn"})
    assert %{"reason" => "ask_not_open", "state" => "answered"} = get_in(again, ["error", "data"])

    other = mcp_tool(repo, "t3", "ask", %{"work_request_id" => work_request.id, "question" => "Need a staging key?"})
    other_id = get_in(other, ["result", "structuredContent", "ask", "id"])
    missing_answer = mcp_tool(repo, "t1", "resolve_ask", %{"ask_id" => other_id, "to" => "answered"})
    assert get_in(missing_answer, ["error", "data", "reason"]) == "missing_answer"

    withdrawn = mcp_tool(repo, "t1", "resolve_ask", %{"ask_id" => other_id, "to" => "withdrawn"})
    assert %{"state" => "withdrawn", "answered_by" => "testbox/t1"} = get_in(withdrawn, ["result", "structuredContent", "ask"])

    read = mcp_tool(repo, nil, "read_work_request", %{"work_request_id" => work_request.id})
    assert get_in(read, ["result", "structuredContent", "asks"]) == []
  end

  test "asks need a Herdr terminal and a writable WorkRequest", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-ASK-ARCHIVED")

    outside = mcp_tool(repo, nil, "ask", %{"work_request_id" => work_request.id, "question" => "Anyone?"})
    assert get_in(outside, ["error", "data", "reason"]) == "read_only_outside_herdr"

    asked = mcp_tool(repo, "t3", "ask", %{"work_request_id" => work_request.id, "question" => "Before archive?"})
    ask_id = get_in(asked, ["result", "structuredContent", "ask", "id"])

    repo.update!(Ecto.Changeset.change(work_request, archived_at: DateTime.utc_now(:microsecond), archive_reason: "manual"))

    for {name, arguments} <- [
          {"ask", %{"work_request_id" => work_request.id, "question" => "After archive?"}},
          {"resolve_ask", %{"ask_id" => ask_id, "to" => "withdrawn"}}
        ] do
      refused = mcp_tool(repo, "t3", name, arguments)
      assert get_in(refused, ["error", "data", "reason"]) == "work_request_archived"
      assert get_in(refused, ["error", "data", "recovery", "next_action"]) == "restore"
    end

    assert get_in(mcp_tool(repo, "t3", "ask", %{"work_request_id" => "WR-MISSING", "question" => "?"}), ["error", "data", "reason"]) == "not_found"
  end

  test "an operator-completed WorkRequest takes no new asks", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-ASK-COMPLETED")
    repo.update!(Ecto.Changeset.change(work_request, operator_completed_at: DateTime.utc_now(:microsecond)))

    refused = mcp_tool(repo, "t3", "ask", %{"work_request_id" => work_request.id, "question" => "After completion?"})
    assert get_in(refused, ["error", "data", "reason"]) == "work_request_completed"
    assert get_in(refused, ["error", "data", "state"]) == "done"
  end
end
