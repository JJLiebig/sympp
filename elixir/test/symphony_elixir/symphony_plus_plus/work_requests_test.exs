defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryResolution
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkedOn)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(Ask)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "historical cyclic, missing and foreign lineage cannot resolve delivery" do
    packages =
      Map.new(["original", "pointer", "recut", "leaf", "foreign"], fn id ->
        {id, %WorkPackage{id: id, work_request_id: if(id == "foreign", do: "other", else: "wr"), status: "ended"}}
      end)

    deliveries = %{
      "original" => %{outcome: "superseded", successor_work_package_id: "pointer"},
      "pointer" => %{outcome: "pr_merged"},
      "recut" => %{outcome: "superseded", successor_work_package_id: "leaf"}
    }

    successors = %{"original" => ["recut", "pointer"]}
    refute DeliveryResolution.resolves_work_request?("original", packages, deliveries, successors)
    deliveries = Map.put(deliveries, "leaf", %{outcome: "completed_no_pr"})
    assert DeliveryResolution.resolves_work_request?("original", packages, deliveries, successors)
    refute DeliveryResolution.resolves_work_request?("original", packages, deliveries, Map.put(successors, "recut", ["original"]))
    refute DeliveryResolution.resolves_work_request?("original", packages, deliveries, Map.put(successors, "recut", ["missing"]))
    refute DeliveryResolution.resolves_work_request?("original", packages, Map.put(deliveries, "foreign", %{outcome: "pr_merged"}), %{"original" => ["foreign"]})

    # Historical actual delivery remains factual even after contradictory retirement annotations.
    delivered = Map.put(deliveries, "original", %{outcome: "pr_merged"})
    assert DeliveryResolution.resolves_work_request?("original", packages, delivered, %{"original" => ["missing", "original"]})
  end

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-requests-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
