defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestWorkPackageDeliveriesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  defmodule UniqueConflictRepo do
    alias Ecto.Changeset

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def exists?(_query), do: true
    def all(_query), do: []
    def delete_all(_query), do: {0, nil}
    def update_all(_query, _updates), do: {0, nil}

    def get(WorkPackage, "WRS-RACE") do
      %WorkPackage{id: "WRS-RACE", work_request_id: "WR-RACE", status: "dispatched"}
    end

    def one(_query) do
      if Process.get(:delivery_unique_conflict_insert_attempted) do
        Process.get(:delivery_unique_conflict_existing)
      end
    end

    def insert(%Changeset{} = changeset) do
      Process.put(:delivery_unique_conflict_insert_attempted, true)

      {:error,
       Changeset.add_error(changeset, :work_package_id, "has already been taken",
         constraint: :unique,
         constraint_name: "sympp_work_request_work_package_deliveries_work_package_id_unique_index"
       )}
    end

    def rollback(reason), do: throw({:rollback, reason})
  end

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "accepts exact replay after a concurrent unique conflict" do
    existing = %WorkPackageDelivery{
      work_request_id: "WR-RACE",
      work_package_id: "WRS-RACE",
      outcome: "completed_no_pr",
      idempotency_key: "delivery-race",
      recorded_by: "delivery-worker",
      no_pr_evidence: "Same no-PR evidence."
    }

    Process.put(:delivery_unique_conflict_existing, existing)
    Process.delete(:delivery_unique_conflict_insert_attempted)

    try do
      assert {:ok, {:ok, ^existing}} =
               UniqueConflictRepo.transaction(fn ->
                 Repository.record_work_package_delivery_in_transaction(
                   UniqueConflictRepo,
                   "WR-RACE",
                   "WRS-RACE",
                   delivery_attrs(%{
                     outcome: "completed_no_pr",
                     idempotency_key: "delivery-race",
                     no_pr_evidence: "Same no-PR evidence."
                   })
                 )
               end)
    after
      Process.delete(:delivery_unique_conflict_existing)
      Process.delete(:delivery_unique_conflict_insert_attempted)
    end
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "delivery-#{System.unique_integer([:positive])}",
      recorded_by: "delivery-worker"
    }

    Enum.into(overrides, defaults)
  end

  defp database_path do
    Path.join(
      System.tmp_dir!(),
      "sympp-work-request-work-package-deliveries-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
    )
  end
end
