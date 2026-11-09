defmodule SymphonyElixir.SymphonyPlusPlus.LifecycleTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryResolution
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)

    assert {:ok, work_request} =
             WorkRequestRepository.create(repo, %{
               title: "Lifecycle",
               repo: "nextide/example",
               base_branch: "main",
               work_type: "feature",
               human_description: "Lifecycle request.",
               constraints: %{},
               desired_dispatch_shape: "single_package"
             })

    {:ok, work_request: work_request}
  end

  test "transitions follow the table and compare-and-set on the stored status", %{repo: repo, work_request: request} do
    package = package!(repo, request, "planned")

    assert {:error, :invalid_status} = Lifecycle.transition(repo, package, :qualify)
    assert {:ok, dispatched} = Lifecycle.transition(repo, package, :dispatch)
    assert dispatched.status == "dispatched"
    assert %DateTime{} = dispatched.dispatched_at

    assert {:error, :stale_status} = Lifecycle.transition(repo, %{dispatched | status: "planned"}, :dispatch)
    assert {:ok, ready} = Lifecycle.transition(repo, dispatched, :qualify)
    assert {:ok, %WorkPackage{status: "dispatched"}} = Lifecycle.transition(repo, ready, :unqualify)
  end

  test "each ending outcome is accepted only from its allowed statuses", %{repo: repo, work_request: request} do
    planned = package!(repo, request, "planned")
    dispatched = package!(repo, request, "dispatched")

    assert {:error, {:ending_not_allowed, "planned", "abandoned"}} =
             DeliveryCloseout.record(repo, request.id, planned.id, ending("abandoned", abandoned_rationale: "No longer needed."))

    assert {:error, {:ending_not_allowed, "dispatched", "skipped"}} =
             DeliveryCloseout.record(repo, request.id, dispatched.id, ending("skipped"))

    assert {:ok, %WorkPackageDelivery{outcome: "skipped"}} = DeliveryCloseout.record(repo, request.id, planned.id, ending("skipped"))

    assert {:ok, %WorkPackageDelivery{outcome: "abandoned"}} =
             DeliveryCloseout.record(repo, request.id, dispatched.id, ending("abandoned", abandoned_rationale: "Rehomed."))

    assert Repo.get!(WorkPackage, planned.id).status == "ended"
    assert Repo.get!(WorkPackage, dispatched.id).status == "ended"
  end

  test "a replayed ending is idempotent and a conflicting ending is refused with the actual outcome", %{repo: repo, work_request: request} do
    package = package!(repo, request, "ready")
    attrs = ending("finished")

    assert {:ok, first} = DeliveryCloseout.record(repo, request.id, package.id, attrs)
    assert {:ok, replay} = DeliveryCloseout.record(repo, request.id, package.id, attrs)
    assert replay.id == first.id
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1

    assert {:error, {:delivery_outcome_conflict, "finished"}} =
             DeliveryCloseout.record(repo, request.id, package.id, ending("completed_no_pr", no_pr_evidence: "Done."))

    assert Repo.get!(WorkPackage, package.id).status == "ended"
  end

  test "ending clears only the ended package's blockers", %{repo: repo, work_request: request} do
    package = package!(repo, request, "ready")
    sibling = package!(repo, request, "dispatched")

    blocker!(repo, package.id, "terminal-blocker")
    blocker!(repo, sibling.id, "nonterminal-blocker")

    assert {:ok, _delivery} = DeliveryCloseout.record(repo, request.id, package.id, ending("finished"))

    assert WorkPackageActivity.context(repo, package.id).blocker_state.active_ids == []
    assert WorkPackageActivity.context(repo, sibling.id).blocker_state.active_ids == ["nonterminal-blocker"]

    event_count = repo.aggregate(ProgressEvent, :count, :id)
    assert :ok = Lifecycle.apply_terminal_effects(repo, Repo.get!(WorkPackage, package.id))
    assert repo.aggregate(ProgressEvent, :count, :id) == event_count
  end

  test "qualification fails on each predicate that does not hold" do
    qualified = %{
      pr_state: "open",
      pr_draft?: false,
      ci_status: "passing",
      review: :none,
      dependencies_delivered?: true,
      stacked_on: []
    }

    assert :qualified = Lifecycle.qualification(qualified)

    for {change, reason} <- [
          {%{pr_state: "closed"}, "pr_not_open"},
          {%{pr_draft?: true}, "pr_draft"},
          {%{ci_status: "failing"}, "ci_not_green"},
          {%{ci_status: "unknown"}, "ci_not_green"},
          {%{review: :not_done}, "review_not_done"},
          {%{dependencies_delivered?: false}, "dependency_not_delivered"},
          {%{stacked_on: ["wp-other"]}, "stacked_on_unmerged_work"}
        ] do
      assert {:unqualified, [^reason]} = Lifecycle.qualification(Map.merge(qualified, change))
    end

    # A repository without CI accepts a head whose CI reports nothing; an
    # override also accepts pending CI. Neither accepts failing CI.
    assert :qualified = Lifecycle.qualification(Map.merge(qualified, %{ci_status: "unknown", no_ci?: true}))
    assert {:unqualified, ["ci_not_green"]} = Lifecycle.qualification(Map.merge(qualified, %{ci_status: "pending", no_ci?: true}))

    for status <- ["unknown", "pending"],
        do: assert(:qualified = Lifecycle.qualification(Map.merge(qualified, %{ci_status: status, ci_override?: true})))

    assert {:unqualified, ["ci_not_green"]} = Lifecycle.qualification(Map.merge(qualified, %{ci_status: "failing", ci_override?: true}))
  end

  test "finished resolves the WorkRequest but never satisfies a dependent" do
    packages = %{"wp-a" => %{id: "wp-a", work_request_id: "wr"}}
    deliveries = %{"wp-a" => %{outcome: "finished"}}

    assert DeliveryResolution.resolves_work_request?("wp-a", packages, deliveries)
    refute DeliveryResolution.satisfies_dependents?("wp-a", packages, deliveries)
  end

  test "an unresolved successor chain keeps dependents blocked" do
    packages = %{
      "old" => %{id: "old", work_request_id: "wr"},
      "next" => %{id: "next", work_request_id: "wr"},
      "elsewhere" => %{id: "elsewhere", work_request_id: "other"}
    }

    superseded = %{"old" => %{outcome: "superseded", successor_work_package_id: "next"}}

    refute DeliveryResolution.satisfies_dependents?("old", packages, superseded)
    refute DeliveryResolution.resolves_work_request?("old", packages, superseded)

    assert [%{work_package_id: "next", successor_of: "old", ended_as: nil}] =
             DeliveryResolution.waiting_for("old", packages, superseded)

    finished_successor = Map.put(superseded, "next", %{outcome: "finished"})
    refute DeliveryResolution.satisfies_dependents?("old", packages, finished_successor)
    assert DeliveryResolution.resolves_work_request?("old", packages, finished_successor)
    assert [%{work_package_id: "next", ended_as: "finished"}] = DeliveryResolution.waiting_for("old", packages, finished_successor)

    merged_successor = Map.put(superseded, "next", %{outcome: "pr_merged"})
    assert DeliveryResolution.satisfies_dependents?("old", packages, merged_successor)

    cycle = %{"old" => %{outcome: "superseded", successor_work_package_id: "next"}, "next" => %{outcome: "superseded", successor_work_package_id: "old"}}
    refute DeliveryResolution.satisfies_dependents?("old", packages, cycle)

    rehomed = %{"old" => %{outcome: "superseded", successor_work_package_id: "elsewhere"}, "elsewhere" => %{outcome: "pr_merged"}}
    refute DeliveryResolution.satisfies_dependents?("old", packages, rehomed)
    assert [%{work_package_id: "old", ended_as: "superseded"}] = DeliveryResolution.waiting_for("old", packages, rehomed)
  end

  test "legacy endings resolve only when the old status was merged or closed" do
    packages = Map.new(~w(merged closed abandoned), &{&1, %{id: &1, work_request_id: "wr"}})
    deliveries = Map.new(~w(merged closed abandoned), &{&1, %{outcome: "legacy", legacy_status: &1}})

    assert DeliveryResolution.resolves_work_request?("merged", packages, deliveries)
    assert DeliveryResolution.resolves_work_request?("closed", packages, deliveries)
    refute DeliveryResolution.resolves_work_request?("abandoned", packages, deliveries)
  end

  test "next action comes from the status and its derived progress" do
    assert %{action: "deliver_prerequisites", actor: "architect"} = Lifecycle.next_action("planned", %{dependencies_met?: false})
    assert %{action: "dispatch_work_package", actor: "architect"} = Lifecycle.next_action("planned")
    assert %{action: "run_launch_line", actor: "architect"} = Lifecycle.next_action("dispatched", %{progress: "launching"})
    assert %{action: "wait", actor: "worker"} = Lifecycle.next_action("dispatched", %{progress: "implementing"})
    assert %{action: "inspect_worker", actor: "architect"} = Lifecycle.next_action("dispatched", %{progress: "worker_exited"})
    assert %{action: "inspect_worker", actor: "architect"} = Lifecycle.next_action("dispatched", %{progress: "review_ci", attention?: true, worker_idle?: true})
    assert %{action: "merge_pr", actor: "architect"} = Lifecycle.next_action("ready")
    assert %{action: "sync_pr", actor: "architect"} = Lifecycle.next_action("ready", %{attention?: true})
    assert %{action: "finish", actor: "operator"} = Lifecycle.next_action("ready", %{merge_rights?: false})
    assert %{action: nil, actor: nil} = Lifecycle.next_action("ended")
  end

  defp package!(repo, request, status) do
    attrs = WorkPackageFactory.attrs(kind: "standard_pr", work_request_id: request.id, status: status)
    assert {:ok, package} = Repository.create(repo, attrs)
    package
  end

  defp ending(outcome, evidence \\ []) do
    Map.merge(%{"outcome" => outcome, "idempotency_key" => "lifecycle-#{outcome}"}, Map.new(evidence, fn {key, value} -> {Atom.to_string(key), value} end))
  end

  defp blocker!(repo, work_package_id, blocker_id) do
    payload = %{type: "blocker", source_tool: "set_blocker", blocker_id: blocker_id, active: true}

    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "Blocked by #{blocker_id}",
               status: "blocked",
               idempotency_key: "report:#{blocker_id}",
               payload: payload
             })
  end
end
