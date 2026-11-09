defmodule Mix.Tasks.Sympp.CockpitTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sympp.Cockpit, as: CockpitTask
  alias Mix.Tasks.Sympp.OfflineMigrate
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Api, DefaultClient}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server, Stdio}
  alias SymphonyElixir.SymphonyPlusPlus.Observer
  alias SymphonyElixir.SymphonyPlusPlus.OfflineSandbox
  alias SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint

  setup do
    Mix.Task.reenable("sympp.cockpit")
    previous_shell = Mix.shell()
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    previous_dashboard_origin = System.get_env("SYMPP_DASHBOARD_ORIGIN")
    previous_open_dashboard = System.get_env("SYMPP_OPEN_DASHBOARD")
    previous_defer_dashboard_open = System.get_env("SYMPP_DEFER_DASHBOARD_OPEN")

    Mix.shell(Mix.Shell.Process)
    System.delete_env("SYMPP_DASHBOARD_ORIGIN")
    System.delete_env("SYMPP_OPEN_DASHBOARD")
    System.delete_env("SYMPP_DEFER_DASHBOARD_OPEN")
    ensure_cockpit_dashboard_asset!()

    on_exit(fn ->
      Mix.shell(previous_shell)
      restore_env(:sympp_repo_database, previous_database)
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint_config)
      restore_system_env("SYMPP_DASHBOARD_ORIGIN", previous_dashboard_origin)
      restore_system_env("SYMPP_OPEN_DASHBOARD", previous_open_dashboard)
      restore_system_env("SYMPP_DEFER_DASHBOARD_OPEN", previous_defer_dashboard_open)
      stop_endpoint()
    end)

    :ok
  end

  test "marked snapshots refuse an unprotected boot and serve local actions with MCP and probes disabled" do
    database = WorkPackageFactory.database_path()
    previous = System.get_env("SYMPP_OFFLINE_SANDBOX")
    {:ok, connection} = Exqlite.Sqlite3.open(database)
    :ok = Exqlite.Sqlite3.execute(connection, "CREATE TABLE sympp_offline_sandbox (created_at TEXT NOT NULL)")
    :ok = Exqlite.Sqlite3.close(connection)

    try do
      System.delete_env("SYMPP_OFFLINE_SANDBOX")
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database, "--port", "0", "--open-dashboard"])

      assert_raise RuntimeError, ~r/offline snapshot/, fn ->
        CockpitTask.run_cockpit_for_test(opts, fn -> flunk("unprotected HTTP server started") end)
      end

      assert_raise RuntimeError, ~r/offline snapshot/, fn ->
        Repo.init(:supervisor, database: database)
      end

      assert_raise RuntimeError, ~r/offline snapshot/, fn ->
        OfflineSandbox.verify!("file:#{URI.encode(database)}?mode=rwc")
      end

      System.put_env("SYMPP_OFFLINE_SANDBOX", "1")
      assert_raise RuntimeError, ~r/requires a marked snapshot/, fn -> OfflineSandbox.verify!(database <> ".missing") end
      OfflineMigrate.run(["--database", database])
      assert :ok = OfflineSandbox.verify!(database)

      opts = Keyword.put(opts, :operator_dashboard_opener, fn _url -> flunk("browser opened") end)

      CockpitTask.run_cockpit_for_test(opts, fn ->
        assert is_list(Repo.config())
        port = wait_for_bound_port()
        origin = "http://127.0.0.1:#{port}"
        assert Req.get!(origin <> "/api/v1/sympp/operator/dashboard", headers: browser_api_headers()).status == 200
        assert Req.post!(origin <> "/mcp", json: %{jsonrpc: "2.0", id: 1, method: "initialize"}).status == 403
        assert Req.post!(origin <> "/mcp/client-lease", json: %{}).status == 403
        assert Req.get!(origin <> "/mcp/readiness").status == 200

        assert {:ok, request} =
                 WorkRequestRepository.create(Repo, %{
                   title: "Copied goal",
                   repo: "example/widget",
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Exercise a copied goal.",
                   desired_dispatch_shape: "single_package"
                 })

        path = origin <> "/api/v1/sympp/operator/work-requests/#{request.id}"
        assert Req.post!(path <> "/complete", json: %{}, headers: browser_api_headers()).status == 200
        assert Req.post!(path <> "/archive", json: %{}, headers: browser_api_headers()).status == 200
        assert Req.post!(path <> "/delete", json: %{}, headers: browser_api_headers()).status == 200
        assert Repo.get(WorkRequest, request.id) == nil

        server = Server.new(Config.default())
        response = Stdio.handle_payload(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, server)
        assert response["error"]["data"]["reason"] == "offline_sandbox"

        # The Observer doesn't run offline, and its GitHub access refuses.
        refute Process.whereis(Observer)
        assert {:error, :offline} = Api.credential()

        assert RepoIdentity.local_git_origin_remote(File.cwd!()) == nil
        assert {:error, :offline_sandbox} = DefaultClient.auth_status()
        assert {:error, :offline_sandbox} = DefaultClient.get_json("repos/example/widget", [])
        assert :ok = OperatorDashboardOpener.open_once(opener: fn _url -> flunk("browser opened") end)
      end)
    after
      restore_system_env("SYMPP_OFFLINE_SANDBOX", previous)
      File.rm(database)
    end
  end

  defp wait_for_bound_port do
    Enum.reduce_while(1..500, nil, fn _attempt, _port ->
      case SymphonyElixir.HttpServer.bound_port() do
        port when is_integer(port) and port > 0 ->
          {:halt, port}

        _port ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
  end

  defp browser_api_headers(cookie_header \\ nil) do
    [
      {"sec-fetch-site", "same-origin"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-dest", "empty"}
    ]
    |> maybe_put_cookie_header(cookie_header)
  end

  defp maybe_put_cookie_header(headers, cookie_header) when is_binary(cookie_header) and cookie_header != "" do
    [{"cookie", cookie_header} | headers]
  end

  defp maybe_put_cookie_header(headers, _cookie_header), do: headers

  defp ensure_cockpit_dashboard_asset! do
    index_path =
      :symphony_elixir
      |> :code.priv_dir()
      |> Path.join("static/index.html")

    File.mkdir_p!(Path.dirname(index_path))
    File.write!(index_path, "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>")
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp stop_endpoint do
    case Process.whereis(Endpoint) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      nil -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
