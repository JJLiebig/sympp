Code.require_file("../mcp_harness.exs", __DIR__)
Code.require_file("mcp_common_helpers.exs", __DIR__)
Code.require_file("mcp_session_helpers.exs", __DIR__)
Code.require_file("mcp_handoff_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @architect_phase_id "phase-mcp-architect-test"
  @handoff_store_process_key :sympp_mcp_test_handoff_store_dir
  @codex_forbidden_top_level_schema_keys ["oneOf", "anyOf", "allOf", "enum", "not"]

  def architect_phase_id, do: @architect_phase_id
  def handoff_store_process_key, do: @handoff_store_process_key
  def codex_forbidden_top_level_schema_keys, do: @codex_forbidden_top_level_schema_keys

  defmodule FailingAuthRepo do
    def get(_schema, _id), do: raise(RuntimeError, "ledger unavailable")
  end

  defmodule UnexpectedAuthRepo do
    def get(_schema, _id), do: {:error, :ledger_down}
  end

  defmodule FailingHealthRepo do
    def query(_sql, _params, _opts), do: {:error, %RuntimeError{message: "C:/secret/path.sqlite"}}
  end

  defmodule DefaultRemoteHealthRepo do
    def config, do: [hostname: "ledger-prod.example.test", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmodule DefaultRemoteIpv6HealthRepo do
    def config, do: [hostname: "::1", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmodule DefaultRemoteDbnameHealthRepo do
    def config, do: [database: "dbname=sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      import Ecto.Query, only: [from: 2]
      import ExUnit.CaptureLog
      import ExUnit.CaptureIO

      alias Ecto.Adapters.SQL
      alias Mix.Tasks.Sympp.Mcp, as: McpTask
      alias SymphonyElixir.MCPHarness
      alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.ArchitectContext
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Repository, as: MCPRepository
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Stdio
      alias SymphonyElixir.SymphonyPlusPlus.MCPCase
      alias SymphonyElixir.SymphonyPlusPlus.Ownership
      alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
      alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
      alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
      alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
      alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
      alias SymphonyElixir.SymphonyPlusPlus.Repo
      alias SymphonyElixir.SymphonyPlusPlus.Repo.MigrationFileLock
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
      alias SymphonyElixir.TestSupport
      alias SymphonyElixir.WorkPackageFactory

      @architect_phase_id SymphonyElixir.SymphonyPlusPlus.MCPCase.architect_phase_id()
      @handoff_store_process_key SymphonyElixir.SymphonyPlusPlus.MCPCase.handoff_store_process_key()
      @codex_forbidden_top_level_schema_keys MCPCase.codex_forbidden_top_level_schema_keys()

      import SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers
      import SymphonyElixir.SymphonyPlusPlus.MCPCase.SessionHelpers
      import SymphonyElixir.SymphonyPlusPlus.MCPCase.HandoffHelpers

      alias SymphonyElixir.SymphonyPlusPlus.MCPCase.{
        DefaultRemoteDbnameHealthRepo,
        DefaultRemoteHealthRepo,
        DefaultRemoteIpv6HealthRepo,
        FailingAuthRepo,
        FailingHealthRepo,
        UnexpectedAuthRepo
      }

      setup_all do
        database_path = WorkPackageFactory.database_path()

        start_supervised!({Repo, database: database_path, pool_size: 1})
        assert :ok = WorkPackageRepository.migrate(Repo)

        on_exit(fn -> File.rm(database_path) end)

        {:ok, repo: Repo}
      end

      setup %{repo: repo} do
        reset_handle_state_store()
        handoff_store_dir = unique_test_handoff_store_dir()
        Process.put(@handoff_store_process_key, handoff_store_dir)
        File.rm_rf(handoff_store_dir)
        repo.delete_all(Artifact)
        repo.delete_all(ProgressEvent)
        repo.delete_all(PlanNode)
        repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Cards.Card)
        repo.delete_all(WorkedOn)
        repo.delete_all(WorkRequest)
        repo.delete_all(WorkPackage)
        repo.delete_all(Phase)

        on_exit(fn -> File.rm_rf(handoff_store_dir) end)

        :ok
      end
    end
  end
end
