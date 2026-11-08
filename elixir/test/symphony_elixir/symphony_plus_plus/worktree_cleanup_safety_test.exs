Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorktreeCleanupSafetyTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "cleanup removes a dirty owned worktree and leaves other checkouts untouched", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-safety-owned")
    foreign = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-safety-foreign")
    codex_home = Path.join(fixture.root, "codex-home")
    {package, path} = prepared!(repo, fixture, codex_home, "WP-CLEANUP-SAFETY-OWNED", "feat/owned")
    foreign_readme = File.read!(Path.join(foreign.repo_root, "README.md"))

    File.write!(Path.join(path, "untracked.txt"), "Owned disposable work\n")

    assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    refute File.exists?(path)
    assert File.read!(Path.join(foreign.repo_root, "README.md")) == foreign_readme
    assert {:ok, %{status: "already_clean"}} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
  end

  test "cleanup refuses an outside-root path substitution without deleting unrelated content", %{repo: repo} do
    if TestSupport.symlink_supported?() do
      fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-safety-symlink")
      codex_home = Path.join(fixture.root, "codex-home")
      {package, path} = prepared!(repo, fixture, codex_home, "WP-CLEANUP-SAFETY-SYMLINK", "feat/safe-path")
      saved = path <> "-saved"
      unrelated = Path.join(fixture.root, "unrelated")
      File.mkdir_p!(unrelated)
      File.write!(Path.join(unrelated, "keep.txt"), "Unrelated data\n")
      File.rename!(path, saved)
      File.ln_s!(unrelated, path)

      assert {:error, :unsafe_worktree_path} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
      assert File.read!(Path.join(unrelated, "keep.txt")) == "Unrelated data\n"

      File.rm!(path)
      File.rename!(saved, path)

      assert {:ok, %{status: "cleaned"}} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
      refute File.exists?(path)
      assert File.read!(Path.join(unrelated, "keep.txt")) == "Unrelated data\n"
    end
  end

  test "cleanup refuses unrelated non-Git contents and clears records whose checkout is gone", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-safety-metadata")
    codex_home = Path.join(fixture.root, "codex-home")
    {package, path} = prepared!(repo, fixture, codex_home, "WP-CLEANUP-SAFETY-METADATA", "feat/metadata")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "unrelated.txt"), "Not disposable Git content\n")

    assert {:error, :invalid_worktree_path} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert File.read!(Path.join(path, "unrelated.txt")) == "Not disposable Git content\n"

    File.rm!(Path.join(path, "unrelated.txt"))
    assert {:ok, %{status: "stale_record_cleared"}} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    refute File.exists?(path)

    {_package, second} = prepared!(repo, fixture, codex_home, package.id, "feat/metadata")
    File.rm_rf!(second)
    File.mkdir_p!(second)
    File.write!(Path.join(second, ".git"), "gitdir: missing-git-dir\n")
    assert {:ok, %{status: "stale_record_cleared"}} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)

    {_package, third} = prepared!(repo, fixture, codex_home, package.id, "feat/metadata")
    File.rm_rf!(third)
    File.write!(third, "Not a directory\n")
    assert {:error, :invalid_worktree_path} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert File.read!(third) == "Not a directory\n"

    File.rm!(third)
    assert {:ok, %{status: "stale_record_cleared"}} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
  end

  defp prepared!(repo, fixture, codex_home, id, branch) do
    package =
      case Repository.get(repo, id) do
        {:ok, package} ->
          package

        {:error, :not_found} ->
          {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(id: id, kind: "mcp", base_branch: "main"))
          package
      end

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"target_repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    assert File.dir?(prepared.worktree_path)
    {package, prepared.worktree_path}
  end
end
