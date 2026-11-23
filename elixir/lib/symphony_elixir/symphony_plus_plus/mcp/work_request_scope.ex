defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestScope do
  @moduledoc """
  Resolves the WorkRequest, packages and questions a tool call names.

  Every trusted caller may read any WorkRequest; owner-gated writes are checked
  by `Ownership` before a handler runs. This module only makes sure the named
  objects exist and belong together.
  """

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type repo :: module()
  @type filters :: map()

  @doc "A WorkRequest and its repository filters (its own repo and base branch)."
  @spec work_request_scope(repo(), String.t()) :: {:ok, WorkRequest.t(), filters()} | {:error, term()}
  def work_request_scope(repo, work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestService.get(repo, work_request_id) do
      {:ok, work_request, %{"repo" => work_request.repo, "base_branch" => work_request.base_branch}}
    end
  end

  @doc "A WorkRequest and one of its packages."
  @spec work_package_scope(repo(), String.t(), String.t()) ::
          {:ok, WorkRequest.t(), WorkPackage.t()} | {:error, term()}
  def work_package_scope(repo, work_request_id, id) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestService.get(repo, work_request_id),
         {:ok, %WorkPackage{} = package} <- WorkRequestService.get_work_package(repo, work_request_id, id) do
      {:ok, work_request, package}
    end
  end

  @spec scoped_work_request(repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, term()}
  def scoped_work_request(repo, work_request_id), do: WorkRequestService.get(repo, work_request_id)

  @spec require_work_package_in_work_request(WorkPackage.t(), WorkRequest.t()) :: :ok | {:error, :not_found}
  def require_work_package_in_work_request(%WorkPackage{work_request_id: id}, %WorkRequest{id: id}), do: :ok
  def require_work_package_in_work_request(%WorkPackage{}, %WorkRequest{}), do: {:error, :not_found}
end
