Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.DeliveryReconcile02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle

  @moduletag :ci_slow

  test "dispatch refuses packages outside a WorkRequest", %{repo: repo} do
    assert {:ok, unlinked_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-WORKTREE-UNLINKED", kind: "mcp", base_branch: "main")
             )

    response =
      mcp_tool(repo, "t1", "dispatch_work_package", %{
        "work_package_id" => unlinked_package.id,
        "review_mode" => "none",
        "target_repo_root" => test_repo_root()
      })

    assert get_in(response, ["error", "code"]) == -32_004
    assert get_in(response, ["error", "data", "code"]) == "not_found"
  end

  test "dispatch prepares from the package delivery base and reports a divergent package branch", %{repo: repo} do
    delivery_base = "feature/kraken-batch-service-redesign"
    fixture = TestSupport.git_repo_fixture!(delivery_base, prefix: "sympp-mcp-delivery-base-worktree")
    config = Config.default(repo: repo, repo_root: test_repo_root())

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-DELIVERY-BASE",
        repo: fixture.origin,
        base_branch: "symphony-plus-plus/beta"
      )

    package =
      planned_package!(repo, work_request,
        id: "WRS-MCP-WORKTREE-DELIVERY-BASE",
        title: "Prepare delivery-base worktree",
        base_branch: delivery_base,
        branch_pattern: "feat/delivery-base-worktree"
      )

    prepared = hand_off(repo, package, %{"target_repo_root" => fixture.repo_root}, config)
    assert prepared["worktree"]["base_branch"] == delivery_base
    assert prepared["worktree"]["branch"] == "feat/delivery-base-worktree"
    assert File.dir?(prepared["worktree"]["path"])
    assert comparable_path(repo.get!(WorkPackage, package.id).worktree_target_repo_root) == comparable_path(fixture.repo_root)

    assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id)
    refute File.exists?(prepared["worktree"]["path"])

    assert {:ok, package} = WorkPackageRepository.update(repo, package.id, %{branch_pattern: nil})
    assert {:ok, default_branch} = WorktreeScope.prepare_branch(package)
    TestSupport.git_output!(fixture.repo_root, ["checkout", "-b", default_branch, "origin/#{delivery_base}"])
    File.write!(Path.join(fixture.repo_root, "stale-branch.txt"), "stale\n")
    TestSupport.git_output!(fixture.repo_root, ["add", "stale-branch.txt"])
    TestSupport.git_output!(fixture.repo_root, ["commit", "-m", "Stale branch"])
    TestSupport.git_output!(fixture.repo_root, ["checkout", delivery_base])

    stale = hand_off(repo, package, %{"target_repo_root" => fixture.repo_root}, config)
    assert stale["work_package"]["status"] == "dispatched"
    assert stale["error"]["reason"] == "stale_existing_branch"
    assert stale["error"]["branch"] == default_branch
    assert stale["error"]["existing_revision"] == fixture.repo_root |> TestSupport.git_output!(["rev-parse", default_branch]) |> String.trim()
    assert stale["error"]["base_ref"] == "origin/#{delivery_base}"
    assert stale["error"]["remediation"] =~ "Remove or rename that branch"

    TestSupport.git_output!(fixture.repo_root, ["branch", "-D", default_branch])
    retried = hand_off(repo, package, %{"target_repo_root" => fixture.repo_root}, config)
    assert retried["worktree"]["branch"] == default_branch

    assert {:ok, other_branch} = WorktreeScope.prepare_branch(%{package | id: "#{package.id}-OTHER"})
    refute other_branch == default_branch
    assert {:ok, spaced_branch} = WorktreeScope.prepare_branch(%{package | id: "foo bar"})
    assert {:ok, dashed_branch} = WorktreeScope.prepare_branch(%{package | id: "foo-bar"})
    refute spaced_branch == dashed_branch

    assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id)
  end

  test "dispatch fills templated branch patterns uniquely per package", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-template-worktree")
    config = Config.default(repo: repo, repo_root: test_repo_root())
    work_request = create_work_request!(repo, id: "WR-MCP-WORKTREE-TEMPLATE", repo: fixture.origin, base_branch: "symphony-plus-plus/beta")

    package =
      planned_package!(repo, work_request,
        id: "WRS-MCP-WORKTREE-TEMPLATE",
        title: "Prepare templated branch worktree",
        base_branch: "symphony-plus-plus/beta",
        branch_pattern: "agent/{{work_package_id}}/{{slug}}"
      )

    prepared = hand_off(repo, package, %{"target_repo_root" => fixture.repo_root}, config)
    assert {:ok, derived_branch} = WorktreeScope.prepare_branch(package)
    assert prepared["worktree"]["branch"] == derived_branch
    assert :ok = WorktreeScope.require_local_branch_pattern_scope(package, derived_branch, prepared_worktree?: true)

    assert {:error, :branch_scope_mismatch} =
             WorktreeScope.require_local_branch_pattern_scope(package, "feat/out-of-template", prepared_worktree?: true)

    shared_template = %{package | branch_pattern: "agent/{{phase_id}}", phase_id: "shared-phase"}
    assert {:ok, shared_branch} = WorktreeScope.prepare_branch(shared_template)
    assert {:ok, other_shared_branch} = WorktreeScope.prepare_branch(%{shared_template | id: "#{package.id}-OTHER"})
    refute shared_branch == other_shared_branch

    assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id)
  end

  test "dispatch refuses a checkout whose origin belongs to another owner of the same name", %{repo: repo} do
    target_repo_root = TestSupport.git_repo_with_origin_fixture!("https://github.com/acme/frontend.git", prefix: "sympp-mcp-bare-scope-target")
    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    work_request = create_work_request!(repo, id: "WR-MCP-WORKTREE-BARE-REPO", repo: "frontend", base_branch: "symphony-plus-plus/beta")

    package =
      planned_package!(repo, work_request,
        id: "WRS-MCP-WORKTREE-BARE-REPO",
        title: "Prepare owner-scoped worktree",
        base_branch: "symphony-plus-plus/beta",
        branch_pattern: "feat/bare-repo-worktree"
      )

    try do
      Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["JJLiebig/frontend"])
      refused = hand_off(repo, package, %{"target_repo_root" => target_repo_root}, Config.default(repo: repo))
      assert refused["error"]["reason"] == "target_repo_root_scope_mismatch"
      assert refused["work_package"]["status"] == "dispatched"
    after
      restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes)
    end
  end

  test "dispatch accepts an explicit checkout with an owner-qualified origin regardless of the host checkout", %{repo: repo} do
    fixture =
      "symphony-plus-plus/beta"
      |> TestSupport.git_repo_fixture!(prefix: "sympp-mcp-bare-host-conflict-worktree")
      |> set_relative_owner_origin!("acme/frontend")

    target_repo_root = Path.join(fixture.root, "frontend")
    File.rename!(fixture.repo_root, target_repo_root)
    host_repo_root = Path.join(fixture.root, "sympp")
    File.mkdir_p!(host_repo_root)
    config = Config.default(repo: repo, repo_root: host_repo_root)
    work_request = create_work_request!(repo, id: "WR-MCP-WORKTREE-HOST-CONFLICT", repo: "frontend", base_branch: "symphony-plus-plus/beta")

    package =
      planned_package!(repo, work_request,
        id: "WRS-MCP-WORKTREE-HOST-CONFLICT",
        title: "Prepare bare repo target",
        base_branch: "symphony-plus-plus/beta",
        branch_pattern: "feat/bare-host-conflict-worktree"
      )

    host_checkout = hand_off(repo, package, %{"target_repo_root" => host_repo_root}, config)
    assert host_checkout["error"]["reason"] == "target_repo_root_scope_mismatch"
    assert host_checkout["error"]["expected_repo"] == work_request.repo
    assert host_checkout["error"]["target_repo_root"] == host_repo_root
    assert host_checkout["error"]["recovery"] =~ "Pass target_repo_root"

    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    try do
      Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["other/frontend"])
      conflicting = hand_off(repo, package, %{"target_repo_root" => target_repo_root}, config)
      assert conflicting["error"]["reason"] == "target_repo_root_scope_mismatch"
    after
      restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes)
    end

    assert hand_off(repo, package, %{"target_repo_root" => target_repo_root}, config)["worktree"]["path"]
    assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id)

    other_owner_config = Config.default(repo: repo, repo_root: Path.join(fixture.root, "other-symphony-plus-plus"))
    assert hand_off(repo, package, %{"target_repo_root" => target_repo_root}, other_owner_config)["worktree"]["path"]
  end

  defp planned_package!(repo, work_request, attrs) do
    attrs =
      attrs
      |> Keyword.merge(
        allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_packages/**"],
        acceptance_criteria: ["Prepare the package worktree."]
      )
      |> work_request_work_package_attrs()

    assert {:ok, package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, attrs)
    package
  end

  defp hand_off(repo, package, arguments, config) do
    arguments = Map.merge(%{"work_request_id" => package.work_request_id, "work_package_id" => package.id, "review_mode" => "none"}, arguments)
    response = mcp_tool(repo, "t1", "dispatch_work_package", arguments, config: config)
    get_in(response, ["result", "structuredContent"]) || flunk(inspect(response))
  end
end
