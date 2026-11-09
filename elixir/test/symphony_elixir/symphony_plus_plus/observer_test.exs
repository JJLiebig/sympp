defmodule SymphonyElixir.SymphonyPlusPlus.ObserverTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHubTestSupport
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Api, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.Observer
  alias SymphonyElixir.SymphonyPlusPlus.Observer.Observation
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.ReviewStatus
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.TestSupport
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
    test "a merge is recorded as pr_merged with no MCP call, and the PR is no longer watched", %{repo: repo} do
      package = package!(repo, "WP-OBS-MERGE")
      attach!(repo, package, 41)

      sweep(repo, %{{:pr, "nextide", "repo", 41} => {:ok, pr(41, "head-a", %{"ci" => %{"status" => "pending"}})}})
      assert repo.get!(WorkPackage, package.id).status == "dispatched"

      merged = pr(41, "head-a", %{"state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "merge-41"})
      sweep(repo, %{{:pr, "nextide", "repo", 41} => {:ok, merged}})

      assert repo.get!(WorkPackage, package.id).status == "ended"
      delivery = repo.get_by!(WorkPackageDelivery, work_package_id: package.id)
      assert {delivery.outcome, delivery.pr_number, delivery.merge_commit_sha} == {"pr_merged", 41, "merge-41"}

      Observer.sweep(repo, snapshot: fn entries -> flunk("ended package still watched: #{inspect(entries)}") end, review: &no_review/2)
    end

    test "a merged PR matches a package scoped to its local checkout", %{repo: repo} do
      repo_path = TestSupport.git_repo_with_origin_fixture!("https://github.com/nextide/repo.git", prefix: "sympp-observer-repo")
      package = package!(repo, "WP-OBS-LOCAL", repo: repo_path)
      attach!(repo, package, 27)

      merged = pr(27, "head-local", %{"state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "merge-27"})
      sweep(repo, %{{:pr, "nextide", "repo", 27} => {:ok, merged}})

      assert repo.get!(WorkPackage, package.id).status == "ended"
    end

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

    test "a PR found on the package's branch is attached", %{repo: repo} do
      package = package!(repo, "WP-OBS-DISCOVER")
      entry = {:branch, "nextide", "repo", "agent/example", "main"}

      sweep(repo, %{entry => {:ok, nil}})
      assert {:error, :missing_attached_pr} = current_pr(repo, package.id)

      sweep(repo, %{entry => {:ok, pr(77, "head-b", %{"ci" => %{"status" => "pending"}})}})
      assert {:ok, %{ref: %{number: 77}, payload: %{"head_sha" => "head-b"}}} = current_pr(repo, package.id)

      # Once attached, the PR itself is watched.
      sweep(repo, %{{:pr, "nextide", "repo", 77} => {:ok, pr(77, "head-b", %{"ci" => %{"status" => "pending"}})}})
    end

    test "a discovered PR on another base branch is not attached", %{repo: repo} do
      package = package!(repo, "WP-OBS-OTHER-BASE")
      sweep(repo, %{{:branch, "nextide", "repo", "agent/example", "main"} => {:ok, pr(78, "head-c", %{"base_branch" => "release"})}})
      assert {:error, :missing_attached_pr} = current_pr(repo, package.id)
    end

    test "an attached PR retargeted to another base unqualifies its package", %{repo: repo} do
      package = package!(repo, "WP-OBS-RETARGET", status: "ready")
      attach!(repo, package, 79)

      sweep(repo, %{{:pr, "nextide", "repo", 79} => {:ok, pr(79, "head-a", %{"base_branch" => "release"})}})

      assert repo.get!(WorkPackage, package.id).status == "dispatched"
      assert "pr_base_mismatch" in unqualified_event!(repo, package.id).payload["reasons"]
    end

    test "a ready PR merged into another base unqualifies instead of ending", %{repo: repo} do
      package = package!(repo, "WP-OBS-MERGED-ELSEWHERE", status: "ready")
      attach!(repo, package, 81)

      merged =
        pr(81, "head-a", %{"base_branch" => "release", "state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "merge-81"})

      sweep(repo, %{{:pr, "nextide", "repo", 81} => {:ok, merged}})

      assert repo.get!(WorkPackage, package.id).status == "dispatched"
      refute repo.get_by(WorkPackageDelivery, work_package_id: package.id)
      assert "pr_base_mismatch" in unqualified_event!(repo, package.id).payload["reasons"]
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

    test "CI changes are recorded once; an unchanged snapshot after a restart records nothing", %{repo: repo} do
      package = package!(repo, "WP-OBS-CI")
      attach!(repo, package, 70)
      entry = {:pr, "nextide", "repo", 70}

      sweep(repo, %{entry => {:ok, pr(70, "head-a", %{"ci" => %{"status" => "pending", "completed" => 1, "total" => 2}})}})
      failing = pr(70, "head-a", %{"ci" => %{"status" => "failing", "completed" => 2, "total" => 2}})
      sweep(repo, %{entry => {:ok, failing}}, failing_checks: fn @repo_name, "head-a" -> {:ok, ["build"]} end)

      assert {:ok, %{payload: payload}} = current_pr(repo, package.id, ["sync_pr"])
      assert payload["check_summary"] == %{"status" => "failing", "current" => 2, "total" => 2}
      assert get_in(repo.get!(Observation, package.id).pr, ["ci", "failing"]) == ["build"]
      before = length(events(repo, package.id))

      # A new Observer process starts with no memory: the stored snapshot keeps
      # it from recording the same state, or re-reading check details, again.
      sweep(repo, %{entry => {:ok, failing}}, failing_checks: fn _repository, _head -> flunk("detail read for an unchanged head") end)
      assert length(events(repo, package.id)) == before
      assert repo.get!(WorkPackage, package.id).status == "dispatched"
    end

    test "a closed PR is recorded, unqualifies its package and is no longer watched", %{repo: repo} do
      package = package!(repo, "WP-OBS-CLOSED", status: "ready")
      attach!(repo, package, 80)

      sweep(repo, %{{:pr, "nextide", "repo", 80} => {:ok, pr(80, "head-a", %{"state" => "closed"})}})
      assert repo.get!(WorkPackage, package.id).status == "dispatched"
      assert %{"reasons" => reasons} = unqualified_event!(repo, package.id).payload
      assert "pr_not_open" in reasons

      Observer.sweep(repo, snapshot: fn entries -> assert entries == [] end, review: &no_review/2)
    end
  end

  describe "qualification" do
    test "auto-qualifies when PR, CI and review are green for the head, and unqualifies when the head moves", %{repo: repo} do
      package = package!(repo, "WP-OBS-QUALIFY", review_mode: "fast", review_id: "rvw_qualify0001")
      attach!(repo, package, 50)
      entry = {:pr, "nextide", "repo", 50}
      green = pr(50, "head-a")

      # A review done for an earlier head doesn't count.
      sweep(repo, %{entry => {:ok, green}}, review: review_done("head-old"))
      assert repo.get!(WorkPackage, package.id).status == "dispatched"

      sweep(repo, %{entry => {:ok, green}}, review: review_done("head-a"))
      assert repo.get!(WorkPackage, package.id).status == "ready"

      sweep(repo, %{entry => {:ok, pr(50, "head-b", %{"ci" => %{"status" => "pending"}})}}, review: review_done("head-a"))
      assert repo.get!(WorkPackage, package.id).status == "dispatched"
      assert %{"reasons" => reasons, "head_sha" => "head-b"} = unqualified_event!(repo, package.id).payload
      assert "head_changed" in reasons

      # Replaying the same snapshot doesn't unqualify or record again.
      before = length(events(repo, package.id))
      sweep(repo, %{entry => {:ok, pr(50, "head-b", %{"ci" => %{"status" => "pending"}})}}, review: review_done("head-a"))
      assert length(events(repo, package.id)) == before
    end

    test "stale consumed inputs block qualification", %{repo: repo} do
      prerequisite = package!(repo, "WP-OBS-PREREQ", status: "ready")
      prerequisite_head = String.duplicate("a", 40)
      dependent_head = String.duplicate("b", 40)
      attach!(repo, prerequisite, 60, prerequisite_head)
      dependent = package!(repo, "WP-OBS-DEPENDENT", work_request_id: prerequisite.work_request_id)
      attach!(repo, dependent, 61, dependent_head)
      edge = pinned_dependency!(repo, dependent, prerequisite, prerequisite_head)

      snapshot = %{
        {:pr, "nextide", "repo", 60} => {:ok, pr(60, prerequisite_head)},
        {:pr, "nextide", "repo", 61} => {:ok, pr(61, dependent_head)}
      }

      sweep(repo, snapshot)
      assert repo.get!(WorkPackage, dependent.id).status == "dispatched"
      assert repo.get!(WorkPackage, prerequisite.id).status == "ready"

      # The architect states which prerequisite input the head consumed.
      assert {:ok, _selection} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: dependent.id,
                 summary: "Consumed inputs",
                 payload: %{
                   "type" => "dependency_inputs",
                   "source_tool" => "sync_pr",
                   "head_sha" => dependent_head,
                   "dependency_inputs" => [%{"dependency_id" => edge.id, "prerequisite_work_package_id" => prerequisite.id, "candidate_head_sha" => prerequisite_head}]
                 }
               })

      sweep(repo, snapshot)
      assert repo.get!(WorkPackage, dependent.id).status == "ready"
    end

    test "an unreachable GitHub flags the package stale and never transitions", %{repo: repo} do
      ready = package!(repo, "WP-OBS-GH-DOWN", status: "ready")
      attach!(repo, ready, 90)
      entry = {:pr, "nextide", "repo", 90}
      sweep(repo, %{entry => {:ok, pr(90, "head-a")}})

      merged = pr(90, "head-a", %{"state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "merge-90"})

      paused_until = System.system_time(:millisecond) + 60_000

      for failure <- [{:error, :request_failed}, {:error, {:rate_limited, paused_until}}] do
        sweep(repo, %{entry => failure})
        assert repo.get!(WorkPackage, ready.id).status == "ready"
        assert repo.get!(Observation, ready.id).stale == ["github"]
      end

      assert {:ok, board} = DeliveryBoard.project(repo, ready.work_request_id)
      eligibility = Enum.find(board.work_packages, &(&1.id == ready.id)).merge_eligibility
      refute eligibility.eligible
      assert "observation_stale" in eligibility.reason_codes

      sweep(repo, %{entry => {:ok, merged}})
      assert repo.get!(WorkPackage, ready.id).status == "ended"
    end

    test "without a GitHub token every watched package is stale and nothing changes", %{repo: repo} do
      package = package!(repo, "WP-OBS-NO-TOKEN", status: "ready")
      attach!(repo, package, 91)
      Api.forget_token()

      GitHubTestSupport.with_github_token_env(nil, fn ->
        Application.put_env(:symphony_elixir, :sympp_github_request, fn request -> flunk("GitHub request without a token: #{inspect(request.url)}") end)

        try do
          Observer.sweep(repo, review: &no_review/2)
        after
          Application.delete_env(:symphony_elixir, :sympp_github_request)
          Api.forget_token()
        end
      end)

      assert repo.get!(WorkPackage, package.id).status == "ready"
      assert repo.get!(Observation, package.id).stale == ["github"]
    end

    test "an unreachable review host flags the package stale and blocks qualifying only", %{repo: repo} do
      dispatched = package!(repo, "WP-OBS-REVIEW-DOWN", review_mode: "normal", review_id: "rvw_reviewdown01")
      ready = package!(repo, "WP-OBS-REVIEW-DOWN-READY", status: "ready", review_mode: "normal", review_id: "rvw_reviewdown02")
      attach!(repo, dispatched, 92)
      attach!(repo, ready, 93)

      snapshot = %{{:pr, "nextide", "repo", 92} => {:ok, pr(92, "head-a")}, {:pr, "nextide", "repo", 93} => {:ok, pr(93, "head-a")}}
      sweep(repo, snapshot, review: fn _id, _machine -> :unknown end)

      assert repo.get!(WorkPackage, dispatched.id).status == "dispatched"
      assert repo.get!(WorkPackage, ready.id).status == "ready"
      assert repo.get!(Observation, dispatched.id).stale == ["review"]
      assert repo.get!(Observation, ready.id).stale == ["review"]

      # The merge itself is still recorded: it doesn't depend on the review host.
      merged = pr(93, "head-a", %{"state" => "merged", "merged" => true, "merged_at" => "2026-11-09T10:00:00Z", "merge_commit_sha" => "merge-93"})
      sweep(repo, Map.put(snapshot, {:pr, "nextide", "repo", 93}, {:ok, merged}), review: fn _id, _machine -> :unknown end)
      assert repo.get!(WorkPackage, ready.id).status == "ended"
    end
  end

  describe "terminals" do
    test "a worker terminal moves its package from launching to implementing, and finishing it to worker_exited", %{repo: repo} do
      package = package!(repo, "WP-OBS-WORKER")
      next_action = fn -> board_row(repo, package).operational_state.activity_signal["next_action"] end

      assert next_action.() == "run_launch_line"

      worker = %{"state" => "live", "status" => "working", "labels" => %{"sympp.role" => "worker", "sympp.work_package_id" => package.id}}
      Observer.observe_terminals(repo, {:ok, %{core_id: "core-1", core_name: "jj", terminals: %{"t9" => worker}}})
      assert %WorkedOn{display_address: "jj/t9", role: "worker", state: "live"} = Ownership.workers(repo, [package.id])[package.id]
      assert next_action.() == "wait"

      # An unreachable core changes nothing.
      Observer.observe_terminals(repo, :unavailable)
      assert Ownership.workers(repo, [package.id])[package.id].state == "live"

      Observer.observe_terminals(repo, {:ok, %{core_id: "core-1", terminals: %{"t9" => Map.put(worker, "state", "finished")}}})
      assert %WorkedOn{state: "finished", finish_reason: "terminal_finished"} = Ownership.workers(repo, [package.id])[package.id]
      assert next_action.() == "inspect_worker"
    end

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
      done = Jason.encode!(%{"review" => "rvw_read0001", "done" => true, "status" => "done", "head" => "abc123", "progress" => "1/1", "rounds" => 2})
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
      assert %{"done" => true, "reviewed_head" => "abc123", "status" => "passed", "current" => 1, "total" => 1, "round" => 2} = review
      assert ReviewStatus.state({:ok, review}, "abc123" <> String.duplicate("0", 34)) == :done
      assert ReviewStatus.state({:ok, review}, "def456") == :pending

      assert {:ok, ^review} = ReviewStatus.read("rvw_read0001", "worker-box") |> then(fn {:ok, remote} -> {:ok, Map.put(remote, "observed_at", review["observed_at"])} end)
      assert_received {:command, "hc", ["exec", "--json", "--on", "worker-box", "--timeout", "3", "--", "sh", "-c", command, "sh", "rvw_read0001"], _timeout}
      # The skills install first, else the Codex marketplace plugin.
      assert command =~ ~s("$HOME/.agents/skills/review-suite/plugins/review-suite/scripts/review.py")
      assert command =~ ~s("${CODEX_HOME:-$HOME/.codex}"/plugins/cache/review-suite/review-suite/*/scripts/review.py)
    end

    test "a cycle that doesn't exist yet is not started; an unusable answer is unknown" do
      answers = %{
        "rvw_missing0001" => {:ok, {Jason.encode!(%{"error" => "unknown review cycle id: rvw_missing0001", "status" => "usage_error"}), 2}},
        "rvw_broken0001" => {:ok, {"Traceback (most recent call last)", 1}},
        "rvw_timeout0001" => :error
      }

      Application.put_env(:symphony_elixir, :sympp_review_command, fn "python3", [_script, "--id", id | _rest], _timeout -> Map.fetch!(answers, id) end)

      assert ReviewStatus.read("rvw_missing0001", nil) == :not_started
      assert ReviewStatus.state(:not_started, "abc") == :pending
      assert ReviewStatus.read("rvw_broken0001", nil) == :unknown
      assert ReviewStatus.read("rvw_timeout0001", nil) == :unknown
      assert ReviewStatus.state(:unknown, "abc") == :unknown
    end
  end

  test "PR progress helpers preserve created_at precedence over legacy sequences" do
    old_event = %ProgressEvent{id: "old-pr", sequence: 200, created_at: ~U[2026-05-20 12:00:00Z], payload: pr_event_payload(1, "old-head")}
    new_event = %ProgressEvent{id: "new-pr", sequence: 1, created_at: ~U[2026-05-21 12:00:00Z], payload: pr_event_payload(2, "new-head")}

    assert {:ok, %{ref: %{number: 2}, payload: %{"head_sha" => "new-head"}}} =
             PullRequestProgress.current_pr_state([new_event, old_event], ["attach_pr"])
  end

  defp sweep(repo, snapshot, opts \\ []) do
    Observer.sweep(repo,
      snapshot: fn entries ->
        assert Enum.sort(entries) == Enum.sort(Map.keys(snapshot)), "watched #{inspect(entries)}"
        snapshot
      end,
      review: Keyword.get(opts, :review, &no_review/2),
      failing_checks: Keyword.get(opts, :failing_checks, fn _repository, _head -> {:ok, []} end)
    )
  end

  defp no_review(_id, _machine), do: flunk("review read for a package in mode none")

  defp review_done(head), do: fn _id, _machine -> {:ok, %{"done" => true, "status" => "passed", "reviewed_head" => head}} end

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

  defp pinned_dependency!(repo, dependent, prerequisite, head) do
    assert {:ok, edge} =
             ProductTreeRepository.create_dependency_edge(repo, %{
               work_request_id: dependent.work_request_id,
               source_kind: "work_package",
               source_id: dependent.id,
               target_kind: "work_package",
               target_id: prerequisite.id,
               kind: "depends_on",
               reason: "Consume the qualified prerequisite",
               candidate_head_sha: head
             })

    edge
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

  defp board_row(repo, package) do
    {:ok, board} = DeliveryBoard.project(repo, package.work_request_id)
    Enum.find(board.work_packages, &(&1.id == package.id))
  end

  defp events(repo, package_id) do
    {:ok, events} = PlanningRepository.list_progress_events(repo, package_id)
    events
  end

  defp current_pr(repo, package_id, sources \\ ["attach_pr"]) do
    repo |> events(package_id) |> PullRequestProgress.current_pr_state(sources)
  end

  defp unqualified_event!(repo, package_id) do
    repo |> events(package_id) |> Enum.filter(&(&1.status == "unqualified")) |> List.last() || flunk("no unqualify recorded")
  end
end
