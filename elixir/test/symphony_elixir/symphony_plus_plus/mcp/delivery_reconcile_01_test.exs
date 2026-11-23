Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.DeliveryReconcile01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.Toon

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
          "params" => %{
            "name" => "list_work_requests",
            "arguments" => %{"phase" => "planned", "repo" => work_request.repo}
          }
        },
        local_server
      )

    list_payload = get_in(list_response, ["result", "structuredContent"])
    redacted_repo = "https://example.test/repo?token=[REDACTED]"
    assert list_payload["filters"] == %{"phase" => "planned", "repo" => redacted_repo}
    assert get_in(list_response, ["result", "content", Access.at(0), "text"]) =~ ~s(  repo: "#{redacted_repo}")
    assert list_payload["total_count"] == 1
    assert [%{"id" => "WR-MCP-LOCAL-READ", "title" => listed_title} = listed] = list_payload["work_requests"]
    assert listed_title == "Local [REDACTED] discovery"
    assert listed["repo"] == redacted_repo
    refute Map.has_key?(listed, "base_branch")
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

    assert get_in(read_response, ["result", "structuredContent", "work_request", "repo"]) == "https://example.test/repo?token=[REDACTED]"
    assert_same_projection(read_response)

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

    assert_same_projection(board_response)

    refute inspect(board_response) =~ "ghp_localreadsecret"
    refute inspect(board_response) =~ "localreadsecretvalue"
    refute inspect(board_response) =~ "raw-secret-localreadbranch"

    brief_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-read-brief",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => work_request.id, "view" => "request"}}
        },
        read_server
      )

    assert get_in(brief_response, ["result", "structuredContent", "work_request", "base_branch"]) == "feature/[REDACTED]"
    assert_same_projection(brief_response)
    refute inspect(brief_response) =~ "localreadsecretvalue"
  end

  defp assert_same_projection(response) do
    assert %{"structuredContent" => payload, "content" => [%{"type" => "text", "text" => text}]} = response["result"]
    assert text == Toon.encode_json(payload)
  end
end
