defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestArchitectHandoffClaimLeaseTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkRequestRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :sympp_repo_database, original_database)
      File.rm(database_path)
    end)

    {:ok, repo: Repo, database_path: database_path}
  end

  setup %{repo: repo} do
    Enum.each([ClaimLease, GrantScope, AccessGrant, WorkPackage, Phase, WorkRequest], &repo.delete_all/1)
    :ok
  end

  test "fresh active architect claim lease still allows replay of an existing unclaimed handoff", %{
    repo: repo,
    database_path: database_path
  } do
    first = create_handoff!(repo, database_path, [])
    {anchor, first_grant} = handoff_anchor_and_grant!(repo, first)
    assert {:ok, lease} = ClaimLeaseService.claim(repo, anchor.id, claim_actor("active local architect"), stale_after_ms: 60_000)

    assert {:ok, replayed} =
             ArchitectHandoff.create_or_replay(repo, first.work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(database_path)
             )

    assert replayed.status == :replayed
    assert replayed.grant.id == first.grant.id
    assert replayed.local_architect_claim["arguments"]["work_request_id"] == first.work_request.id
    assert {:ok, [%AccessGrant{id: grant_id}]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert grant_id == first_grant.id

    assert {:ok, _released} = ClaimLeaseService.release(repo, lease.id, reason: "test cleanup")
  end

  test "fresh active architect claim lease blocks handoff renewal without minting a duplicate grant", %{
    repo: repo,
    database_path: database_path
  } do
    first = create_handoff!(repo, database_path, [])
    {anchor, first_grant} = handoff_anchor_and_grant!(repo, first)

    first_grant
    |> Ecto.Changeset.change(claimed_at: DateTime.utc_now(:microsecond), claimed_by: ArchitectHandoff.claimed_by())
    |> repo.update!()

    assert {:ok, lease} =
             ClaimLeaseService.claim(repo, anchor.id, claim_actor("active architect"),
               access_grant_id: first_grant.id,
               stale_after_ms: 60_000
             )

    assert {:error, :claim_lease_active_for_other_actor} =
             ArchitectHandoff.create_or_replay(repo, first.work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(database_path)
             )

    assert {:ok, [preserved]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert preserved.id == first_grant.id
    assert is_nil(preserved.revoked_at)

    assert {:ok, _released} = ClaimLeaseService.release(repo, lease.id, reason: "test cleanup")
  end

  defp create_handoff!(repo, database_path, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(database_path)
             )

    Map.put(handoff, :work_request, Map.put(handoff.work_request, :id, work_request.id))
  end

  defp handoff_anchor_and_grant!(repo, handoff) do
    assert {:ok, anchor} = WorkPackageRepository.get(repo, handoff.anchor_package.id)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    {anchor, grant}
  end

  defp work_request_attrs(overrides) do
    Map.merge(
      %{
        id: "WR-ARCH-HANDOFF-CLAIM-#{System.unique_integer([:positive])}",
        title: "Start architect handoff",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        work_type: "feature",
        human_description: "Let an architect clarify and slice the request.",
        constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
        desired_dispatch_shape: "architect_led_feature_branch"
      },
      Map.new(overrides)
    )
  end

  defp handoff_opts(database_path) do
    [
      claimed_by: ArchitectHandoff.claimed_by(),
      database: database_path,
      local_architect_claim?: true
    ]
  end

  defp claim_actor(display_name) do
    %{"actor_kind" => "agent", "actor_id" => "test:#{display_name}", "actor_display_name" => display_name}
  end
end
