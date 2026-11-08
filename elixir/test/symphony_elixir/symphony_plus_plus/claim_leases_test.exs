defmodule SymphonyElixir.SymphonyPlusPlus.ClaimLeaseReleaseTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ClaimLease)
    repo.delete_all(WorkPackage)

    :ok
  end

  test "release still rejects stale active claim leases", %{repo: repo} do
    package = create_work_package!(repo, "SYMPP-CLAIM-STALE-ACTIVE-RELEASE")

    assert {:ok, lease} =
             ClaimLeaseService.claim(repo, package.id, actor("worker"),
               now: DateTime.add(DateTime.utc_now(:microsecond), -10, :second),
               stale_after_ms: 1
             )

    assert {:error, :claim_stale} = ClaimLeaseService.release(repo, lease.id, reason: "active stale recovery")

    assert %ClaimLease{status: "active", released_at: nil, release_reason: nil} = repo.get!(ClaimLease, lease.id)
  end

  defp create_work_package!(repo, id) do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: id, kind: "mcp"))
    package
  end

  defp actor(name) do
    %{
      "actor_kind" => "agent",
      "actor_id" => "agent:#{name}",
      "actor_display_name" => name
    }
  end
end
