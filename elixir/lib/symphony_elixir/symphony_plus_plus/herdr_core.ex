defmodule SymphonyElixir.SymphonyPlusPlus.HerdrCore do
  @moduledoc """
  The factory host's own herdr-core view of terminals.

  It reads `hc server status` and `hc ls --all` on the factory host and caches
  the result briefly. A terminal on another core is `:unseen`; when the core
  can't be reached the answer is `:unknown`. Neither ever counts as finished.

  The source is the `:sympp_herdr_core` application setting: `"hc"` (default),
  another command path, `nil` to disable, or a zero-arity function returning
  `{:ok, %{core_id: id, terminals: %{address => record}}}` (tests).
  """

  @cache_key {__MODULE__, :snapshot}
  @cache_ms 15_000
  @command_timeout_ms 2_000

  @type view :: {:live, map()} | :finished | :unseen | :unknown
  @type snapshot :: %{core_id: String.t(), terminals: %{String.t() => map()}}

  @doc "How the factory's core sees one terminal."
  @spec view(String.t(), String.t()) :: view()
  def view(core_id, address) when is_binary(core_id) and is_binary(address) do
    case snapshot() do
      {:ok, %{core_id: ^core_id, terminals: terminals}} ->
        case Map.get(terminals, address) do
          %{"state" => "live"} = record -> {:live, record}
          # Same core, finished or no longer listed: the terminal has ended.
          _finished_or_gone -> :finished
        end

      {:ok, %{}} ->
        :unseen

      :unavailable ->
        :unknown
    end
  end

  @doc "One terminal's record from the factory's core, for its live working/idle state."
  @spec status_state(String.t(), String.t()) :: String.t()
  def status_state(core_id, address) do
    case view(core_id, address) do
      {:live, %{"status" => %{"state" => state}}} when is_binary(state) -> state
      {:live, %{"status" => state}} when is_binary(state) -> state
      {:live, _record} -> "live"
      :finished -> "finished"
      _unseen_or_unknown -> "unknown"
    end
  end

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @spec snapshot() :: {:ok, snapshot()} | :unavailable
  defp snapshot do
    case Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc") do
      nil -> :unavailable
      fun when is_function(fun, 0) -> normalize(fun.())
      command when is_binary(command) -> cached_command_snapshot(command)
    end
  end

  defp cached_command_snapshot(command) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {^command, at, result} when now - at < @cache_ms ->
        result

      _stale ->
        result = load_command(command)
        :persistent_term.put(@cache_key, {command, now, result})
        result
    end
  end

  defp load_command(command) do
    with path when is_binary(path) <- System.find_executable(command),
         {:ok, %{"core" => %{"id" => core_id}}} when is_binary(core_id) <- run(path, ["server", "status", "--json"]),
         {:ok, %{"terminals" => terminals}} when is_list(terminals) <- run(path, ["ls", "--all", "--json"]) do
      {:ok, %{core_id: core_id, terminals: Map.new(terminals, &{&1["address"], &1})}}
    else
      _unavailable -> :unavailable
    end
  end

  defp run(path, args) do
    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: false) end)

    case Task.yield(task, @command_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> Jason.decode(output)
      _failed -> :error
    end
  rescue
    _error -> :error
  end

  defp normalize({:ok, %{core_id: core_id, terminals: terminals}} = result) when is_binary(core_id) and is_map(terminals), do: result
  defp normalize(_result), do: :unavailable
end
