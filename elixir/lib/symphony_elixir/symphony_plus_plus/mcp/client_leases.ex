defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases do
  @moduledoc """
  Tracks stdio bridge heartbeat freshness for `/mcp/client-lease`.

  Bridge lease files under `codex-plugin-leases` are the runtime liveness
  authority. When the runtime opts into shutdown-on-idle, this process also
  stops the BEAM after every bridge lease is gone or stale.

  A bridge running in a Herdr terminal names that terminal in its lease. Bridges
  heartbeat every 60 seconds; a terminal whose last heartbeat is older than the
  3-minute TTL has unknown liveness, which never ends its ownership.
  """

  use GenServer

  alias SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

  @default_ttl_ms 3 * 60 * 1_000
  @default_sweep_ms 30 * 1_000
  @default_shutdown_delay_ms 1_000
  @actions ["attach", "heartbeat", "detach"]

  @type summary :: %{active_client_count: non_neg_integer(), stale_after_ms: pos_integer()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    opts =
      Keyword.put_new(
        opts,
        :dashboard_opener,
        if(name == __MODULE__, do: OperatorDashboardOpener, else: nil)
      )

    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @spec ensure_started() :: :ok | {:error, :client_lease_unavailable}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> :ok
      nil -> start_lease_store()
    end
  end

  @spec handle_payload(term(), (String.t() -> term()) | nil) :: {:ok, summary()} | {:error, atom()}
  def handle_payload(payload, on_terminal_detached \\ nil) do
    with true <- is_map(payload) || {:error, :invalid_request},
         {:ok, client_id} <- lease_id(payload),
         {:ok, action} <- lease_action(payload),
         :ok <- ensure_started() do
      apply_lease_action(action, client_id, terminal_key(payload), on_terminal_detached)
    end
  end

  @spec attach(binary()) :: {:ok, summary()} | {:error, :unavailable}
  def attach(client_id), do: attach(client_id, __MODULE__)

  @spec attach(binary(), GenServer.server(), String.t() | nil) :: {:ok, summary()} | {:error, :unavailable}
  def attach(client_id, server, terminal_key \\ nil), do: lease_call(server, {:attach, client_id, terminal_key})

  @spec heartbeat(binary(), GenServer.server(), String.t() | nil) :: {:ok, summary()} | {:error, :unavailable}
  def heartbeat(client_id, server \\ __MODULE__, terminal_key \\ nil), do: lease_call(server, {:heartbeat, client_id, terminal_key})

  @doc "Whether a bridge in this Herdr terminal sent a heartbeat within the TTL."
  @spec terminal_live?(String.t(), GenServer.server()) :: boolean()
  def terminal_live?(terminal_key, server \\ __MODULE__) do
    case Process.whereis(__MODULE__) do
      nil when server == __MODULE__ -> false
      _pid -> lease_call(server, {:terminal_live?, terminal_key}) == true
    end
  end

  @doc "The Herdr terminal named in a lease payload, if any."
  @spec terminal_key(map()) :: String.t() | nil
  def terminal_key(%{"terminal" => terminal}) do
    case Terminal.from_meta(terminal) do
      %Terminal{key: key} -> key
      nil -> nil
    end
  end

  def terminal_key(_payload), do: nil

  @spec detach(binary(), GenServer.server()) :: {:ok, summary()} | {:error, :unavailable}
  def detach(client_id, server \\ __MODULE__), do: lease_call(server, {:detach, client_id, nil, nil})

  @doc """
  Detaches a bridge that names a Herdr terminal. When no other bridge in that
  terminal still holds a fresh lease, `on_last` runs with the terminal key
  inside this process, so attaches and heartbeats are ordered around it.
  """
  @spec detach_terminal(binary(), String.t(), (String.t() -> term()), GenServer.server()) :: {:ok, summary()} | {:error, :unavailable}
  def detach_terminal(client_id, terminal_key, on_last, server \\ __MODULE__) when is_function(on_last, 1),
    do: lease_call(server, {:detach, client_id, terminal_key, on_last})

  @spec active_count(GenServer.server()) :: non_neg_integer()
  def active_count(server \\ __MODULE__) do
    case lease_call(server, :active_count) do
      {:ok, %{active_client_count: count}} -> count
      {:error, _reason} -> 0
    end
  end

  @impl true
  def init(opts) do
    shutdown_delay_ms =
      option(opts, :shutdown_delay_ms, :mcp_client_lease_shutdown_delay_ms, @default_shutdown_delay_ms)

    state = %{
      leases: %{},
      bridge_lease_dir: Keyword.get(opts, :bridge_lease_dir, System.get_env("SYMPP_MCP_BRIDGE_LEASE_DIR")),
      bridge_probe: Keyword.get(opts, :bridge_probe, System.get_env("SYMPP_MCP_BRIDGE_PROBE")),
      dashboard_opener: Keyword.get(opts, :dashboard_opener),
      ttl_ms: option(opts, :ttl_ms, :mcp_client_lease_ttl_ms, @default_ttl_ms),
      sweep_ms: option(opts, :sweep_ms, :mcp_client_lease_sweep_ms, @default_sweep_ms),
      shutdown_delay_ms: shutdown_delay_ms,
      shutdown_on_idle?: shutdown_on_idle_runtime?(opts),
      lease_seen?: false,
      shutdown_timer: nil,
      shutdown_id: nil,
      shutdown_fun: Keyword.get(opts, :shutdown_fun, fn -> System.stop(0) end)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call({action, client_id, terminal_key}, _from, state) when action in [:attach, :heartbeat] do
    state =
      state
      |> cancel_shutdown()
      |> record_lease(client_id, terminal_key)

    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:terminal_live?, terminal_key}, _from, state) do
    state = prune_and_notify_idle(state, now_ms())
    {:reply, Enum.any?(state.leases, fn {_id, lease} -> lease.terminal == terminal_key end), state}
  end

  def handle_call({:detach, client_id, terminal_key, on_last}, _from, state) do
    now = now_ms()

    state =
      state
      |> prune_and_notify_idle(now)
      |> delete_lease(client_id)
      |> maybe_schedule_shutdown()

    if is_function(on_last, 1) and not Enum.any?(state.leases, fn {_id, lease} -> lease.terminal == terminal_key end) do
      run_detached(on_last, terminal_key)
    end

    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call(:active_count, _from, state) do
    state = prune_and_notify_idle(state, now_ms())
    {:reply, {:ok, summary(state)}, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = prune_and_notify_idle(state, now_ms(), true)

    schedule_sweep(state)
    {:noreply, maybe_schedule_shutdown(state)}
  end

  def handle_info({:shutdown_on_idle, shutdown_id}, %{shutdown_id: shutdown_id} = state) do
    state =
      state
      |> Map.put(:shutdown_timer, nil)
      |> Map.put(:shutdown_id, nil)
      |> prune(now_ms())

    if state.shutdown_on_idle? and map_size(state.leases) == 0 do
      state.shutdown_fun.()
    end

    {:noreply, state}
  end

  def handle_info({:shutdown_on_idle, _stale_shutdown_id}, state), do: {:noreply, state}

  def handle_info(:shutdown_on_idle, state), do: {:noreply, state}

  defp lease_call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp start_lease_store do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) -> start_supervised_lease_store()
      nil -> start_direct_lease_store()
    end
  end

  defp start_supervised_lease_store do
    case Supervisor.restart_child(SymphonyElixir.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, :not_found} -> add_supervised_lease_store()
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :client_lease_unavailable}
    end
  catch
    :exit, _reason -> {:error, :client_lease_unavailable}
  end

  defp add_supervised_lease_store do
    case Supervisor.start_child(SymphonyElixir.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :client_lease_unavailable}
    end
  end

  defp start_direct_lease_store do
    case OperatorDashboardOpener.ensure_started() do
      :ok -> start_direct_lease_store_with_opener()
      {:error, _reason} -> {:error, :client_lease_unavailable}
    end
  end

  defp start_direct_lease_store_with_opener do
    case GenServer.start(__MODULE__, [dashboard_opener: OperatorDashboardOpener], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :client_lease_unavailable}
    end
  end

  defp apply_lease_action("attach", client_id, terminal_key, _on_detached), do: normalize_lease_result(attach(client_id, __MODULE__, terminal_key))
  defp apply_lease_action("heartbeat", client_id, terminal_key, _on_detached), do: normalize_lease_result(heartbeat(client_id, __MODULE__, terminal_key))

  defp apply_lease_action("detach", client_id, terminal_key, on_detached) when is_binary(terminal_key) and is_function(on_detached, 1),
    do: normalize_lease_result(detach_terminal(client_id, terminal_key, on_detached))

  defp apply_lease_action("detach", client_id, _terminal_key, _on_detached), do: normalize_lease_result(detach(client_id))

  defp run_detached(on_last, terminal_key) do
    on_last.(terminal_key)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp normalize_lease_result({:ok, result}), do: {:ok, result}
  defp normalize_lease_result({:error, _reason}), do: {:error, :client_lease_unavailable}

  defp prune(%{leases: leases, ttl_ms: ttl_ms} = state, now) do
    %{state | leases: Map.filter(leases, fn {_id, lease} -> now - lease.last_seen_ms <= ttl_ms end)}
  end

  defp summary(%{leases: leases, ttl_ms: ttl_ms}) do
    %{active_client_count: map_size(leases), stale_after_ms: ttl_ms}
  end

  defp schedule_sweep(%{sweep_ms: sweep_ms}), do: Process.send_after(self(), :sweep, sweep_ms)

  defp lease_id(%{"client_id" => client_id}) when is_binary(client_id) do
    client_id = String.trim(client_id)

    if client_id != "" and byte_size(client_id) <= 160 and visible_ascii?(client_id),
      do: {:ok, client_id},
      else: {:error, :invalid_client_id}
  end

  defp lease_id(_payload), do: {:error, :invalid_client_id}

  defp lease_action(%{"action" => action}) when action in @actions, do: {:ok, action}
  defp lease_action(_payload), do: {:error, :invalid_action}

  defp record_lease(state, client_id, terminal_key) do
    now = now_ms()
    state = prune_and_notify_idle(state, now)
    first_client? = map_size(state.leases) == 0

    state =
      state
      |> Map.put(:lease_seen?, true)
      |> Map.update!(:leases, fn leases ->
        bridge = get_in(leases, [client_id, :bridge]) || local_bridge(state.bridge_lease_dir, client_id)
        terminal = terminal_key || get_in(leases, [client_id, :terminal])
        Map.put(leases, client_id, %{last_seen_ms: now, bridge: bridge, terminal: terminal})
      end)

    if first_client?, do: notify_dashboard_opener(state, :client_attached)
    state
  end

  defp delete_lease(state, client_id) do
    had_clients? = map_size(state.leases) > 0
    state = Map.update!(state, :leases, &Map.delete(&1, client_id))

    if had_clients? and map_size(state.leases) == 0,
      do: notify_dashboard_opener(state, :clients_idle)

    state
  end

  defp prune_and_notify_idle(state, now, probe_bridges? \\ false) do
    had_clients? = map_size(state.leases) > 0
    state = prune(state, now)
    state = if probe_bridges?, do: prune_dead_bridges(state), else: state

    if had_clients? and map_size(state.leases) == 0,
      do: notify_dashboard_opener(state, :clients_idle)

    state
  end

  defp local_bridge(directory, client_id) when is_binary(directory) do
    with {:win32, _} <- :os.type(),
         {:ok, files} <- File.ls(directory) do
      Enum.find_value(files, &local_bridge_file(Path.join(directory, &1), client_id))
    else
      _ -> nil
    end
  end

  defp local_bridge(_directory, _client_id), do: nil

  defp local_bridge_file(file, client_id) do
    with {:ok, content} <- File.read(file),
         {:ok, %{"client_id" => ^client_id, "pid" => pid, "process_liveness_pipe" => pipe, "process_liveness_token" => token}} <-
           Jason.decode(content),
         true <- is_integer(pid) and pid > 0 and is_binary(pipe) and is_binary(token),
         true <- String.starts_with?(pipe, "\\\\.\\pipe\\sympp-mcp-#{pid}-"),
         true <- Regex.match?(~r/^[a-f0-9]{64}$/, token) do
      %{pid: pid, pipe: pipe, token: token}
    else
      _ -> nil
    end
  end

  defp prune_dead_bridges(state) do
    bridges = for {id, %{bridge: bridge}} <- state.leases, bridge != nil, do: Map.put(bridge, :id, id)

    if bridges == [] or not is_binary(state.bridge_probe) do
      state
    else
      case probe_bridges(state.bridge_probe, bridges) do
        {:ok, dead_ids} when is_list(dead_ids) -> %{state | leases: Map.drop(state.leases, dead_ids)}
        _ -> state
      end
    end
  end

  defp probe_bridges(script, bridges) do
    with true <- File.regular?(script),
         node when is_binary(node) <- System.find_executable("node") do
      port = Port.open({:spawn_executable, node}, [:binary, :exit_status, :hide, args: [script, "--probe-client-leases"]])
      Port.command(port, Jason.encode!(bridges) <> "\n")
      collect_probe(port, "", now_ms() + 2_000)
    end
  rescue
    _ -> :unknown
  end

  defp collect_probe(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> collect_probe(port, output <> data, deadline)
      {^port, {:exit_status, 0}} -> Jason.decode(output)
      {^port, {:exit_status, _}} -> :unknown
    after
      max(deadline - now_ms(), 0) ->
        Port.close(port)
        :unknown
    end
  end

  defp notify_dashboard_opener(%{dashboard_opener: nil}, _event), do: :ok

  defp notify_dashboard_opener(%{dashboard_opener: opener}, :client_attached),
    do: OperatorDashboardOpener.client_attached(opener)

  defp notify_dashboard_opener(%{dashboard_opener: opener}, :clients_idle),
    do: OperatorDashboardOpener.clients_idle(opener)

  defp maybe_schedule_shutdown(%{shutdown_on_idle?: false} = state), do: state
  defp maybe_schedule_shutdown(%{lease_seen?: false} = state), do: state
  defp maybe_schedule_shutdown(%{shutdown_timer: timer} = state) when is_reference(timer), do: state
  defp maybe_schedule_shutdown(%{leases: leases} = state) when map_size(leases) > 0, do: state

  defp maybe_schedule_shutdown(state) do
    shutdown_id = make_ref()
    shutdown_timer = Process.send_after(self(), {:shutdown_on_idle, shutdown_id}, state.shutdown_delay_ms)
    %{state | shutdown_timer: shutdown_timer, shutdown_id: shutdown_id}
  end

  defp cancel_shutdown(%{shutdown_timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | shutdown_timer: nil, shutdown_id: nil}
  end

  defp cancel_shutdown(state), do: state

  defp shutdown_on_idle_runtime?(opts) do
    value =
      Keyword.get(
        opts,
        :shutdown_on_idle,
        Application.get_env(:symphony_elixir, :mcp_client_shutdown_on_idle, System.get_env("SYMPP_MCP_SHUTDOWN_ON_IDLE"))
      )

    truthy?(value)
  end

  defp truthy?(value) when value in [true, 1, "1"], do: true
  defp truthy?(value) when is_binary(value), do: String.downcase(String.trim(value)) in ["true", "yes", "on"]
  defp truthy?(_value), do: false

  defp visible_ascii?(<<>>), do: true
  defp visible_ascii?(<<byte, rest::binary>>) when byte >= 0x21 and byte <= 0x7E, do: visible_ascii?(rest)
  defp visible_ascii?(_value), do: false

  defp option(opts, option_key, env_key, default) do
    value = Keyword.get(opts, option_key, Application.get_env(:symphony_elixir, env_key, default))

    if is_integer(value) and value > 0, do: value, else: default
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
