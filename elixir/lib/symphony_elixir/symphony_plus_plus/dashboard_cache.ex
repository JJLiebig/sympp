defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCache do
  @moduledoc false
  use GenServer

  alias Exqlite.Sqlite3
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, OperatorConfig, Repo}

  @ttl_ms 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec json(module(), term(), (-> term())) :: {:ok, binary(), binary()} | {:error, term()}
  def json(Repo, surface, fun) do
    source = Repo.get_dynamic_repo()
    source = if is_atom(source), do: Process.whereis(source), else: source
    surface = {surface, OperatorConfig.load()}

    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:json, source, surface, fun}, :infinity)
    else
      encode(fun.())
    end
  end

  def json(_repo, _surface, fun), do: encode(fun.())

  @impl true
  def init(_opts) do
    :ok = DashboardPubSub.subscribe()
    {:ok, %{sources: %{}, entries: %{}}}
  end

  @impl true
  def handle_call({:json, source, surface, fun}, _from, state) do
    previous = Repo.put_dynamic_repo(source)

    try do
      {connection, state} = connection(source, state)
      version = data_version(connection)
      key = {source, surface}
      now = System.monotonic_time(:millisecond)

      case Map.get(state.entries, key) do
        {^version, expires, result} when not is_nil(version) and expires > now ->
          {:reply, result, state}

        _missing ->
          result = build(fun)
          # The projection uses an Ecto read transaction. A commit during that
          # snapshot must never label the old snapshot with the new version.
          entries =
            if match?({:ok, _, _}, result) and version != nil and data_version(connection) == version do
              Map.put(state.entries, key, {version, now + @ttl_ms, result})
            else
              Map.delete(state.entries, key)
            end

          {:reply, result, %{state | entries: entries}}
      end
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp build(fun) do
    encode(HerdrCore.with_cached_reads(fun))
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      if String.contains?(String.downcase(message), ["busy", "locked"]),
        do: {:error, :database_busy},
        else: {:error, {:storage_failed, message}}
  end

  @impl true
  def handle_info(:operator_dashboard_changed, state), do: {:noreply, %{state | entries: %{}}}

  def handle_info({:DOWN, _ref, :process, source, _reason}, state) do
    Sqlite3.close(Map.get(state.sources, source))
    entries = Map.reject(state.entries, fn {{owner, _surface}, _entry} -> owner == source end)
    {:noreply, %{state | sources: Map.delete(state.sources, source), entries: entries}}
  end

  defp connection(source, state) do
    case Map.fetch(state.sources, source) do
      {:ok, connection} -> {connection, state}
      :error -> open_connection(source, state)
    end
  end

  defp open_connection(source, state) do
    # A dedicated read-only connection observes commits by *every* writer,
    # including other factory processes. data_version is connection-local;
    # querying it through the Ecto pool would not be a valid cache token.
    with {:ok, %{rows: rows}} <- Repo.query("PRAGMA database_list"),
         [_, "main", path] when path != "" <- Enum.find(rows, &(Enum.at(&1, 1) == "main")),
         {:ok, connection} <- Sqlite3.open(path, mode: :readonly) do
      if is_pid(source), do: Process.monitor(source)
      {connection, %{state | sources: Map.put(state.sources, source, connection)}}
    else
      _unavailable -> {nil, state}
    end
  end

  defp data_version(nil), do: nil

  defp data_version(connection) do
    case Sqlite3.prepare(connection, "PRAGMA data_version") do
      {:ok, statement} ->
        try do
          case Sqlite3.step(connection, statement) do
            {:row, [version]} -> version
            _unavailable -> nil
          end
        after
          Sqlite3.release(connection, statement)
        end

      _unavailable ->
        nil
    end
  end

  defp encode({:ok, payload}) do
    body = Jason.encode!(payload)
    # generated_at describes the snapshot, not a board change.
    digest = :crypto.hash(:sha256, Jason.encode!(Map.delete(payload, :generated_at))) |> Base.encode16(case: :lower)
    {:ok, body, "\"#{digest}\""}
  end

  defp encode(error), do: error
end
