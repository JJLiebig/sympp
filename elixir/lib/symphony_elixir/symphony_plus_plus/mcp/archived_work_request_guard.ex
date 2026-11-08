defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchivedWorkRequestGuard do
  @moduledoc """
  Refuses an MCP write whose target WorkRequest is archived, with
  `next_action: restore`. A worker session always targets its assigned package;
  other callers target the `work_request_id` argument, else the WorkRequest of the
  `work_package_id` argument. Reads and writes without a WorkRequest pass.
  """

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{CurrentWorkRequest, ErrorDetails, Session, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{Phase, WorkRequest}

  @spec check(module() | nil, Session.t() | nil, String.t(), map()) :: :ok | {:error, integer(), String.t(), map()}
  def check(nil, _session, _name, _arguments), do: :ok

  def check(repo, session, name, arguments) when is_binary(name) and is_map(arguments) do
    with false <- ToolCatalog.read_call?(name, arguments),
         %WorkRequest{} = work_request <- target(repo, session, arguments),
         {:error, :work_request_archived} <- Phase.require_writable(work_request) do
      ErrorDetails.lifecycle_error(name, :work_request_archived, %{"phase" => "archived"})
    else
      _writable -> :ok
    end
  rescue
    # A ledger that is not running or not readable is reported by the tool itself.
    _error in [RuntimeError, DBConnection.ConnectionError, Exqlite.Error] -> :ok
  end

  def check(_repo, _session, _name, _arguments), do: :ok

  defp target(repo, session, arguments) do
    case work_request_id(repo, session, arguments) do
      id when is_binary(id) -> repo.get(WorkRequest, id)
      _id -> nil
    end
  end

  defp work_request_id(repo, %Session{assignment: %{grant_role: "worker", work_package_id: id}}, _arguments),
    do: package_work_request_id(repo, id)

  defp work_request_id(repo, session, arguments) do
    cond do
      is_binary(arguments["work_request_id"]) -> arguments["work_request_id"]
      is_binary(arguments["work_package_id"]) -> package_work_request_id(repo, arguments["work_package_id"])
      true -> current_work_request_id(session)
    end
  end

  defp current_work_request_id(%Session{} = session) do
    case CurrentWorkRequest.id_argument(%{}, session) do
      {:ok, id} -> id
      _no_single_scope -> nil
    end
  end

  defp current_work_request_id(nil), do: nil

  defp package_work_request_id(repo, id) when is_binary(id) do
    case repo.get(WorkPackage, id) do
      %WorkPackage{work_request_id: work_request_id} -> work_request_id
      nil -> nil
    end
  end

  defp package_work_request_id(_repo, _id), do: nil
end
