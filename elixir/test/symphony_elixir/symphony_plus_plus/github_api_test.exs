defmodule SymphonyElixir.SymphonyPlusPlus.GitHubApiTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHubTestSupport
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Api, RateGovernor, Snapshot}

  setup do
    RateGovernor.create_table()
    Api.create_table()
    Api.forget_token()
    test_pid = self()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :sympp_github_request)
      Application.put_env(:symphony_elixir, :sympp_gh_token_command, fn -> nil end)
      Api.forget_token()
    end)

    {:ok, test_pid: test_pid}
  end

  describe "rate governor" do
    test "a 403 or 429 without a reset backs off from 30 s, doubling to 15 min; a pause is only extended" do
      credential = unique_credential()

      backoffs =
        Enum.map_reduce(1..7, 0, fn _attempt, now ->
          until = RateGovernor.penalize(credential, %{}, now)
          {until - now, until}
        end)
        |> elem(0)

      assert backoffs == [30_000, 60_000, 120_000, 240_000, 480_000, 900_000, 900_000]

      paused_until = RateGovernor.state(credential).paused_until
      assert RateGovernor.penalize(credential, %{"retry-after" => ["1"]}, paused_until - 10_000) == paused_until
      assert {:error, {:rate_limited, ^paused_until}} = RateGovernor.allow(credential, "graphql", :interactive, paused_until - 1)

      # A success after the pause resets the backoff.
      RateGovernor.record(credential, %{}, paused_until + 1)
      assert RateGovernor.penalize(credential, %{}, paused_until + 2) == paused_until + 2 + 30_000
    end

    test "concurrent updates to one credential never lose a pause" do
      credential = unique_credential()
      budget = %{"x-ratelimit-remaining" => ["4000"], "x-ratelimit-limit" => ["5000"], "x-ratelimit-reset" => ["3600"]}

      1..50
      |> Enum.map(fn index ->
        Task.async(fn -> if rem(index, 10) == 0, do: RateGovernor.penalize(credential, %{}, 0), else: RateGovernor.record(credential, budget, 0) end)
      end)
      |> Task.await_many()

      # Five penalties in a row: 30 s doubling to 480 s, none overwritten by a success.
      assert RateGovernor.state(credential).paused_until == 480_000
    end

    test "retry-after, or the reset time when the budget is spent, sets the pause" do
      credential = unique_credential()
      assert RateGovernor.penalize(credential, %{"retry-after" => ["120"]}, 0) == 120_000

      other = unique_credential()
      reset = %{"x-ratelimit-remaining" => ["0"], "x-ratelimit-limit" => ["5000"], "x-ratelimit-reset" => ["600"], "x-ratelimit-resource" => ["graphql"]}
      assert RateGovernor.penalize(other, reset, 0) == 600_000
    end

    test "background reads stop below 10 % of the budget; interactive reads may spend it down to 1" do
      credential = unique_credential()
      budget = fn remaining -> %{"x-ratelimit-remaining" => [remaining], "x-ratelimit-limit" => ["5000"], "x-ratelimit-reset" => ["3600"], "x-ratelimit-resource" => ["core"]} end

      RateGovernor.record(credential, budget.("500"), 0)
      assert :ok = RateGovernor.allow(credential, "core", :background, 0)

      RateGovernor.record(credential, budget.("499"), 0)
      assert {:error, {:rate_limited, 3_600_000}} = RateGovernor.allow(credential, "core", :background, 0)
      assert :ok = RateGovernor.allow(credential, "core", :interactive, 0)
      assert :ok = RateGovernor.allow(credential, "graphql", :background, 0)

      RateGovernor.record(credential, budget.("0"), 0)
      assert {:error, {:rate_limited, _reset}} = RateGovernor.allow(credential, "core", :interactive, 0)

      # A response that arrives late can't raise the budget within its reset
      # window, whether it succeeded or was refused, nor bring back an older window.
      RateGovernor.record(credential, budget.("4999"), 0)
      RateGovernor.penalize(credential, Map.put(budget.("4999"), "retry-after", ["1"]), 0)
      RateGovernor.record(credential, %{budget.("4999") | "x-ratelimit-reset" => ["1800"]}, 0)
      assert {:error, {:rate_limited, 3_600_000}} = RateGovernor.allow(credential, "core", :interactive, 1_000)

      # After the reset time the old budget no longer applies.
      assert :ok = RateGovernor.allow(credential, "core", :background, 3_600_001)
    end
  end

  describe "HTTP access" do
    test "the token is read once from gh auth token and a 429 pauses further requests", %{test_pid: test_pid} do
      token_reads = :counters.new(1, [])
      Application.put_env(:symphony_elixir, :sympp_gh_token_command, fn -> :counters.add(token_reads, 1, 1) && "gho_test_token" end)

      request(fn request ->
        send(test_pid, {:request, request})
        {:ok, %{status: 429, headers: %{"retry-after" => "90"}, body: ~s({"message":"secondary rate limit"})}}
      end)

      GitHubTestSupport.with_github_token_env(nil, fn ->
        assert {:error, {:rate_limited, until}} = Api.graphql("query { viewer { login } }", %{})
        assert_in_delta until, System.system_time(:millisecond) + 90_000, 5_000
        assert_received {:request, %{method: :post, url: "https://api.github.com/graphql", headers: headers}}
        assert {"authorization", "Bearer gho_test_token"} in headers

        # Paused: the next request never goes out.
        assert {:error, {:rate_limited, ^until}} = Api.graphql("query { viewer { login } }", %{})
        refute_received {:request, _request}
        assert :counters.get(token_reads, 1) == 1
      end)
    end

    test "403 and 429 are told apart from other refusals, and 401 forgets the token" do
      GitHubTestSupport.with_github_token_env("ghp_env_token", fn ->
        request(fn _request -> {:ok, %{status: 403, headers: %{}, body: ~s({"message":"Resource not accessible by integration"})}} end)
        assert {:error, :forbidden} = Api.rest_get("repos/nextide/repo/commits/abc/check-runs")

        request(fn _request -> {:ok, %{status: 403, headers: %{"x-ratelimit-remaining" => "0", "x-ratelimit-limit" => "5000", "x-ratelimit-reset" => "4102444800"}, body: "{}"}} end)
        assert {:error, {:rate_limited, 4_102_444_800_000}} = Api.rest_get("repos/nextide/repo/commits/def/check-runs")
      end)

      # The token is kept until GitHub refuses it; a different one is a fresh credential.
      Api.forget_token()

      GitHubTestSupport.with_github_token_env("ghp_second_token", fn ->
        request(fn _request -> {:ok, %{status: 401, headers: %{}, body: "{}"}} end)
        assert {:error, :unauthorized} = Api.graphql("query { viewer { login } }", %{})
        assert :persistent_term.get({Api, :token}, nil) == nil
      end)
    end

    test "REST reads revalidate with the stored ETag and a 304 returns the cached body", %{test_pid: test_pid} do
      GitHubTestSupport.with_github_token_env("ghp_etag_token", fn ->
        path = "repos/nextide/repo/commits/#{String.duplicate("c", 40)}/check-runs?per_page=100"

        request(fn request ->
          send(test_pid, {:headers, request.headers})

          if List.keymember?(request.headers, "if-none-match", 0),
            do: {:ok, %{status: 304, headers: %{"etag" => ~s(W/"runs")}, body: ""}},
            else: {:ok, %{status: 200, headers: %{"etag" => ~s(W/"runs")}, body: ~s({"check_runs":[{"name":"build","conclusion":"failure"}]})}}
        end)

        assert {:ok, %{"check_runs" => [%{"name" => "build"}]} = body} = Api.rest_get(path)
        assert_received {:headers, first}
        refute List.keymember?(first, "if-none-match", 0)

        assert {:ok, ^body} = Api.rest_get(path)
        assert_received {:headers, second}
        assert {"if-none-match", ~s(W/"runs")} in second
      end)
    end
  end

  describe "snapshot" do
    test "one aliased document reads PRs and branches; a fork's branch with the same name is never taken" do
      graphql = fn query, variables, :background ->
        assert query =~ "e0: repository(owner: $o0, name: $r0) { pullRequest(number: $n0)"
        assert query =~ "e1: repository(owner: $o1, name: $r1) { pullRequests(headRefName: $b1, baseRefName: $t1"

        assert variables == %{
                 "o0" => "nextide",
                 "r0" => "repo",
                 "n0" => 7,
                 "o1" => "nextide",
                 "r1" => "repo",
                 "b1" => "agent/x",
                 "t1" => "main",
                 "o2" => "nextide",
                 "r2" => "repo",
                 "b2" => "agent/y",
                 "t2" => "main"
               }

        {:ok,
         %{
           "e0" => %{"pullRequest" => node(7, "nextide", %{"merged" => true, "state" => "MERGED", "mergedAt" => "2026-11-09T10:00:00Z", "mergeCommit" => %{"oid" => "m7"}})},
           "e1" => %{"pullRequests" => %{"nodes" => [node(8, "a-fork"), node(9, "NextIde", %{"state" => "CLOSED"}), node(10, "nextide")]}},
           "e2" => %{"pullRequests" => %{"nodes" => [node(11, "a-fork")]}}
         }}
      end

      entries = [{:pr, "nextide", "repo", 7}, {:branch, "nextide", "repo", "agent/x", "main"}, {:branch, "nextide", "repo", "agent/y", "main"}]
      results = Snapshot.fetch(entries, graphql: graphql)

      assert {:ok, %{"state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "m7", "repository" => "nextide/repo"}} =
               results[{:pr, "nextide", "repo", 7}]

      assert {:ok, %{"number" => 10, "state" => "open"}} = results[{:branch, "nextide", "repo", "agent/x", "main"}]
      assert {:ok, nil} = results[{:branch, "nextide", "repo", "agent/y", "main"}]
    end

    test "check rollups, the Codex receipt and failed documents" do
      rollup = fn state, counts -> %{"state" => state, "contexts" => %{"checkRunCountsByState" => counts, "statusContextCountsByState" => []}} end

      nodes = %{
        "e0" => %{"pullRequest" => node(1, "o", %{"commits" => commit(rollup.("SUCCESS", [%{"state" => "SUCCESS", "count" => 3}]))})},
        "e1" => %{"pullRequest" => node(2, "o", %{"commits" => commit(rollup.("PENDING", [%{"state" => "SUCCESS", "count" => 1}, %{"state" => "IN_PROGRESS", "count" => 2}]))})},
        "e2" => %{"pullRequest" => node(3, "o", %{"commits" => commit(rollup.("FAILURE", [%{"state" => "FAILURE", "count" => 1}]))})},
        "e3" => %{"pullRequest" => node(4, "o", %{"commits" => commit(nil)})},
        "e4" => nil
      }

      entries = for number <- 1..5, do: {:pr, "o", "r", number}
      results = Snapshot.fetch(entries, graphql: fn _query, _variables, _priority -> {:ok, nodes} end)

      assert {:ok, %{"ci" => %{"status" => "passing", "completed" => 3, "total" => 3}}} = results[{:pr, "o", "r", 1}]
      assert {:ok, %{"ci" => %{"status" => "pending", "completed" => 1, "total" => 3}}} = results[{:pr, "o", "r", 2}]
      assert {:ok, %{"ci" => %{"status" => "failing"}}} = results[{:pr, "o", "r", 3}]
      assert {:ok, %{"ci" => %{"status" => "unknown"}, "github_review" => %{"state" => "commented", "commit" => "head-4"}}} = results[{:pr, "o", "r", 4}]
      assert {:error, :not_found} = results[{:pr, "o", "r", 5}]

      failed = Snapshot.fetch([{:pr, "o", "r", 1}], graphql: fn _query, _variables, _priority -> {:error, {:rate_limited, 123}} end)
      assert failed == %{{:pr, "o", "r", 1} => {:error, {:rate_limited, 123}}}
    end

    test "up to 25 entries share one document" do
      documents = :counters.new(1, [])
      graphql = fn _query, variables, _priority -> :counters.add(documents, 1, 1) && {:ok, Map.new(Map.keys(variables), &{&1, nil})} end
      Snapshot.fetch(for(number <- 1..60, do: {:pr, "o", "r", number}), graphql: graphql)
      assert :counters.get(documents, 1) == 3
    end

    test "commit lists carry the head and base they were read at; a list GitHub can't return whole is an error" do
      commits = fn oids, total -> %{"totalCount" => total, "nodes" => Enum.map(oids, &%{"commit" => %{"oid" => &1}})} end

      data = %{
        "e0" => %{"pullRequest" => %{"headRefOid" => "h1", "baseRefOid" => "b1", "commits" => commits.(["c1", "h1"], 2)}},
        "e1" => %{"pullRequest" => %{"headRefOid" => "h2", "baseRefOid" => "b1", "commits" => commits.(Enum.map(1..100, &"c#{&1}"), 140)}}
      }

      graphql = fn _query, _variables, _priority -> {:ok, data} end
      results = Snapshot.commits([{"o", "r", 1}, {"o", "r", 2}], graphql: graphql)
      assert results[{"o", "r", 1}] == {:ok, %{"head_sha" => "h1", "base_sha" => "b1", "commits" => ["c1", "h1"]}}
      assert {:error, _incomplete} = results[{"o", "r", 2}]
    end
  end

  defp request(fun), do: Application.put_env(:symphony_elixir, :sympp_github_request, fun)

  defp unique_credential, do: "credential-#{System.unique_integer([:positive])}"

  defp node(number, owner, patch \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "url" => "https://github.com/nextide/repo/pull/#{number}",
        "state" => "OPEN",
        "isDraft" => false,
        "merged" => false,
        "headRefOid" => "head-#{number}",
        "headRefName" => "agent/x",
        "baseRefName" => "main",
        "headRepositoryOwner" => %{"login" => owner},
        "reviews" => %{"nodes" => [%{"author" => %{"login" => "chatgpt-codex-connector"}, "state" => "COMMENTED", "commit" => %{"oid" => "head-#{number}"}}]}
      },
      patch
    )
  end

  defp commit(rollup), do: %{"nodes" => [%{"commit" => %{"oid" => "head", "statusCheckRollup" => rollup}}]}
end
