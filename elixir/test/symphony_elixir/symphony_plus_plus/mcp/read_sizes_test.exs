Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ReadSizesTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestPayloads
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: RequestRepository

  test "large delivery reads retain full detail with a usable compact default", %{repo: repo} do
    request =
      create_work_request!(repo,
        id: "wr_read_sizes_fixture",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta",
        title: "Native delivery cockpit",
        human_description: description(),
        desired_dispatch_shape: "architect_led_feature_branch"
      )

    architect = "t1"

    packages =
      for index <- 1..28 do
        assert {:ok, package} =
                 CanonicalWorkPackageFixtures.add_work_package(
                   repo,
                   request.id,
                   work_request_work_package_attrs(
                     id: "wp_00000000000000#{String.pad_leading(to_string(index), 2, "0")}",
                     title: "Native delivery surface #{index}",
                     goal: description(),
                     acceptance_criteria: acceptance(),
                     validation_steps: ["Run the owning MCP tests with a disposable ledger.", "Verify the candidate head and complete fast review."],
                     stop_conditions: ["Ask the parent before changing the delivery contract or runtime defaults."],
                     review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "fast"}}
                   )
                 )

        package
      end

    for index <- 1..16 do
      assert {:ok, _decision} =
               RequestRepository.record_decision(
                 repo,
                 request.id,
                 work_request_decision_attrs(
                   id: "decision_fixture_#{index}",
                   decision: "Decision #{index}: keep native delivery on the shared ledger. " <> description(),
                   rationale: "The operator needs current evidence, explicit ownership and reliable next actions.",
                   scope_impact: "Keep the installed runtime separate from candidate verification."
                 )
               )
    end

    assert {:ok, _question} = RequestRepository.ask_question(repo, request.id, work_request_question_attrs([]))

    package = repo.update!(Ecto.Changeset.change(hd(packages), status: "dispatched"))

    for index <- 1..12 do
      response =
        mcp_tool(repo, architect, "append_progress", %{
          "work_package_id" => package.id,
          "summary" => "Validation checkpoint #{index}",
          "body" => description(),
          "idempotency_key" => "fixture-progress-#{index}"
        })

      refute response["error"]
    end

    reads = [
      {"overview", "read_work_request", %{"work_request_id" => request.id}},
      {"list", "list_work_requests", %{}},
      {"plan", "read_work_request", %{"work_request_id" => request.id, "view" => "plan"}},
      {"package", "read_work_request", %{"work_request_id" => request.id, "view" => "package", "work_package_id" => package.id}},
      {"board", "read_work_request", %{"work_request_id" => request.id, "view" => "board"}}
    ]

    sizes =
      for {label, name, arguments} <- reads do
        response = mcp_tool(repo, nil, name, arguments)
        refute response["error"], inspect(response["error"])
        result = response["result"]

        full =
          if label in ~w(overview plan package) do
            full_response = mcp_tool(repo, nil, name, Map.put(arguments, "detail", "full"))
            refute full_response["error"]
            full_response["result"]
          else
            result
          end

        %{
          tool: label,
          after: measure(result),
          before: measure(full)
        }
      end

    IO.puts("READ_SIZES=" <> Jason.encode!(sizes))

    summary_result = mcp_tool(repo, architect, "read_work_request", %{"work_request_id" => request.id})["result"]
    assert String.length(Jason.encode!(summary_result)) < 8_000
    summary = summary_result["structuredContent"]
    assert String.length(Jason.encode!(summary)) < 8_000
    assert summary["work_request"]["human_description"] == description()
    assert summary["work_request"]["phase"] == "active"
    assert length(summary["work_packages"]) == 28
    assert hd(summary["work_packages"])["next_action"] == "wait"
    assert List.last(summary["work_packages"])["next_action"] == "dispatch_work_package"
    refute Map.has_key?(hd(summary["work_packages"]), "goal")
    assert length(summary["clarification_questions"]) == 1
    assert Enum.map(summary["decision_log_entries"], & &1["sequence"]) == Enum.to_list(12..16)
    assert summary["omitted"] == %{"package_contracts" => 28, "resolved_questions" => 0, "older_decisions" => 11, "decision_details" => 16}
    assert {:ok, original} = WorkRequestPayloads.work_request_detail(repo, request, [])
    full = mcp_tool(repo, architect, "read_work_request", %{"work_request_id" => request.id, "detail" => "full"})["result"]["structuredContent"]
    assert Map.delete(full, "scope") == original

    local =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "local-summary", "method" => "tools/call", "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => request.id}}},
        local_mcp_server(local_mcp_config(repo), "read-sizes-local")
      )

    assert local["result"]["structuredContent"]["work_packages"] == summary["work_packages"]

    plan = mcp_tool(repo, architect, "read_work_request", %{"work_request_id" => request.id, "view" => "plan"})["result"]["structuredContent"]
    full_plan = mcp_tool(repo, architect, "read_work_request", %{"work_request_id" => request.id, "view" => "plan", "detail" => "full"})["result"]["structuredContent"]
    assert plan["plan"]["execution_graph"] == full_plan["plan"]["execution_graph"]
    assert length(plan["plan"]["work_packages"]) == 28
    assert full_plan["plan"]["work_packages"] |> hd() |> Map.has_key?("operational_state")
    refute plan["plan"]["work_packages"] |> hd() |> Map.has_key?("operational_state")

    for {label, tool, arguments} <- reads, label in ~w(overview plan package) do
      invalid = mcp_tool(repo, nil, tool, Map.put(arguments, "detail", "invalid"))
      assert get_in(invalid, ["error", "data", "reason"]) == "invalid_detail"
    end

    # Existing delivery evidence must still drive the architect's next action.
    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{type: "pr", source_tool: "sync_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/123", head_sha: "abc123"}
             })

    repo.update!(Ecto.Changeset.change(Enum.at(packages, 1), status: "ended"))
    changed = mcp_tool(repo, architect, "read_work_request", %{"work_request_id" => request.id})["result"]["structuredContent"]
    assert hd(changed["work_packages"])["pr_url"] == "https://github.com/nextide/symphony-plus-plus/pull/123"
    assert Enum.at(changed["work_packages"], 1)["next_action"] == "reconcile_work_request"
    repo.update!(Ecto.Changeset.change(Enum.at(packages, 1), status: "dispatched"))

    assert {:ok, _delivery} =
             CanonicalWorkPackageFixtures.end_work_package(repo, request.id, Enum.at(packages, 1).id, %{
               outcome: "pr_merged",
               idempotency_key: "fixture-merged",
               recorded_by: "fixture-architect",
               pr_url: "https://github.com/nextide/symphony-plus-plus/pull/124",
               pr_number: 124,
               pr_repository: request.repo,
               pr_merged_at: DateTime.utc_now(:microsecond),
               merge_commit_sha: "merged124"
             })

    delivered = mcp_tool(repo, architect, "read_work_request", %{"work_request_id" => request.id})["result"]["structuredContent"]
    assert Enum.at(delivered["work_packages"], 1)["next_action"] == "none"
    assert Enum.at(delivered["work_packages"], 1)["pr_url"] == "https://github.com/nextide/symphony-plus-plus/pull/124"
  end

  defp measure(result) do
    %{
      structured: result["structuredContent"] |> Jason.encode!() |> String.length(),
      text: result["content"] |> hd() |> Map.fetch!("text") |> String.length(),
      result: result |> Jason.encode!() |> String.length()
    }
  end

  defp description do
    "The human overseer needs to see current ownership, dependencies, reviews and delivery progress in the native cockpit. " <>
      "Use the same ledger as the web board and preserve upstream behavior. Candidate verification must use disposable homes and databases. " <>
      "Show active workers, waiting reasons, pull requests and the next action without requiring transcript inspection. " <>
      "Keep full contracts and evidence available for the owning worker, while ordinary architecture reads summarize the current delivery state. " <>
      "A completed source change does not qualify installed runtimes or live external providers. Record exact tested revisions and outstanding limits."
  end

  defp acceptance do
    [
      "The operator can identify active, waiting and completed packages using current ledger evidence.",
      "The worker receives the complete allowed scope, acceptance outcomes, validation and stopping conditions.",
      "Architecture reads preserve request identity, open questions, decisions, PR presence and next actions.",
      "No production ledger, installed plugin cache, provider credentials or live terminal session is changed."
    ]
  end
end
