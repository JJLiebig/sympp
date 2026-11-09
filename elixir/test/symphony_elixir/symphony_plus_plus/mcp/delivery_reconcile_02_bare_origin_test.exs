Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.DeliveryReconcile02BareOriginTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle

  @moduletag :ci_slow

  test "dispatch finds a bare-named repo's checkout by its owner-qualified origin", %{repo: repo} do
    fixture =
      "symphony-plus-plus/beta"
      |> TestSupport.git_repo_fixture!(prefix: "sympp-mcp-bare-origin-worktree")
      |> set_relative_owner_origin!("JJLiebig/sympp")

    config = Config.default(repo: repo, repo_root: fixture.repo_root)
    work_request = create_work_request!(repo, id: "WR-MCP-WORKTREE-BARE-ORIGIN", repo: "sympp", base_branch: "symphony-plus-plus/beta")

    assert {:ok, package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-WORKTREE-BARE-ORIGIN",
                 title: "Prepare bare repo target origin worktree",
                 base_branch: "symphony-plus-plus/beta",
                 branch_pattern: "feat/bare-origin-worktree",
                 allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Accept unambiguous owner-qualified target origin."]
               )
             )

    dispatch = fn ->
      mcp_tool(repo, "t1", "dispatch_work_package", %{"work_request_id" => work_request.id, "work_package_id" => package.id, "review_mode" => "none"}, config: config)
      |> get_in(["result", "structuredContent", "worktree", "path"])
    end

    path = dispatch.()
    assert File.dir?(path)
    assert comparable_path(repo.get!(WorkPackage, package.id).worktree_target_repo_root) == comparable_path(fixture.repo_root)

    assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id)
    assert {:ok, %{worktree_path: nil}} = WorkPackageRepository.get(repo, package.id)
    refute File.exists?(path)

    replayed = dispatch.()
    assert File.dir?(replayed)

    assert {:ok, _package} = WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: nil})
    File.rm_rf!(replayed)

    assert {:ok, %{status: "stale_record_cleared"}} = WorktreeLifecycle.cleanup(repo, package.id)
    assert {:ok, %{worktree_path: nil}} = WorkPackageRepository.get(repo, package.id)
  end
end
