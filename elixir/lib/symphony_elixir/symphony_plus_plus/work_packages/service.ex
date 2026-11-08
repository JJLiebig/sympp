defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle

  @type error :: Repository.error() | WorktreeLifecycle.error()

  @spec create(Repository.repo(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def create(repo, attrs), do: Repository.create(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list(repo), do: Repository.list(repo)

  @spec update(Repository.repo(), String.t(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def update(repo, id, attrs), do: Repository.update(repo, id, attrs)

  @spec prepare_worktree(Repository.repo(), String.t(), map()) ::
          {:ok, WorktreeLifecycle.lifecycle_result()} | {:error, error()}
  def prepare_worktree(repo, id, attrs), do: WorktreeLifecycle.prepare(repo, id, attrs)

  @spec validate_worktree_cleanup(Repository.repo(), String.t()) ::
          {:ok, WorktreeLifecycle.lifecycle_result()} | {:error, error()}
  @spec validate_worktree_cleanup(Repository.repo(), String.t(), keyword()) ::
          {:ok, WorktreeLifecycle.lifecycle_result()} | {:error, error()}
  def validate_worktree_cleanup(repo, id, opts \\ []), do: WorktreeLifecycle.validate_cleanup(repo, id, opts)
end
