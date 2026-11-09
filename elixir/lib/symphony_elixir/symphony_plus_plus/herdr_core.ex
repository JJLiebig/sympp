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
  @send_timeout_ms 10_000

  @type view :: {:live, map()} | :finished | :unseen | :unknown
  @type snapshot :: %{
          required(:core_id) => String.t(),
          required(:terminals) => %{String.t() => map()},
          optional(:core_name) => String.t()
        }

  @doc """
  How the factory's core sees one terminal. With `confirm: true`, a terminal
  the cached snapshot shows finished or doesn't list is checked against a fresh
  snapshot, so a terminal started since the last read is never taken as
  finished. Use it before refusing a write or taking ownership over.
  """
  @spec view(String.t(), String.t(), keyword()) :: view()
  def view(core_id, address, opts \\ []) when is_binary(core_id) and is_binary(address) do
    case view_in(snapshot(false), core_id, address) do
      :finished -> if Keyword.get(opts, :confirm, false), do: view_in(snapshot(true), core_id, address), else: :finished
      view -> view
    end
  end

  defp view_in(snapshot, core_id, address) do
    case snapshot do
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

  @doc """
  The factory host's Herdr machine name: its core's name, or the host name when
  the core can't be reached. `hc run --on <name>` on the factory host reaches
  this machine.
  """
  @spec machine_name() :: String.t()
  def machine_name do
    case snapshot(false) do
      {:ok, %{core_name: name}} when is_binary(name) and name != "" ->
        name

      _unnamed ->
        {:ok, host} = :inet.gethostname()
        to_string(host)
    end
  end

  @doc """
  Pastes text into a terminal's input without pressing Enter (`hc send
  --no-submit`), so the agent reads it on its next turn and a person can still
  edit it. `target` is a terminal address, optionally `machine/address`.

  The command is the `:sympp_herdr_send` application setting: `"hc"` (default),
  another command path, `nil` to disable, or a two-arity function (tests).
  """
  @spec paste(String.t(), String.t()) :: :ok | :error
  def paste(target, text) when is_binary(target) and is_binary(text) do
    case Application.get_env(:symphony_elixir, :sympp_herdr_send, "hc") do
      nil -> :error
      fun when is_function(fun, 2) -> if fun.(target, text) == :ok, do: :ok, else: :error
      command when is_binary(command) -> paste_with(System.find_executable(command), target, text)
    end
  end

  defp paste_with(nil, _target, _text), do: :error

  defp paste_with(path, target, text) do
    task = Task.async(fn -> System.cmd(path, ["send", "--no-submit", "--raw", target, text], stderr_to_stdout: true) end)

    case Task.yield(task, @send_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      _failed -> :error
    end
  rescue
    _error -> :error
  end

  @spec snapshot(boolean()) :: {:ok, snapshot()} | :unavailable
  defp snapshot(fresh?) do
    case Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc") do
      nil -> :unavailable
      fun when is_function(fun, 0) -> normalize(fun.())
      command when is_binary(command) -> cached_command_snapshot(command, fresh?)
    end
  end

  defp cached_command_snapshot(command, fresh?) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {^command, at, result} when not fresh? and now - at < @cache_ms ->
        result

      _stale ->
        result = load_command(command)
        :persistent_term.put(@cache_key, {command, now, result})
        result
    end
  end

  defp load_command(command) do
    with path when is_binary(path) <- System.find_executable(command),
         {:ok, %{"core" => %{"id" => core_id} = core}} when is_binary(core_id) <- run(path, ["server", "status", "--json"]),
         {:ok, %{"terminals" => terminals}} when is_list(terminals) <- run(path, ["ls", "--all", "--json"]) do
      snapshot = %{core_id: core_id, terminals: Map.new(terminals, &{&1["address"], &1})}
      {:ok, if(is_binary(core["name"]), do: Map.put(snapshot, :core_name, core["name"]), else: snapshot)}
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
