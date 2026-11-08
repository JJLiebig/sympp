defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LocalClaimLeases do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService

  @type grant_action :: :claimed | :reconnected | {:recovered, map()}

  @spec ensure(module(), String.t(), map(), pos_integer(), String.t()) ::
          {:ok, ClaimLease.t(), :created | :heartbeat | :reclaimed} | {:error, term()}
  def ensure(repo, work_package_id, actor, stale_after_ms, stale_reason)
      when is_atom(repo) and is_binary(work_package_id) and is_map(actor) and is_integer(stale_after_ms) and
             is_binary(stale_reason) do
    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = lease} -> renew(repo, work_package_id, lease, actor, stale_after_ms, stale_reason)
      {:error, :not_found} -> claim_new(repo, work_package_id, actor, stale_after_ms, stale_reason)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec worker_actor(map()) :: map()
  def worker_actor(claim) when is_map(claim) do
    owner_id = actor_hash(["worker", claim.work_package_id, claim.claimed_by] |> Enum.join("\0"))
    actor(claim.claimed_by, owner_id)
  end

  @spec architect_actor(map()) :: map()
  def architect_actor(claim) when is_map(claim) do
    owner_id =
      ["architect", claim.work_request_id, claim.architect_anchor_work_package_id, claim.claimed_by]
      |> Enum.join("\0")
      |> actor_hash()

    actor(claim.claimed_by, owner_id)
  end

  @spec reclaim_opts(String.t(), pos_integer()) :: keyword()
  def reclaim_opts(reason, stale_after_ms) when is_binary(reason) and is_integer(stale_after_ms) do
    [
      reason: reason,
      current_stale_after_ms: stale_after_ms,
      inherit_access_grant?: false,
      stale_after_ms: stale_after_ms
    ]
  end

  @spec actor_hash(iodata()) :: String.t()
  def actor_hash(material), do: Base.url_encode64(:crypto.hash(:sha256, material), padding: false)

  @spec claim_worker_grant(
          module(),
          String.t(),
          map(),
          ClaimLease.t(),
          :created | :heartbeat | :reclaimed,
          [String.t()],
          DateTime.t()
        ) ::
          {:ok, AccessGrant.t(), grant_action()} | {:error, term()}
  def claim_worker_grant(repo, work_package_id, claim, %ClaimLease{} = lease, lease_action, existing_grant_ids, %DateTime{} = claim_now)
      when is_atom(repo) and is_binary(work_package_id) and is_map(claim) and
             lease_action in [:created, :heartbeat, :reclaimed] and is_list(existing_grant_ids) do
    case AccessGrantService.claim_local_worker_grant(repo, work_package_id,
           claimed_by: claim.claimed_by,
           now: claim_now
         ) do
      {:ok, %AccessGrant{} = grant} ->
        {:ok, grant, grant_action(grant, existing_grant_ids)}

      {:error, :already_claimed} when lease_action == :reclaimed ->
        recover_worker_grant_owner(repo, work_package_id, claim, lease, claim_now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec rollback_worker_grant_recovery(module(), map()) :: term()
  def rollback_worker_grant_recovery(repo, %{id: id, recovered_claimed_by: recovered_claimed_by} = recovery)
      when is_atom(repo) and is_binary(id) and is_binary(recovered_claimed_by) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(grant in AccessGrant,
        where: grant.id == ^id,
        where: grant.claimed_by == ^recovered_claimed_by,
        where: is_nil(grant.revoked_at)
      )

    repo.update_all(query,
      set: [
        claimed_at: Map.get(recovery, :previous_claimed_at),
        claimed_by: Map.get(recovery, :previous_claimed_by),
        updated_at: now
      ]
    )
  end

  defp recover_worker_grant_owner(repo, work_package_id, claim, %ClaimLease{} = lease, %DateTime{} = claim_now) do
    repo.transaction(fn ->
      with {:ok, previous_owner} <- previous_worker_claim_owner(repo, work_package_id, lease),
           %AccessGrant{} = recovered_owner <-
             recoverable_worker_grant(repo, work_package_id, previous_owner, claim, claim_now),
           {:ok, %AccessGrant{} = grant} <- recover_worker_grant_owner(repo, recovered_owner, claim, claim_now) do
        {:ok, grant, {:recovered, worker_recovery(recovered_owner, claim)}}
      else
        nil -> repo.rollback(:already_claimed)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, %AccessGrant{} = grant, action}} -> {:ok, grant, action}
      {:error, reason} -> {:error, reason}
    end
  end

  defp previous_worker_claim_owner(repo, work_package_id, %ClaimLease{previous_claim_id: previous_claim_id})
       when is_binary(previous_claim_id) do
    case repo.get(ClaimLease, previous_claim_id) do
      %ClaimLease{work_package_id: ^work_package_id, actor_display_name: owner}
      when is_binary(owner) and owner != "" ->
        {:ok, owner}

      %ClaimLease{} ->
        {:error, :already_claimed}

      nil ->
        {:error, :already_claimed}
    end
  end

  defp previous_worker_claim_owner(_repo, _work_package_id, %ClaimLease{}), do: {:error, :already_claimed}

  defp recoverable_worker_grant(repo, work_package_id, previous_owner, claim, %DateTime{} = now) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: not is_nil(grant.claimed_at),
        where: grant.claimed_by == ^previous_owner,
        where: grant.claimed_by != ^claim.claimed_by,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id],
        limit: 1
      )

    repo.one(query)
  end

  defp recover_worker_grant_owner(repo, %AccessGrant{} = recovered_owner, claim, %DateTime{} = claim_now) do
    recovered_owner
    |> AccessGrant.claim_changeset(%{
      claimed_at: claim_now,
      claimed_by: claim.claimed_by
    })
    |> repo.update()
  end

  defp worker_recovery(%AccessGrant{} = recovered_owner, claim) do
    %{
      id: recovered_owner.id,
      previous_claimed_at: recovered_owner.claimed_at,
      previous_claimed_by: recovered_owner.claimed_by,
      recovered_claimed_by: claim.claimed_by
    }
  end

  defp grant_action(%AccessGrant{id: id}, existing_grant_ids) when is_binary(id) do
    if id in existing_grant_ids, do: :reconnected, else: :claimed
  end

  defp renew(repo, work_package_id, %ClaimLease{} = lease, actor, stale_after_ms, stale_reason) do
    now = DateTime.utc_now(:microsecond)

    cond do
      ClaimLease.stale?(lease, now, stale_after_ms) ->
        reclaim(repo, work_package_id, actor, stale_after_ms, stale_reason)

      same_owner?(lease, actor) and lease.status == "active" ->
        heartbeat(repo, work_package_id, lease, actor, stale_after_ms, stale_reason)

      same_owner?(lease, actor) ->
        {:error, :claim_lease_not_active}

      true ->
        {:error, :claim_lease_active_for_other_actor}
    end
  end

  defp heartbeat(repo, work_package_id, %ClaimLease{} = lease, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.heartbeat(repo, lease.id, stale_after_ms: stale_after_ms) do
      {:ok, %ClaimLease{} = renewed} -> {:ok, renewed, :heartbeat}
      {:error, :claim_stale} -> reclaim(repo, work_package_id, actor, stale_after_ms, stale_reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_new(repo, work_package_id, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.claim(repo, work_package_id, actor, stale_after_ms: stale_after_ms) do
      {:ok, %ClaimLease{} = lease} -> {:ok, lease, :created}
      {:error, :active_claim_exists} -> renew_current(repo, work_package_id, actor, stale_after_ms, stale_reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_current(repo, work_package_id, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = lease} ->
        if same_owner?(lease, actor),
          do: renew(repo, work_package_id, lease, actor, stale_after_ms, stale_reason),
          else: {:error, :active_claim_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reclaim(repo, work_package_id, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.reclaim_stale(repo, work_package_id, actor, reclaim_opts(stale_reason, stale_after_ms)) do
      {:ok, %ClaimLease{} = lease} -> {:ok, lease, :reclaimed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_owner?(%ClaimLease{} = lease, actor) when is_map(actor) do
    lease.actor_kind == Map.get(actor, "actor_kind") and
      lease.actor_display_name == Map.get(actor, "actor_display_name") and
      actor_id_match?(lease.actor_id, Map.get(actor, "actor_id"))
  end

  defp actor(display_name, owner_id) do
    %{
      "actor_kind" => "agent",
      "actor_id" => "local:" <> owner_id,
      "actor_display_name" => display_name
    }
  end

  defp actor_id_match?(actor_id, actor_id) when is_binary(actor_id), do: true

  defp actor_id_match?(lease_actor_id, actor_id) when is_binary(lease_actor_id) and is_binary(actor_id) do
    String.starts_with?(lease_actor_id, actor_id <> ":")
  end

  defp actor_id_match?(_lease_actor_id, _actor_id), do: false
end
