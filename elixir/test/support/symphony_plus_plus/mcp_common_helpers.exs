Code.require_file("../mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers do
  @moduledoc false

  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @repo_root Path.expand("../../../..", __DIR__)

  def main_database_row_matches?([_seq, "main", path], database_path) do
    Repo.same_database_path?(path, database_path)
  end

  def main_database_row_matches?(_row, _database_path), do: false

  def initialize_params do
    %{
      "protocolVersion" => "2025-03-26",
      "clientInfo" => %{"name" => "sympp-test-client", "version" => "0.1.0"},
      "capabilities" => %{}
    }
  end

  def tools_for_server(server) do
    %{"result" => %{"tools" => tools}} =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)

    tools
  end

  def handle_state_agent, do: Module.concat(Server, HandleState)

  def handle_state_store_key(server), do: {handle_state_namespace(server.config), server.state_key}

  def handle_state_namespace(%Config{} = config), do: {config.mode, ledger_namespace(config)}

  def ledger_namespace(%Config{repo: repo, database: database}) do
    case current_ledger_identity(repo, database) do
      {:ok, identity} -> identity
      :error -> {:configured_database, repo_database_key(repo, database)}
    end
  end

  def current_ledger_identity(repo, database) do
    case SQL.query(repo, "PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &main_database_row?/1) do
          [_seq, "main", path] -> {:ok, main_database_identity(repo, path, database)}
          _row -> :error
        end

      _result ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  def main_database_row?([_seq, "main", _path]), do: true
  def main_database_row?(_row), do: false

  def main_database_identity(repo, path, _database) when is_binary(path) and path != "" do
    {:main_database, repo_database_key(repo, path)}
  end

  def main_database_identity(repo, _path, nil), do: blank_database_identity(repo)
  def main_database_identity(repo, _path, database), do: {:configured_database, repo_database_key(repo, database)}

  def blank_database_identity(repo) when is_pid(repo), do: {:repo_process, repo}

  def blank_database_identity(repo) when is_atom(repo) do
    case repo.get_dynamic_repo() do
      nil -> {:repo, repo}
      dynamic_repo -> {:dynamic_repo, dynamic_repo}
    end
  end

  def repo_database_key(repo, database) do
    if function_exported?(repo, :database_key, 1), do: repo.database_key(database), else: database
  end

  def handle_state_store do
    ensure_handle_state_agent()
    Agent.get(handle_state_agent(), & &1)
  end

  def put_handle_state_entry(server, entry) do
    ensure_handle_state_agent()
    Agent.update(handle_state_agent(), &Map.put(&1, handle_state_store_key(server), entry))
  end

  def reset_handle_state_store do
    ensure_handle_state_agent()
    Agent.update(handle_state_agent(), fn _store -> %{} end)
  end

  def delete_handle_state_entry(server) do
    ensure_handle_state_agent()
    Agent.update(handle_state_agent(), &Map.delete(&1, handle_state_store_key(server)))
  end

  def ensure_handle_state_agent do
    case Process.whereis(handle_state_agent()) do
      nil ->
        case Agent.start(fn -> %{} end, name: handle_state_agent()) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  def attach_tool(repo, terminal, name, arguments) do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => name, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}},
        repo: repo,
        terminal: terminal
      )

    assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    response
  end

  def response_progress_payload(repo, response) do
    event_id = get_in(response, ["result", "structuredContent", "progress_event", "id"])
    refute Map.has_key?(get_in(response, ["result", "structuredContent", "progress_event"]), "payload")
    repo.get!(ProgressEvent, event_id).payload
  end

  def tool_result_text(response) do
    get_in(response, ["result", "content", Access.at(0), "text"])
  end

  def assert_toon_tool_text!(response) do
    text = tool_result_text(response)
    assert is_binary(text)
    assert text != ""
    refute String.starts_with?(String.trim_leading(text), "{")
    assert {:error, _reason} = Jason.decode(text)
    text
  end

  def metadata_idempotency_key(payload) do
    "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  def review_suite_artifact_id(work_package_id, head_sha) do
    material = [work_package_id, head_sha, "review-suite-result.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  def create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  def work_request_attrs(overrides) do
    defaults = %{
      id: "WR-MCP-#{System.unique_integer([:positive])}",
      title: "Improve WorkRequest intake",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package"
    }

    Enum.into(overrides, defaults)
  end

  def work_request_question_attrs(overrides) do
    defaults = %{
      category: "scope",
      question: "Which branch should this target?",
      why_needed: "The architect needs the target before slicing."
    }

    Enum.into(overrides, defaults)
  end

  def work_request_decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Keep this WorkRequest narrow.",
      rationale: "The next slice owns broader orchestration.",
      scope_impact: "No new runtime tools.",
      created_by: "architect-1"
    }

    Enum.into(overrides, defaults)
  end

  def work_request_work_package_attrs(overrides) do
    defaults = %{
      title: "Add WorkRequest MCP reads",
      goal: "Expose scoped read-only WorkRequest MCP payloads.",
      kind: "mcp",
      base_branch: "symphony-plus-plus/beta",
      branch_pattern: "agent/SYMPP-V2-WR-013/workrequest-read-mcp-tools",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir_web/live/**"],
      acceptance_criteria: ["WorkRequest MCP reads are scoped and redacted."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      stop_conditions: ["Stop before mutation or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  def test_repo_root do
    @repo_root
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)
end
