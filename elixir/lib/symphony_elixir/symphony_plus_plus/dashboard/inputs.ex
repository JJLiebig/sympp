defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.Inputs do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.DashboardCache

  @scope {__MODULE__, :scope}
  @ledger {__MODULE__, :ledger}
  @cache __MODULE__

  @spec init() :: :ets.tid()
  def init, do: :ets.new(@cache, [:named_table, :public, read_concurrency: true])

  @spec capture(pid() | nil, atom(), (-> result)) :: {result, map()} when result: var
  def capture(source, surface, fun) do
    Process.put(@ledger, {source, surface})

    try do
      scoped(%{}, fn -> {fun.(), elem(Process.get(@scope), 0)} end)
    after
      Process.delete(@ledger)
    end
  end

  @spec ledger() :: pid() | nil
  def ledger, do: elem(ledger_surface(), 0)

  @spec ledger_surface() :: {pid() | nil, atom() | nil}
  def ledger_surface, do: Process.get(@ledger, {nil, nil})

  @spec forget_ledger(pid()) :: :ok
  def forget_ledger(source) do
    :ets.match_delete(@cache, {{:ledger, source, :_}, :_, :_})
    :ok
  end

  @spec check((-> result)) :: result when result: var
  def check(fun), do: scoped(nil, fun)

  @spec active?() :: boolean()
  def active?, do: Process.get(@scope) != nil

  @spec observe(term(), (-> result)) :: result when result: var
  def observe(key, read), do: record(key, memo(key, read), read)

  @spec record(term(), result, (-> result)) :: result when result: var
  def record(key, value, read) do
    case Process.get(@scope) do
      {observations, memo} when is_map(observations) ->
        Process.put(@scope, {Map.put(observations, key, {value, read}), memo})

      _not_building ->
        :ok
    end

    value
  end

  @spec current?(map()) :: boolean()
  def current?(observations) do
    Enum.all?(observations, fn {key, {value, read}} -> memo(key, read) == value end)
  end

  @spec memo(term(), (-> result)) :: result when result: var
  def memo(key, read) do
    case Process.get(@scope) do
      {_observations, memo} ->
        case Map.fetch(memo, key) do
          {:ok, value} ->
            value

          :error ->
            value = read.()
            {observations, memo} = Process.get(@scope)
            Process.put(@scope, {observations, Map.put(memo, key, value)})
            value
        end

      nil ->
        read.()
    end
  end

  # Reuse the last stored value across projection workers. Read the stamp again
  # under the lock so another builder can fill the same cache miss.
  @spec shared(term(), (-> term()), (-> result)) :: result when result: var
  @spec shared(term(), (-> term()), (-> result), :sync | :background) :: result when result: var
  def shared(key, stamp, read, mode \\ :sync) do
    if active?() do
      memo({:shared, key}, fn -> shared_value(key, stamp, read, mode) end)
    else
      read.()
    end
  end

  defp shared_value(key, stamp, read, mode) do
    current = stamp.()

    case :ets.lookup(@cache, key) do
      [{^key, ^current, value}] ->
        value

      [{^key, _stale, value}] when mode == :background ->
        refresh_background(key, current, value, read)
        value

      _miss ->
        load_missing(key, stamp, current, read, mode)
    end
  end

  defp load_missing(key, stamp, current, read, mode) do
    case Process.get(@scope) do
      {nil, _memo} when mode == :background ->
        refresh_background(key, current, nil, read)
        nil

      _build ->
        :global.trans({{__MODULE__, key}, self()}, fn -> load(key, stamp.(), read) end)
    end
  end

  defp refresh_background(key, stamp, previous, read) do
    pending = {:refreshing, key}
    job = fn -> refresh(key, stamp, previous, read, pending) end

    with true <- :ets.insert_new(@cache, {pending, true}),
         {:error, _reason} <- Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, job) do
      :ets.delete(@cache, pending)
    end
  end

  defp refresh(key, stamp, previous, read, pending) do
    value = load(key, stamp, read)
    if value != previous, do: DashboardCache.inputs_changed()
  after
    :ets.delete(@cache, pending)
  end

  @spec file_stamp(Path.t()) :: term()
  def file_stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        # File.stat has second precision. Within the current second, verify
        # contents as well so a same-size in-place edit cannot be missed.
        now = System.system_time(:second)
        recent = if max(stat.mtime, stat.ctime) >= now, do: file_digest(path)
        {stat.inode, stat.size, stat.mtime, stat.ctime, recent}

      _not_a_file ->
        nil
    end
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, contents} -> :crypto.hash(:sha256, contents)
      {:error, _reason} -> nil
    end
  end

  defp lookup(key, stamp) do
    case :ets.lookup(@cache, key) do
      [{^key, ^stamp, value}] -> {:ok, value}
      _missing_or_changed -> :miss
    end
  end

  defp load(key, stamp, read) do
    case lookup(key, stamp) do
      {:ok, value} ->
        value

      :miss ->
        value = read.()
        unless match?({:error, _reason}, value), do: :ets.insert(@cache, {key, stamp, value})
        value
    end
  end

  defp scoped(observations, fun) do
    Process.put(@scope, {observations, %{}})

    try do
      fun.()
    after
      Process.delete(@scope)
    end
  end
end
