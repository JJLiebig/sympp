defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestScope do
  @moduledoc """
  Resolves the WorkRequest, packages and questions a tool call names.

  Every trusted caller may read any WorkRequest; owner-gated writes are checked
  by `Ownership` before a handler runs. This module only makes sure the named
  objects exist and belong together.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
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

  @spec work_request_list_filters(filters(), String.t() | nil) :: filters()
  def work_request_list_filters(filters, nil), do: filters
  def work_request_list_filters(filters, status), do: Map.put(filters, "status", status)

  @spec work_request_repository_filters(filters()) :: map()
  def work_request_repository_filters(filters), do: Map.take(filters, ["repo", "base_branch", "status"])

  @spec scoped_work_request_question(repo(), String.t(), String.t()) ::
          {:ok, ClarificationQuestion.t()} | {:error, term()}
  def scoped_work_request_question(repo, work_request_id, question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        %ClarificationQuestion{} = question -> {:ok, question}
        nil -> {:error, :not_found}
      end
    end
  end

  @spec scoped_delivery_board(repo(), WorkRequest.t(), [WorkPackage.t()], keyword()) :: term()
  def scoped_delivery_board(repo, %WorkRequest{} = work_request, work_packages, opts \\ []) when is_list(work_packages) do
    {visible_work_package_ids, work_package_contexts} =
      visible_delivery_board_work_package_contexts(repo, work_request, work_packages)

    project_opts =
      [
        work_request: work_request,
        work_packages: work_packages,
        visible_work_package_ids: visible_work_package_ids,
        work_package_contexts: work_package_contexts,
        slice_projection: Keyword.get(opts, :slice_projection)
      ]
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

    DeliveryBoard.project(repo, work_request.id, project_opts)
  end

  @doc "The WorkRequest's packages plus any same-WorkRequest successors their endings name."
  @spec visible_delivery_board_work_package_contexts(repo(), WorkRequest.t(), [WorkPackage.t()]) ::
          {[String.t()], map()}
  def visible_delivery_board_work_package_contexts(repo, %WorkRequest{} = work_request, work_packages) do
    work_package_ids = Enum.map(work_packages, & &1.id)

    successor_ids =
      repo.all(
        from(delivery in WorkPackageDelivery,
          where: delivery.work_request_id == ^work_request.id and delivery.work_package_id in ^work_package_ids,
          select: delivery.successor_work_package_id
        )
      )

    ids = (work_package_ids ++ successor_ids) |> Enum.filter(&filled_string?/1) |> Enum.uniq()
    owned = Map.new(work_packages, &{&1.id, &1})

    work_package_contexts =
      repo.all(from(work_package in WorkPackage, where: work_package.id in ^ids))
      |> Enum.filter(&(Map.has_key?(owned, &1.id) and &1.work_request_id == work_request.id))
      |> Map.new(&{&1.id, %{work_package: &1}})

    {Map.keys(work_package_contexts), work_package_contexts}
  end

  @spec require_work_package_in_work_request(WorkPackage.t(), WorkRequest.t()) :: :ok | {:error, :not_found}
  def require_work_package_in_work_request(%WorkPackage{work_request_id: id}, %WorkRequest{id: id}), do: :ok
  def require_work_package_in_work_request(%WorkPackage{}, %WorkRequest{}), do: {:error, :not_found}

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""
end
