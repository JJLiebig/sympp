defmodule SymphonyElixir.SymphonyPlusPlus.LifecycleTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
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

  defp package!(repo, request, status) do
    attrs = WorkPackageFactory.attrs(kind: "standard_pr", work_request_id: request.id, status: status)
    assert {:ok, package} = Repository.create(repo, attrs)
    package
  end
end
