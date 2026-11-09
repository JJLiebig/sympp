defmodule SymphonyElixir.SymphonyPlusPlus.WorktreeLifecycleCompatTest do
  use SymphonyElixir.TestSupport

  @moduletag :ci_slow

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(WorkPackage)
    :ok
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "source checkout permissions survive a private factory umask" do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-checkout-modes")
    File.write!(Path.join(fixture.repo_root, "tool.sh"), "#!/bin/sh\necho ok\n")
    TestSupport.git_output!(fixture.repo_root, ["add", "tool.sh"])
    TestSupport.git_output!(fixture.repo_root, ["update-index", "--chmod=+x", "tool.sh"])
    TestSupport.git_output!(fixture.repo_root, ["commit", "-m", "Add executable fixture"])
    TestSupport.git_output!(fixture.repo_root, ["push", "origin", "main"])
    checkout = Path.join(fixture.root, "clone with spaces")
    worktree = Path.join(fixture.root, "worktree with spaces")
    private_file = Path.join(fixture.root, "private-state")
    helper = Path.expand("lib/symphony_elixir/symphony_plus_plus/git_checkout.ex")

    script = """
    [origin, checkout, worktree, private_file] = System.argv()
    git = System.find_executable("git")
    {_, 0} = SymphonyElixir.SymphonyPlusPlus.GitCheckout.run(git, ["clone", "--branch", "main", "--", origin, checkout])
    {_, 0} = SymphonyElixir.SymphonyPlusPlus.GitCheckout.run(git, ["-C", checkout, "worktree", "add", "-b", "test-modes", worktree, "origin/main"])
    File.write!(private_file, "private")
    """

    assert {output, 0} =
             System.cmd("sh", ["-c", "umask 077; exec \"$@\"", "test-checkout", System.find_executable("elixir"), "-r", helper, "-e", script, "--", fixture.origin, checkout, worktree, private_file],
               stderr_to_stdout: true
             )

    for root <- [checkout, worktree] do
      assert Bitwise.band(File.stat!(Path.join(root, "README.md")).mode, 0o777) == 0o644, output
      assert Bitwise.band(File.stat!(Path.join(root, "tool.sh")).mode, 0o777) == 0o755, output
      assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o755, output
    end

    assert Bitwise.band(File.stat!(private_file).mode, 0o777) == 0o600
  end

  test "cleanup retries a proven Windows partial worktree removal", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-recovery")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-RECOVERY", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/partial-remove"},
               codex_home: codex_home
             )

    fake_git = partial_remove_git(prepared.worktree_path)

    assert {:error, {:git_failed, 255, details}} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, git: fake_git)

    assert details.stage == "git_worktree_remove"
    assert details.rule == "durable_preflight_proof"
    assert Path.expand(details.recorded_worktree_path) == Path.expand(prepared.worktree_path)
    assert Path.expand(details.resolved_worktree_path) == Path.expand(prepared.worktree_path)
    assert File.exists?(Path.join(prepared.worktree_path, "README.md"))
    refute File.exists?(Path.join(prepared.worktree_path, ".git"))

    assert {:ok, failed_package} = Repository.get(repo, package.id)
    assert is_binary(failed_package.worktree_cleanup_proof)

    assert {:ok, recovered} =
             File.cd!(fixture.root, fn ->
               WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, git: fake_git)
             end)

    assert recovered.stage == "residue_removal"
    assert recovered.rule == "durable_preflight_proof"
    refute File.exists?(prepared.worktree_path)

    assert {:ok, cleaned_package} = Repository.get(repo, package.id)
    assert cleaned_package.worktree_path == nil
    assert cleaned_package.worktree_target_repo_root == nil
    assert cleaned_package.worktree_cleanup_proof == nil
  end

  test "cleanup removes residue after Git reports successful worktree removal", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-residue")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-RESIDUE", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/residue-remove"},
               codex_home: codex_home
             )

    residue = Path.join([prepared.worktree_path, "node_modules", "residue"])
    File.mkdir_p!(residue)

    preserved_target =
      if match?({:win32, _name}, :os.type()) do
        target = Path.join(fixture.root, "broken-junction-target")
        preserved_target = Path.join(fixture.root, "preserved-junction-target")
        File.mkdir_p!(target)
        File.mkdir_p!(preserved_target)
        File.write!(Path.join(preserved_target, "sentinel"), "keep")
        junction = Path.join(residue, "broken")
        preserved_junction = Path.join(residue, "preserved")
        script = Path.join(fixture.root, "junction.ps1")
        File.write!(script, "param($Path, $Target)\nNew-Item -ItemType Junction -Path $Path -Target $Target | Out-Null\n")

        {_output, 0} =
          System.cmd("powershell.exe", ["-NoProfile", "-File", script, "-Path", junction, "-Target", target], stderr_to_stdout: true)

        {_output, 0} =
          System.cmd("powershell.exe", ["-NoProfile", "-File", script, "-Path", preserved_junction, "-Target", preserved_target], stderr_to_stdout: true)

        File.rmdir!(target)

        on_exit(fn ->
          for path <- [junction, preserved_junction], match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)), do: File.rmdir(path)
        end)

        preserved_target
      else
        File.write!(Path.join(residue, "leftover"), "ignored")
        nil
      end

    assert {:ok, cleaned} =
             WorktreeLifecycle.cleanup(repo, package.id,
               codex_home: codex_home,
               git: partial_remove_git(prepared.worktree_path, 0)
             )

    assert cleaned.status == "cleaned"
    refute File.exists?(prepared.worktree_path)
    if preserved_target, do: assert(File.read!(Path.join(preserved_target, "sentinel")) == "keep")

    assert {:ok, cleaned_package} = Repository.get(repo, package.id)
    assert cleaned_package.worktree_path == nil
    assert cleaned_package.worktree_target_repo_root == nil
    assert cleaned_package.worktree_cleanup_proof == nil
  end

  test "cleanup runs before_remove inside the worktree after persisting proof", %{repo: repo} do
    {fixture, package, prepared, opts} = prepare_hook_worktree(repo)
    marker = Path.join(fixture.root, "hook-result")

    write_workflow_file!(Workflow.workflow_file_path(),
      hook_before_remove: "cat README.md > #{TestSupport.shell_path(marker)}"
    )

    git = System.find_executable("git")

    checked_git = fn repo_root, args ->
      if args == ["worktree", "remove", "--force", prepared.worktree_path] do
        assert is_binary(repo.get!(WorkPackage, package.id).worktree_cleanup_proof)
        assert File.read!(marker) == File.read!(Path.join(prepared.worktree_path, "README.md"))
      end

      System.cmd(git, ["-C", repo_root | args], stderr_to_stdout: true)
    end

    assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id, Keyword.put(opts, :git, checked_git))
    refute File.exists?(prepared.worktree_path)
  end

  defp prepare_hook_worktree(repo) do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-hooks")
    opts = [codex_home: Path.join(fixture.root, "codex-home")]

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-HOOK", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-hook"},
               opts
             )

    {fixture, package, prepared, opts}
  end

  defp partial_remove_git(worktree_path, status \\ 255) do
    git = System.find_executable("git") || flunk("git executable is required")

    fn repo_root, args ->
      case args do
        ["worktree", "remove", "--force", ^worktree_path] ->
          File.rm!(Path.join(worktree_path, ".git"))
          {_output, 0} = System.cmd(git, ["-C", repo_root, "worktree", "prune"], stderr_to_stdout: true)
          {"simulated Windows partial worktree removal\n", status}

        _args ->
          System.cmd(git, ["-C", repo_root | args], stderr_to_stdout: true)
      end
    end
  end
end
