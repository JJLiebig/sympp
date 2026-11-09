defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Payloads do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type timestamp_value :: DateTime.t() | NaiveDateTime.t() | nil

  @spec optional_payload(map()) :: {:ok, map()} | {:tool_error, String.t()}
  def optional_payload(arguments) do
    case Map.get(arguments, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _payload -> {:tool_error, "invalid_payload"}
    end
  end

  @doc false
  @spec mcp_timestamp(timestamp_value()) :: String.t() | nil
  def mcp_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  def mcp_timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  def mcp_timestamp(nil), do: nil

  @spec timestamp(timestamp_value()) :: String.t() | nil
  def timestamp(timestamp), do: mcp_timestamp(timestamp)

  @spec work_package_payload(WorkPackage.t()) :: map()
  def work_package_payload(%WorkPackage{} = work_package) do
    %{"id" => work_package.id, "kind" => work_package.kind, "status" => work_package.status}
  end

  @spec work_package_contract_payload(WorkPackage.t()) :: map()
  def work_package_contract_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.merge(%{
      "acceptance_criteria" => work_package.acceptance_criteria || [],
      "allowed_file_globs" => work_package.allowed_file_globs || [],
      "base_branch" => work_package.base_branch,
      "parent_id" => work_package.parent_id,
      "phase_id" => work_package.phase_id,
      "policy_template" => work_package.policy_template,
      "repo" => work_package.repo,
      "title" => work_package.title
    })
  end

  @spec json_safe_payload(term()) :: term()
  def json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
