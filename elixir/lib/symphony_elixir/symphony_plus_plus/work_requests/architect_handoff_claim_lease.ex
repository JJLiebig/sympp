defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoffClaimLease do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService

  @spec require_no_fresh(module(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def require_no_fresh(repo, work_package_id, %DateTime{} = now)
      when is_atom(repo) and is_binary(work_package_id) do
    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = lease} -> if ClaimLease.stale?(lease, now), do: :ok, else: {:error, :claim_lease_active_for_other_actor}
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
