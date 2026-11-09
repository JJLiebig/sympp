defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, SoloTools}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.{InputSchemas, SurfaceSpecs}

  @health_tool "sympp.health"
  @mcp_contract_schema_version "sympp-mcp-contract.v1"
  @mcp_contract_health_fields [
    "caller.access",
    "factory_owned_worktrees",
    "ledger",
    "mode",
    "source.mcp_contract.fingerprint",
    "source.mcp_contract.schema_version",
    "source.revision",
    "status",
    "version"
  ]
  @solo_tools SoloTools.tool_names()
  @bootstrap_tools ["create_work_request"]
  @local_operator_tools ["record_work_request_operator_decision", "summarize_failed_mcp_calls"]
  @blocker_closeout_decisions ["resolved", "still_active"]
  @architect_tools [
    "list_work_requests",
    "read_work_request",
    "append_finding",
    "append_progress",
    "resolve_blocker",
    "sync_pr",
    "record_work_package_delivery",
    "set_report",
    "ask_question",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "record_decision",
    "edit_plan",
    "skip_work_package",
    "dispatch_work_package"
  ]
  @known_tools Enum.uniq([@health_tool] ++ @solo_tools ++ @bootstrap_tools ++ @local_operator_tools ++ @architect_tools)
  @work_request_views ["overview", "plan", "board", "package"]
  # Every tool is a write unless listed here. Writes need a Herdr terminal
  # identity; the same split drives the MCP readOnlyHint annotation.
  @read_tools [
    @health_tool,
    "list_work_requests",
    "read_work_request",
    "solo_list",
    "solo_show",
    "summarize_failed_mcp_calls"
  ]
  # Writes that take or confirm ownership of the target WorkRequest. Decisions,
  # questions, WorkRequest creation and Solo stay open to any Herdr terminal.
  @owner_gated_tools [
    "append_finding",
    "append_progress",
    "resolve_blocker",
    "sync_pr",
    "record_work_package_delivery",
    "set_report",
    "edit_plan",
    "skip_work_package",
    "dispatch_work_package"
  ]
  @type tool_name :: String.t()
  @type input_schema :: map()
  @type tool_spec :: map()

  @spec health_tool() :: tool_name()
  def health_tool, do: @health_tool

  @spec mcp_contract_schema_version() :: String.t()
  def mcp_contract_schema_version, do: @mcp_contract_schema_version

  @spec mcp_contract_health_fields() :: [String.t()]
  def mcp_contract_health_fields, do: @mcp_contract_health_fields

  @spec solo_tools() :: [tool_name()]
  def solo_tools, do: @solo_tools

  @spec bootstrap_tools() :: [tool_name()]
  def bootstrap_tools, do: @bootstrap_tools

  @spec local_operator_tools() :: [tool_name()]
  def local_operator_tools, do: @local_operator_tools

  @spec blocker_closeout_decisions() :: [String.t()]
  def blocker_closeout_decisions, do: @blocker_closeout_decisions

  @spec architect_tools() :: [tool_name()]
  def architect_tools, do: @architect_tools

  @spec tool_access(tool_name()) :: :read | :write
  def tool_access(name) when name in @read_tools, do: :read
  def tool_access(_name), do: :write

  @doc "Whether one call only reads."
  @spec read_call?(tool_name(), map()) :: boolean()
  def read_call?(name, _arguments), do: tool_access(name) == :read

  @doc """
  Whether one call must own the target WorkRequest. Any chief or architect may
  end a package as `finished` without owning it.
  """
  @spec owner_gated_call?(tool_name(), map()) :: boolean()
  def owner_gated_call?("record_work_package_delivery", %{"outcome" => "finished"}), do: false
  def owner_gated_call?(name, arguments) when is_map(arguments), do: name in @owner_gated_tools and not read_call?(name, arguments)

  @spec known_tool?(term()) :: boolean()
  def known_tool?(name), do: name in @known_tools

  @spec known_tools() :: [tool_name()]
  def known_tools, do: @known_tools

  @spec work_request_views() :: [String.t()]
  def work_request_views, do: @work_request_views

  @spec solo_tool_input_schema(tool_name()) :: input_schema()
  defdelegate solo_tool_input_schema(name), to: InputSchemas

  @spec bootstrap_tool_input_schema(tool_name()) :: input_schema()
  defdelegate bootstrap_tool_input_schema(name), to: InputSchemas

  @spec local_operator_tool_input_schema(tool_name()) :: input_schema()
  defdelegate local_operator_tool_input_schema(name), to: InputSchemas

  @spec architect_tool_input_schema(tool_name()) :: input_schema()
  defdelegate architect_tool_input_schema(name), to: InputSchemas

  @spec startup_tool_specs(:full | :architect | :coordinator | :solo, Config.t()) :: [tool_spec()]
  defdelegate startup_tool_specs(profile, config), to: SurfaceSpecs

  @spec lean_tool_specs([tool_spec()]) :: [tool_spec()]
  defdelegate lean_tool_specs(specs), to: SurfaceSpecs

  @spec local_operator_tool_specs() :: [tool_spec()]
  defdelegate local_operator_tool_specs(), to: SurfaceSpecs
end
