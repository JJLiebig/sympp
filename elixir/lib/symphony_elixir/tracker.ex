defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback start_agent_run(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback list_active_agent_runs() :: {:ok, [term()]} | {:error, term()}
  @callback heartbeat_agent_run(String.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback mark_agent_run_running(String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback mark_agent_run_retrying(String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback mark_agent_run_completed(String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback mark_agent_run_failed(String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback mark_agent_run_stopped(String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}

  @optional_callbacks start_agent_run: 2,
                      list_active_agent_runs: 0,
                      heartbeat_agent_run: 2,
                      mark_agent_run_running: 2,
                      mark_agent_run_retrying: 2,
                      mark_agent_run_completed: 2,
                      mark_agent_run_failed: 2,
                      mark_agent_run_stopped: 2

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec start_agent_run(term(), keyword()) :: {:ok, term() | nil} | {:error, term()}
  def start_agent_run(issue, opts \\ []) do
    adapter = adapter()

    if function_exported?(adapter, :start_agent_run, 2) do
      adapter.start_agent_run(issue, opts)
    else
      {:ok, nil}
    end
  end

  @spec list_active_agent_runs() :: {:ok, [term()]} | {:error, term()}
  def list_active_agent_runs do
    adapter = adapter()

    if function_exported?(adapter, :list_active_agent_runs, 0) do
      adapter.list_active_agent_runs()
    else
      {:ok, []}
    end
  end

  @spec heartbeat_agent_run(String.t() | nil, map()) :: {:ok, term() | nil} | {:error, term()}
  def heartbeat_agent_run(agent_run_id, attrs \\ %{})

  @spec heartbeat_agent_run(String.t() | nil, map()) :: {:ok, term() | nil} | {:error, term()}
  def heartbeat_agent_run(nil, _attrs), do: {:ok, nil}

  def heartbeat_agent_run(agent_run_id, attrs) when is_binary(agent_run_id) and is_map(attrs) do
    adapter = adapter()

    if function_exported?(adapter, :heartbeat_agent_run, 2) do
      adapter.heartbeat_agent_run(agent_run_id, attrs)
    else
      {:ok, nil}
    end
  end

  @spec mark_agent_run_retrying(String.t() | nil, String.t() | nil) :: {:ok, term() | nil} | {:error, term()}
  def mark_agent_run_retrying(agent_run_id, reason \\ nil), do: mark_agent_run(agent_run_id, reason, :mark_agent_run_retrying)

  @spec mark_agent_run_running(String.t() | nil, String.t() | nil) :: {:ok, term() | nil} | {:error, term()}
  def mark_agent_run_running(agent_run_id, reason \\ nil), do: mark_agent_run(agent_run_id, reason, :mark_agent_run_running)

  @spec mark_agent_run_completed(String.t() | nil, String.t() | nil) :: {:ok, term() | nil} | {:error, term()}
  def mark_agent_run_completed(agent_run_id, reason \\ nil), do: mark_agent_run(agent_run_id, reason, :mark_agent_run_completed)

  @spec mark_agent_run_failed(String.t() | nil, String.t() | nil) :: {:ok, term() | nil} | {:error, term()}
  def mark_agent_run_failed(agent_run_id, reason \\ nil), do: mark_agent_run(agent_run_id, reason, :mark_agent_run_failed)

  @spec mark_agent_run_stopped(String.t() | nil, String.t() | nil) :: {:ok, term() | nil} | {:error, term()}
  def mark_agent_run_stopped(agent_run_id, reason \\ nil), do: mark_agent_run(agent_run_id, reason, :mark_agent_run_stopped)

  defp mark_agent_run(nil, _reason, _callback), do: {:ok, nil}

  defp mark_agent_run(agent_run_id, reason, callback) when is_binary(agent_run_id) and is_atom(callback) do
    adapter = adapter()

    if function_exported?(adapter, callback, 2) do
      apply(adapter, callback, [agent_run_id, reason])
    else
      {:ok, nil}
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
