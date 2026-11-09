defmodule SymphonyElixir.SymphonyPlusPlus.RepoIdentityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.TestSupport

  test "scope match rejects owner and repo-name conflicts" do
    refute RepoIdentity.scope_match?("JJLiebig/sympp", "https://github.com/elsewhere/sympp.git")
    refute RepoIdentity.scope_match?("sympp", "https://github.com/JJLiebig/sympp.git")
    refute RepoIdentity.scope_match?("frontend", "https://github.com/other/frontend.git")

    refute RepoIdentity.scope_match?("frontend", "https://github.com/other/frontend.git", trusted_remotes: ["https://github.com/JJLiebig/frontend.git"])

    refute RepoIdentity.scope_match?("sympp", "https://github.com/JJLiebig/other-repo.git")
  end

  test "scope match rejects bare repos when trusted remotes make the bare name ambiguous" do
    refute RepoIdentity.scope_match?("shared", "https://github.com/alpha/shared.git",
             trusted_remotes: [
               "https://github.com/alpha/shared.git",
               "https://github.com/beta/shared.git"
             ]
           )
  end

  test "does not promote path origin trust without matching explicit remote" do
    origin = "https://github.com/JJLiebig/nextide-saas-vod-intelligence.git"
    repo_path = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-repo-identity-path-only")

    catalog =
      RepoIdentity.catalog(
        ["nextide-saas-vod-intelligence", repo_path],
        local_path_remotes?: true
      )

    assert RepoIdentity.fields(catalog, "nextide-saas-vod-intelligence") == %{
             repo_key: "nextide-saas-vod-intelligence",
             repo_display: "nextide-saas-vod-intelligence",
             repo_remote: nil,
             repo_aliases: ["nextide-saas-vod-intelligence"]
           }

    assert RepoIdentity.fields(catalog, repo_path) == %{
             repo_key: "nextide-saas-vod-intelligence",
             repo_display: "nextide-saas-vod-intelligence",
             repo_remote: "JJLiebig/nextide-saas-vod-intelligence",
             repo_aliases:
               Enum.sort_by(
                 [repo_path, "nextide-saas-vod-intelligence", "JJLiebig/nextide-saas-vod-intelligence"],
                 &String.downcase/1
               )
           }
  end

  test "keeps path-derived origin trust scoped to the path entry" do
    origin = "https://github.com/JJLiebig/nextide-saas-live-chat.git"
    repo_path = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-repo-identity-scoped")

    catalog =
      RepoIdentity.catalog(
        [repo_path, "nextide-saas-live-chat", "Elsewhere/nextide-saas-live-chat"],
        local_path_remotes?: true
      )

    assert RepoIdentity.fields(catalog, repo_path) == %{
             repo_key: "jjliebig/nextide-saas-live-chat",
             repo_display: "JJLiebig/nextide-saas-live-chat",
             repo_remote: "JJLiebig/nextide-saas-live-chat",
             repo_aliases:
               Enum.sort_by(
                 [repo_path, "JJLiebig/nextide-saas-live-chat"],
                 &String.downcase/1
               )
           }

    assert RepoIdentity.fields(catalog, "nextide-saas-live-chat") == %{
             repo_key: "nextide-saas-live-chat",
             repo_display: "nextide-saas-live-chat",
             repo_remote: nil,
             repo_aliases: ["nextide-saas-live-chat"]
           }

    assert RepoIdentity.fields(catalog, "Elsewhere/nextide-saas-live-chat") == %{
             repo_key: "elsewhere/nextide-saas-live-chat",
             repo_display: "Elsewhere/nextide-saas-live-chat",
             repo_remote: "Elsewhere/nextide-saas-live-chat",
             repo_aliases: ["Elsewhere/nextide-saas-live-chat"]
           }
  end

  test "does not inherit parent origin from non-worktree gitdir files" do
    root = Path.join(System.tmp_dir!(), "sympp-repo-identity-gitdir-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "checkout")
    gitdir = Path.join([root, "super", ".git", "modules", "child"])
    parent_git = Path.join([root, "super", ".git"])

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(repo_path)
    File.mkdir_p!(gitdir)
    File.mkdir_p!(parent_git)
    File.write!(Path.join(repo_path, ".git"), "gitdir: #{gitdir}\n")
    File.write!(Path.join(parent_git, "config"), ~s([remote "origin"]\n\turl = https://github.com/parent/project.git\n))

    assert RepoIdentity.local_git_origin_remote(repo_path) == nil
  end

  test "does not read oversized gitdir pointer files" do
    root = Path.join(System.tmp_dir!(), "sympp-repo-identity-gitfile-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "checkout")
    gitdir = Path.join([root, ".git", "worktrees", "checkout"])

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(repo_path)
    File.mkdir_p!(gitdir)
    File.write!(Path.join(repo_path, ".git"), String.duplicate("x", 4_097))
    File.write!(Path.join(gitdir, "config"), ~s([remote "origin"]\n\turl = https://github.com/owner/project.git\n))

    assert RepoIdentity.local_git_origin_remote(repo_path) == nil
  end

  test "rejects extended UNC repo paths" do
    assert RepoIdentity.local_git_origin_remote("\\\\?\\UNC\\server\\share\\repo") == nil
  end
end
