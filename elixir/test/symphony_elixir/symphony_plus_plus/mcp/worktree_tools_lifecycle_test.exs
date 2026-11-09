Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeToolsLifecycleTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  @moduletag :ci_slow

  test "factory clones missing repositories beside owner siblings and serializes resolves" do
    alias SymphonyElixir.SymphonyPlusPlus.FactoryRepos
    fixture = TestSupport.git_repo_fixture!("beta", prefix: "sympp-factory-siblings")
    root = Path.join(fixture.root, "factory")
    sibling = Path.join([root, "group", "sibling"])
    File.mkdir_p!(Path.dirname(sibling))
    {_, 0} = System.cmd("git", ["clone", fixture.origin, sibling], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", sibling, "remote", "set-url", "origin", "git@github.com:example/sibling.git"])
    peer = Path.join(fixture.root, "ssh-peer.js")

    File.write!(peer, """
    const {spawnSync} = require("node:child_process");
    const result = spawnSync("git", ["upload-pack", #{Jason.encode!(fixture.origin)}], {stdio: "inherit"});
    process.exit(result.status ?? 1);
    """)

    node = System.find_executable("node")
    command = Enum.map_join([node, peer], " ", fn value -> "'" <> String.replace(value, "'", "'\"'\"'") <> "'" end)
    keys = ["SYMPP_REPOS_ROOT", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    System.put_env("SYMPP_REPOS_ROOT", root)
    System.put_env("GIT_SSH_COMMAND", command)
    System.put_env("GIT_SSH_VARIANT", "ssh")
    expected = Path.join([root, "group", "missing"])
    tasks = for _ <- 1..2, do: Task.async(fn -> FactoryRepos.resolve("git@github.com:example/missing.git") end)
    assert Enum.map(tasks, &Task.await(&1, 15_000)) == [{:ok, expected}, {:ok, expected}]
    refute File.exists?(Path.join(root, "missing"))
  end

  test "nested factory checkout is reused and owns prepare, replay and cleanup", %{repo: repo} do
    alias SymphonyElixir.SymphonyPlusPlus.FactoryRepos
    alias SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeScope
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle

    fixture = TestSupport.git_repo_fixture!("beta", prefix: "sympp-factory-repos")
    repos_root = Path.join(fixture.root, "factory")
    nested = Path.join([repos_root, "group", Path.basename(fixture.repo_root)])
    File.mkdir_p!(Path.dirname(nested))
    {_, 0} = System.cmd("git", ["-C", fixture.repo_root, "worktree", "add", "--detach", nested, "beta"], stderr_to_stdout: true)
    fixture = %{fixture | repo_root: nested}
    remote = "https://github.com/factory/#{Path.basename(fixture.repo_root)}.git"
    {_, 0} = System.cmd("git", ["-C", fixture.repo_root, "remote", "set-url", "origin", remote])
    previous = System.get_env("SYMPP_REPOS_ROOT")
    System.put_env("SYMPP_REPOS_ROOT", repos_root)

    on_exit(fn ->
      if previous, do: System.put_env("SYMPP_REPOS_ROOT", previous), else: System.delete_env("SYMPP_REPOS_ROOT")
    end)

    assert {:ok, checkout} = FactoryRepos.resolve(remote)
    assert checkout == fixture.repo_root

    name = Path.basename(checkout)
    ssh_remote = "ssh://deploy@git.example/team/#{name}.git"
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", "deploy@git.example:team/#{name}.git"])
    assert {:ok, ^checkout} = FactoryRepos.resolve("deploy@git.example:team/#{name}.git")
    refute FactoryRepos.matches?(checkout, ssh_remote)
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", ssh_remote])
    assert {:ok, ^checkout} = FactoryRepos.resolve(ssh_remote)
    refute FactoryRepos.matches?(checkout, String.replace_suffix(ssh_remote, ".git", ""))
    refute FactoryRepos.matches?(checkout, "ssh://other-user@git.example/team/#{name}.git")
    assert FactoryRepos.matches?(checkout, "ssh://deploy@git.example:22/team/#{name}.git")
    refute FactoryRepos.matches?(checkout, "ssh://deploy@git.example:443/team/#{name}.git")
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", "ssh://git@git.example/team/#{name}.git"])
    refute FactoryRepos.matches?(checkout, "ssh://git.example/team/#{name}.git")
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", "git.example:team/#{name}.git"])
    assert {:ok, ^checkout} = FactoryRepos.resolve("git.example:team/#{name}.git")
    refute FactoryRepos.matches?(checkout, "git@git.example:team/#{name}.git")
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", ssh_remote])
    assert {:error, :invalid_target_repo_root} = FactoryRepos.resolve("ssh://deploy:password@git.example/team/#{name}.git")

    http_remote = "https://alice@git.example/team/#{name}.git"
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", http_remote])
    assert FactoryRepos.matches?(checkout, "https://git.example/team/#{name}.git")
    refute FactoryRepos.matches?(checkout, "https://git.example:444/team/#{name}.git")

    for protocol <- ["http", "git"] do
      network_remote = "#{protocol}://git.example/team/#{name}.git"
      {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", network_remote])
      assert {:ok, ^checkout} = FactoryRepos.resolve(network_remote)
      refute FactoryRepos.matches?(checkout, "#{protocol}://git.example:443/team/#{name}.git")
    end

    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", remote])
    File.mkdir_p!(Path.join(repos_root, name))
    refute FactoryRepos.matches?(checkout, String.replace(remote, "/factory/", "/other/"))
    conflicting_remote = String.replace(remote, "/factory/", "/other/")
    conflicting_root = Path.join(repos_root, name)
    assert {:error, {:target_repo_root_scope_mismatch, ^conflicting_root}} = FactoryRepos.resolve(conflicting_remote)
    conflict_package = %SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage{repo: conflicting_remote}

    assert {:tool_error, "target_repo_root_scope_mismatch", details} =
             WorktreeScope.prepare_target_repo_root(nil, conflict_package, Config.default(repo: repo))

    assert details["expected_repo"] == conflicting_remote
    assert details["target_repo_root"] == conflicting_root
    assert details["recovery"] =~ "SYMPP_REPOS_ROOT"
    assert details["recovery"] =~ "does not override"

    assert {:error, :invalid_target_repo_root} = FactoryRepos.resolve("C:\\Code\\client")
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(repo: remote, base_branch: "beta"))
    config = Config.default(repo: repo)
    assert {:ok, ^checkout} = WorktreeScope.target_repo_root_argument("C:\\Code\\client", package, config)

    # Fetch from the disposable fixture without contacting a provider.
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", fixture.origin])
    attrs = %{"target_repo_root" => checkout, "base_branch" => "beta", "branch" => "fix/login"}
    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs)
    assert Path.dirname(prepared.worktree_path) == Path.join([repos_root, ".worktrees", Path.basename(checkout)])
    assert Path.basename(prepared.worktree_path) =~ "fix-login-"
    # A later shallow duplicate must not redirect an already prepared package.
    flat = Path.join(repos_root, name)
    {_, 0} = System.cmd("git", ["clone", fixture.origin, flat], stderr_to_stdout: true)

    for path <- [flat, checkout] do
      {_, 0} = System.cmd("git", ["-C", path, "remote", "set-url", "origin", remote])
    end

    assert {:ok, ^flat} = FactoryRepos.resolve(remote)
    assert {:ok, recorded} = WorkPackageRepository.get(repo, package.id)
    assert {:ok, ^checkout} = WorktreeScope.target_repo_root_argument(nil, recorded, config)
    {_, 0} = System.cmd("git", ["-C", checkout, "remote", "set-url", "origin", fixture.origin])
    assert {:ok, replay} = WorktreeLifecycle.prepare(repo, package.id, attrs)
    assert replay.worktree_path == prepared.worktree_path
    assert {:ok, _} = WorktreeLifecycle.cleanup(repo, package.id, target_repo_root: checkout)
    refute File.exists?(prepared.worktree_path)

    long_branch = String.duplicate("component/", 40) <> "login"
    assert {:ok, long_prepared} = WorktreeLifecycle.prepare(repo, package.id, Map.put(attrs, "branch", long_branch))
    assert byte_size(Path.basename(long_prepared.worktree_path)) <= 255
    assert {branch, 0} = System.cmd("git", ["-C", long_prepared.worktree_path, "branch", "--show-current"])
    assert String.trim(branch) == long_branch
    assert {:ok, _} = WorktreeLifecycle.cleanup(repo, package.id, target_repo_root: checkout)
  end
end
