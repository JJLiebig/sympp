defmodule SymphonyElixir.SymphonyPlusPlus.HerdrCore do
  @moduledoc """
  The factory host's own herdr-core view of terminals.

  It reads `hc server status` and `terminal.list` through `hc connect` on the factory host and caches
  the result briefly; the `Observer` refreshes it every 15 s. Worker terminals
  (label `sympp.role=worker`) carry their labels; chief terminals
  (`sympp.role=chief`) and terminals labelled `sympp.card=1` carry that label. A terminal on another core is
  `:unseen`; when the core can't be reached the answer is `:unknown`. Neither
  ever counts as finished. Ordinary reads keep using the last good snapshot for
  up to 2 minutes while the core is unreachable; reads that confirm a finish
  never do.

  The source is the `:sympp_herdr_core` application setting: `"hc"` (default),
  another command path, `nil` to disable, or a zero-arity function returning
  `{:ok, %{core_id: id, terminals: %{address => record}}}` (tests).
  """

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Inputs
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardCache, DashboardPubSub, Observer}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

  @cache_key {__MODULE__, :snapshot}
  @refresh_key {__MODULE__, :refresh}
  @cache_ms 15_000
  @last_good_ms 120_000
  @command_timeout_ms 2_000
  # Herdr waits up to three seconds for remote machines before returning a partial list.
  @list_timeout_ms 5_000
  # Herdr's hangup, terminate and kill escalation can take three seconds.
  @kill_timeout_ms 5_000
  # Herdr holds a submitted send for 60 seconds after the last key in an unfinished draft by default.
  @send_timeout_ms 75_000

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

  @doc false
  @spec board_view(String.t(), String.t()) :: view()
  def board_view(core_id, address) do
    if Inputs.active?() do
      view_in(Inputs.memo(:herdr_snapshot, &board_snapshot/0), core_id, address)
    else
      view(core_id, address)
    end
  end

  defp board_snapshot do
    case Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc") do
      nil ->
        :unavailable

      fun when is_function(fun, 0) ->
        normalize(fun.())

      command when is_binary(command) ->
        refresh_on_demand()

        @cache_key
        |> :persistent_term.get(nil)
        |> last_good(command)
        |> usable_good(System.monotonic_time(:millisecond))
        |> track_board_expiry()
    end
  end

  defp track_board_expiry({:ok, _snapshot} = result) do
    DashboardCache.track_core_expiry()
    result
  end

  defp track_board_expiry(:unavailable), do: :unavailable

  @doc "The factory core's current snapshot: cached, or the last good one for up to 2 minutes."
  @spec current() :: {:ok, snapshot()} | :unavailable
  def current, do: snapshot(false)

  @doc false
  @spec last_good_deadline() :: integer() | nil
  def last_good_deadline do
    command = Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc")

    case last_good(:persistent_term.get(@cache_key, nil), command) do
      {at, _snapshot} -> at + @last_good_ms
      nil -> nil
    end
  end

  @doc false
  @spec refresh_on_demand() :: :ok
  def refresh_on_demand do
    # The installed factory already checks Herdr through its Observer.
    with nil <- Process.whereis(Observer),
         command when is_binary(command) <- Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc") do
      now = System.monotonic_time(:millisecond)

      case :persistent_term.get(@cache_key, nil) do
        {^command, at, _result, _good} when now - at < @cache_ms -> :ok
        cached -> refresh_background(command, last_good(cached, command), now)
      end
    end

    :ok
  end

  @doc "One terminal's record from the factory's core, for its live working/idle state."
  @spec status_state(String.t(), String.t()) :: String.t()
  def status_state(core_id, address), do: status(view(core_id, address))

  @doc false
  @spec board_worker(String.t(), String.t()) :: {String.t(), String.t() | nil}
  def board_worker(core_id, address) do
    Inputs.observe({:worker_display, core_id, address}, fn -> worker_display(board_view(core_id, address)) end)
  end

  defp worker_display(view), do: {status(view), preview_url(view)}

  defp status({:live, %{"status" => %{"state" => state}}}) when is_binary(state), do: state
  defp status({:live, %{"status" => state}}) when is_binary(state), do: state
  defp status({:live, _record}), do: "live"
  defp status(:finished), do: "finished"
  defp status(_unseen_or_unknown), do: "unknown"

  defp preview_url({:live, record}) do
    with url when is_binary(url) <- get_in(record, ["labels", "sympp.preview_url"]),
         value = String.trim(url),
         true <- String.length(value) <= 2048 and Regex.match?(~r/^https?:\/\/[^\s\/?#]+(?:[\/?#]\S*)?$/i, value) do
      value
    else
      _absent_or_invalid -> nil
    end
  end

  defp preview_url(_other), do: nil

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

  @doc false
  @spec worker_name(String.t()) :: String.t()
  def worker_name(work_package_id) do
    # Herdr names are 1-32 characters of a-z, 0-9, - and _.
    case work_package_id |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "-") |> String.slice(0, 32) do
      "" -> "worker"
      name -> name
    end
  end

  @doc "The package bound to a live terminal by its sympp launch name and labels."
  @spec live_worker_package_id(map()) :: String.t() | nil
  def live_worker_package_id(%{
        "state" => "live",
        "name" => name,
        "labels" => %{"sympp.role" => "worker", "sympp.work_package_id" => id}
      })
      when is_binary(id) do
    if name == worker_name(id), do: id
  end

  def live_worker_package_id(_record), do: nil

  @doc "Closes a live worker after confirming its binding at the supplied Herdr address."
  @spec close_worker(String.t(), String.t()) :: :ok | :error
  def close_worker(address, work_package_id) do
    with command when is_binary(command) <- Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc"),
         path when is_binary(path) <- System.find_executable(command),
         {:ok, %{"address" => ^address} = terminal} <- run(path, ["get", address, "--json"]),
         ^work_package_id <- live_worker_package_id(terminal) do
      case run(path, ["kill", address, "--json"], @kill_timeout_ms) do
        {:ok, %{"state" => "finished"}} -> :ok
        _failed -> :error
      end
    else
      _unconfirmed_or_finished -> :ok
    end
  end

  @doc """
  Submits a message to the recorded terminal using Herdr's configured submit
  keys. `terminal_key` is the terminal's key (core id plus address).

  Messages go only to a terminal the factory's own core sees live. Herdr
  machine names are local aliases, so a terminal on another core can't be
  addressed safely from here. Otherwise the reason is `terminal_finished`,
  `terminal_unreachable` or `send_failed`.
  """
  @spec deliver(String.t(), String.t()) :: :ok | {:error, String.t()}
  def deliver(terminal_key, text) when is_binary(terminal_key) and is_binary(text) do
    with {:ok, address} <- delivery_target(terminal_key) do
      args = ["send", "--raw", address, text]
      if send_message(args) == :ok, do: :ok, else: {:error, "send_failed"}
    end
  end

  defp delivery_target(terminal_key) do
    case Terminal.split_key(terminal_key) do
      {core_id, address} ->
        case view(core_id, address, confirm: true) do
          {:live, _record} -> {:ok, address}
          :finished -> {:error, "terminal_finished"}
          _unseen_or_unknown -> {:error, "terminal_unreachable"}
        end

      :error ->
        {:error, "terminal_unreachable"}
    end
  end

  # The command is the `:sympp_herdr_send` application setting: `"hc"`
  # (default), another command path, `nil` to disable, or a function that
  # receives the command arguments (tests).
  defp send_message(args) do
    case Application.get_env(:symphony_elixir, :sympp_herdr_send, "hc") do
      nil -> :error
      fun when is_function(fun, 1) -> if fun.(args) == :ok, do: :ok, else: :error
      command when is_binary(command) -> send_with(System.find_executable(command), args)
    end
  end

  defp send_with(nil, _args), do: :error

  defp send_with(path, args) do
    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

    case Task.yield(task, @send_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      _failed -> :error
    end
  rescue
    _error -> :error
  end

  @doc """
  A fresh snapshot of the factory's core, for the `Observer`. `:unavailable`
  when the core can't be reached; the last good snapshot then stays in use for
  ordinary reads for up to 2 minutes.
  """
  @spec refresh() :: {:ok, snapshot()} | :unavailable
  def refresh do
    command = Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc")
    previous_good = last_good(:persistent_term.get(@cache_key, nil), command)
    refresh_and_notify(previous_good, System.monotonic_time(:millisecond))
  end

  @doc "The configured `hc` executable on the factory host, if any."
  @spec command_path() :: String.t() | nil
  def command_path do
    case Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc") do
      command when is_binary(command) -> System.find_executable(command)
      _function_or_disabled -> System.find_executable("hc")
    end
  end

  @spec snapshot(boolean()) :: {:ok, snapshot()} | :unavailable
  defp snapshot(fresh?), do: load(fresh?, not fresh?)

  defp load(fresh?, last_good?) do
    case Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc") do
      nil -> :unavailable
      fun when is_function(fun, 0) -> normalize(fun.())
      command when is_binary(command) -> cached_command_snapshot(command, fresh?, last_good?)
    end
  end

  defp cached_command_snapshot(command, fresh?, last_good?) do
    now = System.monotonic_time(:millisecond)

    {result, good} =
      case :persistent_term.get(@cache_key, nil) do
        {^command, at, result, good} when not fresh? and now - at < @cache_ms ->
          {result, good}

        cached ->
          result = load_command(command)
          good = if result == :unavailable, do: last_good(cached, command), else: {now, result}
          :persistent_term.put(@cache_key, {command, now, result, good})
          {result, good}
      end

    case {result, good} do
      {:unavailable, {at, good_result}} when last_good? and now - at < @last_good_ms ->
        good_result

      _current ->
        result
    end
  end

  defp refresh_background(command, previous_good, started_at) do
    :global.trans(
      {{__MODULE__, :refresh}, self()},
      fn -> start_background_refresh(command, previous_good, started_at) end,
      [node()],
      0
    )
  end

  defp start_background_refresh(command, previous_good, started_at) do
    unless pending_refresh?(command) do
      {:ok, pid} =
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          refresh_and_notify(previous_good, started_at)
        end)

      :persistent_term.put(@refresh_key, {command, pid})
    end
  end

  defp pending_refresh?(command) do
    case :persistent_term.get(@refresh_key, nil) do
      {^command, pid} -> Process.alive?(pid)
      _other -> false
    end
  end

  defp refresh_and_notify(previous_good, started_at) do
    result = load(true, false)
    now = System.monotonic_time(:millisecond)

    # Compare against what the dashboard could use, not an expired snapshot
    # that it had to present as unknown. Capture it when scheduling, before
    # another caller can update the shared cache.
    previous = usable_good(previous_good, started_at)
    fallback = usable_good(previous_good, now)
    current = if result == :unavailable, do: fallback, else: result

    recovered? = fallback == :unavailable and result != :unavailable

    if display_snapshot(current) != display_snapshot(previous) or recovered? do
      DashboardPubSub.broadcast_changed()
    end

    result
  end

  defp display_snapshot({:ok, %{core_id: core_id, terminals: terminals}}) do
    live = for {address, %{"state" => "live"} = record} <- terminals, into: %{}, do: {address, worker_display({:live, record})}
    {core_id, live}
  end

  defp display_snapshot(:unavailable), do: :unavailable

  defp usable_good({at, snapshot}, now) when now - at < @last_good_ms, do: snapshot
  defp usable_good(_expired_or_missing, _now), do: :unavailable

  defp last_good({command, _at, _result, good}, command), do: good
  defp last_good(_cached, _command), do: nil

  defp load_command(command) do
    with path when is_binary(path) <- System.find_executable(command),
         {:ok, %{"core" => %{"id" => core_id} = core}} when is_binary(core_id) <- run(path, ["server", "status", "--json"]),
         {:ok, %{"terminals" => records}} when is_list(records) <- list_terminals(path) do
      terminals = Map.new(records, fn record -> {record["address"], Map.delete(record, "argv")} end)

      snapshot = %{core_id: core_id, terminals: terminals}
      {:ok, if(is_binary(core["name"]), do: Map.put(snapshot, :core_name, core["name"]), else: snapshot)}
    else
      _unavailable -> :unavailable
    end
  end

  # The CLI's compact `hc ls` output omits labels. `terminal.list` returns full
  # public records, including those forwarded by other machines.
  defp list_terminals(path) do
    task =
      Task.async(fn ->
        port = Port.open({:spawn_executable, path}, [:binary, :exit_status, :hide, args: ["connect"]])

        try do
          Port.command(port, Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "terminal.list", params: %{all: true}}) <> "\n")
          list_response(port, "")
        after
          if Port.info(port), do: Port.close(port)
        end
      end)

    case Task.yield(task, @list_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _failed -> :error
    end
  rescue
    _error -> :error
  end

  defp list_response(port, buffer) do
    receive do
      {^port, {:data, data}} ->
        case String.split(buffer <> data, "\n", parts: 2) do
          [line, _rest] ->
            case Jason.decode(line) do
              {:ok, %{"id" => 1, "result" => result}} -> {:ok, result}
              _invalid -> :error
            end

          [partial] ->
            list_response(port, partial)
        end

      {^port, {:exit_status, _status}} ->
        :error
    end
  end

  defp run(path, args, timeout \\ @command_timeout_ms) do
    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: false) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> Jason.decode(output)
      _failed -> :error
    end
  rescue
    _error -> :error
  end

  defp normalize({:ok, %{core_id: core_id, terminals: terminals}} = result) when is_binary(core_id) and is_map(terminals), do: result
  defp normalize(_result), do: :unavailable
end
