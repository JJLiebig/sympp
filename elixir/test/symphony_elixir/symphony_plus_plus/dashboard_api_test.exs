Code.require_file(Path.expand("../../support/symphony_plus_plus/dashboard_fixture_database_test.exs", __DIR__))

defmodule SymphonyElixir.SymphonyPlusPlus.DashboardApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Cards.Card
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.RetentionThrottle
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule BusyRepo do
    @moduledoc false

    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule CountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def all(query) do
      count_artifact_list_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_artifact_list_query(%Ecto.Query{from: %{source: {"sympp_artifacts", _schema}}, order_bys: [_ | _]}) do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &(&1 + 1))
      end
    end

    defp count_artifact_list_query(_query), do: :ok
  end

  defmodule WorkRequestCardCountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @counted_tables [
      "sympp_work_requests",
      "sympp_asks",
      "sympp_work_request_decision_logs",
      "sympp_work_packages",
      "sympp_work_package_deliveries"
    ]

    def all(query) do
      count_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_query(%Ecto.Query{from: %{source: {table, _schema}}}) when table in @counted_tables do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &Map.update(&1, table, 1, fn count -> count + 1 end))
      end
    end

    defp count_query(_query), do: :ok
  end

  defmodule DashboardQueryCountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @counter_key {__MODULE__, :query_count}

    def reset, do: Process.put(@counter_key, 0)
    def count, do: Process.get(@counter_key, 0)

    def all(query), do: counted(fn -> Repo.all(query) end)
    def one(query), do: counted(fn -> Repo.one(query) end)
    def get(queryable, id), do: counted(fn -> Repo.get(queryable, id) end)
    def get!(queryable, id), do: counted(fn -> Repo.get!(queryable, id) end)
    def query(sql, params), do: counted(fn -> Repo.query(sql, params) end)
    def update_all(query, updates), do: counted(fn -> Repo.update_all(query, updates) end)
    def transaction(fun), do: Repo.transaction(fun)

    defp counted(fun) do
      Process.put(@counter_key, count() + 1)
      fun.()
    end
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
    start_test_endpoint()

    on_exit(fn ->
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(OperatorAudit)
    repo.delete_all(AgentRun)
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(PlanNode)
    repo.delete_all(Card)
    repo.delete_all(WorkedOn)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    repo.delete_all(DecisionLogEntry)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Asks.Ask)
    repo.delete_all(WorkRequest)
    repo.delete_all(OperatorSettings)
    RetentionThrottle.reset(repo)
    :ok
  end

  test "hydrated dashboard rejects unsupported methods" do
    assert json_response(post(build_conn(), "/api/v1/sympp/operator/dashboard/hydrated", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "operator notification stream rejects cross-origin requests and unsupported methods" do
    conn = local_operator_conn() |> put_req_header("origin", "https://example.invalid")
    assert json_response(get(conn, "/api/v1/sympp/operator/events"), 401)["error"]["code"] == "unauthorized"
    assert json_response(post(local_operator_conn(), "/api/v1/sympp/operator/events", %{}), 405)["error"]["code"] == "method_not_allowed"
  end

  test "localhost requests without same-origin browser metadata are rejected" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(
                 post(conn, "/api/v1/sympp/operator/work-requests", %{
                   "title" => "Cross-origin request",
                   "repo" => "sympp",
                   "base_branch" => "main"
                 }),
                 401
               )
    end)
  end

  test "configured nonlocal dashboard origin is rejected" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://example.com:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://example.com:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
      end)
    end)
  end

  test "local-looking cross-origin requests do not become local operator" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("origin", "http://localhost:3000")
        |> put_req_header("sec-fetch-site", "cross-site")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(
                 post(conn, "/api/v1/sympp/operator/work-requests", %{
                   "title" => "Cross-origin request",
                   "repo" => "sympp",
                   "base_branch" => "main"
                 }),
                 401
               )
    end)
  end

  test "configured dashboard origin rejects a different localhost hostname" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://spp.localhost:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://other.localhost:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []
      end)
    end)
  end

  test "Phoenix request logger filters dashboard session secret parameters" do
    sentinel = "sympp-dashboard-log-secret-sentinel"

    params = %{
      "work_key" => sentinel,
      "work_key_secret" => "#{sentinel}-work-key-secret",
      "grant_secret" => "#{sentinel}-grant-secret",
      "secret" => "#{sentinel}-generic-secret",
      "operator_bootstrap" => "#{sentinel}-operator-bootstrap",
      "work_package_id" => "SYMPP-P10-LOG-FILTER"
    }

    filtered = Phoenix.Logger.filter_values(params)
    filtered_text = inspect(filtered)

    refute filtered_text =~ sentinel
    assert filtered["work_key"] == "[FILTERED]"
    assert filtered["work_key_secret"] == "[FILTERED]"
    assert filtered["grant_secret"] == "[FILTERED]"
    assert filtered["secret"] == "[FILTERED]"
    assert filtered["operator_bootstrap"] == "[FILTERED]"
    assert filtered["work_package_id"] == "SYMPP-P10-LOG-FILTER"
  end

  defp local_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", "http://localhost")
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp with_local_operator_endpoint(fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end

  defp with_local_operator_dashboard_origin(origin, fun) when is_binary(origin) and is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_dashboard_origin, origin)
    )

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end
end
