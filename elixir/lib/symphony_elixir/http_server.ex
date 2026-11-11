defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  @secret_key_bytes 48

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case keyword_get_lazy(opts, :port, &Config.server_port/0) do
      port when is_integer(port) and port >= 0 ->
        host = keyword_get_lazy(opts, :host, fn -> Config.settings!().server.host end)
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        with {:ok, ip} <- parse_host(host) do
          endpoint_opts = [
            server: true,
            http: [ip: ip, port: port],
            url: [host: normalize_host(host)],
            orchestrator: orchestrator,
            snapshot_timeout_ms: snapshot_timeout_ms,
            secret_key_base: secret_key_base()
          ]

          endpoint_config =
            :symphony_elixir
            |> Application.get_env(Endpoint, [])
            |> Keyword.merge(endpoint_opts)

          Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
          # Explicit factory startup prepares the first full reads before the
          # listener opens. A cache failure leaves diagnostic routes available.
          prime_dashboard(opts)
          Endpoint.start_link()
        end

      _ ->
        :ignore
    end
  end

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp prime_dashboard(opts) do
    if Keyword.get(opts, :prime_dashboard, false), do: LocalOperatorDashboard.prime(Repo)
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host) when is_tuple(host), do: host |> :inet.ntoa() |> to_string()

  defp keyword_get_lazy(opts, key, fun) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> fun.()
    end
  end

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
