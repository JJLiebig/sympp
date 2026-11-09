Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.DeliveryReconcile01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch

  test "reads redact historical credential-bearing request and delivery scope", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-LOCAL-READ",
        title: "Local ghp_localreadsecret discovery",
        repo: "https://example.test/repo?token=ghp_localreadsecret",
        base_branch: "feature/raw-secret-localreadbranch",
        human_description: "Do not expose Bearer localreadsecretvalue."
      )

    _other_status =
      create_work_request!(
        repo,
        id: "WR-MCP-LOCAL-READ-DRAFT",
        repo: work_request.repo,
        base_branch: work_request.base_branch
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-LOCAL-READ",
                 base_branch: work_request.base_branch
               )
             )

    local_server = local_mcp_server(local_mcp_config(repo), "local-work-request-read-state")

    {list_response, list_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-list-work-requests",
          "method" => "tools/call",
          "params" => %{"name" => "list_work_requests", "arguments" => %{"phase" => "planned"}}
        },
        local_server
      )

    list_payload = get_in(list_response, ["result", "structuredContent"])
    assert list_payload["filters"] == %{"phase" => "planned"}
    assert list_payload["total_count"] == 1
    assert [%{"id" => "WR-MCP-LOCAL-READ", "title" => listed_title} = listed] = list_payload["work_requests"]
    assert listed_title == "Local [REDACTED] discovery"
    assert listed["repo"] == "https://example.test/repo?token=[REDACTED]"
    assert listed["base_branch"] == "feature/[REDACTED]"
    refute inspect(list_response) =~ "ghp_localreadsecret"
    refute inspect(list_response) =~ "localreadsecretvalue"
    refute inspect(list_response) =~ "raw-secret-localreadbranch"

    {read_response, read_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-read-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"detail" => "full", "work_request_id" => work_request.id}}
        },
        list_server
      )

    assert get_in(read_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id
    assert get_in(read_response, ["result", "structuredContent", "work_packages", Access.at(0), "id"]) == work_package.id

    assert get_in(read_response, ["result", "structuredContent", "scope"]) == %{
             "repo" => "https://example.test/repo?token=[REDACTED]",
             "base_branch" => "feature/[REDACTED]"
           }

    refute inspect(read_response) =~ "ghp_localreadsecret"
    refute inspect(read_response) =~ "localreadsecretvalue"
    refute inspect(read_response) =~ "raw-secret-localreadbranch"

    board_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-read-delivery-board",
          "method" => "tools/call",
          "params" => %{
            "name" => "read_work_request",
            "arguments" => %{"work_request_id" => work_request.id, "view" => "board"}
          }
        },
        read_server
      )

    assert get_in(board_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id
    assert get_in(board_response, ["result", "structuredContent", "delivery_board", "work_packages", Access.at(0), "id"]) == work_package.id

    assert get_in(board_response, ["result", "structuredContent", "scope"]) == %{
             "repo" => "https://example.test/repo?token=[REDACTED]",
             "base_branch" => "feature/[REDACTED]"
           }

    refute inspect(board_response) =~ "ghp_localreadsecret"
    refute inspect(board_response) =~ "localreadsecretvalue"
    refute inspect(board_response) =~ "raw-secret-localreadbranch"
  end

  test "dispatch redacts secrets from its response and the worker's assignment", %{repo: repo} do
    repo_path = TestSupport.git_repo_with_origin_fixture!("https://github.com/nextide/repo.git", prefix: "sympp-architect-handoff")
    anchor = %{repo: repo_path, base_branch: "symphony-plus-plus/beta"}

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DISPATCH",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        human_description: "Do not return raw_secret_value."
      )

    secret_title_token = "raw_secret_bootstrap_title"

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-WR-SLICE-DISPATCH",
                 title: "Dispatch #{secret_title_token}",
                 base_branch: anchor.base_branch,
                 goal: "Dispatch without leaking raw_secret_value.",
                 allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"]
               )
             )

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    live_database_path = current_main_database_path(repo)
    configured_database = sqlite_file_uri(live_database_path, "mode=rwc&cache=shared")

    response =
      mcp_tool(
        repo,
        "t1",
        "dispatch_work_package",
        %{"review_mode" => "fast", "work_request_id" => work_request.id, "work_package_id" => approved_slice.id},
        config: Config.default(repo: repo, database: configured_database)
      )

    payload = get_in(response, ["result", "structuredContent"])
    assert payload["work_package"]["id"] == approved_slice.id
    assert payload["work_package"]["status"] == "dispatched"
    assert payload["work_package"]["review_mode"] == "fast"

    # The worker reads this assignment from the file dispatch writes.
    assert {:ok, assignment} = WorkPackageDispatch.assignment(repo, repo.get!(WorkPackage, approved_slice.id))
    assert assignment["work_package"]["id"] == approved_slice.id
    assert assignment["work_package"]["allowed_file_globs"] == work_package.allowed_file_globs
    assert assignment["work_package"]["acceptance_criteria"] == work_package.acceptance_criteria
    assert assignment["work_package"]["validation_steps"] == work_package.validation_steps
    assert assignment["parent_work_request"]["id"] == work_request.id
    refute Map.has_key?(assignment, "claim")
    serialized_response = inspect(response) <> inspect(assignment)
    refute serialized_response =~ "raw_secret_value"
    refute serialized_response =~ "secret_hash"
    refute serialized_response =~ secret_title_token
    refute serialized_response =~ "run_mcp_command"
    refute serialized_response =~ "local-private-file"
    refute serialized_response =~ ".secret"

    assert {:ok, persisted_slice} = WorkRequestRepository.get_work_package(repo, work_request.id, approved_slice.id)
    assert persisted_slice.status == "dispatched"
    assert persisted_slice.id == payload["work_package"]["id"]
  end

  test "dispatch uses configured storage", %{repo: repo} do
    anchor = %{repo: "nextide/symphony-plus-plus", base_branch: "symphony-plus-plus/beta"}

    in_scope =
      create_work_request!(repo,
        id: "WR-MCP-WR-DISPATCH-GUARD",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, _work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               in_scope.id,
               work_request_work_package_attrs(id: "WRS-MCP-WR-DISPATCH-PLANNED", base_branch: anchor.base_branch)
             )

    assert {:ok, live_database_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               in_scope.id,
               work_request_work_package_attrs(id: "WRS-MCP-WR-DISPATCH-LIVE-DATABASE", base_branch: anchor.base_branch)
             )

    assert {:ok, approved_live_database_slice} =
             CanonicalWorkPackageFixtures.approve_work_package(repo, in_scope.id, live_database_slice.id, "planned")

    live_database = current_main_database_path(repo)
    configured_live_database = sqlite_file_uri(live_database, "mode=rwc&cache=shared")
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    live_database_response =
      try do
        Application.put_env(:symphony_elixir, :sympp_repo_database, configured_live_database)

        mcp_tool(repo, "t1", "dispatch_work_package", %{
          "review_mode" => "none",
          "work_request_id" => in_scope.id,
          "work_package_id" => approved_live_database_slice.id
        })
      after
        restore_app_env(:sympp_repo_database, original_database)
      end

    live_database_payload = get_in(live_database_response, ["result", "structuredContent"])
    assert live_database_payload["work_package"]["status"] == "dispatched"
    assert repo.get!(WorkPackage, approved_live_database_slice.id).review_mode == "none"

    assert {:ok, blank_database_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               in_scope.id,
               work_request_work_package_attrs(id: "WRS-MCP-WR-DISPATCH-BLANK-DATABASE", base_branch: anchor.base_branch)
             )

    assert {:ok, approved_blank_database_slice} =
             CanonicalWorkPackageFixtures.approve_work_package(repo, in_scope.id, blank_database_slice.id, "planned")

    blank_database_response =
      mcp_tool(
        repo,
        "t1",
        "dispatch_work_package",
        %{"review_mode" => "none", "work_request_id" => in_scope.id, "work_package_id" => approved_blank_database_slice.id},
        config: Config.default(repo: repo, repo_root: test_repo_root(), database: "   ")
      )

    blank_database_payload = get_in(blank_database_response, ["result", "structuredContent"])
    assert blank_database_payload["work_package"]["status"] == "dispatched"
  end
end
