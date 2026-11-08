defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkPackageWorkerRevoke do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @reason_codes ["worker_recycled", "work_package_worker_key_revoked"]

  # A worker key can be revoked once the package was dispatched; revoking never
  # changes the package status.
  @spec require_revoke_status(WorkPackage.t()) :: :ok | {:tool_error, String.t()}
  def require_revoke_status(%WorkPackage{} = work_package) do
    if Lifecycle.planned?(work_package), do: {:tool_error, "work_package_not_closeout_ready"}, else: :ok
  end

  @spec payload(WorkRequest.t(), WorkPackage.t(), AccessGrant.t(), term()) :: map()
  def payload(%WorkRequest{} = work_request, %WorkPackage{} = work_package, %AccessGrant{} = grant, reason) do
    %{
      "type" => "work_package_worker_key_revoke",
      "source_tool" => "revoke_work_package_worker_key",
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "grant_id" => grant.id,
      "reason" => redacted_reason(reason),
      "revoked_at" => timestamp(grant.revoked_at),
      "work_package_status" => work_package.status,
      "lifecycle_state" => "recycled",
      "reason_codes" => @reason_codes
    }
  end

  @spec reason_codes() :: [String.t()]
  def reason_codes, do: @reason_codes

  @spec redacted_reason(term()) :: String.t()
  def redacted_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  def redacted_reason(_reason), do: ""

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp timestamp(nil), do: nil
end
