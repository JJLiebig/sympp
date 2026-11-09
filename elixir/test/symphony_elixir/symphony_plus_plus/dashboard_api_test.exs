Code.require_file(Path.expand("../../support/symphony_plus_plus/dashboard_fixture_database_test.exs", __DIR__))

defmodule SymphonyElixir.SymphonyPlusPlus.DashboardApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Ecto.Query, only: [from: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Asks
  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.Cards
  alias SymphonyElixir.SymphonyPlusPlus.Cards.Card
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardFixtureDatabase
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Observer.Observation
  alias SymphonyElixir.SymphonyPlusPlus.OperationalLineage
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
  alias SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.RetentionThrottle
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.ReactDashboardController
  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule BusyRepo do
    @moduledoc false

    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule CountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def all(query) do
      count_artifact_list_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_artifact_list_query(%Ecto.Query{from: %{source: {"sympp_artifacts", _schema}}, order_bys: [_ | _]}) do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &(&1 + 1))
      end
    end

    defp count_artifact_list_query(_query), do: :ok
  end

  defmodule WorkRequestCardCountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @counted_tables [
      "sympp_work_requests",
      "sympp_asks",
      "sympp_work_request_decision_logs",
      "sympp_work_packages",
      "sympp_work_package_deliveries"
    ]

    def all(query) do
      count_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_query(%Ecto.Query{from: %{source: {table, _schema}}}) when table in @counted_tables do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &Map.update(&1, table, 1, fn count -> count + 1 end))
      end
    end

    defp count_query(_query), do: :ok
  end

  defmodule DashboardQueryCountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @counter_key {__MODULE__, :query_count}

    def reset, do: Process.put(@counter_key, 0)
    def count, do: Process.get(@counter_key, 0)

    def all(query), do: counted(fn -> Repo.all(query) end)
    def one(query), do: counted(fn -> Repo.one(query) end)
    def get(queryable, id), do: counted(fn -> Repo.get(queryable, id) end)
    def get!(queryable, id), do: counted(fn -> Repo.get!(queryable, id) end)
    def query(sql, params), do: counted(fn -> Repo.query(sql, params) end)
    def update_all(query, updates), do: counted(fn -> Repo.update_all(query, updates) end)
    def transaction(fun), do: Repo.transaction(fun)

    defp counted(fun) do
      Process.put(@counter_key, count() + 1)
      fun.()
    end
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
    start_test_endpoint()

    on_exit(fn ->
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(OperatorAudit)
    repo.delete_all(AgentRun)
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(PlanNode)
    repo.delete_all(Card)
    repo.delete_all(WorkedOn)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    repo.delete_all(DecisionLogEntry)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Asks.Ask)
    repo.delete_all(WorkRequest)
    repo.delete_all(OperatorSettings)
    RetentionThrottle.reset(repo)
    :ok
  end

  test "package operational state follows provider-backed merged PR state", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-OP-MERGED-PR",
                 kind: "mcp",
                 status: "ready",
                 policy_template: "mcp"
               )
             )

    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/77", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/77",
                 repository: "example/repo",
                 number: 77,
                 head_sha: "head-a",
                 merge_state: %{merged: true}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, card} = Dashboard.card(repo, work_package)
    assert card.operational_state.key == "merged"
    assert card.operational_state.raw_status == "ready"

    attention_by_key = Map.new(card.operational_state.attention_items, &{&1.key, &1})
    refute Map.has_key?(attention_by_key, "pr_merged_raw_status_open")

    assert {:ok, _new_branch_head} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch advanced",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-b"},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, stale_card} = Dashboard.card(repo, work_package)
    assert stale_card.operational_state.key == "merge_ready"
    refute Enum.any?(stale_card.operational_state.attention_items, &(&1.key == "pr_merged_raw_status_open"))
  end

  test "phase board status filters keep repo identity from the phase scope", %{repo: repo} do
    with_trusted_repo_remotes(["JJLiebig/sympp"], fn ->
      assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-repo-identity", title: "Repo identity phase"})

      assert {:ok, bare} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-DASH-PHASE-REPO-BARE",
                   kind: "mcp",
                   phase_id: phase.id,
                   status: "planned",
                   repo: "sympp",
                   base_branch: "main"
                 )
               )

      assert {:ok, _owner} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-DASH-PHASE-REPO-OWNER",
                   kind: "mcp",
                   phase_id: phase.id,
                   status: "dispatched",
                   repo: "JJLiebig/sympp",
                   base_branch: "main"
                 )
               )

      assert {:ok, board} = Dashboard.phase_board(repo, phase.id, status: "planned")
      assert [%{id: bare_id} = card] = board.groups["planned"]
      assert bare_id == bare.id
      assert card.repo == "sympp"
      assert card.repo_key == "sympp"
      assert card.repo_display == "sympp"
      assert card.repo_remote == "JJLiebig/sympp"
      assert card.repo_aliases == ["JJLiebig/sympp", "sympp"]
    end)
  end

  test "dashboard WorkRequest list batches related card count reads", %{repo: repo} do
    first = create_work_request!(repo, id: "WR-DASH-BATCH-1")
    second = create_work_request!(repo, id: "WR-DASH-BATCH-2")

    insert_ask!(repo, first.id)
    assert {:ok, _decision} = WorkRequestRepository.record_decision(repo, second.id, decision_attrs(id: "WRD-DASH-BATCH-1"))
    assert {:ok, _slice} = CanonicalWorkPackageFixtures.add_work_package(repo, second.id, work_package_attrs(id: "WRS-DASH-BATCH-1"))

    {:ok, counter} = Agent.start_link(fn -> %{} end)
    WorkRequestCardCountingRepo.counter(counter)

    try do
      assert {:ok, payload} = Dashboard.work_requests(WorkRequestCardCountingRepo)
      assert payload.total_count == 2
      assert Enum.map(payload.work_requests, & &1.id) == [first.id, second.id]

      assert Agent.get(counter, &(&1 |> Map.values() |> Enum.sum())) <= 8
    after
      WorkRequestCardCountingRepo.clear_counter()
      Agent.stop(counter)
    end
  end

  test "local WorkRequest detail includes work-package operational state from linked package activity", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-SLICES")

    assert {:ok, approved_ready} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-READY"))

    set_canonical_package_status!(repo, approved_ready, "dispatched")

    assert {:ok, approved_idle_linked} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-IDLE-LINKED"))

    set_canonical_package_status!(repo, approved_idle_linked, "dispatched")

    assert {:ok, approved_prepared_linked} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-PREPARED-LINKED"))

    prepared_package = set_canonical_package_status!(repo, approved_prepared_linked, "dispatched")

    assert {:ok, _prepared_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: prepared_package.id,
               summary: "Prepared WorkPackage worktree",
               status: "prepared",
               payload: %{
                 type: "worktree_lifecycle",
                 source_tool: "prepare_work_package_worktree",
                 status: "prepared",
                 worktree_path: "/tmp/sympp-worktree",
                 branch: "agent/prepared"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, approved_linked} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-LINKED"))

    set_canonical_package_status!(repo, approved_linked, "dispatched")

    assert {:ok, approved_terminal} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-TERMINAL"))

    set_canonical_package_status!(repo, approved_terminal, "ended")

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)
    slices_by_id = Map.new(payload.work_packages, &{&1.id, &1})

    assert get_in(slices_by_id, ["WRS-OP-READY", :operational_state, :key]) == "dispatched"
    assert get_in(slices_by_id, ["WRS-OP-READY", :operational_state, :raw_status]) == "dispatched"
    assert get_in(slices_by_id, ["WRS-OP-IDLE-LINKED", :operational_state, :key]) == "dispatched"

    prepared_linked_slice = Map.fetch!(slices_by_id, "WRS-OP-PREPARED-LINKED")
    assert prepared_linked_slice.work_package_status == "dispatched"
    assert prepared_linked_slice.operational_state.key == "prepared"
    assert prepared_linked_slice.operational_state.raw_status == "dispatched"
    assert prepared_linked_slice.operational_state.has_started == false
    assert prepared_linked_slice.operational_state.has_prepared_worktree == true
    refute Enum.any?(prepared_linked_slice.operational_state.attention_items, &(&1.key == "linked_package_started_while_slice_idle"))

    linked_slice = Map.fetch!(slices_by_id, "WRS-OP-LINKED")
    assert linked_slice.work_package_status == "dispatched"
    assert linked_slice.operational_state.key == "dispatched"
    assert linked_slice.operational_state.raw_status == "dispatched"

    terminal_slice = Map.fetch!(slices_by_id, "WRS-OP-TERMINAL")
    assert terminal_slice.work_package_status == "ended"
    assert terminal_slice.operational_state.key == "needs_closeout"
    assert terminal_slice.attention_reason_codes == ["terminal_package_without_delivery_outcome"]
  end

  test "WorkRequest completion shows needs closeout for an ended package without an ending row", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-MERGED")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-MERGED"))

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    merged_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-MERGED",
        status: "ended"
      )

    assert {:ok, dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", merged_package.id)

    assert dispatched_slice.status == "ended"

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)
    assert payload.work_request.phase == "unresolved"
    assert payload.work_request.completed_at == nil
    assert payload.work_request.archived_at == nil
    assert payload.work_request.operational_state.key == "needs_closeout"
    assert payload.work_request.operational_state.label == "Needs Closeout"
    assert payload.work_request.operational_state.phase == "unresolved"

    [slice] = payload.work_packages
    assert slice.status == "ended"
    assert slice.work_package_status == "ended"
    assert slice.operational_state.key == "needs_closeout"
    assert slice.operational_state.raw_status == "ended"
    assert slice.attention_reason_codes == ["terminal_package_without_delivery_outcome"]
  end

  test "board phase follows delivery pointers and stays unresolved for missing recuts", %{repo: repo} do
    request = create_work_request!(repo, id: "WR-DASH-SUCCESSOR-SCOPE")

    [original, successor] =
      for id <- ["original", "successor"] do
        assert {:ok, package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-DASH-#{id}"))
        package
      end

    assert {:ok, _superseded} =
             CanonicalWorkPackageFixtures.end_work_package(repo, request.id, original.id, %{
               outcome: "superseded",
               idempotency_key: "dashboard-pointer-only",
               successor_work_package_id: successor.id,
               superseded_reason: "Replacement scope delivers the goal."
             })

    record_completed_delivery!(repo, successor)
    assert {:ok, cards} = Dashboard.work_requests(repo)
    assert %{phase: "done", completed_at: completed_at} = Enum.find(cards.work_requests, &(&1.id == request.id))
    assert is_binary(completed_at)
    assert {:ok, detail} = Dashboard.work_request_detail(repo, request.id)
    assert detail.work_request.phase == "done"

    assert {:ok, _recut} =
             OperationalLineage.record_recut_as(repo, original.id, successor.id, %{
               reason: "The delivered recut cannot hide an unresolved immutable pointer.",
               decision: %{work_request_id: request.id}
             })

    assert {:ok, _missing_recut} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: original.id,
               summary: "Historical replacement target is missing.",
               status: "operational_lineage_recorded",
               idempotency_key: "dashboard-missing-recut",
               payload: %{type: "operational_lineage", source_tool: "record_operational_lineage", relationship: "recut_as", target_work_package_id: "missing"}
             })

    assert {:ok, cards} = Dashboard.work_requests(repo)
    assert %{phase: "unresolved", completed_at: nil} = Enum.find(cards.work_requests, &(&1.id == request.id))
    assert {:ok, detail} = Dashboard.work_request_detail(repo, request.id)
    assert detail.work_request.phase == "unresolved"
  end

  test "board artifact reads are limited to packages that need artifact-backed readiness", %{repo: repo} do
    assert {:ok, plain_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-PLAIN-ARTIFACTS", kind: "quick_fix", status: "dispatched", policy_template: "quick_fix")
             )

    assert {:ok, validation_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-VALIDATION-ARTIFACTS",
                 kind: "mcp",
                 status: "dispatched",
                 policy_template: "mcp"
               )
             )

    assert {:ok, _plain_artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: plain_package.id,
               path: "plain.txt",
               title: "Plain artifact",
               kind: "note"
             })

    assert {:ok, _validation_artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: validation_package.id,
               path: "validation.txt",
               title: "Validation evidence",
               kind: "review"
             })

    assert {:ok, counter} = Agent.start_link(fn -> 0 end)
    CountingRepo.counter(counter)

    try do
      assert {:ok, board} = Dashboard.board(CountingRepo)
      assert board.total_count == 2
      assert Agent.get(counter, & &1) == 1
    after
      CountingRepo.clear_counter()
      Agent.stop(counter)
    end
  end

  test "stale calculation only flags active or queued runs past the threshold", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-STALE", status: "dispatched"))

    now = DateTime.utc_now(:microsecond)

    fresh_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "running",
        last_seen_at: DateTime.add(now, -299, :second)
      }

    stale_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "starting",
        last_seen_at: DateTime.add(now, -300, :second)
      }

    stopped_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "stopped",
        last_seen_at: DateTime.add(now, -900, :second)
      }

    refute Dashboard.stale_agent_run?(fresh_run, now, 300)
    assert Dashboard.stale_agent_run?(stale_run, now, 300)
    refute Dashboard.stale_agent_run?(stopped_run, now, 300)
  end

  test "metadata projection does not reuse sequence-less attach state after bare reattach" do
    timestamp = ~U[2026-05-05 00:00:00Z]

    branch =
      progress_event("branch", nil, DateTime.add(timestamp, 1, :second), %{
        "type" => "branch",
        "source_tool" => "attach_branch",
        "branch" => "agent/SYMPP-SEQUENCELESS",
        "head_sha" => "head-a"
      })

    semantic_attach =
      progress_event("attach-state", nil, DateTime.add(timestamp, 2, :second), %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "url" => "https://github.com/example/repo/pull/10",
        "repository" => "example/repo",
        "number" => 10,
        "head_sha" => "head-a",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      })

    semantic_events = [branch, semantic_attach]

    assert MetadataProjection.current_pr_state_present?(semantic_events, "head-a")

    bare_reattach =
      progress_event("attach-bare", nil, DateTime.add(timestamp, 3, :second), %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "url" => "https://github.com/example/repo/pull/10",
        "repository" => "example/repo",
        "number" => 10,
        "head_sha" => "head-a"
      })

    stale_events = semantic_events ++ [bare_reattach]

    refute MetadataProjection.current_pr_state_present?(stale_events, "head-a")
    assert MetadataProjection.metadata(stale_events).pr["source_tool"] == "attach_pr"
    refute Map.has_key?(MetadataProjection.metadata(stale_events).pr, "check_summary")

    fresh_sync =
      progress_event("sync-state", nil, DateTime.add(timestamp, 4, :second), %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/example/repo/pull/10",
        "repository" => "example/repo",
        "number" => 10,
        "head_sha" => "head-a",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      })

    fresh_events = stale_events ++ [fresh_sync]

    assert MetadataProjection.current_pr_state_present?(fresh_events, "head-a")
    assert MetadataProjection.metadata(fresh_events).pr["source_tool"] == "sync_pr"
  end

  test "card summaries use total counts and full progress metadata", %{repo: repo} do
    %{work_package: work_package} = create_dashboard_fixture(repo)
    timestamp = ~U[2026-05-05 00:02:00Z]

    for index <- 1..105 do
      assert {:ok, _event} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Heartbeat #{index}",
                 status: "working",
                 payload: %{type: "status", source_tool: "test"},
                 created_at: DateTime.add(timestamp, index, :second)
               })
    end

    assert {:ok, _backfilled_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled older event",
               status: "working",
               payload: %{type: "status", source_tool: "test"},
               created_at: DateTime.add(timestamp, -1, :second)
             })

    for index <- 1..101 do
      assert {:ok, _artifact} =
               PlanningService.append_artifact(repo, %{
                 work_package_id: work_package.id,
                 path: "artifact-#{index}.txt",
                 title: "Artifact #{index}",
                 kind: "log",
                 created_at: DateTime.add(timestamp, 400 + index, :second)
               })
    end

    assert {:ok, card} = Dashboard.card(repo, work_package)
    assert card.artifact_count == 102
    assert card.active_blocker_count == 1
    assert {:ok, latest_progress_at, _offset} = DateTime.from_iso8601(card.latest_progress_at)
    assert DateTime.compare(latest_progress_at, DateTime.add(timestamp, 105, :second)) == :eq
    assert card.metadata.pr["url"] == "https://github.com/example/repo/pull/1"
  end

  test "priority dashboard responds before compact execution signals for a deterministic workload", %{repo: repo} do
    for index <- 1..20 do
      work_request =
        create_work_request!(repo,
          id: "WR-PERF-#{String.pad_leading(to_string(index), 2, "0")}",
          title: "Perf request #{String.pad_leading(to_string(index), 2, "0")}",
          repo: "sympp",
          base_branch: "main"
        )

      if index == 1 do
        work_request
        |> Ecto.Changeset.change(operator_completed_at: DateTime.utc_now(:microsecond))
        |> repo.update!()
      end
    end

    for index <- 1..50 do
      create_work_package!(repo,
        id: "SYMPP-PERF-#{String.pad_leading(to_string(index), 2, "0")}",
        status: "dispatched"
      )
    end

    RetentionThrottle.reset(DashboardQueryCountingRepo)
    assert {:ok, _payload} = LocalOperatorDashboard.operator_dashboard_hydrated_payload(DashboardQueryCountingRepo)

    {base_payload, priority_metrics} =
      dashboard_benchmark(1, fn ->
        LocalOperatorDashboard.operator_dashboard_payload(DashboardQueryCountingRepo)
      end)

    {hydrated_payload, hydrated_metrics} =
      dashboard_benchmark(1, fn ->
        LocalOperatorDashboard.operator_dashboard_hydrated_payload(DashboardQueryCountingRepo)
      end)

    {:ok, deferred_payload} = LocalOperatorDashboard.operator_dashboard_deferred_payload(DashboardQueryCountingRepo)
    priority_metrics = Map.put(priority_metrics, :bytes, byte_size(Jason.encode!(base_payload)))
    hydrated_metrics = Map.put(hydrated_metrics, :bytes, byte_size(Jason.encode!(hydrated_payload)))

    assert base_payload.deferred == %{dashboard_sections: true}
    assert deferred_payload.deferred == %{dashboard_sections: false}
    assert hydrated_payload.deferred == %{dashboard_sections: false}
    assert hydrated_payload.work_requests.total_count == 20
    assert hydrated_payload.work_packages == []
    assert priority_metrics.queries <= 20
    assert hydrated_metrics.queries <= 105
    assert priority_metrics.queries < hydrated_metrics.queries
    assert priority_metrics.bytes < hydrated_metrics.bytes

    maybe_export_dashboard_fixture(repo)

    if System.get_env("SYMPP_DASHBOARD_BENCHMARK") == "1" do
      IO.puts("DASHBOARD_BENCHMARK " <> Jason.encode!(%{priority: priority_metrics, hydrated: hydrated_metrics}))
    end
  end

  test "local operator dashboard reads do not write after migration bootstrap" do
    {bootstrap_queries, queries} =
      with_local_operator_endpoint(fn ->
        {_bootstrap_payload, bootstrap_queries} = capture_queries(&local_operator_dashboard_payload/0)
        {_payload, queries} = capture_queries(&local_operator_dashboard_payload/0)
        {bootstrap_queries, queries}
      end)

    write_query? = &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/i, &1)

    assert Enum.filter(bootstrap_queries, write_query?) in [
             [],
             ["CREATE TABLE IF NOT EXISTS \"schema_migrations\" (\"version\" INTEGER PRIMARY KEY, \"inserted_at\" TEXT)"]
           ]

    assert Enum.filter(queries, write_query?) == []
  end

  test "dashboard fixture export builds a deterministic isolated graph ledger" do
    path = Path.join(System.tmp_dir!(), "sympp-dashboard-graph-fixture-#{System.unique_integer([:positive])}.sqlite3")
    clone_path = path <> ".clone"
    on_exit(fn -> Enum.each([path, path <> "-wal", path <> "-shm", clone_path, clone_path <> "-wal", clone_path <> "-shm"], &File.rm/1) end)

    assert :ok = DashboardFixtureDatabase.export!(path)
    File.cp!(path, clone_path)
    refute File.exists?(clone_path <> "-wal")
    refute File.exists?(clone_path <> "-shm")

    {:ok, pid} = Repo.start_link(database: clone_path, name: nil, pool_size: 1, log: false)
    previous_repo = Repo.put_dynamic_repo(pid)

    try do
      assert %{rows: [["ok"]]} = Repo.query!("PRAGMA quick_check")
      assert {:ok, _fixture_payload} = LocalOperatorDashboard.operator_dashboard_hydrated_payload(Repo)
      assert {:ok, fixture_deferred_payload} = LocalOperatorDashboard.operator_dashboard_deferred_payload(Repo)
      # Measured 223,289 bytes once every ended fixture package carries its ending row; batching is unchanged.
      assert byte_size(Jason.encode!(fixture_deferred_payload)) <= 225_000
      refute Map.has_key?(fixture_deferred_payload, :board)

      expected_signal_keys =
        MapSet.new([
          :active_agent_run,
          :active_blocker_count,
          :active_blockers,
          :id,
          :inserted_at,
          :latest_progress_at,
          :metadata,
          :runtime,
          :updated_at
        ])

      assert Enum.all?(fixture_deferred_payload.work_packages, &(MapSet.new(Map.keys(&1)) == expected_signal_keys))

      parse_signal = Enum.find(fixture_deferred_payload.work_packages, &(&1.id == "WP-FANOUT-PARSE"))
      assert parse_signal.runtime.completed_count == 1
      assert is_map(parse_signal.metadata.pr)
      assert is_binary(parse_signal.latest_progress_at)

      blocker_signal = Enum.find(fixture_deferred_payload.work_packages, &(&1.id == "WP-RECOVERY-SUCCESSOR"))
      assert blocker_signal.active_blocker_count == 1
      assert [%{id: "fixture-schema", active: true}] = blocker_signal.active_blockers
      assert is_binary(blocker_signal.inserted_at)
      assert is_binary(blocker_signal.updated_at)

      assert Repo.all(WorkRequest) |> Enum.map(& &1.id) |> Enum.sort() == [
               "WR-FIXTURE-DENSE",
               "WR-FIXTURE-FANOUT",
               "WR-FIXTURE-KRAKEN-SCALE",
               "WR-FIXTURE-RECOVERY"
             ]

      assert Repo.all(WorkRequest) |> Enum.all?(&(&1.inserted_at == ~U[2026-07-18 08:00:00.000000Z]))

      assert {:ok, fanout} = DeliveryBoard.project(Repo, "WR-FIXTURE-FANOUT")
      fanout_packages = Map.new(fanout.work_packages, &{&1.id, &1})
      assert fanout_packages["WP-FANOUT-PARSE"].work_package.worker_signal.status == "active"
      assert fanout_packages["WP-FANOUT-SOURCE"].work_package.pr_signal.status == "merged"
      assert fanout_packages["WP-FANOUT-INDEX"].work_package.review_signal.status == "pending"
      assert fanout_packages["WP-FANOUT-JOIN"].work_package.dependency_signal.required == 2
      assert fanout_packages["WP-FANOUT-JOIN"].operational_state.key == "dependency_blocked"
      assert fanout_packages["WP-FANOUT-PLAYTEST"].operational_state.key == "dispatched"
      assert fanout_packages["WP-FANOUT-PLAYTEST"].work_package.dependency_signal.satisfied == 1

      assert {:ok, [fanout_detail]} = Dashboard.work_request_board_details(Repo, ["WR-FIXTURE-FANOUT"])
      assert fanout_detail.product_tree.execution_graph.available
      assert length(fanout_detail.product_tree.execution_graph.effective_edges) == 6
      assert length(fanout_detail.product_tree.execution_graph.topological_order) == 6
      assert for(package <- fanout_detail.work_packages, is_nil(package.group), do: package.id) == ["WP-FANOUT-PLAYTEST"]

      assert {:ok, [kraken_detail]} = Dashboard.work_request_board_details(Repo, ["WR-FIXTURE-KRAKEN-SCALE"])
      assert length(kraken_detail.work_packages) == 49
      refute Map.has_key?(kraken_detail, :delivery_board)
      assert kraken_detail.work_packages |> Enum.map(& &1.group) |> Enum.uniq() |> length() == 10
      assert length(kraken_detail.product_tree.execution_graph.effective_edges) == 11

      kraken_edges =
        kraken_detail.product_tree.execution_graph.effective_edges
        |> Enum.map(&{&1.prerequisite_work_package_id, &1.dependent_work_package_id})
        |> MapSet.new()

      assert MapSet.subset?(
               MapSet.new([
                 {"WP-KRAKEN-07", "WP-KRAKEN-04"},
                 {"WP-KRAKEN-31", "WP-KRAKEN-27"},
                 {"WP-KRAKEN-47", "WP-KRAKEN-10"}
               ]),
               kraken_edges
             )

      projected_parse =
        Enum.find(fanout_detail.work_packages, &(&1.id == "WP-FANOUT-PARSE"))

      assert projected_parse.worker_signal["status"] == "active"
      assert get_in(projected_parse.pr_signal, ["checks", "status"]) == "pending"

      parse = Repo.get!(WorkPackage, "WP-FANOUT-PARSE")
      parse_context = Dashboard.work_package_contexts(Repo, [parse])[parse.id]
      assert parse_context.worker_signal.status == "active"
      assert parse_context.runtime_state.active?

      Repo.get!(AgentRun, "RUN-FANOUT-PARSE-LIVE")
      |> AgentRun.update_changeset(%{status: "running", last_seen_at: ~U[2020-01-01 00:00:00.000000Z]})
      |> Repo.update!()

      stale_context = Dashboard.work_package_contexts(Repo, [parse])[parse.id]
      assert stale_context.worker_signal.status == "stale"
      refute stale_context.runtime_state.active?
      refute stale_context.card.operational_state.has_active_worker

      assert {:ok, _branch_advance} =
               PlanningRepository.append_progress_event(Repo, %{
                 work_package_id: parse.id,
                 summary: "Fixture branch advanced",
                 status: "branch_attached",
                 payload: %{type: "branch", source_tool: "attach_branch", branch: "feat/fixture-parse", head_sha: "parse-next-head"},
                 created_at: ~U[2026-07-18 09:01:00.000000Z]
               })

      assert {:ok, advanced_fanout} = DeliveryBoard.project(Repo, "WR-FIXTURE-FANOUT")
      advanced_parse = Enum.find(advanced_fanout.work_packages, &(&1.id == parse.id))
      assert advanced_parse.work_package.review_signal.status == "pending"

      assert {:ok, recovery} = DeliveryBoard.project(Repo, "WR-FIXTURE-RECOVERY")
      recovery_packages = Map.new(recovery.work_packages, &{&1.id, &1})
      assert recovery_packages["WP-RECOVERY-OLD"].successor.work_package_id == "WP-RECOVERY-SUCCESSOR"
      assert recovery_packages["WP-RECOVERY-SKIPPED"].raw_status == "ended"
      assert recovery_packages["WP-RECOVERY-SKIPPED"].delivery.outcome == "skipped"
      assert recovery_packages["WP-RECOVERY-SUCCESSOR"].work_package.review_signal.status == "pending"
      assert Enum.count(recovery.work_packages, &(get_in(&1, [:work_package, :blocker_state, :active?]) == true)) == 1

      assert {:ok, [recovery_detail]} = Dashboard.work_request_board_details(Repo, ["WR-FIXTURE-RECOVERY"])
      assert recovery_detail.product_tree.summary.blocker_count == 1

      assert {:ok, dense_tree} = ProductTree.tree_for_work_request(Repo, "WR-FIXTURE-DENSE")
      assert {:ok, dense_packages} = WorkRequestRepository.list_work_packages(Repo, "WR-FIXTURE-DENSE")
      assert dense_packages |> Enum.map(& &1.group) |> Enum.uniq() |> length() == 3
      assert length(dense_tree.dependency_edges) == 18
      assert Repo.all(AgentRun) |> length() == 7

      assert Repo.all(PlanNode)
             |> Enum.filter(&(&1.work_package_id == "WP-FANOUT-PLAYTEST"))
             |> Enum.map(& &1.id)
             |> Enum.sort() == ["PLAN-FANOUT-PLAYTEST-01"]
    after
      Repo.put_dynamic_repo(previous_repo)
      GenServer.stop(pid)
    end
  end

  test "hydrated dashboard rejects unsupported methods" do
    assert json_response(post(build_conn(), "/api/v1/sympp/operator/dashboard/hydrated", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "local operator dashboard returns compact WorkRequest board details and lean modal enrichment", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(
          repo,
          id: "WR-LOCAL-COMPACT-DETAIL",
          human_description: "Full operator detail should stay lazy.",
          constraints: %{heavy: "constraint"}
        )

      assert {:ok, _decision} =
               WorkRequestRepository.record_decision(repo, work_request.id, decision_attrs(id: "WRD-LOCAL-COMPACT-DETAIL"))

      Enum.each(2..5, fn sequence ->
        assert {:ok, _decision} =
                 WorkRequestRepository.record_decision(
                   repo,
                   work_request.id,
                   decision_attrs(id: "WRD-LOCAL-COMPACT-DETAIL-#{sequence}")
                 )
      end)

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(
                 repo,
                 work_request.id,
                 work_package_attrs(
                   id: "WRS-LOCAL-COMPACT-DETAIL",
                   acceptance_criteria: ["Large acceptance text"],
                   validation_steps: ["Large validation text"],
                   allowed_file_globs: ["large/**"],
                   stop_conditions: ["Large stop condition"]
                 )
               )

      assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved_slice,
          id: "SYMPP-LOCAL-COMPACT-DETAIL",
          status: "dispatched"
        )

      assert {:ok, _dispatched_slice} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", work_package.id)

      assert {:ok, _delivery} =
               CanonicalWorkPackageFixtures.end_work_package(
                 repo,
                 work_request.id,
                 work_package.id,
                 delivery_attrs(%{
                   outcome: "completed_no_pr",
                   idempotency_key: "local-operator-compact-detail",
                   no_pr_evidence: "Full delivery evidence should stay lazy."
                 })
               )

      dashboard = local_operator_dashboard_payload()
      compact_detail = work_request_detail(dashboard, work_request.id)
      [compact_slice] = compact_detail["work_packages"]

      refute Map.has_key?(compact_detail, "decision_logs")
      refute Map.has_key?(compact_detail["work_request"], "human_description")
      refute Map.has_key?(compact_detail["work_request"], "constraints")
      refute Map.has_key?(compact_slice, "acceptance_criteria")
      refute Map.has_key?(compact_slice, "validation_steps")
      refute Map.has_key?(compact_slice, "allowed_file_globs")
      refute Map.has_key?(compact_slice, "stop_conditions")
      refute Map.has_key?(compact_slice["delivery"], "no_pr_evidence")
      assert compact_slice["operational_state"]["key"] == "completed_no_pr"

      enrichment =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-requests/#{work_request.id}")
        |> json_response(200)

      assert Enum.map(enrichment["decision_logs"], & &1["id"]) == [
               "WRD-LOCAL-COMPACT-DETAIL-5",
               "WRD-LOCAL-COMPACT-DETAIL-4",
               "WRD-LOCAL-COMPACT-DETAIL-3"
             ]

      assert enrichment["work_request"]["human_description"] == "Full operator detail should stay lazy."
      assert enrichment["work_request"]["constraints"] == %{"heavy" => "constraint"}
      assert enrichment["summary"]["decision_count"] == 5
      refute Map.has_key?(enrichment, "work_packages")
      refute Map.has_key?(enrichment, "product_tree")
      refute Map.has_key?(enrichment, "delivery_board")

      slice_enrichment =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-requests/#{work_request.id}?work_package_id=#{compact_slice["id"]}")
        |> json_response(200)

      assert [full_slice] = slice_enrichment["work_packages"]
      assert full_slice["id"] == compact_slice["id"]
      assert full_slice["acceptance_criteria"] == ["Large acceptance text"]
      assert full_slice["validation_steps"] == ["Large validation text"]
      assert full_slice["allowed_file_globs"] == ["large/**"]
      assert full_slice["stop_conditions"] == ["Large stop condition"]
      refute Map.has_key?(slice_enrichment, "product_tree")
      refute Map.has_key?(slice_enrichment, "delivery_board")
    end)
  end

  test "local operator dashboard infers canonical repo identity from local origin", %{repo: repo} do
    with_local_repo_origin("https://github.com/JJLiebig/sympp.git", fn ->
      with_local_operator_endpoint(fn ->
        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-IDENTITY",
                     repo: "sympp",
                     base_branch: "main"
                   )
                 )

        # An owner-qualified record of the same repository.
        assert {:ok, _qualified} =
                 WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REPO-IDENTITY-OWNER", repo: "JJLiebig/sympp", base_branch: "main"))

        assert {:ok, _work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Operator intake",
                   repo: "sympp",
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Build the dashboard.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch"
                 })

        payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
        deferred_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/deferred"), 200)
        archived_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=archived"), 200)

        refute Enum.any?(deferred_payload["work_packages"], &(&1["id"] == work_package.id))

        assert [%{"repo_key" => "sympp", "repo_remote" => "JJLiebig/sympp"}] =
                 payload["work_requests"]["work_requests"]

        assert [%{"work_request" => %{"repo_key" => "sympp", "repo_remote" => "JJLiebig/sympp"}}] =
                 deferred_payload["work_request_details"]

        refute Map.has_key?(payload, "archived_work_requests")
        refute Map.has_key?(payload, "work_request_details")
        refute Map.has_key?(payload, "board")
        assert payload["deferred"] == %{"dashboard_sections" => true}
        assert deferred_payload["deferred"] == %{"dashboard_sections" => false}
        assert archived_payload["archived_work_requests"] == %{"total_count" => 0, "work_requests" => []}
      end)
    end)
  end

  test "local operator WorkRequest mutations invalidate exactly once", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(repo,
          id: "WR-DASHBOARD-LOCAL-INVALIDATE",
          repo: "sympp",
          base_branch: "main"
        )

      work_request
      |> Ecto.Changeset.change(operator_completed_at: DateTime.utc_now(:microsecond))
      |> repo.update!()

      assert :ok = DashboardPubSub.subscribe()

      local_operator_conn()
      |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/archive", %{})
      |> json_response(200)

      assert_receive :operator_dashboard_changed
      refute_receive :operator_dashboard_changed, 50
    end)
  end

  test "coalesced mutation invalidation survives later response failure" do
    assert :ok = DashboardPubSub.subscribe()

    assert {{:error, :response_failed}, true} =
             DashboardPubSub.coalesce_changed(fn ->
               assert :ok = DashboardPubSub.broadcast_changed()
               assert :ok = DashboardPubSub.broadcast_changed()
               {:error, :response_failed}
             end)

    assert_receive :operator_dashboard_changed
    refute_receive :operator_dashboard_changed, 50
  end

  test "rolled-back WorkPackage writes do not invalidate the dashboard", %{repo: repo} do
    work_package = create_work_package!(repo, id: "SYMPP-DASHBOARD-PACKAGE-ROLLBACK")
    assert :ok = DashboardPubSub.subscribe()

    assert {:error, :forced_rollback} =
             repo.transaction(fn ->
               assert {:ok, _work_package} =
                        WorkPackageRepository.update(repo, work_package.id, %{title: "Rolled back title"})

               repo.rollback(:forced_rollback)
             end)

    refute_receive :operator_dashboard_changed, 50
    assert {:ok, persisted} = WorkPackageRepository.get(repo, work_package.id)
    assert persisted.title == work_package.title
  end

  test "local operator dashboard projects persisted local path repos through their git origin", %{repo: repo} do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!(
        "https://github.com/JJLiebig/nextide-saas-live-chat.git",
        prefix: "sympp-dashboard-repo-path"
      )

    try do
      with_local_operator_endpoint(fn ->
        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-PATH-IDENTITY",
                     repo: repo_path,
                     base_branch: "main"
                   )
                 )

        assert {:ok, work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Path repo projection",
                   repo: repo_path,
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Project the path repo through local git origin.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch"
                 })

        payload = local_operator_dashboard_payload()
        refute Enum.any?(payload["work_packages"], &(&1["id"] == work_package.id))

        assert [%{"repo" => ^repo_path, "repo_key" => "nextide-saas-live-chat", "repo_remote" => "JJLiebig/nextide-saas-live-chat"}] =
                 payload["work_requests"]["work_requests"]

        assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
        assert {:ok, persisted_request} = WorkRequestRepository.get(repo, work_request.id)

        assert persisted_package.repo == repo_path
        assert persisted_request.repo == repo_path
      end)
    after
      File.rm_rf(repo_path)
    end
  end

  test "local operator dashboard collapses raw remote bare and local path repo identities", %{repo: repo} do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!(
        "https://github.com/JJLiebig/nextide-saas-vod-intelligence.git",
        prefix: "sympp-dashboard-repo-mixed"
      )

    try do
      with_local_operator_endpoint(fn ->
        raw_remote = "JJLiebig/nextide-saas-vod-intelligence"
        bare_repo = "nextide-saas-vod-intelligence"

        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-MIXED-REMOTE",
                     repo: raw_remote,
                     base_branch: "main"
                   )
                 )

        # A local checkout of the same repository joins the same identity.
        assert {:ok, _path_package} =
                 WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REPO-MIXED-PATH", repo: repo_path, base_branch: "main"))

        assert {:ok, work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Mixed repo identity projection",
                   repo: bare_repo,
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Collapse raw remote, bare repo, and local path identities.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch"
                 })

        payload = local_operator_dashboard_payload()

        refute Enum.any?(payload["work_packages"], &(&1["id"] == work_package.id))

        assert [%{"id" => work_request_id, "repo" => ^bare_repo, "repo_key" => ^bare_repo, "repo_remote" => ^raw_remote}] =
                 payload["work_requests"]["work_requests"]

        assert work_request_id == work_request.id

        assert %{"work_request" => %{"repo" => ^bare_repo, "repo_key" => ^bare_repo, "repo_remote" => ^raw_remote}} =
                 work_request_detail(payload, work_request.id)

        assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
        assert {:ok, persisted_request} = WorkRequestRepository.get(repo, work_request.id)

        assert persisted_package.repo == raw_remote
        assert persisted_request.repo == bare_repo
      end)
    after
      File.rm_rf(repo_path)
    end
  end

  test "record detail repo identity stays scoped unless a catalog is passed", %{repo: repo} do
    with_trusted_repo_remotes(["JJLiebig/sympp"], fn ->
      assert {:ok, _unrelated} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-REPO-DETAIL-CATALOG-SOURCE",
                   repo: "JJLiebig/sympp",
                   base_branch: "main"
                 )
               )

      assert {:ok, work_request} =
               WorkRequestRepository.create(repo, %{
                 title: "Scoped detail request",
                 repo: "sympp",
                 base_branch: "main",
                 work_type: "feature",
                 human_description: "Keep detail identity scoped.",
                 constraints: %{},
                 desired_dispatch_shape: "architect_led_feature_branch"
               })

      assert {:ok, request_detail} = Dashboard.work_request_detail(repo, work_request.id)
      assert request_detail.work_request.repo_remote == nil
      assert request_detail.work_request.repo_aliases == ["sympp"]
    end)
  end

  test "dashboard repo identity keeps conflicting owner-qualified repos separate", %{repo: repo} do
    with_local_repo_origin("https://github.com/alpha/shared.git", fn ->
      repo_cases = [
        {:bare, "SYMPP-REPO-CONFLICT-BARE", "shared"},
        {:alpha, "SYMPP-REPO-CONFLICT-A", "alpha/shared"},
        {:beta, "SYMPP-REPO-CONFLICT-B", "beta/shared"}
      ]

      packages = Map.new(repo_cases, &create_repo_identity_package!(repo, &1))
      requests = Map.new(repo_cases, &create_repo_identity_request!(repo, &1))
      expectations = Map.new(repo_cases, fn {key, _id, raw_repo} -> {key, repo_identity_expectation(raw_repo)} end)

      assert {:ok, repo_identity_catalog} = Dashboard.local_operator_repo_identity_catalog(repo)
      opts = [repo_identity_catalog: repo_identity_catalog]

      assert {:ok, board} = Dashboard.operator_board(repo, opts)

      cards_by_id =
        board.groups["dispatched"]
        |> Map.new(&{&1.id, &1})

      Enum.each(repo_cases, fn {key, _id, _raw_repo} ->
        package_card = Map.fetch!(cards_by_id, Map.fetch!(packages, key).id)
        assert_repo_identity(package_card, Map.fetch!(expectations, key))
      end)

      assert {:ok, work_requests} = Dashboard.work_requests(repo, opts)

      request_cards_by_id =
        work_requests.work_requests
        |> Map.new(&{&1.id, &1})

      Enum.each(repo_cases, fn {key, _id, _raw_repo} ->
        request = Map.fetch!(requests, key)

        request_card = Map.fetch!(request_cards_by_id, request.id)
        assert_repo_identity(request_card, Map.fetch!(expectations, key))

        assert {:ok, detail} = Dashboard.work_request_detail(repo, request.id, opts)
        assert_repo_identity(detail.work_request, Map.fetch!(expectations, key))
      end)
    end)
  end

  test "preloaded repo identities include archived WorkRequest repos", %{repo: repo} do
    create_work_request!(repo, id: "WR-REPO-ACTIVE", repo: "shared")
    archived = create_work_request!(repo, id: "WR-REPO-ARCHIVED", repo: "beta/shared")
    set_work_request_archived_at!(archived, repo, DateTime.utc_now(:microsecond))

    assert {:ok, active_requests} = WorkRequestRepository.list(repo)
    assert length(active_requests) == 1
    assert {:ok, packages} = WorkPackageRepository.list(repo)
    assert {:ok, expected} = Dashboard.local_operator_repo_identity_catalog(repo)
    assert {:ok, actual} = Dashboard.local_operator_repo_identity_catalog(repo, packages, active_requests)
    assert actual == expected
  end

  test "local operator dashboard exposes active blocking edges", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(
          repo,
          id: "WR-ACTIVE-BLOCKING-EDGES",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(
                 repo,
                 work_request.id,
                 work_package_attrs(id: "WRS-ACTIVE-BLOCKING-EDGES")
               )

      assert {:ok, approved_slice} =
               CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

      linked_package =
        create_matching_work_package!(
          repo,
          work_request,
          approved_slice,
          id: "SYMPP-ACTIVE-BLOCKING-LINKED",
          status: "dispatched"
        )

      assert {:ok, _dispatched_slice} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", linked_package.id)

      unlinked_package =
        create_work_package!(
          repo,
          id: "SYMPP-ACTIVE-BLOCKING-UNLINKED",
          status: "dispatched"
        )

      timestamp = ~U[2026-05-20 10:00:00Z]

      append_blocker_event!(repo, linked_package.id, "blocker-linked", true,
        summary: "Blocked by sk-secret123",
        body: "Bearer raw-secret-value",
        created_at: DateTime.add(timestamp, 1, :second)
      )

      append_blocker_event!(repo, linked_package.id, "blocker-resolved", true,
        summary: "Temporary blocker",
        created_at: DateTime.add(timestamp, 2, :second)
      )

      append_blocker_event!(repo, linked_package.id, "blocker-resolved", false,
        summary: "Resolved blocker",
        created_at: DateTime.add(timestamp, 3, :second)
      )

      append_blocker_event!(repo, unlinked_package.id, "blocker-unlinked", true,
        summary: "Blocked on review",
        created_at: DateTime.add(timestamp, 4, :second)
      )

      payload = local_operator_dashboard_payload()
      edges = payload["active_blocking_edges"]

      assert Enum.map(edges, & &1["blocker_id"]) == ["blocker-linked"]
      refute Enum.any?(edges, &(&1["blocker_id"] == "blocker-resolved"))

      assert [linked_edge] = edges
      assert linked_edge["from"] == %{"kind" => "work_package", "id" => linked_package.id}
      assert linked_edge["to"] == %{"kind" => "work_package", "id" => linked_package.id}
      assert linked_edge["work_request_id"] == work_request.id
      assert linked_edge["work_package_id"] == linked_package.id
      assert linked_edge["summary"] == "[REDACTED]"
      assert linked_edge["body"] == "[REDACTED]"

      linked_card =
        payload["work_packages"]
        |> Enum.find(&(&1["id"] == linked_package.id))

      assert linked_card["active_blocker_count"] == 1
      assert [%{"id" => "blocker-linked", "summary" => "[REDACTED]", "active" => true}] = linked_card["active_blockers"]

      repeated_payload = local_operator_dashboard_payload()
      assert Enum.map(repeated_payload["active_blocking_edges"], & &1["id"]) == Enum.map(edges, & &1["id"])
    end)
  end

  test "hydrated board exposes dispatch and stable forward PR observations", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, request} =
               WorkRequestRepository.create(repo, %{
                 title: "Widget delivery",
                 repo: "example-org/widget-service",
                 base_branch: "beta",
                 work_type: "feature",
                 human_description: "Deliver widget support.",
                 desired_dispatch_shape: "single_package"
               })

      assert {:ok, package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WP-WIDGET-BOARD", repo: "example-org/widget-service", base_branch: "beta"))
      package |> Ecto.Changeset.change(dispatched_at: ~U[2026-10-01 09:00:00.000000Z]) |> repo.update!()

      fetch = fn ->
        payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/hydrated"), 200)
        detail = Enum.find(payload["work_request_details"], &(&1["work_request"]["id"] == request.id))
        Enum.find(detail["work_packages"], &(&1["id"] == package.id))
      end

      assert %{"stage" => "build", "entered_at" => "2026-10-01T09:00:00.000000Z"} = fetch.()["board_state"]

      snapshot = %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "repository" => "example-org/widget-service",
        "number" => 42,
        "url" => "https://github.com/example-org/widget-service/pull/42",
        "head_sha" => "head-a",
        "created_at" => "2026-10-01T09:05:00Z",
        "check_summary" => %{"status" => "pending"}
      }

      append = fn payload, offset ->
        attrs = %{work_package_id: package.id, summary: "Observed widget PR", status: "pr_synced", payload: payload, created_at: DateTime.add(~U[2026-10-01 09:10:00Z], offset, :second)}
        assert {:ok, event} = PlanningRepository.append_progress_event(repo, attrs)
        event
      end

      first = append.(snapshot, 0)
      assert %{"stage" => "checks", "entered_at" => nil} = fetch.()["board_state"]
      assert fetch.()["pr_signal"]["checks"]["changed_at"] == first.payload["checks_changed_at"]
      assert fetch.()["pr_signal"]["created_at"] == "2026-10-01T09:05:00Z"

      assert {:ok, _backfill} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: package.id,
                 summary: "Earlier widget attachment",
                 status: "pr_attached",
                 payload: Map.delete(snapshot, "check_summary"),
                 created_at: ~U[2025-10-01 09:00:00Z]
               })

      repeated = append.(Map.put(snapshot, "source_tool", "sync_pr"), 2)
      assert repeated.payload["checks_changed_at"] == first.payload["checks_changed_at"]
      assert fetch.()["board_state"]["entered_at"] == nil

      next_head = append.(snapshot |> Map.put("source_tool", "sync_pr") |> Map.put("head_sha", "head-b"), 3)
      assert next_head.payload["head_changed_at"] != first.payload["head_changed_at"]
      assert fetch.()["pr_signal"]["head_sha"] == "head-b"
      assert fetch.()["pr_signal"]["checks"]["changed_at"] == next_head.payload["checks_changed_at"]

      append.(%{"type" => "branch", "source_tool" => "attach_branch", "branch" => "feat/widget", "head_sha" => "head-a"}, 4)
      returning = append.(Map.put(snapshot, "source_tool", "sync_pr"), 5)
      assert returning.payload["head_changed_at"] != first.payload["head_changed_at"]
      assert returning.payload["head_changed_at"] != next_head.payload["head_changed_at"]
      assert returning.payload["checks_changed_at"] != next_head.payload["checks_changed_at"]
      assert fetch.()["pr_signal"]["head_changed_at"] == returning.payload["head_changed_at"]

      passing_snapshot = snapshot |> Map.put("source_tool", "sync_pr") |> Map.put("check_summary", %{"status" => "passing"})
      passing = append.(passing_snapshot, 7)
      append.(snapshot, 6)
      stable = append.(passing_snapshot, 8)
      assert stable.payload["checks_changed_at"] == passing.payload["checks_changed_at"]
      assert stable.payload["head_changed_at"] == returning.payload["head_changed_at"]
      assert fetch.()["pr_signal"]["checks"]["changed_at"] == passing.payload["checks_changed_at"]
    end)
  end

  test "operator notification stream rejects cross-origin requests and unsupported methods" do
    conn = local_operator_conn() |> put_req_header("origin", "https://example.invalid")
    assert json_response(get(conn, "/api/v1/sympp/operator/events"), 401)["error"]["code"] == "unauthorized"
    assert json_response(post(local_operator_conn(), "/api/v1/sympp/operator/events", %{}), 405)["error"]["code"] == "method_not_allowed"
  end

  test "local operator config keeps runtime bootstrap usable when priority data is unavailable" do
    with_local_operator_endpoint(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, sympp_repo: BusyRepo)

      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/config"), 200)

      refute Map.has_key?(payload, "dashboard")
    end)
  end

  test "localhost requests without same-origin browser metadata are rejected" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(
                 post(conn, "/api/v1/sympp/operator/work-requests", %{
                   "title" => "Cross-origin request",
                   "repo" => "sympp",
                   "base_branch" => "main"
                 }),
                 401
               )
    end)
  end

  test "exited or idle workers route recovery to the architect while failing checks wait on an active worker" do
    alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard.Signals
    package = %SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage{status: "dispatched"}
    unseen = Signals.activity(package, %{}, %{key: "dispatched"}, [])
    assert {unseen["next_actor"], unseen["next_action"]} == {"architect", "run_launch_line"}
    working = Signals.activity(package, %{worker_terminal: %{state: "live", status: "working"}}, %{key: "dispatched"}, [])
    assert {working["next_actor"], working["next_action"]} == {"worker", "wait"}
    exited = Signals.activity(package, %{worker_terminal: %{state: "finished", status: "finished"}}, %{key: "dispatched"}, [])
    assert exited["next_actor"] == "architect"
    assert exited["next_action"] == "inspect_worker"
    assert exited["waiting_reason"] == "worker_exited"
    failing_pr = %{status: "open", checks: %{status: "failing"}}
    working_terminal = %{state: "live", status: "working"}
    failing = Signals.activity(package, %{pr_signal: failing_pr, worker_terminal: working_terminal}, %{key: "dispatched"}, [])
    assert failing["next_actor"] == "worker"
    assert failing["next_action"] == "wait"
    assert failing["waiting_reason"] == "validation_failed"
    idle_terminal = %{state: "live", status: "idle"}
    unattended = Signals.activity(package, %{pr_signal: failing_pr, worker_terminal: idle_terminal}, %{key: "dispatched"}, [])
    assert unattended["next_actor"] == "architect"
    assert unattended["next_action"] == "inspect_worker"
    exited_terminal = %{state: "finished", status: "finished"}
    abandoned = Signals.activity(package, %{pr_signal: failing_pr, worker_terminal: exited_terminal}, %{key: "dispatched"}, [])
    assert {abandoned["next_actor"], abandoned["next_action"]} == {"architect", "inspect_worker"}
  end

  test "Herdr reads the complete execution graph and current worker sessions over direct loopback", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-HERDR-DETAIL")

      for sequence <- 1..5 do
        assert {:ok, _decision} =
                 WorkRequestRepository.record_decision(repo, work_request.id, decision_attrs(id: "WRD-HERDR-DETAIL-#{sequence}"))
      end

      active =
        create_work_package!(repo,
          id: "WP-HERDR-ACTIVE",
          work_request_id: work_request.id,
          group: "Delivery / Runtime",
          status: "dispatched",
          owner_id: "accountable-owner"
        )

      downstream =
        create_work_package!(repo,
          id: "WP-HERDR-DOWNSTREAM",
          work_request_id: work_request.id,
          group: "Delivery",
          status: "planned"
        )

      stale =
        create_work_package!(repo,
          id: "WP-HERDR-STALE",
          work_request_id: work_request.id,
          status: "dispatched",
          owner_id: "stale-accountable-owner"
        )

      terminal =
        create_work_package!(repo,
          id: "WP-HERDR-TERMINAL-RUN",
          work_request_id: work_request.id,
          status: "dispatched"
        )

      assert {:ok, _edge} =
               ProductTree.create_dependency_edge(repo, %{
                 work_request_id: work_request.id,
                 source_kind: "work_package",
                 source_id: active.id,
                 target_kind: "work_package",
                 target_id: downstream.id,
                 kind: "depends_on",
                 reason: "Herdr graph fixture"
               })

      assert {:ok, active_run} =
               AgentRunRepository.start_run(repo, %{
                 work_package_id: active.id,
                 status: "running",
                 actor_id: "current-actor",
                 session_id: "codex-current-session"
               })

      append_blocker_event!(repo, active.id, "herdr-blocker", true, summary: "Needs operator attention")

      assert {:ok, _stale_run} =
               AgentRunRepository.start_run(repo, %{
                 work_package_id: stale.id,
                 status: "running",
                 session_id: "codex-stale-session",
                 last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -600, :second)
               })

      assert {:ok, terminal_run} =
               AgentRunRepository.start_run(repo, %{
                 work_package_id: terminal.id,
                 status: "running",
                 session_id: "codex-terminal-session"
               })

      assert {:ok, _terminal_run} = AgentRunRepository.mark_completed(repo, terminal_run.id, "done")

      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> get("/api/v1/sympp/herdr/work-requests/#{work_request.id}")

      payload = json_response(conn, 200)
      assert get_in(payload, ["work_request", "id"]) == work_request.id
      assert Enum.map(payload["decision_logs"], & &1["id"]) == Enum.map(5..1, &"WRD-HERDR-DETAIL-#{&1}")
      assert payload["summary"]["decision_count"] == 5

      assert %{
               "work_request_id" => work_request_id,
               "sequence" => 5,
               "source_type" => "architect",
               "decision" => "Keep this WorkRequest narrow.",
               "rationale" => "The next slice owns broader orchestration.",
               "scope_impact" => "No new runtime tools.",
               "created_by" => "architect-1"
             } = hd(payload["decision_logs"])

      assert work_request_id == work_request.id

      assert Enum.sort(payload["execution_graph"]["work_package_ids"]) ==
               Enum.sort([active.id, downstream.id, stale.id, terminal.id])

      assert Enum.any?(payload["execution_graph"]["effective_edges"], fn edge ->
               edge["prerequisite_work_package_id"] == downstream.id and edge["dependent_work_package_id"] == active.id
             end)

      assert payload["worker_sessions"] == [
               %{"work_package_id" => active.id, "agent_session_id" => "codex-current-session"}
             ]

      packages = Map.new(payload["work_packages"], &{&1["id"], &1})
      assert packages[active.id]["activity_signal"]["accountable_owner"]["id"] == "accountable-owner"
      assert packages[active.id]["activity_signal"]["current_actor"]["id"] == "current-actor"
      assert packages[stale.id]["activity_signal"]["accountable_owner"]["id"] == "stale-accountable-owner"
      assert packages[stale.id]["activity_signal"]["current_actor"] == nil
      assert packages[stale.id]["activity_signal"]["observation_state"] == "stale"
      assert packages[terminal.id]["activity_signal"]["current_actor"] == nil
      assert packages[terminal.id]["activity_signal"]["observation_state"] == "unknown"

      assert payload["attention_keys"] == ["group:Delivery", "group:Delivery / Runtime", "work_package:#{active.id}"]

      assert :ok = OperatorDashboardOpener.ensure_started()
      opener = :sys.get_state(OperatorDashboardOpener)
      assert :ok = DashboardPubSub.subscribe()

      assert {:error, :native_read_verified} =
               repo.transaction(fn ->
                 # A pending migration must not turn this read into a schema write.
                 repo.query!("DELETE FROM schema_migrations WHERE version = (SELECT MAX(version) FROM schema_migrations)", [])
                 before_read = repo.query!("SELECT total_changes()", []).rows

                 board =
                   build_conn()
                   |> Map.put(:host, "localhost")
                   |> Map.put(:remote_ip, {127, 0, 0, 1})
                   |> get("/api/v1/sympp/herdr/dashboard")
                   |> json_response(200)

                 detail = Enum.find(board["work_request_details"], &(&1["work_request"]["id"] == work_request.id))
                 assert Enum.find(detail["work_packages"], &(&1["id"] == active.id))["group"] == "Delivery / Runtime"
                 signal = Enum.find(board["work_packages"], &(&1["id"] == active.id))
                 assert signal["active_agent_run"]["id"] == active_run.id
                 assert board["runtime"] == %{"offline" => false, "repos_root" => nil}

                 native_detail =
                   build_conn()
                   |> Map.put(:host, "localhost")
                   |> Map.put(:remote_ip, {127, 0, 0, 1})
                   |> get("/api/v1/sympp/herdr/work-requests/#{work_request.id}")
                   |> json_response(200)

                 assert native_detail["decision_logs"] == payload["decision_logs"]
                 assert repo.query!("SELECT total_changes()", []).rows == before_read
                 repo.rollback(:native_read_verified)
               end)

      assert :sys.get_state(OperatorDashboardOpener) == opener
      refute_received :operator_dashboard_changed

      for {host, remote_ip} <- [{"localhost", {203, 0, 113, 1}}, {"example.invalid", {127, 0, 0, 1}}] do
        denied =
          build_conn()
          |> Map.put(:host, host)
          |> Map.put(:remote_ip, remote_ip)
          |> get("/api/v1/sympp/herdr/dashboard")

        assert json_response(denied, 401)["error"]["code"] == "unauthorized"

        for path <- [
              "/api/v1/sympp/herdr/work-requests",
              "/api/v1/sympp/herdr/asks/missing/answer",
              "/api/v1/sympp/herdr/decisions/missing/feedback",
              "/api/v1/sympp/herdr/cards/missing/dismiss",
              "/api/v1/sympp/herdr/work-packages/missing/finish",
              "/api/v1/sympp/herdr/work-requests/missing/release",
              "/api/v1/sympp/herdr/work-requests/missing/complete",
              "/api/v1/sympp/herdr/work-requests/missing/archive",
              "/api/v1/sympp/herdr/work-requests/missing/restore",
              "/api/v1/sympp/herdr/work-requests/missing/delete"
            ] do
          mutation =
            native_operator_conn()
            |> Map.put(:host, host)
            |> Map.put(:remote_ip, remote_ip)
            |> post(path, Jason.encode!(%{answer: "Denied network input"}))

          assert json_response(mutation, 401)["error"]["code"] == "unauthorized"
        end
      end

      with_local_operator_dashboard_origin("http://localhost", fn ->
        for method <- [:post, :options],
            path <- [
              "/api/v1/sympp/herdr/work-requests",
              "/api/v1/sympp/herdr/asks/missing/answer",
              "/api/v1/sympp/herdr/decisions/missing/feedback",
              "/api/v1/sympp/herdr/cards/missing/dismiss",
              "/api/v1/sympp/herdr/work-packages/missing/finish",
              "/api/v1/sympp/herdr/work-requests/missing/release",
              "/api/v1/sympp/herdr/work-requests/missing/complete",
              "/api/v1/sympp/herdr/work-requests/missing/archive",
              "/api/v1/sympp/herdr/work-requests/missing/restore",
              "/api/v1/sympp/herdr/work-requests/missing/delete"
            ] do
          request =
            native_operator_conn()
            |> put_req_header("origin", "http://localhost")
            |> dispatch(@endpoint, method, path, "{}")

          assert request.status == if(method == :post, do: 401, else: 405)
          assert Plug.Conn.get_resp_header(request, "access-control-allow-origin") == []
          assert Plug.Conn.get_resp_header(request, "access-control-allow-methods") == []
        end
      end)

      forwarded =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "127.0.0.1")
        |> get("/api/v1/sympp/herdr/work-requests/#{work_request.id}")

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(forwarded, 401)
    end)
  end

  test "Herdr detail returns a storage error without migrating an uninitialized ledger" do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    try do
      {conn, queries} =
        capture_queries(fn ->
          build_conn()
          |> Map.put(:host, "localhost")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> get("/api/v1/sympp/herdr/work-requests/missing")
        end)

      assert json_response(conn, 503) ==
               %{"error" => %{"code" => "storage_failed", "message" => "Dashboard ledger storage failed"}}

      refute Enum.any?(queries, &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/i, &1))
    after
      Application.put_env(:symphony_elixir, :sympp_repo_database, original_database)
      File.rm(database_path)
    end
  end

  test "Herdr detail returns the existing busy error" do
    with_local_operator_endpoint(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, sympp_repo: BusyRepo)

      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> get("/api/v1/sympp/herdr/work-requests/missing")

      assert json_response(conn, 503) ==
               %{"error" => %{"code" => "database_busy", "message" => "Dashboard ledger is busy"}}
    end)
  end

  test "Herdr details show the Review Suite cycle the Observer read", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-HERDR-OBSERVED-REVIEW")

      reviewing =
        repo
        |> create_work_package!(id: "WP-HERDR-OBSERVED-REVIEW", work_request_id: work_request.id, status: "dispatched")
        |> Ecto.Changeset.change(review_mode: "fast", review_id: "rvw_observed01")
        |> repo.update!()

      observed = %{
        "evidence_id" => "rvw_observed01",
        "status" => "in_progress",
        "provider_status" => "running",
        "round" => 3,
        "current" => 2,
        "total" => 3,
        "step" => "correctness",
        "next_action" => "wait",
        "steps" => [%{"index" => 2, "name" => "correctness", "state" => "current"}],
        "round_history" => [%{"number" => 3, "step" => "correctness", "status" => "running", "started_at" => "2026-10-01T09:00:00Z"}],
        "round_started_at" => "2026-10-01T09:00:00Z",
        "observed_at" => "2026-10-01T09:05:00Z"
      }

      repo.insert!(%Observation{work_package_id: reviewing.id, review: observed, stale: [], observed_at: DateTime.utc_now(:microsecond)})

      payload =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> get("/api/v1/sympp/herdr/work-requests/#{work_request.id}")
        |> json_response(200)

      packages = Map.new(payload["work_packages"], &{&1["id"], &1})
      review = packages[reviewing.id]["review_signal"]
      assert review["evidence_id"] == "rvw_observed01"
      assert review["mode"] == "fast"
      assert {review["current"], review["total"], review["round"]} == {2, 3, 3}
      assert review["step"] == "correctness"
      assert review["status"] == "in_progress"
      assert review["observation_state"] == "current"
      assert review["steps"] == [%{"index" => 2, "name" => "correctness", "state" => "current"}]

      web_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/hydrated"), 200)
      web_detail = Enum.find(web_payload["work_request_details"], &(&1["work_request"]["id"] == work_request.id))
      assert Enum.find(web_detail["work_packages"], &(&1["id"] == reviewing.id))["review_signal"] == review

      activity = packages[reviewing.id]["activity_signal"]
      assert activity["stage"] == "reviewing"
      assert activity["waiting_reason"] == "review_in_progress"

      # A package whose review host can't be read isn't merge eligible.
      assert {:ok, _ready} = Lifecycle.transition(repo, repo.get!(WorkPackage, reviewing.id), :qualify)
      repo.update!(Ecto.Changeset.change(repo.get!(Observation, reviewing.id), review: %{"status" => "passed", "done" => true}, stale: ["review"]))
      assert {:ok, ready_payload} = LocalOperatorDashboard.herdr_work_request_detail_payload(repo, work_request.id)
      ready_package = Enum.find(ready_payload.work_packages, &(&1.id == reviewing.id))
      assert ready_package.review_signal["status"] == "passed"
      assert "observation_stale" in ready_package.merge_eligibility["reason_codes"]
      refute ready_package.merge_eligibility["eligible"]
      assert ready_package.activity_signal["next_action"] == "wait"
    end)
  end

  test "ordinary local dashboard load can mutate directly", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-ORDINARY-MUTATION")
      index = "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>"

      with_static_dashboard_file("index.html", index, fn ->
        shell_conn =
          build_conn(:get, "/sympp/board")
          |> Map.put(:host, "localhost")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("sec-fetch-site", "none")
          |> put_req_header("sec-fetch-mode", "navigate")
          |> get("/sympp/board")

        html_response(shell_conn, 200)

        payload =
          shell_conn
          |> recycle_local_operator_conn("http://localhost")
          |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/complete", %{})
          |> json_response(200)

        assert payload["work_request"]["phase"] == "done"
        assert is_binary(payload["work_request"]["operator_completed_at"])

        assert {:ok, %{operator_completed_at: %DateTime{}}} =
                 WorkRequestRepository.get(repo, work_request.id)
      end)
    end)
  end

  test "spp.localhost dashboard origin can load local operator config" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://spp.localhost:5174", fn ->
        index = "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>"

        with_static_dashboard_file("index.html", index, fn ->
          shell_conn =
            build_conn(:get, "/sympp/board")
            |> Map.put(:host, "spp.localhost")
            |> Map.put(:remote_ip, {127, 0, 0, 1})
            |> put_req_header("sec-fetch-site", "none")
            |> put_req_header("sec-fetch-mode", "navigate")
            |> ReactDashboardController.index(%{})

          assert redirected_to(shell_conn, 302) == "http://spp.localhost:5174/sympp/board"

          conn =
            build_conn()
            |> Map.put(:host, "127.0.0.1")
            |> Map.put(:remote_ip, {127, 0, 0, 1})
            |> put_req_header("origin", "http://spp.localhost:5174")
            |> put_req_header("sec-fetch-site", "same-site")
            |> put_req_header("sec-fetch-mode", "cors")
            |> put_req_header("sec-fetch-dest", "empty")
            |> get("/api/v1/sympp/operator/config")

          json_response(conn, 200)
        end)
      end)
    end)
  end

  test "same-origin local dashboard config is available without bootstrap state" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("sec-fetch-site", "same-origin")
        |> put_req_header("sec-fetch-mode", "cors")
        |> put_req_header("sec-fetch-dest", "empty")
        |> get("/api/v1/sympp/operator/config")

      json_response(conn, 200)
    end)
  end

  test "configured nonlocal dashboard origin is rejected" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://example.com:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://example.com:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
      end)
    end)
  end

  test "local-looking cross-origin requests do not become local operator" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("origin", "http://localhost:3000")
        |> put_req_header("sec-fetch-site", "cross-site")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(
                 post(conn, "/api/v1/sympp/operator/work-requests", %{
                   "title" => "Cross-origin request",
                   "repo" => "sympp",
                   "base_branch" => "main"
                 }),
                 401
               )
    end)
  end

  test "configured dashboard origin can load local operator config" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://127.0.0.1:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://127.0.0.1:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        json_response(conn, 200)
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["http://127.0.0.1:5174"]
      end)
    end)
  end

  test "configured local dashboard origin receives operator API preflight" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://127.0.0.1:5174", fn ->
        conn =
          build_conn(:options, "/api/v1/sympp/operator/work-requests")
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://127.0.0.1:5174")
          |> put_req_header("access-control-request-method", "POST")
          |> put_req_header("access-control-request-headers", "content-type")
          |> options("/api/v1/sympp/operator/work-requests")

        assert response(conn, 204) == ""
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["http://127.0.0.1:5174"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-headers") == ["accept, content-type"]
      end)
    end)
  end

  test "configured dashboard origin rejects a different localhost hostname" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://spp.localhost:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://other.localhost:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []
      end)
    end)
  end

  test "the operator dismisses a card on the board or in the Herdr panel", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      card = insert_card!(repo, "core/t1", "review_ci", nil, DateTime.utc_now(:microsecond))

      assert [%{"id" => card_id, "state" => "review_ci", "worked_on" => %{"address" => "core/t1"}}] =
               native_operator_conn() |> get("/api/v1/sympp/herdr/dashboard") |> json_response(200) |> Map.fetch!("cards")

      assert card_id == card.id

      assert %{"ok" => true, "card_id" => ^card_id, "state" => "dismissed"} =
               local_operator_conn() |> post("/api/v1/sympp/operator/cards/#{card_id}/dismiss") |> json_response(200)

      assert %{"ok" => true, "state" => "dismissed"} =
               native_operator_conn() |> post("/api/v1/sympp/herdr/cards/#{card_id}/dismiss", "{}") |> json_response(200)

      assert [%{"id" => ^card_id, "state" => "dismissed"}] = local_operator_dashboard_payload()["cards"]
      assert %{"error" => %{"code" => "not_found"}} = local_operator_conn() |> post("/api/v1/sympp/operator/cards/missing/dismiss") |> json_response(404)
    end)
  end

  test "both boards show each package's worker terminal, stale observations, progress and CI override", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      request = create_work_request!(repo, id: "WR-WORKER-SIGNALS")
      working = create_work_package!(repo, id: "WP-SIGNALS-WORKING", work_request_id: request.id, status: "dispatched")
      exited = create_work_package!(repo, id: "WP-SIGNALS-EXITED", work_request_id: request.id, status: "dispatched")
      planned = create_work_package!(repo, id: "WP-SIGNALS-PLANNED", work_request_id: request.id, status: "planned")
      now = DateTime.utc_now(:microsecond)

      for {package, address, state} <- [{working, "t5", "live"}, {exited, "t6", "finished"}] do
        repo.insert!(%WorkedOn{
          id: "wo-" <> package.id,
          subject_kind: "work_package",
          subject_id: package.id,
          terminal_key: "core-test/" <> address,
          display_address: "jjdev/" <> address,
          role: "worker",
          state: state,
          started_at: now
        })
      end

      repo.insert!(%Observation{work_package_id: working.id, stale: ["github"], observed_at: now})
      override = %{"reason" => "CI is stuck on the runner queue.", "by" => "jjdev/t1", "head" => String.duplicate("a", 40)}
      repo.update!(Ecto.Changeset.change(working, ci_override: override))
      # The factory's core sees the live worker busy.
      core_view = {:ok, %{core_id: "core-test", terminals: %{"t5" => %{"state" => "live", "status" => "working"}}}}
      Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core_view end)
      on_exit(fn -> Application.put_env(:symphony_elixir, :sympp_herdr_core, nil) end)

      expected = %{
        working.id => %{
          "worker_terminal" => %{"address" => "jjdev/t5", "state" => "live", "status" => "working"},
          "observation_stale" => ["github"],
          "progress" => "implementing",
          "ci_override" => override
        },
        exited.id => %{
          "worker_terminal" => %{"address" => "jjdev/t6", "state" => "finished", "status" => "finished"},
          "observation_stale" => [],
          "progress" => "worker_exited"
        },
        planned.id => %{"worker_terminal" => nil, "observation_stale" => [], "progress" => nil}
      }

      for path <- ["/api/v1/sympp/herdr/dashboard", "/api/v1/sympp/operator/dashboard/hydrated"] do
        conn = if String.contains?(path, "/herdr/"), do: native_operator_conn(), else: local_operator_conn()
        detail = conn |> get(path) |> json_response(200) |> work_request_detail(request.id)
        observed = Map.new(detail["work_packages"], &{&1["id"], Map.take(&1, ["worker_terminal", "observation_stale", "progress", "ci_override"])})
        assert observed == expected, path
      end
    end)
  end

  test "ended cards drop off the board and the ledger after the card retention window", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"card_retention_days" => 1})
      # The factory's core reports these terminals finished.
      Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> {:ok, %{core_id: "core", terminals: %{}}} end)
      on_exit(fn -> Application.put_env(:symphony_elixir, :sympp_herdr_core, nil) end)

      now = DateTime.utc_now(:microsecond)
      long_ago = DateTime.add(now, -3 * 24 * 60 * 60, :second)
      open = insert_card!(repo, "core/t1", "working", nil, long_ago)
      expired = insert_card!(repo, "core/t2", "merged", long_ago, long_ago)
      recent = insert_card!(repo, "core/t3", "done", now, now)

      repo.insert!(%Ask{
        id: "ask-expired-card",
        card_id: expired.id,
        question: "Old question",
        state: "withdrawn",
        inserted_at: long_ago,
        updated_at: long_ago
      })

      assert Enum.map(local_operator_dashboard_payload()["cards"], & &1["id"]) == [open.id, recent.id]

      run_operator_retention(repo)

      assert Enum.map(local_operator_dashboard_payload()["cards"], &{&1["id"], &1["state"]}) == [{open.id, "working"}, {recent.id, "done"}]
      assert repo.get(Card, expired.id) == nil
      assert repo.get(Ask, "ask-expired-card") == nil
      refute repo.exists?(from(row in WorkedOn, where: row.subject_id == ^expired.id))
      assert repo.exists?(from(row in WorkedOn, where: row.subject_id == ^recent.id))
    end)
  end

  test "local operator retention skips repeated passes inside the throttle window", %{repo: repo} do
    with_retention_throttle_ms(60_000, fn ->
      with_local_operator_endpoint(fn ->
        assert {:ok, _settings} =
                 OperatorSettingsRepository.update(repo, %{
                   "work_request_archive_after_days" => 1,
                   "card_retention_days" => 1
                 })

        stale_at = DateTime.add(DateTime.utc_now(:microsecond), -8 * 24 * 60 * 60, :second)

        first_request = create_completed_delivered_work_request!(repo, "WR-LOCAL-THROTTLE-FIRST", stale_at)

        run_operator_retention(repo)
        first_payload = local_operator_dashboard_payload()

        assert Enum.any?(first_payload["archived_work_requests"]["work_requests"], &(&1["id"] == first_request.id))

        second_request = create_completed_delivered_work_request!(repo, "WR-LOCAL-THROTTLE-SECOND", stale_at)

        run_operator_retention(repo)
        second_payload = local_operator_dashboard_payload()

        assert Enum.any?(second_payload["work_requests"]["work_requests"], &(&1["id"] == second_request.id))
        refute Enum.any?(second_payload["archived_work_requests"]["work_requests"], &(&1["id"] == second_request.id))
      end)
    end)
  end

  test "local operator retention runs after the throttle window expires", %{repo: repo} do
    with_retention_throttle_ms(10, fn ->
      with_local_operator_endpoint(fn ->
        assert {:ok, _settings} =
                 OperatorSettingsRepository.update(repo, %{
                   "work_request_archive_after_days" => 1,
                   "card_retention_days" => 1
                 })

        stale_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
        first_request = create_completed_delivered_work_request!(repo, "WR-LOCAL-THROTTLE-EXPIRED-FIRST", stale_at)

        run_operator_retention(repo)
        first_payload = local_operator_dashboard_payload()

        assert Enum.any?(first_payload["archived_work_requests"]["work_requests"], &(&1["id"] == first_request.id))

        second_request = create_completed_delivered_work_request!(repo, "WR-LOCAL-THROTTLE-EXPIRED-SECOND", stale_at)

        Process.sleep(25)

        run_operator_retention(repo)
        second_payload = local_operator_dashboard_payload()

        refute Enum.any?(second_payload["work_requests"]["work_requests"], &(&1["id"] == second_request.id))
        assert Enum.any?(second_payload["archived_work_requests"]["work_requests"], &(&1["id"] == second_request.id))
      end)
    end)
  end

  test "local operator retention keeps only linked WorkPackage signals", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"work_request_archive_after_days" => 1})

      stale_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
      recent_at = DateTime.utc_now(:microsecond)

      stale_terminal_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-STALE-TERMINAL",
          status: "ended",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )
        |> set_work_package_updated_at!(repo, stale_at)

      recent_terminal_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-RECENT-TERMINAL",
          status: "ended",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, recent_at)

      active_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-ACTIVE",
          status: "dispatched",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      existing_hidden_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-EXISTING-HIDDEN",
          status: "ended",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      terminal_parent_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-TERMINAL-PARENT",
          status: "ended",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      child_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-PARENT-CHILD",
          status: "dispatched",
          parent_id: terminal_parent_package.id,
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      work_request =
        create_work_request!(repo,
          id: "WR-LOCAL-RETENTION-LINKED",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(
                 repo,
                 work_request.id,
                 work_package_attrs(id: "WRS-LOCAL-RETENTION-LINKED", base_branch: work_request.base_branch)
               )

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      linked_terminal_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-RETENTION-LINKED-TERMINAL",
          status: "ended"
        )
        |> set_work_package_updated_at!(repo, stale_at)

      assert {:ok, _dispatched} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", linked_terminal_package.id)

      assert {:ok, _settings} =
               OperatorSettingsRepository.update(repo, %{
                 "hidden_work_package_ids" => [existing_hidden_package.id, existing_hidden_package.id]
               })

      run_operator_retention(repo)
      payload = local_operator_dashboard_payload()

      assert get_in(payload, ["settings", "hidden_work_package_ids"]) == [
               existing_hidden_package.id
             ]

      package_ids = dashboard_work_package_ids(payload)

      refute stale_terminal_package.id in package_ids
      refute existing_hidden_package.id in package_ids
      refute recent_terminal_package.id in package_ids
      refute active_package.id in package_ids
      refute terminal_parent_package.id in package_ids
      refute child_package.id in package_ids
      assert linked_terminal_package.id in package_ids
      refute Map.has_key?(payload, "work_request_work_package_ids")
    end)
  end

  test "local operator dashboard recovers malformed hidden package ids before clearing blockers and archiving", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-CLEAR-BLOCKER-STALE-DASHBOARD")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-CLEAR-BLOCKER-STALE-DASHBOARD"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-CLEAR-BLOCKER-STALE-DASHBOARD",
          status: "dispatched"
        )

      archive_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-STALE-DASHBOARD",
          status: "ended",
          repo: work_package.repo,
          base_branch: work_package.base_branch
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

      assert {:ok, _blocker} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Review scope blocker",
                 body: "Reviewer requested an out-of-scope file change.",
                 status: "blocked",
                 idempotency_key: "local-clear-blocker-stale-dashboard",
                 payload: %{type: "blocker", source_tool: "set_blocker", blocker_id: "local-clear-blocker-stale-dashboard", active: true}
               })

      assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"hidden_work_package_ids" => []})

      repo.query!("UPDATE sympp_operator_settings SET hidden_work_package_ids = ? WHERE id = ?", [
        "not-json",
        OperatorSettings.settings_id()
      ])

      dashboard_payload = local_operator_dashboard_payload()

      assert get_in(dashboard_payload, ["settings", "hidden_work_package_ids"]) == []
      assert %{rows: [["not-json"]]} = repo.query!("SELECT hidden_work_package_ids FROM sympp_operator_settings WHERE id = ?", [OperatorSettings.settings_id()])

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/blockers/local-clear-blocker-stale-dashboard/clear", %{})
        |> json_response(200)

      assert %{"progress_event" => %{"blocker_id" => "local-clear-blocker-stale-dashboard"}} = payload
      refute Map.has_key?(payload, "dashboard")
      refute Map.has_key?(payload, "error")

      assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
      refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
      assert length(blocker_clear_events(progress_events, "local-clear-blocker-stale-dashboard")) == 1

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "dispatched"

      archive_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{archive_package.id}/archive", %{})
        |> json_response(200)

      refute Map.has_key?(archive_payload, "dashboard")

      refreshed_dashboard_payload = local_operator_dashboard_payload()

      assert get_in(refreshed_dashboard_payload, ["settings", "hidden_work_package_ids"]) == [archive_package.id]
      refute archive_package.id in dashboard_work_package_ids(refreshed_dashboard_payload)
    end)
  end

  test "react dashboard shell injects prefix-aware runtime config" do
    index = """
    <!doctype html>
    <html>
      <head>
        <link rel="icon" href="/splusplus-logo.png">
        <script type="module" src="/assets/index.js"></script>
      </head>
      <body><div id="root"></div></body>
    </html>
    """

    with_static_dashboard_file("index.html", index, fn ->
      html =
        build_conn(:get, "/sympp/board")
        |> Map.put(:script_name, ["app"])
        |> ReactDashboardController.index(%{})
        |> html_response(200)

      assert html =~ ~s(href="/app/splusplus-logo.png")
      assert html =~ ~s(src="/app/assets/index.js")
      assert html =~ "window.SYMPP_DASHBOARD_CONFIG"
      assert html =~ ~s("apiBase":"/app/api/v1/sympp/operator")
      assert html =~ ~s("logoUrl":"/app/splusplus-logo.png")
    end)
  end

  test "endpoint caches hashed dashboard assets immutably" do
    with_static_dashboard_file("assets/index-deadbeef.js", "asset-bytes", fn ->
      conn = get(build_conn(), "/assets/index-deadbeef.js")

      assert response(conn, 200) == "asset-bytes"
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end)
  end

  test "Phoenix request logger filters dashboard session secret parameters" do
    sentinel = "sympp-dashboard-log-secret-sentinel"

    params = %{
      "work_key" => sentinel,
      "work_key_secret" => "#{sentinel}-work-key-secret",
      "grant_secret" => "#{sentinel}-grant-secret",
      "secret" => "#{sentinel}-generic-secret",
      "operator_bootstrap" => "#{sentinel}-operator-bootstrap",
      "work_package_id" => "SYMPP-P10-LOG-FILTER"
    }

    filtered = Phoenix.Logger.filter_values(params)
    filtered_text = inspect(filtered)

    refute filtered_text =~ sentinel
    assert filtered["work_key"] == "[FILTERED]"
    assert filtered["work_key_secret"] == "[FILTERED]"
    assert filtered["grant_secret"] == "[FILTERED]"
    assert filtered["secret"] == "[FILTERED]"
    assert filtered["operator_bootstrap"] == "[FILTERED]"
    assert filtered["work_package_id"] == "SYMPP-P10-LOG-FILTER"
  end

  test "dashboard auth preflight treats in-memory SQLite ledgers as absent" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      for database_path <- [":memory:", "file::memory:?cache=shared", "file:?mode=rwc"] do
        Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
        assert Repo.database_path() == database_path
        assert Repo.database_path_if_present() == nil
      end
    after
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  test "dashboard reads normalize SQLite busy errors" do
    assert {:error, :database_busy} = Dashboard.board(BusyRepo)
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_completed_delivered_work_request!(repo, id, completed_at) do
    work_request = create_work_request!(repo, id: id)

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-#{id}"))

    record_completed_delivery!(repo, work_package)
    delivery = repo.get_by!(WorkPackageDelivery, work_package_id: work_package.id)
    repo.update!(Ecto.Changeset.change(delivery, recorded_at: completed_at))
    repo.get!(WorkRequest, work_request.id)
  end

  defp record_completed_delivery!(repo, package) do
    assert {:ok, _delivery} =
             CanonicalWorkPackageFixtures.end_work_package(repo, package.work_request_id, package.id, %{
               outcome: "completed_no_pr",
               idempotency_key: "delivered-#{package.id}",
               no_pr_evidence: "Direct completion evidence for archive and display behavior."
             })
  end

  defp create_work_package!(repo, overrides) do
    overrides
    |> WorkPackageFactory.attrs()
    |> then(&WorkPackageRepository.create(repo, &1))
    |> case do
      {:ok, work_package} -> work_package
      {:error, reason} -> flunk("failed to create WorkPackage: #{inspect(reason)}")
    end
  end

  defp set_work_package_updated_at!(%WorkPackage{} = work_package, repo, %DateTime{} = updated_at) do
    work_package
    |> Ecto.Changeset.change(updated_at: updated_at)
    |> repo.update!()
  end

  defp insert_card!(repo, terminal_key, state, ended_at, updated_at) do
    card =
      repo.insert!(%Card{
        id: Cards.card_id(terminal_key),
        terminal_key: terminal_key,
        state: state,
        title: terminal_key,
        repository: "acme/app",
        branch: "feature",
        ended_at: ended_at,
        observed_at: updated_at,
        inserted_at: updated_at,
        updated_at: updated_at
      })

    repo.insert!(%WorkedOn{
      id: "wo-" <> card.id,
      subject_kind: "card",
      subject_id: card.id,
      terminal_key: terminal_key,
      display_address: terminal_key,
      role: "card",
      state: if(ended_at, do: "finished", else: "live"),
      started_at: updated_at
    })

    card
  end

  defp set_work_request_archived_at!(%WorkRequest{} = work_request, repo, %DateTime{} = timestamp) do
    work_request
    |> Ecto.Changeset.change(archived_at: timestamp, updated_at: timestamp)
    |> repo.update!()
  end

  defp create_matching_work_package!(repo, work_request, work_package, overrides) do
    attrs =
      [
        kind: work_package.kind,
        title: work_package.title,
        repo: work_request.repo,
        base_branch: work_package.base_branch,
        branch_pattern: work_package.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: work_package.allowed_file_globs,
        acceptance_criteria: work_package.acceptance_criteria,
        review_requirement: work_package.review_requirement
      ]
      |> Keyword.merge(overrides)

    create_work_package!(repo, attrs)
  end

  defp set_canonical_package_status!(repo, work_package, status) do
    repo.update!(
      Ecto.Changeset.change(work_package,
        status: status,
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )
  end

  defp append_blocker_event!(repo, work_package_id, blocker_id, active, overrides) do
    attrs =
      [
        work_package_id: work_package_id,
        summary: "Blocked",
        status: if(active, do: "blocked", else: "unblocked"),
        idempotency_key: "#{blocker_id}-#{active}-#{System.unique_integer([:positive])}",
        payload: %{type: "blocker", source_tool: "set_blocker", blocker_id: blocker_id, active: active}
      ]
      |> Keyword.merge(overrides)
      |> Map.new()

    assert {:ok, event} = PlanningRepository.append_progress_event(repo, attrs)
    event
  end

  defp blocker_clear_events(progress_events, blocker_id) do
    Enum.filter(progress_events, &(get_in(&1.payload, ["active"]) == false and get_in(&1.payload, ["blocker_id"]) == blocker_id))
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DASH-#{System.unique_integer([:positive])}",
      title: "Improve intake flow",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package"
    }

    Enum.into(overrides, defaults)
  end

  defp asking_terminal(address), do: Terminal.from_meta(%{"core_id" => "core-test", "terminal_id" => address, "core_name" => "jjdev"})

  defp insert_ask!(repo, work_request_id) do
    assert {:ok, ask} = Asks.open(repo, asking_terminal("t1"), %{"work_request_id" => work_request_id, "question" => "Which branch should this target?"})
    ask
  end

  defp decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Keep this WorkRequest narrow.",
      rationale: "The next slice owns broader orchestration.",
      scope_impact: "No new runtime tools.",
      created_by: "architect-1"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      title: "Add WorkRequest dashboard API",
      goal: "Expose read-only dashboard view models.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "agent/SYMPP-V2-WR-004/workrequest-read-api",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/dashboard.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir_web/live/**"],
      acceptance_criteria: ["WorkRequest dashboard API reads are scoped and redacted."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/dashboard_api_test.exs"],
      stop_conditions: ["Stop before UI or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "dashboard-delivery-#{System.unique_integer([:positive])}",
      recorded_by: "dashboard-api-test"
    }

    Enum.into(overrides, defaults)
  end

  defp create_dashboard_fixture(repo, opts \\ []) do
    id = Keyword.get(opts, :id, "SYMPP-DASH-API")
    status = Keyword.get(opts, :status, "dispatched")

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: id,
                 kind: "mcp",
                 status: status,
                 title: "Dashboard API raw-secret-value",
                 branch_pattern: "agent/#{id}",
                 product_description: "Build dashboard with raw-secret-value",
                 engineering_scope: "No credential handling",
                 acceptance_criteria: ["Expose read API", "Redact raw-secret-value"]
               )
             )

    append_state(repo, work_package)

    %{work_package: work_package}
  end

  defp append_state(repo, work_package) do
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Implement API",
               body: "Add read endpoints",
               status: "done",
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/1", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Blocked on validation",
               status: "blocked",
               idempotency_key: "blocker-a",
               payload: %{type: "blocker", source_tool: "set_blocker", blocker_id: "blocker-a", active: true},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, _artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "review-log-raw-secret-value.txt",
               title: "Review log raw-secret-value",
               kind: "review",
               uri: "https://example.test/review-log.txt?X-Amz-Signature=raw-secret-value",
               metadata: %{"access_grant_id" => "grant-other-worker", "agent_run_id" => "run-other-worker"},
               created_at: DateTime.add(timestamp, 7, :second)
             })

    assert {:ok, _run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               actor_id: "worker-1",
               status: "running",
               attempt: 1,
               worker_host: "local",
               worker_task_handle: "task-1",
               workspace_path: "C:/tmp/workspace",
               session_id: "session-1"
             })
  end

  defp progress_event(id, sequence, created_at, payload) do
    %ProgressEvent{
      id: id,
      work_package_id: "SYMPP-SEQUENCELESS",
      summary: id,
      status: "recorded",
      sequence: sequence,
      created_at: created_at,
      payload: payload
    }
  end

  defp with_retention_throttle_ms(window_ms, fun) when is_integer(window_ms) and is_function(fun, 0) do
    original = Application.fetch_env(:symphony_elixir, :sympp_operator_retention_throttle_ms)
    Application.put_env(:symphony_elixir, :sympp_operator_retention_throttle_ms, window_ms)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_operator_retention_throttle_ms, original)
    end
  end

  defp with_trusted_repo_remotes(remotes, fun) when is_list(remotes) and is_function(fun, 0) do
    original = Application.fetch_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, remotes)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_repo_identity_trusted_remotes, original)
    end
  end

  defp create_repo_identity_package!(repo, {key, id, raw_repo}) do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: id, repo: raw_repo, base_branch: "main")
             )

    {key, package}
  end

  defp create_repo_identity_request!(repo, {key, id, raw_repo}) do
    assert {:ok, request} =
             WorkRequestRepository.create(repo, %{
               title: "#{id} request",
               repo: raw_repo,
               base_branch: "main",
               work_type: "feature",
               human_description: "#{raw_repo} repo identity coverage.",
               constraints: %{},
               desired_dispatch_shape: "architect_led_feature_branch"
             })

    {key, request}
  end

  defp repo_identity_expectation(raw_repo) do
    %{
      repo: raw_repo,
      repo_key: String.downcase(raw_repo),
      repo_display: raw_repo,
      repo_remote: if(String.contains?(raw_repo, "/"), do: raw_repo),
      repo_aliases: [raw_repo]
    }
  end

  defp assert_repo_identity(record, expected) do
    Enum.each(expected, fn {field, value} ->
      assert Map.fetch!(record, field) == value
    end)
  end

  defp with_local_repo_origin(origin, fun) when is_binary(origin) and is_function(fun, 0) do
    original_repo_root = Application.fetch_env(:symphony_elixir, :sympp_repo_root)
    original_trusted_remotes = Application.fetch_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    repo_root = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-dashboard-repo-root")

    Application.put_env(:symphony_elixir, :sympp_repo_root, repo_root)
    Application.delete_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_repo_root, original_repo_root)
      restore_fetched_app_env(:sympp_repo_identity_trusted_remotes, original_trusted_remotes)
    end
  end

  defp restore_fetched_app_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_fetched_app_env(key, :error), do: Application.delete_env(:symphony_elixir, key)

  defp local_operator_dashboard_payload do
    initial = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
    deferred = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/deferred"), 200)
    archived = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=archived"), 200)

    initial
    |> Map.merge(deferred)
    |> Map.merge(archived)
  end

  defp run_operator_retention(repo) do
    assert {:ok, settings} = OperatorSettingsRepository.get(repo)
    assert :ok = LocalOperatorDashboard.run_operator_retention(repo, settings)
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, to_string(metadata.query || "")}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp dashboard_benchmark(requests, fun) do
    DashboardQueryCountingRepo.reset()
    started_at = System.monotonic_time()
    assert {:ok, payload} = fun.()

    elapsed_ms =
      System.monotonic_time()
      |> Kernel.-(started_at)
      |> System.convert_time_unit(:native, :microsecond)
      |> Kernel./(1000)

    {payload, %{requests: requests, queries: DashboardQueryCountingRepo.count(), settle_ms: elapsed_ms}}
  end

  defp maybe_export_dashboard_fixture(_repo) do
    case System.get_env("SYMPP_DASHBOARD_FIXTURE_DATABASE") do
      path when is_binary(path) and path != "" ->
        DashboardFixtureDatabase.export!(path)

      _path ->
        :ok
    end
  end

  defp work_request_detail(dashboard, work_request_id) do
    dashboard
    |> get_in(["work_request_details"])
    |> Kernel.||([])
    |> Enum.find(&(get_in(&1, ["work_request", "id"]) == work_request_id))
  end

  defp dashboard_work_package_ids(dashboard) do
    dashboard
    |> Map.get("work_packages", [])
    |> Enum.map(& &1["id"])
  end

  defp native_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/json")
  end

  defp local_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", "http://localhost")
  end

  defp recycle_local_operator_conn(conn, origin) do
    conn
    |> recycle()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", origin)
  end

  defp with_static_dashboard_file(file_name, contents, fun) when is_function(fun, 0) do
    static_dir =
      :symphony_elixir
      |> :code.priv_dir()
      |> Path.join("static")

    path = Path.join(static_dir, file_name)
    original = File.read(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    try do
      fun.()
    after
      case original do
        {:ok, previous} -> File.write!(path, previous)
        {:error, _reason} -> File.rm(path)
      end
    end
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp with_local_operator_endpoint(fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end

  defp with_local_operator_dashboard_origin(origin, fun) when is_binary(origin) and is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_dashboard_origin, origin)
    )

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end
end
