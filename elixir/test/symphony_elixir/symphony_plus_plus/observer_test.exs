defmodule SymphonyElixir.SymphonyPlusPlus.ObserverTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardCache, DashboardPubSub, Observer}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress
  alias SymphonyElixir.SymphonyPlusPlus.Observer.Observation
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Qualification
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  @repo_name "nextide/repo"

  setup_all do
    database_path = WorkPackageFactory.database_path()
    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)
    on_exit(fn -> File.rm(database_path) end)
    {:ok, repo: Repo, database_path: database_path}
  end

  setup %{repo: repo} do
    for table <- ~w(sympp_worked_on sympp_work_package_observations sympp_artifacts sympp_progress_events sympp_product_tree_dependency_edges
                    sympp_work_package_deliveries sympp_worktree_cleanup_queue sympp_work_packages sympp_work_requests) do
      repo.query!("DELETE FROM #{table}")
    end

    :ok
  end

  describe "GitHub" do
    test "a PR attachment closes the pre-PR display read window", %{repo: repo} do
      package = package!(repo, "WP-OBS-REVIEW-ATTACH", branch_pattern: "agent/example", review_mode: "fast", review_id: "review-attach")
      :ok = sweep(repo, %{{:branch, "nextide", "repo", "agent/example", "main"} => {:ok, nil}})
      candidates = Observer.pre_pr_review_candidates(repo, {:request, package.work_request_id})
      [job] = Observer.display_reviews(repo, candidates)

      assert {:ok, :ok} =
               repo.transaction(fn ->
                 Qualification.record_pr(repo, Actor.observer(), package, pr_event_payload(939, "head-a"))
               end)

      # The already selected display read finishes with an unavailable host.
      :ok = Observer.refresh_display_review(repo, job)

      assert %Observation{pr_absent: false, stale: []} = repo.get!(Observation, package.id)
    end

    test "PR discovery clears a review outage recorded during its sweep", %{repo: repo} do
      package = package!(repo, "WP-OBS-REVIEW-RACE", branch_pattern: "agent/example", review_mode: "fast", review_id: "review-race")
      branch = {:branch, "nextide", "repo", "agent/example", "main"}
      :ok = sweep(repo, %{branch => {:ok, nil}})

      review = %{"done" => true, "status" => "passed", "accepted_head" => "head-a"}
      absent = repo.get!(Observation, package.id)
      assert absent.pr_absent
      displayed = repo.update!(Ecto.Changeset.change(absent, review: review))

      discover = fn [^branch] ->
        # A display reader records an outage after the sweep loaded its snapshot.
        repo.update!(Ecto.Changeset.change(displayed, stale: ["review"]))
        %{branch => {:ok, pr(938, "head-a")}}
      end

      :ok = Observer.sweep(repo, snapshot: discover, review: fn "review-race", _route -> {:ok, review} end)

      assert %WorkPackage{status: "ready"} = repo.get!(WorkPackage, package.id)
      assert %Observation{pr: %{"number" => 938}, pr_absent: false, review: ^review, stale: []} = repo.get!(Observation, package.id)
    end

    test "the sweep uses each package's newest valid attachment in chronological order", %{repo: repo} do
      legacy = package!(repo, "WP-OBS-LEGACY-ATTACHMENT", status: "ready")
      repaired = package!(repo, "WP-OBS-REPAIRED-ATTACHMENT")

      url_only = Map.drop(pr_event_payload(910, "head-a"), ["repository", "number"])
      repair = Map.merge(pr_event_payload(913, "head-r"), %{"source_tool" => "sync_pr", "attachment_repair" => true})
      plain_sync = Map.merge(pr_event_payload(914, "head-s"), %{"source_tool" => "sync_pr", "attachment_repair" => 1})
      malformed = Map.put(pr_event_payload(912, "head-invalid"), "number", 0)

      for {package, created_at, payload} <- [
            {legacy, ~U[2026-11-09 10:00:02.000000Z], url_only},
            {legacy, ~U[2026-11-09 10:00:01.000000Z], pr_event_payload(911, "head-older")},
            {legacy, ~U[2026-11-09 10:00:03.000000Z], malformed},
            {repaired, ~U[2026-11-09 10:00:01.000000Z], Map.delete(repair, "url")},
            {repaired, ~U[2026-11-09 10:00:02.000000Z], plain_sync}
          ] do
        assert {:ok, _event} =
                 PlanningRepository.append_progress_event(repo, %{
                   work_package_id: package.id,
                   summary: "Historical PR evidence",
                   created_at: created_at,
                   payload: payload
                 })
      end

      sweep(repo, %{
        {:pr, "nextide", "repo", 910} => {:ok, pr(910, "head-b", %{"ci" => %{"status" => "unknown"}})},
        {:pr, "nextide", "repo", 913} => {:ok, pr(913, "head-r")}
      })

      assert repo.get!(Observation, legacy.id).pr["head_sha"] == "head-b"
      assert repo.get!(WorkPackage, legacy.id).status == "dispatched"
      assert repo.get!(WorkPackage, repaired.id).status == "ready"
    end

    test "equivalent sweeps leave cached boards alone and changed review evidence appears on the live boards", %{
      repo: repo,
      database_path: database_path
    } do
      package = package!(repo, "WP-OBS-EQUIVALENT", review_mode: "fast", review_id: "review-13")
      attach!(repo, package, 13)
      snapshot = %{{:pr, "nextide", "repo", 13} => {:ok, pr(13, "head-a")}}
      review = %{"status" => "in_progress", "observed_at" => "2026-11-22T02:00:00Z"}
      :ok = sweep(repo, snapshot, review: fn _, _ -> {:ok, review} end)
      stored = repo.get!(Observation, package.id)

      clock = System.monotonic_time(:millisecond)
      original_clock = :sys.get_state(DashboardCache).clock
      :sys.replace_state(DashboardCache, &%{&1 | clock: fn -> clock end})
      on_exit(fn -> :sys.replace_state(DashboardCache, &%{&1 | clock: original_clock}) end)

      builds = :counters.new(4, [])

      boards =
        [
          priority: fn -> LocalOperatorDashboard.operator_dashboard_payload(repo) end,
          archived: fn -> LocalOperatorDashboard.operator_dashboard_surface_payload(repo, "archived") end,
          hydrated: fn -> LocalOperatorDashboard.operator_dashboard_hydrated_payload(repo) end,
          herdr: fn -> LocalOperatorDashboard.herdr_dashboard_payload(repo) end
        ]
        |> Enum.with_index(1)
        |> Map.new(fn {{surface, load}, index} ->
          build = fn ->
            :counters.add(builds, index, 1)
            load.()
          end

          {surface, fn -> DashboardCache.json(repo, surface, build) end}
        end)

      first = Map.new(boards, fn {surface, get} -> {surface, get.()} end)
      assert Enum.all?(Map.values(first), &match?({:ok, _, _}, &1))
      assert Enum.map(1..4, &:counters.get(builds, &1)) == [1, 1, 1, 1]
      :ok = DashboardPubSub.subscribe()
      {:ok, reader} = Exqlite.Sqlite3.open(database_path, mode: :readonly)
      on_exit(fn -> Exqlite.Sqlite3.close(reader) end)
      {:ok, version} = Exqlite.Sqlite3.prepare(reader, "PRAGMA data_version")
      on_exit(fn -> Exqlite.Sqlite3.release(reader, version) end)
      {:row, before} = Exqlite.Sqlite3.step(reader, version)
      :ok = Exqlite.Sqlite3.reset(version)

      for stamp <- ["2026-11-22T02:01:00Z", "2026-11-22T02:02:00Z"] do
        :ok = sweep(repo, snapshot, review: fn _, _ -> {:ok, Map.put(review, "observed_at", stamp)} end)
      end

      assert {:row, ^before} = Exqlite.Sqlite3.step(reader, version)
      :ok = Exqlite.Sqlite3.reset(version)
      assert repo.get!(Observation, package.id) == stored
      send(DashboardCache, :refresh_tick)
      assert Map.new(boards, fn {surface, get} -> {surface, get.()} end) == first
      assert Enum.map(1..4, &:counters.get(builds, &1)) == [1, 1, 1, 1]
      refute_received :operator_dashboard_changed

      changed = %{"status" => "failed", "observed_at" => "2026-11-22T02:03:00Z"}
      :ok = sweep(repo, snapshot, review: fn _, _ -> {:ok, changed} end)
      assert %{review: ^changed} = repo.get!(Observation, package.id)

      for surface <- [:hydrated, :herdr] do
        assert {:ok, body, etag} = boards[surface].()
        assert etag != elem(first[surface], 2)
        assert %{"work_request_details" => [%{"work_packages" => [%{"review_signal" => %{"status" => "failed"}}]}]} = Jason.decode!(body)
      end

      assert boards.priority.() == first.priority
      assert boards.archived.() == first.archived
      assert Enum.map(1..4, &:counters.get(builds, &1)) == [1, 1, 2, 2]
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
