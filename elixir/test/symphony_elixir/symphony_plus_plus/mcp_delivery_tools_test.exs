Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPDeliveryToolsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    schemas = [
      ProgressEvent,
      WorkPackageDelivery,
      WorkPackage,
      WorkedOn,
      WorkRequest,
      WorkPackage,
      Phase
    ]

    for schema <- schemas do
      repo.delete_all(schema)
    end

    :ok
  end

  test "an ended plan with abandoned scope reads as unresolved everywhere", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-CLOSED-EXECUTION")

    read = fn tool, args ->
      response = mcp_tool(repo, "t1", tool, args)
      assert response["error"] == nil
      get_in(response, ["result", "structuredContent"])
    end

    assert read.("read_work_request", %{"detail" => "full", "work_request_id" => work_request.id})["work_request"]["phase"] == "intake"

    packages =
      for index <- 1..25 do
        status = if index == 25, do: "planned", else: "dispatched"
        create_work_package!(repo, work_request, id: "WP-CLOSED-#{index}", status: status)
      end

    for {package, index} <- Enum.with_index(Enum.take(packages, 24), 1) do
      args =
        case index do
          2 ->
            abandoned_args(work_request, package, "close-#{index}", "The operator dropped this scope.")

          3 ->
            superseded_args(work_request, package, "close-#{index}", hd(packages).id, "Covered by the first package.")

          4 ->
            :merged

          _ ->
            no_pr_args(work_request, package, "close-#{index}", "Accepted investigation evidence.")
        end

      if args == :merged,
        do: record_merged!(repo, work_request, package, "close-#{index}"),
        else: read.("close_work_package", args)
    end

    assert read.("read_work_request", %{"detail" => "full", "work_request_id" => work_request.id})["work_request"]["phase"] == "planned"
    active = read.("read_work_request", %{"work_request_id" => work_request.id, "view" => "board"})["delivery_board"]["work_packages"] |> List.last()
    assert active["merge_eligibility"]["next_action"] == "dispatch_work_package"
    overview_packages = read.("read_work_request", %{"work_request_id" => work_request.id})["work_packages"]
    assert %{"next_action" => "dispatch_work_package"} = Enum.find(overview_packages, &(&1["id"] == active["id"]))

    read.("close_work_package", %{"work_package_id" => List.last(packages).id, "outcome" => "skipped"})

    for detail <- ["summary", "full"] do
      board = read.("read_work_request", %{"work_request_id" => work_request.id, "view" => "board", "detail" => detail})
      assert board["work_request"]["phase"] == "unresolved"
      assert length(board["delivery_board"]["work_packages"]) == 25
      assert Enum.all?(board["delivery_board"]["work_packages"], &is_nil(&1["merge_eligibility"]["next_action"]))
    end

    request = read.("read_work_request", %{"detail" => "full", "work_request_id" => work_request.id})["work_request"]
    assert request["phase"] == "unresolved"
    assert request["next_action"] == "complete_or_archive"
    listed = read.("list_work_requests", %{"phase" => "unresolved"})["work_requests"]
    assert Enum.map(listed, & &1["id"]) == [work_request.id]
    assert {:ok, native} = Dashboard.work_request_detail(repo, work_request.id)
    assert native.work_request.phase == "unresolved"
    assert native.work_request.completed_at == nil

    full = read.("read_work_request", %{"work_request_id" => work_request.id, "view" => "board", "detail" => "full"})
    assert get_in(full, ["delivery_board", "work_packages", Access.at(0), "delivery", "no_pr_evidence"]) == "Accepted investigation evidence."
  end

  test "any architect may finish another terminal's package, but only its owner records other endings", %{repo: repo} do
    {other_request, other_slice, other_package} = linked_slice!(repo, work_request_id: "WR-MCP-FINISH-OTHER", work_package_status: "ready")
    assert {:ok, _row, :acquired} = Ownership.acquire(repo, other_request.id, terminal("t2"))
    terminal = "t1"

    refused = record_delivery(repo, terminal, no_pr_args(other_request, other_slice, "finish-other-no-pr", "Not my request."))
    assert get_in(refused, ["error", "data", "code"]) == "owned_by_other_terminal"
    assert repo.get!(WorkPackage, other_package.id).status == "ready"

    finished =
      record_delivery(repo, terminal, %{"work_package_id" => other_slice.id, "outcome" => "finished"})

    assert get_in(finished, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "finished"
    assert repo.get!(WorkPackage, other_package.id).status == "ended"
    assert {:ok, %{phase: "done"}} = SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase.load_one(repo, repo.get!(WorkRequest, other_request.id))

    # Another architect repeating the same finish gets the same ending back.
    replay = record_delivery(repo, "t3", %{"work_package_id" => other_slice.id, "outcome" => "finished"})
    assert get_in(replay, ["result", "structuredContent", "work_package_delivery"]) == get_in(finished, ["result", "structuredContent", "work_package_delivery"])

    {_request, racing, _package} = linked_slice!(repo, work_request_id: "WR-MCP-FINISH-RACE", work_package_status: "ready")

    endings =
      for address <- ["t4", "t5", "t6"] do
        Task.async(fn -> record_delivery(repo, address, %{"work_package_id" => racing.id, "outcome" => "finished"}) end)
      end
      |> Task.await_many(30_000)
      |> Enum.map(&get_in(&1, ["result", "structuredContent", "work_package_delivery", "id"]))

    assert [id, id, id] = endings
    assert is_binary(id)

    conflict = record_delivery(repo, "t2", %{"work_package_id" => other_slice.id, "outcome" => "abandoned", "rationale" => "Dropped."})

    assert %{"code" => "delivery_outcome_conflict", "outcome" => "finished", "state" => "ended", "next_action" => "none"} =
             get_in(conflict, ["error", "data"])

    assert Ownership.owner(repo, other_request.id).display_address == "testbox/t2"
  end

  test "close_work_package replays idempotently and refuses a different close with the actual outcome", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-CLOSE")
    planned = create_work_package!(repo, work_request, id: "WP-MCP-CLOSE-PLANNED", status: "planned")
    {_request, dispatched, _package} = linked_slice!(repo, work_request_id: "WR-MCP-CLOSE-DISPATCHED")
    owner = "t1"

    early = record_delivery(repo, owner, %{"work_package_id" => dispatched.id, "outcome" => "skipped"})

    assert %{"code" => "ending_not_allowed", "state" => "dispatched", "allowed_outcomes" => allowed, "next_action" => next, "message" => _} =
             early["error"]["data"]

    assert "skipped" not in allowed and "abandoned" in allowed
    assert next == "wait"

    missing = record_delivery(repo, owner, %{"work_package_id" => dispatched.id, "outcome" => "abandoned"})
    assert %{"code" => "missing_rationale", "state" => "dispatched", "next_action" => "fix_arguments", "message" => "rationale is required."} = missing["error"]["data"]

    unused = record_delivery(repo, owner, %{"work_package_id" => planned.id, "outcome" => "skipped", "rationale" => "Not needed."})
    assert %{"code" => "argument_not_used", "arguments" => ["rationale"], "state" => "planned"} = unused["error"]["data"]

    skipped = record_delivery(repo, owner, %{"work_package_id" => planned.id, "outcome" => "skipped"})
    assert %{"outcome" => "skipped", "id" => delivery_id} = skipped["result"]["structuredContent"]["work_package_delivery"]
    assert skipped["result"]["structuredContent"]["work_package"]["status"] == "ended"

    replay = record_delivery(repo, owner, %{"work_package_id" => planned.id, "outcome" => "skipped"})
    assert replay["result"]["structuredContent"]["work_package_delivery"]["id"] == delivery_id

    conflict = record_delivery(repo, owner, %{"work_package_id" => planned.id, "outcome" => "abandoned", "rationale" => "Changed my mind."})
    assert conflict["error"]["code"] == -32_009
    assert %{"code" => "delivery_outcome_conflict", "outcome" => "skipped", "state" => "ended", "next_action" => "none"} = conflict["error"]["data"]
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
  end

  test "every tool error carries code, message, state and next_action", %{repo: repo} do
    for tool <- ToolCatalog.tools() do
      data = mcp_tool(repo, "t1", tool, %{"not_an_argument" => true}) |> get_in(["error", "data"])
      assert %{"code" => code, "message" => message, "state" => _state, "next_action" => next_action} = data, tool
      assert is_binary(code) and is_binary(message) and is_binary(next_action), tool
    end

    missing = mcp_tool(repo, "t1", "close_work_package", %{"work_package_id" => "WP-NOWHERE", "outcome" => "skipped"})
    assert %{"code" => "not_found", "state" => nil, "next_action" => "check_id"} = missing["error"]["data"]
  end

  test "architect reads the delivery board and records a redacted, replayable closeout", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-READ-CLOSE")

    terminal = "t1"

    board_response =
      mcp_tool(repo, terminal, "read_work_request", %{"view" => "board", "detail" => "full", "work_request_id" => work_request.id})

    board_payload = get_in(board_response, ["result", "structuredContent"])

    assert get_in(board_payload, ["delivery_board", "work_packages", Access.at(0), "work_package", "id"]) ==
             linked_package.id

    evidence_url = "https://example.invalid/delivery?token=placeholder"
    evidence_query_value = "placeholder"

    closeout_args =
      no_pr_args(
        work_request,
        work_package,
        "delivery-mcp-no-pr",
        "Operator confirmed #{evidence_url} completed without a PR."
      )

    closeout_response = record_delivery(repo, terminal, closeout_args)
    closeout_payload = get_in(closeout_response, ["result", "structuredContent"])

    assert closeout_payload["work_package_delivery"]["outcome"] == "completed_no_pr"
    refute Map.has_key?(closeout_payload["work_package_delivery"], "no_pr_evidence")
    refute inspect(closeout_response) =~ evidence_query_value

    read_closed_response =
      mcp_tool(repo, terminal, "read_work_request", %{"view" => "board", "detail" => "full", "work_request_id" => work_request.id})

    assert get_in(read_closed_response, [
             "result",
             "structuredContent",
             "delivery_board",
             "counts",
             "completed_no_pr"
           ]) == 1

    assert get_in(read_closed_response, [
             "result",
             "structuredContent",
             "delivery_board",
             "work_packages",
             Access.at(0),
             "operational_state",
             "key"
           ]) == "completed_no_pr"

    delivery_evidence_path = [
      "delivery_board",
      "work_packages",
      Access.at(0),
      "delivery",
      "no_pr_evidence"
    ]

    assert get_in(read_closed_response, ["result", "structuredContent" | delivery_evidence_path]) =~ "[REDACTED]"
    refute get_in(read_closed_response, ["result", "structuredContent" | delivery_evidence_path]) =~ evidence_query_value
    assert repo.get!(WorkPackage, linked_package.id).status == "ended"

    replay_response = record_delivery(repo, terminal, closeout_args)

    assert get_in(replay_response, ["result", "structuredContent", "work_package_delivery", "id"]) ==
             closeout_payload["work_package_delivery"]["id"]

    refute get_in(read_closed_response, ["result", "structuredContent" | delivery_evidence_path]) =~
             evidence_query_value

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
  end

  test "architect abandons a no-code failed dispatch after its replacement is delivered, leaving other packages alone",
       %{repo: repo} do
    {work_request, failed_slice, failed_package} =
      linked_slice!(repo,
        work_request_id: "WR-MCP-DELIVERY-ABANDON-FAILED-DISPATCH",
        work_package_status: "dispatched"
      )

    terminal = "t1"

    oracle_slice = create_work_package!(repo, work_request, id: "WRS-MCP-DELIVERY-ORACLE-ACTIVE")

    assert {:ok, approved_oracle} =
             CanonicalWorkPackageFixtures.approve_work_package(
               repo,
               work_request.id,
               oracle_slice.id,
               "planned"
             )

    oracle_package =
      create_matching_work_package!(repo, work_request, approved_oracle,
        id: "WP-MCP-DELIVERY-ORACLE-ACTIVE",
        status: "dispatched"
      )

    assert {:ok, _oracle_dispatch} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               approved_oracle.id,
               "approved",
               oracle_package.id
             )

    replacement_slice =
      create_work_package!(repo, work_request, id: "WRS-MCP-DELIVERY-REPLACEMENT")

    assert {:ok, approved_replacement} =
             CanonicalWorkPackageFixtures.approve_work_package(
               repo,
               work_request.id,
               replacement_slice.id,
               "planned"
             )

    replacement_package =
      create_matching_work_package!(repo, work_request, approved_replacement,
        id: "WP-MCP-DELIVERY-REPLACEMENT",
        status: "ready"
      )

    assert {:ok, dispatched_replacement} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               approved_replacement.id,
               "approved",
               replacement_package.id
             )

    assert %{outcome: "pr_merged"} = record_merged!(repo, work_request, dispatched_replacement, "delivery-mcp-replacement-pr")

    assert repo.get!(WorkPackage, replacement_package.id).status == "ended"

    abandon_response =
      record_delivery(
        repo,
        terminal,
        abandoned_args(
          work_request,
          failed_slice,
          "delivery-mcp-abandoned-failed-dispatch",
          "Wildcard branch dispatch failed before implementation; replacement slice already delivered."
        )
      )

    assert get_in(abandon_response, [
             "result",
             "structuredContent",
             "work_package_delivery",
             "outcome"
           ]) == "abandoned"

    assert repo.get!(WorkPackage, failed_package.id).status == "ended"
    assert repo.get!(WorkPackage, oracle_package.id).status == "dispatched"
  end

  defp linked_slice!(repo, overrides) do
    request_id = Keyword.fetch!(overrides, :work_request_id)
    work_package_status = Keyword.get(overrides, :work_package_status, "dispatched")
    work_request = create_work_request!(repo, id: request_id)
    work_package = create_work_package!(repo, work_request, id: "WRS-#{request_id}")

    assert {:ok, approved_slice} =
             CanonicalWorkPackageFixtures.approve_work_package(
               repo,
               work_request.id,
               work_package.id,
               "planned"
             )

    linked_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-#{request_id}",
        status: work_package_status
      )

    assert {:ok, dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               approved_slice.id,
               "approved",
               linked_package.id
             )

    {work_request, dispatched_slice, linked_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, work_request, overrides) do
    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(overrides)
             )

    work_package
  end

  defp create_matching_work_package!(repo, work_request, work_package, overrides) do
    attrs =
      [
        kind: work_package.kind,
        title: work_package.title,
        repo: work_request.repo,
        base_branch: work_package.base_branch,
        branch_pattern: work_package.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: work_package.allowed_file_globs,
        acceptance_criteria: work_package.acceptance_criteria
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp no_pr_args(_work_request, work_package, idempotency_key, evidence) do
    %{"work_package_id" => work_package.id, "outcome" => "completed_no_pr", "idempotency_key" => idempotency_key, "evidence" => evidence}
  end

  defp abandoned_args(_work_request, work_package, idempotency_key, rationale) do
    %{"work_package_id" => work_package.id, "outcome" => "abandoned", "idempotency_key" => idempotency_key, "rationale" => rationale}
  end

  defp superseded_args(_work_request, work_package, idempotency_key, successor_work_package_id, reason) do
    %{
      "work_package_id" => work_package.id,
      "outcome" => "superseded",
      "idempotency_key" => idempotency_key,
      "successor_work_package_id" => successor_work_package_id,
      "rationale" => reason
    }
  end

  # Merges are recorded from GitHub, never through close_work_package.
  defp record_merged!(repo, work_request, work_package, idempotency_key) do
    assert {:ok, delivery} =
             WorkRequestService.record_work_package_delivery(repo, work_request.id, work_package.id, %{
               "outcome" => "pr_merged",
               "idempotency_key" => idempotency_key,
               "pr_url" => "https://github.com/#{work_request.repo}/pull/24",
               "pr_number" => 24,
               "pr_repository" => work_request.repo,
               "pr_merged_at" => "2026-05-28T12:00:00Z",
               "merge_commit_sha" => "abc24"
             })

    delivery
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-MCP-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Expose delivery MCP tools",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Expose delivery-board and closeout through MCP.",
      constraints: %{
        "allowed_paths" => ["elixir/lib"],
        "forbidden_paths" => [],
        "requires_secret" => false
      },
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      id: "WRS-MCP-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Delivery MCP slice",
      goal: "Close delivered WorkPackages through MCP.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/mcp-delivery",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery MCP tools are scoped."],
      validation_steps: [
        "mix test test/symphony_elixir/symphony_plus_plus/mcp_delivery_tools_test.exs"
      ],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not expose broad package visibility."]
    }

    Enum.into(overrides, defaults)
  end

  defp record_delivery(repo, terminal, arguments),
    do: mcp_tool(repo, terminal, "close_work_package", arguments)

  defp terminal(address), do: Terminal.from_meta(MCPHarness.herdr_meta(address))

  defp mcp_tool(repo, terminal, name, arguments) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: Config.default(repo: repo, repo_root: test_repo_root()),
      terminal: terminal
    )
  end

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
  end
end
