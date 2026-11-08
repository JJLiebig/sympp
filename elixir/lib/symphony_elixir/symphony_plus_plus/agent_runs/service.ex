defmodule SymphonyElixir.SymphonyPlusPlus.AgentRuns.Service do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository

  @type error :: Repository.error()

  @spec start_dispatch(Repository.repo(), Issue.t(), keyword()) :: {:ok, AgentRun.t()} | {:error, error()}
  def start_dispatch(repo, %Issue{} = issue, opts \\ []) when is_atom(repo) and is_list(opts) do
    attrs =
      %{
        work_package_id: issue.id,
        status: Keyword.get(opts, :status, "running"),
        attempt: normalize_attempt(Keyword.get(opts, :attempt)),
        worker_host: Keyword.get(opts, :worker_host),
        worker_task_handle: Keyword.get(opts, :worker_task_handle)
      }

    Repository.start_run(repo, attrs,
      replace_agent_run_id: Keyword.get(opts, :replace_agent_run_id),
      replace_confirmed_dead_worker: Keyword.get(opts, :replace_confirmed_dead_worker),
      retry_recovery_base_ms: Keyword.get(opts, :retry_recovery_base_ms),
      retry_recovery_max_ms: Keyword.get(opts, :retry_recovery_max_ms),
      starting_stale_after_ms: Keyword.get(opts, :starting_stale_after_ms)
    )
  end

  @spec heartbeat(Repository.repo(), String.t(), map()) :: {:ok, AgentRun.t()} | {:error, error()}
  def heartbeat(repo, agent_run_id, attrs \\ %{}) when is_atom(repo) and is_binary(agent_run_id) and is_map(attrs) do
    Repository.heartbeat(repo, agent_run_id, compact_attrs(attrs))
  end

  @spec list_active(Repository.repo()) :: {:ok, [AgentRun.t()]} | {:error, error()}
  def list_active(repo) when is_atom(repo), do: Repository.list_active(repo)

  @spec mark_retrying(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_retrying(repo, agent_run_id, reason \\ nil), do: Repository.mark_retrying(repo, agent_run_id, reason)

  @spec mark_running(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_running(repo, agent_run_id, reason \\ nil), do: Repository.mark_running(repo, agent_run_id, reason)

  @spec mark_completed(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_completed(repo, agent_run_id, reason \\ nil), do: Repository.mark_completed(repo, agent_run_id, reason)

  @spec mark_failed(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_failed(repo, agent_run_id, reason \\ nil), do: Repository.mark_failed(repo, agent_run_id, reason)

  @spec mark_stopped(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_stopped(repo, agent_run_id, reason \\ nil), do: Repository.mark_stopped(repo, agent_run_id, reason)

  defp compact_attrs(attrs) do
    attrs
    |> Map.take([
      :worker_host,
      :worker_task_handle,
      :workspace_path,
      :session_id,
      :codex_input_tokens,
      :codex_output_tokens,
      :codex_total_tokens,
      :turn_count
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_attempt(_attempt), do: 0
end
