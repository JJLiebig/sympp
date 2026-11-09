defmodule SymphonyElixir.SymphonyPlusPlus.ObserverTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress
  alias SymphonyElixir.SymphonyPlusPlus.Observer
  alias SymphonyElixir.SymphonyPlusPlus.Observer.Observation
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.ReviewStatus
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory

  @repo_name "nextide/repo"

  setup_all do
    database_path = WorkPackageFactory.database_path()
    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)
    on_exit(fn -> File.rm(database_path) end)
    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    for table <- ~w(sympp_worked_on sympp_work_package_observations sympp_artifacts sympp_progress_events sympp_product_tree_dependency_edges
                    sympp_work_package_deliveries sympp_worktree_cleanup_queue sympp_work_packages sympp_work_requests) do
      repo.query!("DELETE FROM #{table}")
    end

    on_exit(fn -> Application.put_env(:symphony_elixir, :sympp_review_command, nil) end)
    :ok
  end

  describe "GitHub" do
    test "a merge whose evidence can't be recorded changes nothing", %{repo: repo} do
      package = package!(repo, "WP-OBS-MERGE-CONFLICT", status: "ready")
      attach!(repo, package, 9)

      assert {:ok, _collision} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: package.id,
                 summary: "Pre-existing merge reconciliation key",
                 status: "test_merge_evidence_collision",
                 idempotency_key: "operator_github_merge:#{package.id}:head-a",
                 payload: %{type: "test_collision"}
               })

      merged = pr(9, "head-a", %{"state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "merge-9"})
      sweep(repo, %{{:pr, "nextide", "repo", 9} => {:ok, merged}})

      assert repo.get!(WorkPackage, package.id).status == "ready"
      refute repo.get_by(WorkPackageDelivery, work_package_id: package.id)
      refute Enum.any?(events(repo, package.id), &(&1.status == "github_pr_merged"))
    end

    test "a PR replaced by sync_pr during a sweep is neither re-attached nor recorded as merged", %{repo: repo} do
      package = package!(repo, "WP-OBS-REPLACED")
      attach!(repo, package, 921)
      merged = pr(921, "head-a", %{"state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "merge-921"})

      replace_during_read = fn entries ->
        attach!(repo, package, 922)
        Map.new(entries, &{&1, {:ok, merged}})
      end

      Observer.sweep(repo, snapshot: replace_during_read, review: &no_review/2)

      assert repo.get!(WorkPackage, package.id).status == "dispatched"
      refute repo.get_by(WorkPackageDelivery, work_package_id: package.id)
      assert {:ok, %{ref: %{number: 922}}} = current_pr(repo, package.id)
      refute Enum.any?(events(repo, package.id), &(&1.status == "github_pr_merged"))
      # The unapplied snapshot isn't stored, so the next sweep reads the package afresh.
      assert repo.get!(Observation, package.id).pr == nil
    end

    test "a newer sync_pr of the same PR during a sweep wins over the sweep's older read", %{repo: repo} do
      package = package!(repo, "WP-OBS-NEWER-SYNC")
      attach!(repo, package, 930, "head-a")

      newer_sync_during_read = fn entries ->
        attach!(repo, package, 930, "head-b")
        Map.new(entries, &{&1, {:ok, pr(930, "head-a")}})
      end

      Observer.sweep(repo, snapshot: newer_sync_during_read, review: &no_review/2)

      assert repo.get!(WorkPackage, package.id).status == "dispatched"
      assert {:ok, %{payload: %{"head_sha" => "head-b"}}} = current_pr(repo, package.id)
      assert repo.get!(Observation, package.id).pr == nil
    end
  end

  describe "terminals" do
    test "terminals the factory's core reports finished end their rows; other cores' rows stay", %{repo: repo} do
      package = package!(repo, "WP-OBS-OWNERS")
      seen = owner!(repo, package.work_request_id, "core-1/t1")
      other_request = package!(repo, "WP-OBS-OWNERS-OTHER").work_request_id
      unseen = owner!(repo, other_request, "core-2/t1")

      Observer.observe_terminals(repo, {:ok, %{core_id: "core-1", terminals: %{}}})

      assert %WorkedOn{state: "finished", finish_reason: "terminal_finished"} = repo.get!(WorkedOn, seen.id)
      assert %WorkedOn{state: "live"} = repo.get!(WorkedOn, unseen.id)
    end

    test "a terminal that took ownership after the snapshot was read isn't ended by it", %{repo: repo} do
      package = package!(repo, "WP-OBS-LATE-OWNER")
      read_at = DateTime.utc_now(:microsecond)
      late = owner!(repo, package.work_request_id, "core-1/t5")

      Ownership.observe_core(repo, "core-1", nil, %{}, [], read_at)

      assert %WorkedOn{state: "live"} = repo.get!(WorkedOn, late.id)
    end
  end

  describe "Review Suite state" do
    test "is read locally on the factory host and with hc exec on other machines" do
      head = "abc123" <> String.duplicate("0", 34)
      done = Jason.encode!(%{"review" => "rvw_read0001", "done" => true, "status" => "done", "head" => head, "reviewed_head" => head, "accepted_head" => head, "progress" => "1/1", "rounds" => 2})
      test_pid = self()

      Application.put_env(:symphony_elixir, :sympp_review_command, fn command, args, timeout ->
        send(test_pid, {:command, command, args, timeout})

        case command do
          "python3" -> {:ok, {done, 0}}
          "hc" -> {:ok, {Jason.encode!(%{"code" => 0, "stdout" => Base.encode64(done), "timed_out" => false}), 0}}
        end
      end)

      assert {:ok, review} = ReviewStatus.read("rvw_read0001", nil)
      assert_received {:command, "python3", [_script, "--id", "rvw_read0001", "--show-status", "--json"], 3_000}
      assert %{"done" => true, "reviewed_head" => ^head, "accepted_head" => ^head, "status" => "passed", "current" => 1, "total" => 1, "round" => 2} = review
      assert ReviewStatus.state({:ok, review}, head) == :done
      assert ReviewStatus.state({:ok, review}, "abc123") == :pending
      # Review Suite can keep `done` while reporting the cycle no longer holds.
      for status <- ["stale", "failed", "fix-pending", "invalidated"] do
        stale = Jason.encode!(%{"review" => "rvw_read0001", "done" => true, "status" => status, "accepted_head" => head})
        Application.put_env(:symphony_elixir, :sympp_review_command, fn "python3", _args, _timeout -> {:ok, {stale, 0}} end)
        assert ReviewStatus.state(ReviewStatus.read("rvw_read0001", nil), head) == :pending
      end

      Application.put_env(:symphony_elixir, :sympp_review_command, fn command, args, timeout ->
        send(test_pid, {:command, command, args, timeout})

        case command do
          "python3" -> {:ok, {done, 0}}
          "hc" -> {:ok, {Jason.encode!(%{"code" => 0, "stdout" => Base.encode64(done), "timed_out" => false}), 0}}
        end
      end)

      assert {:ok, ^review} = ReviewStatus.read("rvw_read0001", "worker-box") |> then(fn {:ok, remote} -> {:ok, Map.put(remote, "observed_at", review["observed_at"])} end)
      assert_received {:command, "hc", ["exec", "--json", "--on", "worker-box", "--timeout", "3", "--", "sh", "-c", command, "sh", "rvw_read0001"], _timeout}
      # The skills install first, else the Codex marketplace plugin.
      assert command =~ ~s("$HOME/.agents/skills/review-suite/plugins/review-suite/scripts/review.py")
      assert command =~ ~s("${CODEX_HOME:-$HOME/.codex}"/plugins/cache/review-suite/review-suite/*/scripts/review.py)
    end
  end

  # Commit lists default to each PR's own head commit, so PRs share nothing.
  defp sweep(repo, snapshot, opts \\ []) do
    Observer.sweep(repo,
      snapshot: fn entries ->
        assert Enum.sort(entries) == Enum.sort(Map.keys(snapshot)), "watched #{inspect(entries)}"
        snapshot
      end,
      review: Keyword.get(opts, :review, &no_review/2),
      failing_checks: Keyword.get(opts, :failing_checks, fn _repository, _head -> {:ok, []} end),
      commits: Keyword.get(opts, :commits, listed(snapshot, %{}))
    )
  end

  # Commit lists by PR number (default: the PR's own head), read at each PR's head.
  defp listed(snapshot, lists) do
    fn prs ->
      Map.new(prs, fn {owner, name, number} = pr ->
        {:ok, %{"head_sha" => head} = read} = Map.fetch!(snapshot, {:pr, owner, name, number})
        {pr, {:ok, %{"head_sha" => head, "base_sha" => read["base_sha"], "commits" => Map.get(lists, number, [head])}}}
      end)
    end
  end

  defp no_review(_id, _machine), do: flunk("review read for a package in mode none")

  # Review Suite's `review.py --id <id> --show-status --json` answer, for every review id.

  # Review Suite's base_interaction for a carried review: whether the base change
  # touched the PR's paths and still needs a targeted check.

  defp pr(number, head, patch \\ %{}) do
    Map.merge(
      %{
        "repository" => @repo_name,
        "number" => number,
        "url" => "https://github.com/#{@repo_name}/pull/#{number}",
        "state" => "open",
        "draft" => false,
        "merged" => false,
        "head_sha" => head,
        "branch" => "agent/example",
        "base_branch" => "main",
        "ci" => %{"status" => "passing", "completed" => 1, "total" => 1}
      },
      patch
    )
  end

  defp package!(repo, id, overrides \\ []) do
    {review, overrides} = Keyword.split(overrides, [:review_mode, :review_id])

    work_request_id =
      Keyword.get_lazy(overrides, :work_request_id, fn ->
        {:ok, request} =
          WorkRequestRepository.create(repo, %{
            title: "Observe #{id}",
            repo: Keyword.get(overrides, :repo, @repo_name),
            base_branch: "main",
            work_type: "feature",
            human_description: "Observed delivery.",
            constraints: %{},
            desired_dispatch_shape: "single_package"
          })

        request.id
      end)

    {:ok, package} =
      overrides
      |> Keyword.drop([:work_request_id])
      |> Keyword.merge(id: id, work_request_id: work_request_id, kind: "hotfix")
      |> Keyword.put_new(:repo, @repo_name)
      |> WorkPackageFactory.attrs()
      |> then(&WorkPackageRepository.create(repo, &1))

    repo.update!(Ecto.Changeset.change(package, Keyword.put_new(review, :review_mode, "none")))
  end

  defp attach!(repo, package, number, head \\ "head-a") do
    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: pr_event_payload(number, head)
             })
  end

  defp pr_event_payload(number, head) do
    %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/#{@repo_name}/pull/#{number}", "repository" => @repo_name, "number" => number, "head_sha" => head}
  end

  defp owner!(repo, work_request_id, terminal_key) do
    repo.insert!(%WorkedOn{
      id: "wo-#{System.unique_integer([:positive])}",
      subject_kind: "work_request",
      subject_id: work_request_id,
      terminal_key: terminal_key,
      display_address: terminal_key,
      role: "architect",
      state: "live",
      started_at: DateTime.utc_now(:microsecond)
    })
  end

  defp events(repo, package_id) do
    {:ok, events} = PlanningRepository.list_progress_events(repo, package_id)
    events
  end

  defp current_pr(repo, package_id, sources \\ ["attach_pr"]) do
    repo |> events(package_id) |> PullRequestProgress.current_pr_state(sources)
  end
end
