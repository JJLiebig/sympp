defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPEndpointTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias Phoenix.Endpoint.RenderErrors

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ClientLeases,
    FailedCall,
    HTTPStateStore
  }

  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.MigrationFileLock
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint
  @client_key "__sympp_mcp_local_http_client__"

  defmodule LazyHTTPRepo do
    @moduledoc false

    use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3
  end

  defmodule FailingLazyHTTPRepo do
    @moduledoc false

    def __adapter__, do: Ecto.Adapters.SQLite3
    def config, do: Application.get_env(:symphony_elixir, __MODULE__, [])
    def start_link(_opts), do: {:error, :start_failed}
  end

  defmodule RemoteHTTPRepo do
    @moduledoc false

    def config, do: [hostname: "ledger-http.example.test", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(_sql, _params, _opts), do: {:ok, %{rows: [[1]]}}
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    sympp_repo_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    Application.put_env(
      :symphony_elixir,
      Endpoint,
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)
    )

    repo_opts = [database: database_path, pool_size: 5, queue_target: 30_000, queue_interval: 30_000, timeout: 30_000]
    start_supervised!({Repo, repo_opts})
    if Process.whereis(Endpoint) == nil, do: start_supervised!({Endpoint, []})

    assert :ok = WorkPackageRepository.migrate(Repo)
    assert :ok = SoloSessionRepository.migrate(Repo)
    assert :ok = PhaseRepository.migrate(Repo)
    assert :ok = WorkRequestRepository.migrate(Repo)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
      restore_sympp_repo_database(sympp_repo_database)
      File.rm(database_path)
    end)

    {:ok, database_path: database_path}
  end

  setup do
    reset_server_response_state()
    if Process.whereis(HTTPStateStore) == nil, do: start_supervised!(HTTPStateStore)
    HTTPStateStore.reset!()
    Repo.delete_all(OperatorSettings)
    Repo.delete_all(WorkedOn)
    FailedCall.reset()
    :ok
  end

  test "unexpected endpoint errors return safe JSON regardless of accepted format" do
    for path <- ["/mcp", "/api/v1/state"],
        accept <- [nil, "*/*", "application/json, text/event-stream", "text/html"] do
      conn = Plug.Test.conn(:post, path)
      conn = if accept, do: put_req_header(conn, "accept", accept), else: conn

      {500, headers, body} =
        assert_error_sent(500, fn ->
          RenderErrors.__catch__(
            conn,
            :error,
            RuntimeError.exception("private exception detail"),
            [],
            Endpoint.config(:render_errors)
          )
        end)

      assert {"content-type", "application/json; charset=utf-8"} in headers

      assert Jason.decode!(body) == %{
               "error" => %{"code" => "request_failed", "message" => "Internal Server Error"}
             }
    end
  end

  describe "factory service token access" do
    setup do
      keys = [:sympp_service, :sympp_remote_token_hash]
      previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      Application.put_env(:symphony_elixir, :sympp_service, true)
      Application.put_env(:symphony_elixir, :sympp_remote_token_hash, :crypto.hash(:sha256, token))

      on_exit(fn ->
        for {key, value} <- previous do
          if is_nil(value) do
            Application.delete_env(:symphony_elixir, key)
          else
            Application.put_env(:symphony_elixir, key, value)
          end
        end
      end)

      %{remote: [remote_ip: {100, 64, 0, 2}, host: "100.123.207.19"], headers: [{"authorization", "Bearer " <> token}]}
    end

    test "remote non-board entrypoints require the token before routing or parsing", %{remote: remote} do
      for headers <- [[], [{"authorization", "Bearer wrong"}], [{"authorization", "Basic wrong"}]] do
        for path <- ["/mcp", "/mcp/readiness", "/mcp/client-lease", "/api/v1/sympp/herdr/dashboard", "/api/v1/sympp/operator/dashboard"] do
          assert get_local(path, headers, remote).status == 401
        end

        assert post_raw("not json", headers, remote).status == 401
        assert post_raw("not json", headers, Keyword.put(remote, :path, "/api/v1/sympp/herdr/work-requests")).status == 401
      end
    end

    test "direct tailnet peers can read only the board without credentials", %{remote: remote} do
      ipv6 = {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1}
      mapped = {0, 0, 0, 0, 0, 65_535, 0x6440, 2}

      for ip <- [{100, 64, 0, 0}, {100, 127, 255, 255}, ipv6, mapped] do
        opts = Keyword.put(remote, :remote_ip, ip)
        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [], opts) |> json_response(200) |> Map.has_key?("work_request_details")

        events = "/api/v1/sympp/operator/dashboard/events"

        for path <- ["/", "/sympp", "/sympp/board", "/assets/index.js", "/favicon.ico", "/splusplus-logo.png", events] do
          conn = Plug.Test.conn("GET", path) |> Map.put(:remote_ip, ip) |> SymphonyElixirWeb.FactoryAccessPlug.call([])
          refute conn.halted
          assert SymphonyElixirWeb.FactoryAccessPlug.board_read_only?(conn)
          refute SymphonyElixirWeb.FactoryAccessPlug.authenticated?(conn)
        end
      end

      outside_ipv6 = {0xFD7A, 0x115C, 0xA1E1, 0, 0, 0, 0, 1}

      for ip <- [{100, 63, 255, 255}, {100, 128, 0, 0}, {192, 168, 1, 5}, {8, 8, 8, 8}, outside_ipv6] do
        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [], Keyword.put(remote, :remote_ip, ip)).status == 401
        assert get_local("/sympp", [], Keyword.put(remote, :remote_ip, ip)).status == 401
      end

      for header <- ["forwarded", "x-real-ip", "x-forwarded-for", "x-forwarded-custom"] do
        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [{header, "127.0.0.1"}], remote).status == 401
      end

      for path <- ["/api/v1/sympp/operator/dashboard/hydrated", "/sympp/board", "/assets/index.js"] do
        assert get_local(path, [{"authorization", "Bearer wrong"}], remote).status == 401
      end

      for path <- ["/api/v1/sympp/operator/settings", "/api/v1/sympp/operator/work-requests/example/archive", "/api/v1/sympp/operator/work-requests/example/release", "/mcp/client-lease"] do
        assert post_json(%{}, [], Keyword.put(remote, :path, path)).status == 401
      end
    end

    test "browser sign-in authorizes board writes but never MCP and token rotation revokes it", %{remote: remote, headers: headers} do
      login_path = "/api/v1/sympp/board-session"
      assert post_json(%{}, [], Keyword.put(remote, :path, login_path)).status == 401
      code_response = post_json(%{}, headers, Keyword.put(remote, :path, "/api/v1/sympp/board-sign-in-code"))
      code = json_response(code_response, 200)["code"]
      code_headers = [{"authorization", "Board " <> code}]
      assert post_json(%{}, code_headers, remote).status == 401
      login = post_json(%{}, code_headers, Keyword.put(remote, :path, login_path))
      assert post_json(%{}, code_headers, Keyword.put(remote, :path, login_path)).status == 401
      assert login.status == 204
      [set_cookie] = get_resp_header(login, "set-cookie")
      assert set_cookie =~ "HttpOnly"
      assert set_cookie =~ "SameSite=Strict"
      assert set_cookie =~ "max-age=2592000"
      cookie = hd(String.split(set_cookie, ";"))
      browser = [{"cookie", cookie}, {"origin", "http://100.123.207.19:4000"}]
      path = "/api/v1/sympp/operator/settings"
      result = post_json(%{"capture_failed_mcp_calls" => true}, browser, Keyword.put(remote, :path, path)) |> json_response(200)
      assert result["settings"]["capture_failed_mcp_calls"] == true
      assert get_local("/api/v1/sympp/operator/dashboard/hydrated", browser, remote).status == 200
      assert get_local("/mcp/readiness", browser, remote).status == 401
      assert post_json(initialize_request("cookie-mcp"), browser, remote).status == 401
      assert post_json(%{}, [{"cookie", cookie}, {"origin", "http://evil.example"}], Keyword.put(remote, :path, path)).status == 401
      assert post_json(%{}, [{"cookie", cookie}], Keyword.put(remote, :path, path)).status == 401
      assert post_json(%{}, [{"x-forwarded-for", "127.0.0.1"} | browser], Keyword.put(remote, :path, path)).status == 403
      assert post_json(%{}, [{"cookie", cookie <> "tampered"} | tl(browser)], Keyword.put(remote, :path, path)).status == 401
      Application.put_env(:symphony_elixir, :sympp_remote_token_hash, :crypto.strong_rand_bytes(32))
      assert post_json(%{}, browser, Keyword.put(remote, :path, path)).status == 401
    end

    test "remote token grants the existing MCP operator session and dashboard access", %{remote: remote, headers: headers} do
      assert get_local("/mcp/readiness", headers, remote).status == 200
      init = post_json(initialize_request("remote-init"), headers, remote)
      assert init.status == 200
      [session] = get_resp_header(init, "mcp-session-id")
      session_headers = [{"mcp-session-id", session} | headers]
      response = post_json(tool_call_request("remote-read", "list_work_requests", %{}), session_headers, remote) |> json_response(200)
      refute response["error"]
      refute response["result"]["isError"]

      for action <- ["attach", "heartbeat", "detach"] do
        assert post_json(%{"client_id" => "remote-service-test", "action" => action}, headers, Keyword.put(remote, :path, "/mcp/client-lease")).status == 200
      end

      for path <- ["/api/v1/sympp/herdr/dashboard", "/api/v1/sympp/operator/dashboard"] do
        assert get_local(path, headers, remote).status == 200
      end

      # Authentication is required on every follow-up, not just initialize.
      assert post_json(tool_call_request("lost-token", "sympp.health", %{}), [{"mcp-session-id", session}], remote).status == 401
      assert get_local("/mcp/readiness", [{"x-forwarded-for", "127.0.0.1"} | headers], remote).status == 403
    end

    test "service mode preserves the unauthenticated loopback boundary", %{headers: headers} do
      assert get_local("/mcp/readiness").status == 200
      assert get_local("/mcp/readiness", headers, host: "untrusted.example").status == 403
      assert get_local("/mcp/readiness", [{"origin", "http://untrusted.example"}]).status == 403
      assert get_local("/mcp/readiness", [{"x-forwarded-for", "100.64.0.2"}]).status == 403
    end
  end

  test "ten MCP sessions in the owning terminal dispatch distinct packages concurrently and duplicate dispatch returns an MCP error" do
    init = post_json(initialize_request("dispatch-init"))
    headers = [{"mcp-session-id", hd(get_resp_header(init, "mcp-session-id"))}]

    created =
      terminal_call(headers, "t1", "create_work_request", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "title" => "Concurrent dispatch",
        "request_kind" => "docs",
        "description" => "Dispatch independent packages together",
        "workflow_mode" => "single_package"
      })

    request_id = get_in(created, ["result", "structuredContent", "work_request", "id"])
    assert is_binary(request_id), inspect(created)

    sliced =
      terminal_call(headers, "t1", "slice_work_request", %{
        "work_request_id" => request_id,
        "work_packages" =>
          Enum.map(1..11, fn n ->
            WorkPackageFactory.attrs(goal: "Deliver package #{n}", allowed_file_globs: ["docs/**"], validation_steps: [], stop_conditions: [])
          end)
      })

    [blocked_id | package_ids] = get_in(sliced, ["result", "structuredContent", "work_package_ids"])
    assert length(package_ids) == 10

    # Each agent restart or reconnect in the owning terminal opens its own MCP session.
    clients =
      Enum.map(package_ids, fn package_id ->
        conn = post_json(initialize_request(Ecto.UUID.generate()))
        {[{"mcp-session-id", hd(get_resp_header(conn, "mcp-session-id"))}], package_id}
      end)

    tasks =
      Enum.map(clients, fn {client, package_id} ->
        Task.async(fn ->
          receive do: (:dispatch -> :ok)
          result = terminal_call(client, "t1", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => package_id})
          assert result["result"], inspect(result)
          refute result["result"]["isError"], inspect(result)
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :dispatch))
    Enum.each(tasks, &Task.await(&1, 30_000))

    for package_id <- package_ids do
      assert Repo.get!(WorkPackage, package_id).status == "dispatched"
    end

    {client, package_id} = hd(clients)
    duplicate = terminal_call(client, "t1", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => package_id})
    assert duplicate["error"]["data"]["reason"] == "invalid_work_package_status"

    other_terminal = terminal_call(client, "t2", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => blocked_id})
    assert other_terminal["error"]["data"]["reason"] == "owned_by_other_terminal"

    parent = self()

    writer =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            send(parent, :writer_locked)
            receive do: (:release_writer -> :ok)
          end,
          mode: :immediate
        )
      end)

    assert_receive :writer_locked

    try do
      busy = terminal_call(client, "t1", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => blocked_id})
      assert busy["error"]["data"]["reason"] == "database_busy"
      assert busy["error"]["data"]["remediation"] =~ "Read the WorkPackage status"
    after
      send(writer.pid, :release_writer)
      Task.await(writer)
    end

    assert Repo.get!(WorkPackage, blocked_id).status == "planned"
  end

  test "the Herdr binding header follows owner-gated writes, never reads" do
    init = post_json(initialize_request("binding-init"))
    headers = [{"mcp-session-id", hd(get_resp_header(init, "mcp-session-id"))}]

    created =
      tool_call_request("create", "create_work_request", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "title" => "Binding",
        "request_kind" => "docs",
        "description" => "Label the owning pane"
      })
      |> with_terminal("t1")
      |> post_json(headers)

    request_id = get_in(json_response(created, 200), ["result", "structuredContent", "work_request", "id"])
    assert herdr_binding(created) == %{"role" => "architect", "work_request_id" => request_id, "show_inspector" => true}

    read =
      tool_call_request("read", "read_work_request", %{"work_request_id" => request_id})
      |> with_terminal("t2")
      |> post_json(headers)

    assert json_response(read, 200)["result"]
    assert get_resp_header(read, "sympp-herdr-binding") == []

    refused =
      tool_call_request("report", "set_report", %{"work_request_id" => request_id, "brief" => "Not mine"})
      |> with_terminal("t2")
      |> post_json(headers)

    assert json_response(refused, 200)["error"]["data"]["reason"] == "owned_by_other_terminal"
    assert get_resp_header(refused, "sympp-herdr-binding") == []

    # A write naming only the package binds the terminal to the package's WorkRequest.
    sliced =
      terminal_call(headers, "t1", "slice_work_request", %{
        "work_request_id" => request_id,
        "work_packages" => [WorkPackageFactory.attrs(goal: "Bind by package", allowed_file_globs: ["docs/**"], validation_steps: [], stop_conditions: [])]
      })

    [package_id] = get_in(sliced, ["result", "structuredContent", "work_package_ids"])

    progress =
      tool_call_request("progress", "append_progress", %{"work_package_id" => package_id, "summary" => "Started", "idempotency_key" => "bind-1"})
      |> with_terminal("t1")
      |> post_json(headers)

    assert json_response(progress, 200)["result"]
    assert herdr_binding(progress)["work_request_id"] == request_id
  end

  test "a clean bridge detach ends its terminal's ownership" do
    {:ok, work_request} = WorkRequestRepository.create(Repo, work_request_attrs(%{}))
    terminal = Terminal.from_meta(terminal_meta("t4"))
    assert {:ok, _row, :acquired} = Ownership.acquire(Repo, work_request.id, terminal)
    lease = %{"client_id" => "bridge-detach-test", "terminal" => terminal_meta("t4")}

    for action <- ["attach", "heartbeat"] do
      assert %{"status" => "ok"} = json_response(post_json(Map.put(lease, "action", action), [], path: "/mcp/client-lease"), 200)
    end

    assert ClientLeases.terminal_live?(terminal.key)
    assert Ownership.public(Ownership.owner(Repo, work_request.id))["liveness"] == "live"

    assert %{"status" => "ok"} = json_response(post_json(Map.put(lease, "action", "detach"), [], path: "/mcp/client-lease"), 200)
    refute ClientLeases.terminal_live?(terminal.key)
    assert Ownership.owner(Repo, work_request.id) == nil
  end

  defp terminal_call(headers, terminal, name, arguments) do
    Ecto.UUID.generate()
    |> tool_call_request(name, arguments)
    |> with_terminal(terminal)
    |> post_json(headers)
    |> json_response(200)
  end

  defp terminal_meta(address), do: %{"core_id" => "endpoint-core", "core_name" => "testbox", "terminal_id" => address}

  defp with_terminal(payload, address), do: put_in(payload, ["params", "_meta"], %{"herdr" => terminal_meta(address)})

  test "POST /mcp starts the HTTP state store when endpoint runtime omitted it" do
    restore_mode = remove_http_state_store_for_test()
    on_exit(fn -> restore_http_state_store_for_test(restore_mode) end)

    refute Process.whereis(HTTPStateStore)

    conn = post_json(initialize_request("init"))

    assert %{"jsonrpc" => "2.0", "id" => "init", "result" => %{"serverInfo" => %{"name" => "sympp"}}} =
             json_response(conn, 200)

    assert [_session_id] = get_resp_header(conn, "mcp-session-id")
  end

  test "POST /mcp restarts supervised HTTP state store through the application supervisor" do
    if application_supervises_http_state_store?() do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, HTTPStateStore)
      on_exit(fn -> restore_http_state_store_for_test(:application_supervisor) end)

      refute Process.whereis(HTTPStateStore)

      conn = post_json(initialize_request("restart"))

      assert %{"jsonrpc" => "2.0", "id" => "restart", "result" => %{"serverInfo" => %{"name" => "sympp"}}} =
               json_response(conn, 200)

      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      assert Process.whereis(HTTPStateStore) == supervised_http_state_store_pid()
    end
  end

  test "200 concurrent unbound MCP startups stay independent of SQLite" do
    parent = self()
    task_supervisor = start_supervised!(Task.Supervisor)

    repo_holder =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Repo.transaction(
          fn ->
            send(parent, {:repo_held, self()})
            receive do: (:release_repo -> :ok)
          end,
          timeout: :infinity
        )
      end)

    assert_receive {:repo_held, repo_holder_pid}, 5_000

    tasks =
      Enum.map(1..200, fn index ->
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {:startup_ready, self()})
          receive do: (:start -> unbound_startup_handshake(index))
        end)
      end)

    Enum.each(tasks, fn task ->
      pid = task.pid
      assert_receive {:startup_ready, ^pid}, 5_000
    end)

    _session_ids =
      try do
        {results, query_count} =
          count_queries(fn ->
            Enum.each(tasks, &send(&1.pid, :start))
            Task.yield_many(tasks, 5_000)
          end)

        session_ids =
          Enum.map(results, fn
            {_task, {:ok, session_id}} -> session_id
            {_task, nil} -> flunk("MCP startup cohort timed out")
            {_task, {:exit, reason}} -> flunk("MCP startup task exited: #{inspect(reason)}")
          end)

        assert length(session_ids) == 200
        assert length(Enum.uniq(session_ids)) == 200
        assert query_count == 0
        session_ids
      after
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        send(repo_holder_pid, :release_repo)
        assert {:ok, :ok} = Task.await(repo_holder, 5_000)
      end
  end

  test "readiness creates no transport state and rejects a non-loopback peer", %{database_path: database_path} do
    before_state = :sys.get_state(HTTPStateStore)
    display_path = database_path |> Path.expand() |> String.replace("\\", "/")
    user_home = System.user_home!() |> Path.expand() |> String.replace("\\", "/")
    expected_path = String.replace_prefix(display_path, user_home <> "/", "$HOME/")

    for _probe <- 1..100 do
      conn = get_local("/mcp/readiness")

      assert %{
               "status" => "ok",
               "source" => %{"revision" => revision, "mcp_contract" => %{"fingerprint" => fingerprint}},
               "mode" => "http",
               "ledger" => %{"reachable" => true, "mode" => ledger_mode, "identity" => ledger_identity},
               "dashboard" => %{"ready" => dashboard_ready?}
             } = json_response(conn, 200)

      assert is_binary(revision) or is_nil(revision)
      assert fingerprint =~ ~r/^[0-9a-f]{64}$/
      assert ledger_mode in ["live", "configured_identity"]
      assert %{"kind" => "sqlite", "display_path" => ^expected_path, "default_home" => false} = ledger_identity
      assert is_boolean(dashboard_ready?)
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    assert :sys.get_state(HTTPStateStore) == before_state

    assert get_in(get_local("/mcp/readiness", [], remote_ip: {10, 0, 0, 2}) |> json_response(403), ["error", "data", "reason"]) ==
             "local_only"
  end

  test "steady HTTP health requests perform no SQLite work" do
    init = post_json(initialize_request("steady-health-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    {responses, queries} =
      capture_queries(fn ->
        for index <- 1..25 do
          post_json(tool_call_request("steady-health-#{index}", "sympp.health", %{}), [{"mcp-session-id", session_id}])
        end
      end)

    assert Enum.all?(responses, fn response ->
             get_in(json_response(response, 200), ["result", "structuredContent", "status"]) == "ok"
           end)

    assert queries == []
  end

  test "POST /mcp/client-lease restarts a missing lease worker" do
    on_exit(fn -> ClientLeases.detach("restarted-endpoint-client") end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ClientLeases)
    refute Process.whereis(ClientLeases)

    attach = post_json(%{"client_id" => "restarted-endpoint-client", "action" => "attach"}, [], path: "/mcp/client-lease")
    assert %{"status" => "ok"} = json_response(attach, 200)
    assert Process.whereis(ClientLeases)
  end

  test "client lease endpoint refuses non-loopback peer addresses" do
    payload = %{"client_id" => "endpoint-client", "action" => "attach"}

    assert get_in(post_json(payload, [], path: "/mcp/client-lease", remote_ip: {10, 0, 0, 2}) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"
  end

  test "POST /mcp tools/list follows a session initialized from the live dashboard repo" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    Application.delete_env(:symphony_elixir, :sympp_repo_database)

    on_exit(fn -> restore_sympp_repo_database(original_database) end)

    init = post_json(initialize_request("live-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    conn = post_json(tools_list_request("live-tools"), [{"mcp-session-id", session_id}])

    assert [^session_id] = get_resp_header(conn, "mcp-session-id")
    assert "sympp.health" in tool_names(json_response(conn, 200))
  end

  test "cleanup startup and the first MCP write share the migration file lock" do
    database_path = WorkPackageFactory.database_path()
    workspace_path = solo_workspace_path("startup-migration")
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    observer_key = :sympp_migration_lock_wait_observer
    original_observer = Application.get_env(:symphony_elixir, observer_key)
    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)
    Application.put_env(:symphony_elixir, observer_key, self())
    start_supervised!({LazyHTTPRepo, database: database_path, pool_size: 5})

    on_exit(fn ->
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_app_env(observer_key, original_observer)
      File.rm(database_path)
      File.rm_rf(workspace_path)
    end)

    parent = self()

    lock_task =
      Task.async(fn ->
        MigrationFileLock.run(database_path, fn ->
          send(parent, :migration_lock_held)
          receive do: (:release_migration_lock -> :ok)
        end)
      end)

    try do
      assert_receive :migration_lock_held, 5_000
      lock_path = database_path <> ".migration.lock"

      with_endpoint_repo(LazyHTTPRepo, fn ->
        init = post_json(initialize_request("init"))
        [session_id] = get_resp_header(init, "mcp-session-id")
        assert json_response(post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}]), 200)["result"]
        queue_pid = start_supervised!({WorktreeCleanupQueue, repo: LazyHTTPRepo, name: nil})
        assert_receive {:migration_lock_wait, queue_lock_path, ^queue_pid}, 5_000
        assert Repo.same_database_path?(queue_lock_path, lock_path)

        request =
          Task.async(fn ->
            post_json(
              tool_call_request("first-write", "solo_attach", %{
                "repo" => "fixture/startup",
                "base_branch" => "beta",
                "workspace_path" => workspace_path,
                "caller_id" => "startup-test"
              })
              |> with_terminal("t1"),
              [{"mcp-session-id", session_id}]
            )
          end)

        request_pid = request.pid
        assert_receive {:migration_lock_wait, request_lock_path, ^request_pid}, 5_000
        assert Repo.same_database_path?(request_lock_path, lock_path)
        send(lock_task.pid, :release_migration_lock)
        assert :ok = Task.await(lock_task)
        assert get_in(json_response(Task.await(request, 30_000), 200), ["result", "structuredContent", "action"]) == "solo_attach"
      end)
    after
      send(lock_task.pid, :release_migration_lock)
    end
  end

  test "POST /mcp dispatches Solo tools through the dashboard lazy repo seam" do
    database_path = WorkPackageFactory.database_path()
    workspace_path = solo_workspace_path("lazy-repo")
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(database_path)
      File.rm_rf(workspace_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      pre_attach_health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])
      tool_notification = post_json(tool_call_notification("solo_list", %{}), [{"mcp-session-id", session_id}])

      conn =
        post_json(
          tool_call_request("attach", "solo_attach", %{
            "repo" => "nextide/example",
            "base_branch" => "main",
            "workspace_path" => workspace_path,
            "caller_id" => "codex-local"
          })
          |> with_terminal("t1"),
          [{"mcp-session-id", session_id}]
        )

      post_attach_health = post_json(tool_call_request("health-after-attach", "sympp.health", %{}), [{"mcp-session-id", session_id}])

      assert get_in(json_response(pre_attach_health, 200), ["result", "structuredContent", "status"]) == "degraded"
      assert get_in(json_response(pre_attach_health, 200), ["result", "structuredContent", "ledger", "reachable"]) == false
      assert response(tool_notification, 202) == ""
      assert get_in(json_response(conn, 200), ["result", "structuredContent", "action"]) == "solo_attach"
      assert get_in(json_response(post_attach_health, 200), ["result", "structuredContent", "status"]) == "ok"
      assert get_in(json_response(post_attach_health, 200), ["result", "structuredContent", "ledger", "reachable"]) == true
      assert File.exists?(database_path)
    end)
  end

  test "POST /mcp keeps custom repo startup discovery independent from fallback database" do
    fallback_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, Repo)
    original_lazy_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, Repo, database: fallback_database_path)
    Application.delete_env(:symphony_elixir, LazyHTTPRepo)

    on_exit(fn ->
      restore_app_env(Repo, original_repo_config)
      restore_app_env(LazyHTTPRepo, original_lazy_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(fallback_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])

      assert "sympp.health" in tool_names(json_response(tools, 200))
      refute File.exists?(fallback_database_path)
    end)
  end

  test "POST /mcp keeps default repo startup discovery independent from fallback database" do
    fallback_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, Repo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, Repo, database: fallback_database_path)

    on_exit(fn ->
      restore_app_env(Repo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(fallback_database_path)
    end)

    with_endpoint_repo(Repo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])
      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])

      assert "sympp.health" in tool_names(json_response(tools, 200))
      assert get_in(json_response(health, 200), ["result", "structuredContent", "status"]) == "degraded"
      refute File.exists?(fallback_database_path)
    end)
  end

  test "POST /mcp preserves live health for remote custom repo config" do
    with_endpoint_repo(RemoteHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])
      structured = get_in(json_response(health, 200), ["result", "structuredContent"])

      assert structured["status"] == "ok"
      assert structured["ledger"]["reachable"] == true

      assert structured["ledger"]["identity"] == %{
               "kind" => "server",
               "source" => "explicit",
               "endpoint" => "server://ledger-http.example.test:15432"
             }
    end)
  end

  test "POST /mcp keeps state-local follow-up traffic independent from lazy repo failures" do
    database_path = WorkPackageFactory.database_path()
    mismatch_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      if pid = Process.whereis(LazyHTTPRepo), do: GenServer.stop(pid, :normal, 5_000)
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm_rf(database_path)
      File.rm(mismatch_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      {:ok, mismatch_repo} = LazyHTTPRepo.start_link(database: mismatch_database_path, pool_size: 1)
      Process.unlink(mismatch_repo)

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])
      notification = post_json(notification_request(), [{"mcp-session-id", session_id}])
      repo_backed = post_json(tool_call_request("repo-backed", "solo_list", %{}), [{"mcp-session-id", session_id}])
      repo_backed_notification = post_json(tool_call_notification("solo_list", %{}), [{"mcp-session-id", session_id}])
      resources = post_json(resources_list_request("resources"), [{"mcp-session-id", session_id}])
      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])

      version_resource =
        post_json(resources_read_request("version", "sympp://health/version"), [{"mcp-session-id", session_id}])

      protected_resource =
        post_json(
          resources_read_request("protected", "sympp://work-packages/SYMPP-MCP-HTTP/task_plan.md"),
          [{"mcp-session-id", session_id}]
        )

      unknown = post_json(tools_list_request("missing"), [{"mcp-session-id", "missing-session"}])

      assert "solo_attach" in tool_names(json_response(tools, 200))
      assert response(notification, 202) == ""
      assert json_response(repo_backed, 503) == json_rpc_error("repo-backed", -32_000, "Server error", "ledger_unavailable")
      assert json_response(repo_backed_notification, 503) == json_rpc_error(nil, -32_000, "Server error", "ledger_unavailable")
      assert resource_uris(json_response(resources, 200)) == ["sympp://health/version"]
      assert get_in(json_response(health, 200), ["result", "structuredContent", "mode"]) == "http"
      assert get_in(json_response(version_resource, 200), ["result", "contents", Access.at(0), "uri"]) == "sympp://health/version"
      assert json_response(protected_resource, 503) == json_rpc_error("protected", -32_000, "Server error", "ledger_unavailable")
      assert get_in(json_response(unknown, 404), ["error", "data", "reason"]) == "unknown_state_key"
    end)
  end

  test "POST /mcp keeps startup discovery DB-free when dashboard lazy repo startup fails" do
    database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, FailingLazyHTTPRepo)

    Application.put_env(:symphony_elixir, FailingLazyHTTPRepo, database: database_path)

    on_exit(fn ->
      restore_app_env(FailingLazyHTTPRepo, original_repo_config)
      File.rm(database_path)
    end)

    with_endpoint_repo(FailingLazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])
      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])
      repo_backed = post_json(tool_call_request("repo-backed", "solo_list", %{}), [{"mcp-session-id", session_id}])

      assert get_in(json_response(init, 200), ["result", "serverInfo", "name"]) == "sympp"
      assert "sympp.health" in tool_names(json_response(tools, 200))
      assert get_in(json_response(health, 200), ["result", "structuredContent", "mode"]) == "http"
      assert json_response(repo_backed, 503) == json_rpc_error("repo-backed", -32_000, "Server error", "ledger_unavailable")

      assert Enum.any?(Map.keys(:sys.get_state(HTTPStateStore).entries), fn
               {_namespace, _database_key, @client_key, ^session_id} -> true
               _entry -> false
             end)
    end)
  end

  test "POST /mcp observes failed tool requests and notifications once at the endpoint boundary" do
    assert {:ok, _settings} = OperatorSettingsRepository.update(Repo, %{"capture_failed_mcp_calls" => true})

    {request, request_log} =
      with_log(fn -> post_json(tool_call_request("private-endpoint-id", "sympp.health", %{"bearer" => "request-secret"})) end)

    request_error = json_response(request, 400)
    diagnostic_id = get_in(request_error, ["error", "data", "diagnostic_id"])
    assert diagnostic_id =~ ~r/^mcpdiag_[0-9a-f]{16}$/
    assert [request_event] = diagnostic_events(request_log)
    assert request_event["failure_layer"] == "endpoint"
    assert request_event["failure_reason"] == "missing_session_id"
    assert request_event["diagnostic_id"] == diagnostic_id

    {notification, notification_log} =
      with_log(fn -> post_json(tool_call_notification("sympp.health", %{"bearer" => "notification-secret"})) end)

    assert get_in(json_response(notification, 400), ["error", "data", "reason"]) == "missing_session_id"
    assert [notification_event] = diagnostic_events(notification_log)
    assert notification_event["failure_layer"] == "endpoint"
    refute request_log =~ "private-endpoint-id"
    refute request_log =~ "request-secret"
    refute notification_log =~ "notification-secret"
  end

  test "POST /mcp observes each failed tool item in a rejected batch once" do
    assert {:ok, _settings} = OperatorSettingsRepository.update(Repo, %{"capture_failed_mcp_calls" => true})

    payload = [
      tool_call_request("private-batch-id", "sympp.health", %{"bearer" => "request-secret"}),
      tool_call_notification("read_work_request", %{"bearer" => "notification-secret"}),
      tools_list_request("ignored-protocol-item")
    ]

    {conn, log} = with_log(fn -> post_json(payload) end)

    assert json_response(conn, 400) == json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")
    assert events = diagnostic_events(log)
    assert length(events) == 2
    assert Enum.all?(events, &(&1["failure_layer"] == "endpoint"))
    assert Enum.all?(events, &(&1["failure_reason"] == "batch_not_supported"))
    assert events |> Enum.map(& &1["diagnostic_id"]) |> Enum.uniq() |> length() == 2
    assert events |> Enum.map(& &1["tool_name"]) |> Enum.sort() == ["read_work_request", "sympp.health"]
    refute log =~ "private-batch-id"
    refute log =~ "request-secret"
    refute log =~ "notification-secret"
  end

  test "remote peers and malformed header bytes cannot create MCP state" do
    assert get_in(post_json(initialize_request("remote"), [], remote_ip: {10, 0, 0, 2}) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("malformed-host"), [], host: <<255>>) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("malformed-origin"), [{"origin", <<255>>}]) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "origin_not_allowed"

    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  defp post_json(payload, headers \\ [], opts \\ []) do
    payload
    |> Jason.encode!()
    |> post_raw(headers, opts)
  end

  defp get_local(path, headers \\ [], opts \\ []) do
    opts
    |> local_conn()
    |> put_headers(headers)
    |> get(path)
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp count_queries(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    event = Repo.config()[:telemetry_prefix] ++ [:query]
    counter = :atomics.new(1, [])

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, _metadata, counter -> :atomics.add(counter, 1, 1) end,
        counter
      )

    try do
      {fun.(), :atomics.get(counter, 1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp post_raw(body, headers, opts) do
    headers = [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"} | headers]
    path = Keyword.get(opts, :path, "/mcp")

    opts
    |> local_conn()
    |> put_headers(headers)
    |> post(path, body)
  end

  defp local_conn(opts) do
    build_conn()
    |> Map.put(:host, Keyword.get(opts, :host, "localhost"))
    |> Map.put(:port, Keyword.get(opts, :port, 4000))
    |> Map.put(:remote_ip, Keyword.get(opts, :remote_ip, {127, 0, 0, 1}))
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "sympp-http-endpoint-test-client", "version" => "0.1.0"},
        "capabilities" => %{}
      }
    }
  end

  defp tools_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}
  defp resources_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/list", "params" => %{}}
  defp resources_read_request(id, uri), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/read", "params" => %{"uri" => uri}}
  defp notification_request, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}

  defp unbound_startup_handshake(index) do
    init = post_json(initialize_request("init-#{index}"))

    assert %{"result" => %{"serverInfo" => %{"name" => "sympp"}}} = json_response(init, 200)
    assert [session_id] = get_resp_header(init, "mcp-session-id")
    assert session_id =~ ~r/^[!-~]+$/

    if index == 1 do
      headers = [{"mcp-session-id", session_id}]
      assert post_json(notification_request(), headers) |> response(202) == ""
      assert "sympp.health" in (post_json(tools_list_request("tools"), headers) |> json_response(200) |> tool_names())

      assert post_json(resources_list_request("resources"), headers) |> json_response(200) |> resource_uris() == [
               "sympp://health/version"
             ]
    end

    session_id
  end

  defp tool_call_request(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp tool_call_notification(name, arguments) do
    %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp tool_names(payload) do
    payload
    |> get_in(["result", "tools"])
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  defp diagnostic_events(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ~s("event":"sympp_failed_mcp_call")))
    |> Enum.map(fn line ->
      {json_start, 1} = :binary.match(line, "{")
      line |> binary_part(json_start, byte_size(line) - json_start) |> Jason.decode!()
    end)
  end

  defp resource_uris(payload) do
    payload
    |> get_in(["result", "resources"])
    |> Enum.map(& &1["uri"])
    |> Enum.sort()
  end

  defp herdr_binding(conn) do
    [encoded] = get_resp_header(conn, "sympp-herdr-binding")
    padding = String.duplicate("=", rem(4 - rem(byte_size(encoded), 4), 4))

    encoded
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> Kernel.<>(padding)
    |> Base.decode64!()
    |> Jason.decode!()
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-HTTP-#{System.unique_integer([:positive])}",
      title: "HTTP MCP WorkRequest",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Prove HTTP MCP architect continuity.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package"
    }

    Enum.into(overrides, defaults)
  end

  defp json_rpc_error(id, code, message, reason) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => %{"reason" => reason}}}
  end

  defp reset_server_response_state do
    handle_state_agent = Module.concat(Server, HandleState)

    case Process.whereis(handle_state_agent) do
      nil -> :ok
      _pid -> reset_handle_state_agent(handle_state_agent)
    end
  end

  defp reset_handle_state_agent(handle_state_agent) do
    Agent.update(handle_state_agent, fn _store -> %{} end)
  catch
    :exit, _reason -> :ok
  end

  defp restore_sympp_repo_database(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_sympp_repo_database(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp remove_http_state_store_for_test do
    if application_supervises_http_state_store?() do
      _result = Supervisor.terminate_child(SymphonyElixir.Supervisor, HTTPStateStore)
      _result = Supervisor.delete_child(SymphonyElixir.Supervisor, HTTPStateStore)
      :application_supervisor
    else
      stop_http_state_store()
      :standalone
    end
  end

  defp restore_http_state_store_for_test(:application_supervisor) do
    stop_http_state_store()

    case Supervisor.start_child(SymphonyElixir.Supervisor, HTTPStateStore) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp restore_http_state_store_for_test(:standalone), do: stop_http_state_store()

  defp application_supervises_http_state_store? do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        Enum.any?(Supervisor.which_children(SymphonyElixir.Supervisor), fn
          {HTTPStateStore, _pid, _type, _modules} -> true
          _child -> false
        end)

      nil ->
        false
    end
  end

  defp supervised_http_state_store_pid do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        Enum.find_value(Supervisor.which_children(SymphonyElixir.Supervisor), fn
          {HTTPStateStore, child_pid, _type, _modules} when is_pid(child_pid) -> child_pid
          _child -> nil
        end)

      nil ->
        nil
    end
  end

  defp stop_http_state_store do
    case Process.whereis(HTTPStateStore) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _reason -> :ok
  end

  defp with_endpoint_repo(repo, fun) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(endpoint_config, :sympp_repo, repo))

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    end
  end

  defp solo_workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-mcp-http-solo-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
