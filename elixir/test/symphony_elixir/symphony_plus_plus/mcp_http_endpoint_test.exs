defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPEndpointTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias Phoenix.Endpoint.RenderErrors

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    FailedCall,
    HTTPStateStore
  }

  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.MigrationFileLock
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint

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
    Repo.delete_all(FailedCall.Count)
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

      %{remote: [remote_ip: {203, 0, 113, 2}, host: "100.123.207.19"], headers: [{"authorization", "Bearer " <> token}]}
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

    test "direct tailnet peers have full board and native access without credentials", %{remote: remote} do
      ipv6 = {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1}
      mapped = {0, 0, 0, 0, 0, 65_535, 0x6440, 2}
      settings_path = "/api/v1/sympp/operator/settings"

      for ip <- [{100, 64, 0, 0}, {100, 127, 255, 255}, ipv6, mapped] do
        opts = Keyword.put(remote, :remote_ip, ip)
        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [], opts) |> json_response(200) |> Map.has_key?("work_request_details")
        assert get_local("/api/v1/sympp/operator/dashboard?surface=archived", [], opts).status == 200
        assert get_local("/api/v1/sympp/herdr/dashboard", [], opts).status == 200

        for headers <- [[], [{"origin", "http://100.123.207.19:4000"}]] do
          result = post_json(%{"open_dashboard_on_boot" => false}, headers, Keyword.put(opts, :path, settings_path)) |> json_response(200)
          assert result["settings"]["open_dashboard_on_boot"] == false
        end

        intake = %{"title" => "Tailnet intake", "repo" => "example/service", "base_branch" => "main", "human_description" => "Create a request from the native panel."}
        native = post_json(intake, [], Keyword.put(opts, :path, "/api/v1/sympp/herdr/work-requests")) |> json_response(201)
        assert native["work_request"]["work_request"]["title"] == "Tailnet intake"

        for origin <- ["http://evil.example", "null", "http://100.123.207.19:4001", "https://100.123.207.19:4000"] do
          assert post_json(%{"open_dashboard_on_boot" => true}, [{"origin", origin}], Keyword.put(opts, :path, settings_path)).status == 403
          assert post_json(intake, [{"origin", origin}], Keyword.put(opts, :path, "/api/v1/sympp/herdr/work-requests")).status == 403
        end

        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [], opts) |> json_response(200) |> get_in(["settings", "open_dashboard_on_boot"]) == false
      end
    end

    test "tailnet authority requires a trusted Host even when Origin matches", %{remote: remote, headers: token_headers} do
      tailnet = Keyword.put(remote, :remote_ip, {100, 64, 0, 2})
      path = "/api/v1/sympp/operator/settings"
      {:ok, hostname} = :inet.gethostname()

      for host <- ["100.64.0.1", "fd7a:115c:a1e0::1", "factory.tailnet.ts.net", "localhost", "127.0.0.1", "::1", List.to_string(hostname)] do
        opts = tailnet |> Keyword.put(:host, host) |> Keyword.put(:path, path)
        origin = URI.to_string(%URI{scheme: "http", host: host, port: 4000})
        response = post_json(%{"open_dashboard_on_boot" => false}, [{"origin", origin}], opts) |> json_response(200)
        assert response["settings"]["open_dashboard_on_boot"] == false
      end

      for host <- ["rebound.example", "factory.ts.net.evil.example", "100.128.0.1"] do
        opts = tailnet |> Keyword.put(:host, host) |> Keyword.put(:path, path)
        origin_headers = [{"origin", "http://#{host}:4000"}]
        assert post_json(%{"open_dashboard_on_boot" => true}, origin_headers, opts).status == 401
        assert get_local("/api/v1/sympp/herdr/dashboard", [], opts).status == 401
        assert post_json(%{"open_dashboard_on_boot" => false}, origin_headers ++ token_headers, opts).status == 200
      end
    end

    test "outside peers and forwarded tailnet requests retain credential requirements", %{remote: remote, headers: headers} do
      outside_ipv6 = {0xFD7A, 0x115C, 0xA1E1, 0, 0, 0, 0, 1}

      for ip <- [{100, 63, 255, 255}, {100, 128, 0, 0}, {192, 168, 1, 5}, {8, 8, 8, 8}, outside_ipv6] do
        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [], Keyword.put(remote, :remote_ip, ip)).status == 401
        assert get_local("/sympp", [], Keyword.put(remote, :remote_ip, ip)).status == 401
      end

      tailnet = Keyword.put(remote, :remote_ip, {100, 64, 0, 2})

      for header <- ["forwarded", "x-real-ip", "x-forwarded-for", "x-forwarded-custom"] do
        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [{header, "127.0.0.1"}], tailnet).status == 401
        assert get_local("/api/v1/sympp/operator/dashboard/hydrated", [{header, "127.0.0.1"} | headers], tailnet).status == 403
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
      result = post_json(%{"open_dashboard_on_boot" => false}, browser, Keyword.put(remote, :path, path)) |> json_response(200)
      assert result["settings"]["open_dashboard_on_boot"] == false
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

  test "ten MCP sessions in the owning terminal dispatch distinct packages concurrently and a repeated dispatch replays" do
    init = post_json(initialize_request("dispatch-init"))
    headers = [{"mcp-session-id", hd(get_resp_header(init, "mcp-session-id"))}]

    created =
      terminal_call(headers, "t1", "create_work_request", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "title" => "Concurrent dispatch",
        "work_type" => "docs",
        "description" => "Dispatch independent packages together",
        "desired_dispatch_shape" => "single_package"
      })

    request_id = get_in(created, ["result", "structuredContent", "work_request", "id"])
    assert is_binary(request_id), inspect(created)

    sliced =
      terminal_call(headers, "t1", "edit_plan", %{
        "work_request_id" => request_id,
        "ops" =>
          Enum.map(1..11, fn n ->
            add_package_op(goal: "Deliver package #{n}", allowed_file_globs: ["docs/**"], validation_steps: [], stop_conditions: [])
          end)
      })

    [blocked_id | package_ids] = added_package_ids(sliced)
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
          result = terminal_call(client, "t1", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => package_id, "review_mode" => "fast"})
          assert result["result"], inspect(result)
          refute result["result"]["isError"], inspect(result)
          result["result"]["structuredContent"]["work_package"]["review_id"]
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :dispatch))
    review_ids = Enum.map(tasks, &Task.await(&1, 30_000))
    assert review_ids |> Enum.uniq() |> length() == 10

    for package_id <- package_ids do
      assert Repo.get!(WorkPackage, package_id).status == "dispatched"
    end

    {client, package_id} = hd(clients)
    replay = terminal_call(client, "t1", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => package_id, "review_mode" => "fast"})
    assert replay["result"]["structuredContent"]["replay"]
    assert replay["result"]["structuredContent"]["work_package"]["review_id"] == hd(review_ids)

    other_mode = terminal_call(client, "t1", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => package_id, "review_mode" => "deep"})
    assert other_mode["error"]["data"]["code"] == "review_mode_conflict"
    assert other_mode["error"]["data"]["review_mode"] == "fast"

    other_terminal = terminal_call(client, "t2", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => blocked_id, "review_mode" => "fast"})
    assert other_terminal["error"]["data"]["code"] == "owned_by_other_terminal"

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
      busy = terminal_call(client, "t1", "dispatch_work_package", %{"work_request_id" => request_id, "work_package_id" => blocked_id, "review_mode" => "fast"})
      assert busy["error"]["data"]["code"] == "database_busy"
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
        "work_type" => "docs",
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

    assert json_response(refused, 200)["error"]["data"]["code"] == "owned_by_other_terminal"
    assert get_resp_header(refused, "sympp-herdr-binding") == []

    # A write naming only the package binds the terminal to the package's WorkRequest.
    sliced =
      terminal_call(headers, "t1", "edit_plan", %{
        "work_request_id" => request_id,
        "ops" => [add_package_op(goal: "Bind by package", allowed_file_globs: ["docs/**"], validation_steps: [], stop_conditions: [])]
      })

    [package_id] = added_package_ids(sliced)

    progress =
      tool_call_request("progress", "set_blocker", %{"work_package_id" => package_id, "blocker_id" => "bind-1", "active" => true, "summary" => "Waiting"})
      |> with_terminal("t1")
      |> post_json(headers)

    assert json_response(progress, 200)["result"]
    assert herdr_binding(progress)["work_request_id"] == request_id
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

  test "client lease endpoint refuses non-loopback peer addresses" do
    payload = %{"client_id" => "endpoint-client", "action" => "attach"}

    assert get_in(post_json(payload, [], path: "/mcp/client-lease", remote_ip: {10, 0, 0, 2}) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"
  end

  test "cleanup startup and the first MCP write share the migration file lock" do
    database_path = WorkPackageFactory.database_path()
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
              tool_call_request("first-write", "create_work_request", work_request_arguments("fixture/startup", "beta"))
              |> with_terminal("t1"),
              [{"mcp-session-id", session_id}]
            )
          end)

        request_pid = request.pid
        assert_receive {:migration_lock_wait, request_lock_path, ^request_pid}, 5_000
        assert Repo.same_database_path?(request_lock_path, lock_path)
        send(lock_task.pid, :release_migration_lock)
        assert :ok = Task.await(lock_task)
        assert is_binary(get_in(json_response(Task.await(request, 30_000), 200), ["result", "structuredContent", "work_request", "id"]))
      end)
    after
      send(lock_task.pid, :release_migration_lock)
    end
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

  defp tool_call_request(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
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

  defp with_endpoint_repo(repo, fun) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(endpoint_config, :sympp_repo, repo))

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    end
  end

  defp work_request_arguments(repo, base_branch),
    do: %{"repo" => repo, "base_branch" => base_branch, "title" => "Lazy repo write", "work_type" => "feature", "description" => "First write through the HTTP endpoint."}

  defp add_package_op(overrides), do: overrides |> WorkPackageFactory.attrs() |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.put("op", "add_package")

  defp added_package_ids(response), do: Enum.map(get_in(response, ["result", "structuredContent", "applied"]) || [], & &1["work_package_id"])
end
