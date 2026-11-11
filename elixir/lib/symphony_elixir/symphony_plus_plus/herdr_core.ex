defmodule SymphonyElixir.SymphonyPlusPlus.HerdrCore do
  @moduledoc """
  The factory host's own herdr-core view of terminals.

  It reads `hc server status` and `hc ls --all` on the factory host and caches
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

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

  @cache_key {__MODULE__, :snapshot}
  @labels_key {__MODULE__, :labels}
  @cached_reads_key {__MODULE__, :cached_reads}
  @refresh_key {__MODULE__, :refresh}
  @cache_ms 15_000
  @last_good_ms 120_000
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

  @doc "The factory core's current snapshot: cached, or the last good one for up to 2 minutes."
  @spec current() :: {:ok, snapshot()} | :unavailable
  def current, do: snapshot(false)

  @doc false
  @spec with_cached_reads((-> result)) :: result when result: var
  def with_cached_reads(fun) do
    previous = Process.put(@cached_reads_key, true)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@cached_reads_key), else: Process.put(@cached_reads_key, previous)
    end
  end

  @doc """
  One terminal's full record from the factory's core (`hc get`), with its
  labels and title. With a function source (tests) it is the snapshot's record.
  """
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(address) when is_binary(address) do
    case Application.get_env(:symphony_elixir, :sympp_herdr_core, "hc") do
      nil -> :error
      fun when is_function(fun, 0) -> snapshot_record(normalize(fun.()), address)
      command when is_binary(command) -> get_with(System.find_executable(command), address)
    end
  end

  defp snapshot_record({:ok, %{terminals: terminals}}, address) do
    case Map.get(terminals, address) do
      %{} = record -> {:ok, record}
      nil -> :error
    end
  end

  defp snapshot_record(:unavailable, _address), do: :error

  defp get_with(nil, _address), do: :error

  defp get_with(path, address) do
    case run(path, ["get", address, "--json"]) do
      {:ok, %{"address" => ^address} = record} -> {:ok, Map.delete(record, "argv")}
      _unavailable -> :error
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
  Types text into a recorded terminal's input. `terminal_key` is the
  terminal's key (core id plus address). By default the text is left in the
  input without submitting it, for operator answers and decision feedback;
  with `submit: true` it is sent like an ordinary message.

  Text is typed only into a terminal the factory's own core sees live. Herdr
  machine names are local aliases, so a terminal on another core can't be
  addressed safely from here. Otherwise the reason is `terminal_finished`,
  `terminal_unreachable` or `send_failed`.
  """
  @spec deliver(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def deliver(terminal_key, text, opts \\ []) when is_binary(terminal_key) and is_binary(text) do
    mode = if Keyword.get(opts, :submit, false), do: :submit, else: :prefill

    with {:ok, address} <- delivery_target(terminal_key) do
      if type(address, text, mode) == :ok, do: :ok, else: {:error, "send_failed"}
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

  # `hc send --raw`: `:prefill` adds `--no-submit`, so the agent reads the text
  # on its next turn and a person can still edit it; `:submit` presses Enter.
  # The command is the `:sympp_herdr_send` application setting: `"hc"`
  # (default), another command path, `nil` to disable, or a three-arity
  # function `(target, text, mode)` (tests).
  defp type(target, text, mode) do
    case Application.get_env(:symphony_elixir, :sympp_herdr_send, "hc") do
      nil -> :error
      fun when is_function(fun, 3) -> if fun.(target, text, mode) == :ok, do: :ok, else: :error
      command when is_binary(command) -> type_with(System.find_executable(command), target, text, mode)
    end
  end

  defp type_with(nil, _target, _text, _mode), do: :error

  defp type_with(path, target, text, mode) do
    args = if mode == :prefill, do: ["send", "--no-submit", "--raw", target, text], else: ["send", "--raw", target, text]
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
  def refresh, do: load(true, false)

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
          load_uncached_snapshot(command, now, fresh?, cached)
      end

    case {result, good} do
      {:unavailable, {at, good_result}} when last_good? and now - at < @last_good_ms -> good_result
      _current -> result
    end
  end

  defp load_uncached_snapshot(command, now, fresh?, cached) do
    if not fresh? and Process.get(@cached_reads_key, false) do
      good = last_good(cached, command)
      refresh_background(command, good, now)
      {:unavailable, good}
    else
      result = load_command(command)
      good = if result == :unavailable, do: last_good(cached, command), else: {now, result}
      :persistent_term.put(@cache_key, {command, now, result, good})
      {result, good}
    end
  end

  defp refresh_background(command, previous_good, started_at) do
    pending? =
      case :persistent_term.get(@refresh_key, nil) do
        {^command, pid} -> Process.alive?(pid)
        _other -> false
      end

    unless pending? do
      {:ok, pid} =
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          refresh_and_notify(previous_good, started_at)
        end)

      :persistent_term.put(@refresh_key, {command, pid})
    end
  end

  defp refresh_and_notify(previous_good, started_at) do
    result = refresh()
    now = System.monotonic_time(:millisecond)

    # Compare against what the dashboard could use, not an expired snapshot
    # that it had to present as unknown. Capture it when scheduling, before
    # another caller can update the shared cache.
    previous = usable_good(previous_good, started_at)
    fallback = usable_good(previous_good, now)
    current = if result == :unavailable, do: fallback, else: result

    if current != previous or (fallback == :unavailable and result != :unavailable),
      do: DashboardPubSub.broadcast_changed()
  end

  defp usable_good({at, snapshot}, now) when now - at < @last_good_ms, do: snapshot
  defp usable_good(_expired_or_missing, _now), do: :unavailable

  defp last_good({command, _at, _result, good}, command), do: good
  defp last_good(_cached, _command), do: nil

  defp load_command(command) do
    with path when is_binary(path) <- System.find_executable(command),
         {:ok, %{"core" => %{"id" => core_id} = core}} when is_binary(core_id) <- run(path, ["server", "status", "--json"]),
         {:ok, %{"terminals" => terminals}} when is_list(terminals) <- run(path, ["ls", "--all", "--json"]),
         {:ok, %{"terminals" => workers}} when is_list(workers) <- run(path, ["ls", "--all", "--json", "--label", "sympp.role=worker"]),
         {:ok, %{"terminals" => chiefs}} when is_list(chiefs) <- run(path, ["ls", "--all", "--json", "--label", "sympp.role=chief"]),
         {:ok, %{"terminals" => cards}} when is_list(cards) <- run(path, ["ls", "--all", "--json", "--label", "sympp.card=1"]) do
      labels = worker_labels(path, workers)
      marked = Map.merge(marker_labels(cards, "sympp.card", "1"), marker_labels(chiefs, "sympp.role", "chief"), fn _address, card, chief -> Map.merge(card, chief) end)

      terminals =
        Map.new(terminals, fn record ->
          {record["address"], record |> put_labels(labels) |> merge_labels(Map.get(marked, record["address"]))}
        end)

      snapshot = %{core_id: core_id, terminals: terminals}
      {:ok, if(is_binary(core["name"]), do: Map.put(snapshot, :core_name, core["name"]), else: snapshot)}
    else
      _unavailable -> :unavailable
    end
  end

  # `hc ls` lists worker terminals without their labels, so each new worker's
  # labels are read once with `hc get` and kept; a terminal's labels are set
  # when `hc run` starts it.
  defp worker_labels(path, workers) do
    known = :persistent_term.get(@labels_key, %{})
    addresses = for %{"address" => address} <- workers, is_binary(address), do: address

    labels =
      Map.new(addresses, fn address ->
        case Map.fetch(known, address) do
          {:ok, labels} -> {address, labels}
          :error -> {address, read_labels(path, address)}
        end
      end)

    stored = Map.reject(labels, fn {_address, value} -> is_nil(value) end)
    if stored != known, do: :persistent_term.put(@labels_key, stored)
    stored
  end

  defp read_labels(path, address) do
    case run(path, ["get", address, "--json"]) do
      {:ok, %{"labels" => %{} = labels}} -> labels
      _unavailable -> nil
    end
  end

  # `hc ls --label` names the terminals that carry a label, without the rest of their labels.
  defp marker_labels(records, key, value), do: Map.new(for(%{"address" => address} <- records, is_binary(address), do: {address, %{key => value}}))

  defp merge_labels(record, nil), do: record
  defp merge_labels(record, labels), do: Map.update(record, "labels", labels, &Map.merge(&1, labels))

  defp put_labels(%{"labels" => %{}} = record, _labels), do: record

  defp put_labels(record, labels) do
    case Map.get(labels, record["address"]) do
      %{} = terminal_labels -> Map.put(record, "labels", terminal_labels)
      nil -> record
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
