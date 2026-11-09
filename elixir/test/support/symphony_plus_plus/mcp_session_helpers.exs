Code.require_file("mcp_common_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase.SessionHelpers do
  @moduledoc false

  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  def query!(repo_or_pid, sql, params \\ []) do
    SQL.query!(repo_or_pid, sql, params, log: false)
  end

  @doc """
  Calls one tool. `terminal` is a Herdr terminal address such as "t1" (the
  caller's `_meta.herdr`), or nil for a caller outside Herdr.
  """
  def mcp_tool(repo, terminal, name, arguments, opts \\ []) do
    config = Keyword.get(opts, :config, test_mcp_config(repo))
    # A trusted local HTTP connection has an explicit MCP session id.
    state_key = Keyword.get(opts, :state_key, if(config.mode == :http, do: "test-state-#{System.unique_integer([:positive])}"))

    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: config,
      state_key: state_key,
      terminal: terminal,
      labels: Keyword.get(opts, :labels, %{})
    )
  end

  @doc "The `Ownership.Terminal` the harness asserts for `address`."
  def test_terminal(address, labels \\ %{}), do: Terminal.from_meta(MCPHarness.herdr_meta(address, labels))

  @doc "Makes `address` the live owner of a WorkRequest."
  def own!(repo, work_request_id, address \\ "t1") do
    assert {:ok, row, _how} = Ownership.acquire(repo, work_request_id, test_terminal(address))
    row
  end

  def test_mcp_config(repo), do: Config.default(repo: repo, repo_root: test_repo_root())

  def local_mcp_config(repo), do: Config.default(repo: repo, mode: :http, repo_root: test_repo_root(), local_daemon_trusted: true)

  def local_mcp_server(%Config{} = config, state_key) do
    Server.new(config, initialized: true, local_daemon_trusted: true, state_key: state_key)
  end

  def create_dispatched_package!(repo, id, overrides \\ []) do
    attrs =
      [
        id: id,
        kind: "mcp",
        repo: "nextide/symphony-plus-plus",
        base_branch: "feature/sympp-v21-ledger-claims",
        branch_pattern: "agent/#{id}/worker",
        worktree_path: Path.expand(Path.join(System.tmp_dir!(), "sympp-package-#{id}")),
        status: "dispatched"
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, attrs)
    package
  end

  def set_relative_owner_origin!(fixture, owner_repo) do
    relative_origin = "#{owner_repo}.git"
    local_origin = Path.join(fixture.repo_root, relative_origin)

    File.mkdir_p!(Path.dirname(local_origin))
    TestSupport.git_output!(fixture.root, ["clone", "--bare", fixture.origin, local_origin])
    TestSupport.git_output!(fixture.repo_root, ["remote", "set-url", "origin", relative_origin])

    fixture
  end

  def decode_json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  def decode_json_objects_from_mixed_output(output) do
    output
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim_leading/1)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
  end

  def json_rpc_response_summary(responses) do
    Enum.map(responses, fn response ->
      result = Map.get(response, "result", %{})

      %{
        id: Map.get(response, "id"),
        error: get_in(response, ["error", "data", "code"]) || get_in(response, ["error", "data", "reason"]) || get_in(response, ["error", "message"]),
        result_keys: if(is_map(result), do: Map.keys(result), else: [])
      }
    end)
  end

  defp test_repo_root, do: CommonHelpers.test_repo_root()
end
