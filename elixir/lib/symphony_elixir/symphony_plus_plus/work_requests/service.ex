defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlanEdit
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type error ::
          Repository.error()
          | DeliveryCloseout.error()
          | WorkPackageService.error()
          | {:worktree_cleanup_failed, WorkPackageService.error()}

  @spec create(Repository.repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs), do: notify_dashboard(Repository.create(repo, attrs))

  @spec get(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(Repository.repo(), map()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}), do: Repository.list(repo, filters)

  @spec list_page(Repository.repo(), map() | keyword(), pos_integer(), nil | {DateTime.t(), String.t()}) ::
          {:ok, [WorkRequest.t()]} | {:error, error()}
  def list_page(repo, filters, limit, cursor), do: Repository.list_page(repo, filters, limit, cursor)

  @spec update(Repository.repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs), do: notify_dashboard(Repository.update(repo, id, attrs))

  @spec record_decision(Repository.repo(), String.t(), map()) :: {:ok, DecisionLogEntry.t()} | {:error, error()}
  def record_decision(repo, work_request_id, attrs), do: notify_dashboard(Repository.record_decision(repo, work_request_id, attrs))

  @doc """
  Applies plan operations atomically. The caller notifies the dashboard with
  `notify_plan_changed/0` once its own transaction has committed.
  """
  @spec edit_plan(Repository.repo(), String.t(), [map()], String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def edit_plan(repo, work_request_id, ops, created_by), do: PlanEdit.run(repo, work_request_id, ops, created_by)

  @spec notify_plan_changed() :: :ok
  def notify_plan_changed, do: DashboardPubSub.broadcast_changed()

  @spec list_work_packages(Repository.repo(), String.t()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list_work_packages(repo, work_request_id), do: Repository.list_work_packages(repo, work_request_id)

  @spec get_work_package(Repository.repo(), String.t(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get_work_package(repo, work_request_id, id), do: Repository.get_work_package(repo, work_request_id, id)

  @spec record_work_package_delivery(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, WorkPackageDelivery.t()} | {:error, error()}
  def record_work_package_delivery(repo, work_request_id, work_package_id, attrs),
    do: notify_dashboard(DeliveryCloseout.record(repo, work_request_id, work_package_id, attrs))

  @spec list_decisions(Repository.repo(), String.t()) :: {:ok, [DecisionLogEntry.t()]} | {:error, error()}
  def list_decisions(repo, work_request_id), do: Repository.list_decisions(repo, work_request_id)

  @spec complete(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error() | :work_request_archived}
  def complete(repo, work_request_id), do: notify_dashboard(Completion.complete(repo, work_request_id))

  @spec archive(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error() | :not_completed}
  def archive(repo, work_request_id), do: notify_dashboard(Completion.archive(repo, work_request_id))

  @spec restore(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def restore(repo, work_request_id), do: notify_dashboard(Completion.restore(repo, work_request_id))

  @spec delete(Repository.repo(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def delete(repo, work_request_id), do: notify_dashboard(Completion.delete(repo, work_request_id))

  @spec retention_pass(Repository.repo()) ::
          {:ok, Completion.retention_summary()}
          | {:error, Completion.retention_error()}
  @spec retention_pass(Repository.repo(), keyword()) ::
          {:ok, Completion.retention_summary()}
          | {:error, Completion.retention_error()}
  def retention_pass(repo, opts \\ []), do: Completion.retention_pass(repo, opts)

  defp notify_dashboard({:ok, _value} = result) do
    :ok = DashboardPubSub.broadcast_changed()
    result
  end

  defp notify_dashboard(result), do: result
end
