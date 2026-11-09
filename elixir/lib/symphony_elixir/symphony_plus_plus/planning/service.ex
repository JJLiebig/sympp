defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State

  @type error :: Repository.error()

  @spec append_plan_node(Repository.repo(), map()) :: {:ok, PlanNode.t()} | {:error, error()}
  def append_plan_node(repo, attrs), do: Repository.append_plan_node(repo, attrs)

  @spec append_progress_event(Repository.repo(), map()) :: {:ok, ProgressEvent.t()} | {:error, error()}
  def append_progress_event(repo, attrs), do: Repository.append_progress_event(repo, attrs)

  @spec append_artifact(Repository.repo(), map()) :: {:ok, Artifact.t()} | {:error, error()}
  def append_artifact(repo, attrs), do: Repository.append_artifact(repo, attrs)

  @spec update_plan_node_status(Repository.repo(), String.t(), String.t()) :: {:ok, PlanNode.t()} | {:error, error()}
  def update_plan_node_status(repo, plan_node_id, status), do: Repository.update_plan_node_status(repo, plan_node_id, status)

  @spec update_plan_node(Repository.repo(), String.t(), map()) :: {:ok, PlanNode.t()} | {:error, Repository.error()}
  def update_plan_node(repo, plan_node_id, attrs), do: Repository.update_plan_node(repo, plan_node_id, attrs)

  @spec get_state(Repository.repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_state(repo, work_package_id), do: Repository.get_state(repo, work_package_id)

  @spec redact_payload(term()) :: term()
  def redact_payload(payload), do: Redactor.redact(payload)
end
