defmodule SymphonyElixir.SymphonyPlusPlus.GitHubPullRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.GhCliClient

  test "gh reads a PR's commits, and leaves out a list that may be cut short at gh's 100" do
    ref = %{owner: "o", repo: "r", number: 7, repository: "o/r", url: "https://github.com/o/r/pull/7"}

    view = fn count ->
      runner = fn "gh", _args, _opts -> {:ok, Jason.encode!(%{"number" => 7, "commits" => Enum.map(1..count, &%{"oid" => "c#{&1}"})})} end
      {:ok, metadata} = GhCliClient.fetch_pull_request(ref, command_runner: runner)
      metadata["commits"]
    end

    assert view.(2) == ["c1", "c2"]
    assert view.(100) == nil
  end
end
