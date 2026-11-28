defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog do
  @moduledoc """
  The sympp MCP tools: one list, one schema and one description per tool.
  Every chief, architect or card terminal is served the same surface; workers
  get none, because the bridge serves no tools in a `sympp.role=worker`
  terminal.
  """

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

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
  @tools [
    @health_tool,
    "list_work_requests",
    "read_work_request",
    "create_work_request",
    "complete_work_request",
    "move_work_request",
    "edit_plan",
    "dispatch_work_package",
    "sync_pr",
    "close_work_package",
    "record_decision",
    "ask",
    "resolve_ask",
    "set_blocker",
    "set_report",
    "summarize_failed_mcp_calls"
  ]
  @work_request_views ~w(overview plan board package request ask decision flagged_decisions)
  # Every tool is a write unless listed here. Writes need a Herdr terminal
  # identity; the same split drives the MCP readOnlyHint annotation.
  @read_tools [@health_tool, "list_work_requests", "read_work_request", "summarize_failed_mcp_calls"]
  # Writes that take or confirm ownership of the target WorkRequest. Decisions
  # and WorkRequest creation stay open to any Herdr terminal. Only chiefs open asks.
  @owner_gated_tools ["move_work_request", "edit_plan", "dispatch_work_package", "sync_pr", "close_work_package", "set_blocker", "set_report"]

  @type tool_name :: String.t()
  @type tool_spec :: map()

  @spec health_tool() :: tool_name()
  def health_tool, do: @health_tool

  @spec mcp_contract_schema_version() :: String.t()
  def mcp_contract_schema_version, do: @mcp_contract_schema_version

  @spec mcp_contract_health_fields() :: [String.t()]
  def mcp_contract_health_fields, do: @mcp_contract_health_fields

  @spec tools() :: [tool_name()]
  def tools, do: @tools

  @spec known_tool?(term()) :: boolean()
  def known_tool?(name), do: name in @tools

  @spec work_request_views() :: [String.t()]
  def work_request_views, do: @work_request_views

  @spec tool_access(tool_name()) :: :read | :write
  def tool_access(name) when name in @read_tools, do: :read
  def tool_access(_name), do: :write

  @doc "Whether one call only reads."
  @spec read_call?(tool_name(), map()) :: boolean()
  def read_call?(name, _arguments), do: tool_access(name) == :read

  @doc """
  Whether one call must own the target WorkRequest. A chief may move a request
  without taking ownership. Any chief or architect may finish a package.
  """
  @spec owner_gated_call?(tool_name(), map()) :: boolean()
  def owner_gated_call?(name, arguments), do: owner_gated_call?(name, arguments, nil)

  @spec owner_gated_call?(tool_name(), map(), Terminal.t() | nil) :: boolean()
  def owner_gated_call?("move_work_request", _arguments, %Terminal{role: "chief"}), do: false
  def owner_gated_call?("close_work_package", %{"outcome" => "finished"}, _terminal), do: false
  def owner_gated_call?(name, arguments, _terminal) when is_map(arguments), do: name in @owner_gated_tools

  @spec input_schema(tool_name()) :: map()
  defdelegate input_schema(name), to: InputSchemas

  @doc "The tools/list entries, in catalog order."
  @spec tool_specs() :: [tool_spec()]
  def tool_specs, do: Enum.map(@tools, &tool_spec/1)

  defp tool_spec(name) do
    %{
      "name" => name,
      "description" => description(name),
      "inputSchema" => input_schema(name),
      "annotations" => %{"readOnlyHint" => tool_access(name) == :read}
    }
  end

  defp description(@health_tool),
    do: "Returns server version, ledger reachability and identity, and the caller's Herdr terminal with the WorkRequests it owns."

  defp description("list_work_requests"), do: "List WorkRequests in the ledger, newest first."

  defp description("read_work_request"),
    do:
      "Read WorkRequest status (overview), dependencies (plan), or delivery actions (board). Use request for the brief and constraints, package for one contract, ask or decision for one entry, and flagged_decisions for the review index."

  defp description("create_work_request"),
    do: "Create a WorkRequest. The calling terminal becomes its owner unless own is false."

  defp description("complete_work_request"), do: "Chief only. Mark a WorkRequest done."

  defp description("move_work_request"),
    do:
      "Move a WorkRequest and its open packages in the source repository to another repository. The owner or a chief can move it. GitHub-confirmed renames keep attached PRs. Resolve source PRs before importing. A move to the current repository changes nothing."

  defp description("edit_plan"),
    do: "Edit a WorkRequest plan you own. Returns ordered receipts in applied. See the symphony-architect skill for contract fields."

  defp description("dispatch_work_package"),
    do:
      "Dispatch a planned WorkPackage with a review mode: prepares its factory worktree, writes the worker's assignment file and returns launch_line, the hc run command that starts the worker. Calling it again for a dispatched package reuses the same worktree and review id."

  defp description("sync_pr"),
    do: "The factory watches dispatched packages' PRs, CI, reviews and merges on its own. Use sync_pr to attach a PR it can't find (fork or upstream), or to refresh and qualify now."

  defp description("close_work_package"),
    do:
      "End a WorkPackage without a merge; the factory records merges itself. skipped: a planned package. completed_no_pr: delivered without a PR (evidence). superseded: replaced by successor_work_package_id in the same WorkRequest (rationale). abandoned: dropped (rationale). finished: its PR waits on someone else; any chief or architect may finish, without owning the WorkRequest. Repeating the same close changes nothing; a different close of an ended package is refused with its outcome."

  defp description("record_decision"),
    do:
      "Any Herdr terminal can log a decision. Flag in-scope product calls for operator review. Use one plain sentence each when flagged (decision ≤160 chars, rationale ≤240). Put evidence in the report."

  defp description("ask"),
    do: "Chief only. Omit both IDs for cards. Read answers with read_work_request(view: ask, ask_id) or sympp.health caller.card."

  defp description("resolve_ask"),
    do:
      "Use to: answered only for an answer the operator gave in your conversation. Board answers already resolve the ask. The asker or WorkRequest owner may record a conversational answer or use to: withdrawn. A repeat answer returns the stored answer. decision records a decision when the ask first closes."

  defp description("set_blocker"),
    do:
      "Declare (active: true, with a summary) or clear (active: false) a blocker on a package of a WorkRequest you own. Blockers are keyed by blocker_id; setting the state a blocker already has changes nothing. Ending a package clears its blockers."

  defp description("set_report"),
    do: "Patch the operator report on a WorkRequest you own: brief, eta and parking. null clears a field; clearing parking records that work resumed."

  defp description("summarize_failed_mcp_calls"),
    do: "Count failed sympp tool calls per day, tool, reason and layer, including unknown tools and denied calls. Kept across restarts; arguments are never stored."
end
