defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.FinishedPackageLimitsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

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
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "operator board caps finished package cards while preserving totals", %{repo: repo} do
    assert {:ok, _active} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-DASH-ACTIVE-CAP", status: "dispatched"))

    base_time = DateTime.utc_now(:microsecond)

    for index <- 1..5 do
      package_time = if index == 4, do: DateTime.add(base_time, 120, :second), else: DateTime.add(base_time, index, :second)
      package = create_finished_package!(repo, "SYMPP-DASH-FINISHED-CAP-#{index}", package_time)

      if index == 2 do
        append_progress_event!(repo, package.id, 1, DateTime.add(base_time, 29, :second))
      end

      if index == 3 do
        for sequence <- 1..45 do
          append_progress_event!(repo, package.id, sequence, DateTime.add(base_time, 30 + sequence, :second))
        end
      end

      if index == 4 do
        append_progress_event!(repo, package.id, 1, DateTime.add(base_time, 1, :second))
      end
    end

    assert {:ok, operator_board} = Dashboard.operator_board(repo, finished_work_package_limit: 2)
    assert [%{id: "SYMPP-DASH-ACTIVE-CAP"}] = operator_board.groups["dispatched"]
    assert Enum.map(operator_board.groups["ended"], & &1.id) == ["SYMPP-DASH-FINISHED-CAP-4", "SYMPP-DASH-FINISHED-CAP-3"]
    assert operator_board.total_count == 6
    assert operator_board.visible_count == 3

    assert operator_board.package_limits.finished_work_packages == %{
             limit: 2,
             shown_count: 2,
             total_count: 5,
             truncated: true
           }

    assert {:ok, full_board} = Dashboard.board(repo)
    assert length(full_board.groups["ended"]) == 5
    assert full_board.package_limits.finished_work_packages.truncated == false

    hidden_ids =
      ["SYMPP-DASH-FINISHED-CAP-3"] ++
        for index <- 6..50 do
          id = "SYMPP-DASH-HIDDEN-FINISHED-CAP-#{index}"
          package = create_finished_package!(repo, id, DateTime.add(base_time, index, :second))
          append_progress_event!(repo, package.id, 1, DateTime.add(base_time, 100 + index, :second))
          id
        end

    assert {:ok, hidden_board} =
             Dashboard.operator_board(repo,
               finished_work_package_limit: 2,
               hidden_work_package_ids: MapSet.new(hidden_ids)
             )

    assert Enum.map(hidden_board.groups["ended"], & &1.id) == ["SYMPP-DASH-FINISHED-CAP-4", "SYMPP-DASH-FINISHED-CAP-2"]
    assert hidden_board.total_count == 5
    assert hidden_board.visible_count == 3

    assert hidden_board.package_limits.finished_work_packages == %{
             limit: 2,
             shown_count: 2,
             total_count: 4,
             truncated: true
           }
  end

  defp create_finished_package!(repo, id, timestamp) do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: id, status: "ended"))
    repo.update!(Ecto.Changeset.change(work_package, inserted_at: timestamp, updated_at: timestamp))
  end

  defp append_progress_event!(repo, work_package_id, sequence, created_at) do
    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "progress #{sequence}",
               sequence: sequence,
               created_at: created_at
             })
  end
end
