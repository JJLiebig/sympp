defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog do
  @moduledoc """
  The sympp MCP tools: one list, one schema and one description per tool.
  Every chief, architect or card terminal is served the same surface; workers
  get none, because the bridge serves no tools in a `sympp.role=worker`
  terminal.
  """

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry

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
  @work_request_views ["overview", "plan", "board", "package"]
  # Every tool is a write unless listed here. Writes need a Herdr terminal
  # identity; the same split drives the MCP readOnlyHint annotation.
  @read_tools [@health_tool, "list_work_requests", "read_work_request", "summarize_failed_mcp_calls"]
  # Writes that take or confirm ownership of the target WorkRequest. Decisions,
  # asks and WorkRequest creation stay open to any Herdr terminal.
  @owner_gated_tools ["edit_plan", "dispatch_work_package", "sync_pr", "close_work_package", "set_blocker", "set_report"]

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
  Whether one call must own the target WorkRequest. Any chief or architect may
  close a package as `finished` without owning it.
  """
  @spec owner_gated_call?(tool_name(), map()) :: boolean()
  def owner_gated_call?("close_work_package", %{"outcome" => "finished"}), do: false
  def owner_gated_call?(name, arguments) when is_map(arguments), do: name in @owner_gated_tools

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
      "Read one WorkRequest in a view: overview (default; phase, asks, package next actions, recent decisions), plan (packages with group paths, dependencies, execution graph), board (delivery state and evidence) or package (one package's contract, revision, dependencies and task plan; needs work_package_id). detail: full returns complete payloads."

  defp description("create_work_request"),
    do: "Create a WorkRequest. The calling terminal becomes its owner unless own is false."

  defp description("edit_plan"),
    do:
      "Edit the plan of a WorkRequest you own in one atomic call: add_package (contract, optional group path such as \"Backend / Billing\", depends_on), update_package (expected_revision and a patch), set_dependency (from depends on to, optional candidate_head_sha) and remove_dependency. Any failing op rolls back the whole edit; the error names the op index, the state and the next action. Returns each op's result and the plan after the edit."

  defp description("dispatch_work_package"),
    do:
      "Dispatch a planned WorkPackage with a review mode: prepares its factory worktree, writes the worker's assignment file and returns launch_line, the hc run command that starts the worker. Calling it again for a dispatched package reuses the same worktree and review id."

  defp description("sync_pr"),
    do:
      "The factory watches dispatched packages' PRs, CI, reviews and merges on its own. Use sync_pr to attach a PR it can't find (fork or upstream), to record which prerequisite inputs the current PR head consumed (dependency_inputs), or to refresh and qualify now."

  defp description("close_work_package"),
    do:
      "End a WorkPackage without a merge; the factory records merges itself. skipped: a planned package. completed_no_pr: delivered without a PR (evidence). superseded: replaced by successor_work_package_id in the same WorkRequest (rationale). abandoned: dropped (rationale). finished: its PR waits on someone else; any chief or architect may finish, without owning the WorkRequest. Repeating the same close changes nothing; a different close of an ended package is refused with its outcome."

  defp description("record_decision"),
    do:
      "Record a durable decision on a WorkRequest; any Herdr terminal may, without owning it. source_type must be one of: #{Enum.join(DecisionLogEntry.source_types(), ", ")}. flag: true asks the operator to review an in-scope product call; they acknowledge it or send feedback."

  defp description("ask"),
    do:
      "Ask the operator a question: it shows as Needs you on the boards until it is answered or withdrawn. Without work_request_id it asks on your own card. Optionally name a package and give a decision_prompt with options. The operator's answer is typed into your terminal without being submitted when it runs on the factory's machine; otherwise read it from the ask with read_work_request detail: full. Asks never block planning or dispatch, and an ask on a package is withdrawn when the package ends."

  defp description("resolve_ask"),
    do:
      "Resolve an open ask you asked, or one on a WorkRequest you own: to: answered records an answer you got in conversation; to: withdrawn takes it back. decision records a decision in the same step."

  defp description("set_blocker"),
    do:
      "Declare (active: true, with a summary) or clear (active: false) a blocker on a package of a WorkRequest you own. Blockers are keyed by blocker_id; setting the state a blocker already has changes nothing. Ending a package clears its blockers."

  defp description("set_report"),
    do: "Patch the operator report on a WorkRequest you own: brief, eta and parking. null clears a field; clearing parking records that work resumed."

  defp description("summarize_failed_mcp_calls"),
    do: "Count failed sympp tool calls per day, tool, reason and layer, including unknown tools and denied calls. Kept across restarts; arguments are never stored."
end
