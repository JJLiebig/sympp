defmodule CanonicalWorkPackageFixtures do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  def add_work_package(repo, work_request_id, attrs) do
    case repo.get(WorkRequest, work_request_id) do
      %WorkRequest{} = work_request ->
        attrs =
          attrs
          |> Map.new()
          |> Map.put(:work_request_id, work_request_id)
          |> Map.put_new(:repo, work_request.repo)
          |> Map.put_new(:base_branch, work_request.base_branch)
          |> Map.put_new(:sequence, next_sequence(repo, work_request_id))
          |> Map.put_new(:status, "planned")

        WorkPackageRepository.create(repo, attrs)

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Ends a package with the given ending row through the real closeout path.
  A planned package is first moved to where the outcome may be recorded from.
  """
  def end_work_package(repo, work_request_id, work_package_id, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    outcome = Map.fetch!(attrs, "outcome")

    with {:ok, package} <- get_work_package(repo, work_request_id, work_package_id) do
      if package.status not in Lifecycle.ending_sources(outcome) and package.status == "planned" do
        repo.update!(Ecto.Changeset.change(package, status: "dispatched", dispatched_at: package.dispatched_at || now()))
      end

      DeliveryCloseout.record(repo, work_request_id, work_package_id, Map.put_new(attrs, "idempotency_key", "fixture-ending:#{work_package_id}"))
    end
  end

  def add_work_package_for_authoring(repo, work_request_id, attrs),
    do: add_work_package(repo, work_request_id, attrs)

  def approve_work_package(repo, work_request_id, work_package_id, _current_status) do
    get_work_package(repo, work_request_id, work_package_id)
  end

  def dispatch_work_package(repo, work_request_id, planned_id, _current_status, target_id) do
    repo.transaction(fn ->
      with {:ok, planned} <- get_work_package(repo, work_request_id, planned_id),
           %WorkPackage{} = target <- repo.get(WorkPackage, target_id) do
        canonicalize_target(repo, planned, target)
      else
        nil -> repo.rollback(:not_found)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp canonicalize_target(repo, %WorkPackage{id: id} = planned, %WorkPackage{id: id}) do
    status = if planned.status == "planned", do: "dispatched", else: planned.status
    repo.update!(Ecto.Changeset.change(planned, status: status, dispatched_at: now()))
  end

  defp canonicalize_target(repo, %WorkPackage{} = planned, %WorkPackage{} = target) do
    repo.delete!(planned)

    repo.update!(
      Ecto.Changeset.change(target,
        work_request_id: planned.work_request_id,
        product_tree_node_id: planned.product_tree_node_id,
        sequence: planned.sequence,
        goal: planned.goal,
        forbidden_file_globs: planned.forbidden_file_globs,
        validation_steps: planned.validation_steps,
        stop_conditions: planned.stop_conditions,
        contract_revision: planned.contract_revision,
        dispatched_at: now()
      )
    )
  end

  defp get_work_package(repo, work_request_id, work_package_id) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{work_request_id: ^work_request_id} = work_package -> {:ok, work_package}
      _record -> {:error, :not_found}
    end
  end

  defp next_sequence(repo, work_request_id) do
    import Ecto.Query

    repo.one(
      from(work_package in WorkPackage,
        where: work_package.work_request_id == ^work_request_id,
        select: max(work_package.sequence)
      )
    )
    |> Kernel.||(0)
    |> Kernel.+(1)
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
