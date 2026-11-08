Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery

  test "sync_pr ends a ready package only on a verified merge", %{repo: repo} do
    original_client = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, SymphonyElixir.FakeGitHubClient)
    SymphonyElixir.FakeGitHubClient.clear()

    on_exit(fn ->
      SymphonyElixir.FakeGitHubClient.clear()

      case original_client do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        client -> Application.put_env(:symphony_elixir, :sympp_github_client, client)
      end
    end)

    work_request = create_work_request!(repo, repo: "nextide/repo", base_branch: "main")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-READY-SYNC-MERGED",
                 work_request_id: work_request.id,
                 kind: "standard_pr",
                 repo: "nextide/repo",
                 base_branch: "main",
                 status: "ready"
               )
             )

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "fix/ready-sync", head_sha: "head-a"}
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/27", repository: "nextide/repo", number: 27, head_sha: "head-a"}
             })

    assert {:ok, initial_events} = PlanningRepository.list_progress_events(repo, package.id)

    SymphonyElixir.FakeGitHubClient.put_response(
      "nextide/repo",
      27,
      SymphonyElixir.GitHubPullRequestFixtures.metadata(27, "head-a", merged?: false)
    )

    open_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-open",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"work_package_id" => package.id, "url" => "https://github.com/nextide/repo/pull/27"}
          }
        },
        repo: repo,
        terminal: "t1"
      )

    # An open PR refreshes the snapshot but never ends the package.
    assert get_in(open_response, ["result", "structuredContent", "work_package", "status"]) == "ready"
    assert {:ok, synced_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert length(synced_events) > length(initial_events)
    assert repo.get!(WorkPackage, package.id).status == "ready"

    SymphonyElixir.FakeGitHubClient.put_response(
      "nextide/repo",
      27,
      SymphonyElixir.GitHubPullRequestFixtures.metadata(27, "head-a", merged?: true)
    )

    merged_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-merged",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"work_package_id" => package.id, "url" => "https://github.com/nextide/repo/pull/27"}
          }
        },
        repo: repo,
        terminal: "t1"
      )

    assert get_in(merged_response, ["result", "structuredContent", "work_package", "status"]) == "ended"
    assert get_in(merged_response, ["result", "structuredContent", "pr_sync", "status"]) == "merged"
    assert [%{outcome: "pr_merged"}] = repo.all(from(delivery in WorkPackageDelivery, where: delivery.work_package_id == ^package.id))
  end
end
