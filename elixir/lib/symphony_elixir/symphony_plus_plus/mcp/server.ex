defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc """
  The sympp MCP protocol handler.

  Access, per tool call:
  - every trusted caller may read;
  - writes need the Herdr terminal identity the sympp bridge sends in
    `_meta.herdr` (`read_only_outside_herdr` otherwise);
  - owner-gated writes also take or confirm ownership of the target
    WorkRequest through `Ownership` (`owned_by_other_terminal` otherwise).
  """

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      architect_tool_arguments: 2,
      bootstrap_tool_arguments: 2,
      local_operator_tool_arguments: 2,
      optional_list_argument: 2,
      optional_object_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2,
      solo_tool_arguments: 2
    ]

  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectDeliveryTools,
    ArchitectProductTreeTools,
    ArchitectWorkRequestTools,
    BlockerTools,
    Config,
    ErrorDetails,
    FailedCall,
    HandleStateStore,
    Health,
    LocalTrustedTools,
    PackageTools,
    Repository,
    Response,
    SoloTools,
    Surface,
    ToolCatalog,
    ToolResult,
    WorkRequestPayloads
  }

  alias SymphonyElixir.SymphonyPlusPlus.OfflineSandbox
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.OperatorReport
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @protocol_version "2025-03-26"
  @health_tool ToolCatalog.health_tool()
  @solo_tools ToolCatalog.solo_tools()
  @bootstrap_tools ToolCatalog.bootstrap_tools()
  @local_operator_tools ToolCatalog.local_operator_tools()
  @work_request_tools ArchitectWorkRequestTools.tools()
  @product_tree_tools ArchitectProductTreeTools.tools()
  @delivery_tools ArchitectDeliveryTools.tools()
  @package_tools PackageTools.tools()
  @version_resource "sympp://health/version"

  @enforce_keys [:config]
  defstruct [
    :config,
    :state_key,
    :state_key_version,
    local_daemon_trusted: false,
    state_key_explicit: false,
    initialized: false
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          state_key: term(),
          state_key_version: integer() | nil,
          local_daemon_trusted: boolean(),
          state_key_explicit: boolean(),
          initialized: boolean()
        }

  defguardp valid_request_id(id) when is_binary(id) or is_number(id) or is_nil(id)
  defguardp invalid_request_id(id) when not is_binary(id) and not is_number(id) and not is_nil(id)

  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    {state_key, state_key_explicit?} = state_key_option(opts)

    %__MODULE__{
      config: config,
      state_key: state_key,
      state_key_version: nil,
      local_daemon_trusted: Keyword.get(opts, :local_daemon_trusted, config.local_daemon_trusted),
      state_key_explicit: state_key_explicit?,
      initialized: Keyword.get(opts, :initialized, false)
    }
  end

  defp state_key_option(opts) do
    case Keyword.fetch(opts, :state_key) do
      {:ok, state_key} -> explicit_state_key_option(state_key)
      :error -> {make_ref(), false}
    end
  end

  defp explicit_state_key_option(nil), do: {make_ref(), false}

  defp explicit_state_key_option(state_key) when is_binary(state_key) do
    if String.trim(state_key) == "", do: {make_ref(), false}, else: {state_key, true}
  end

  defp explicit_state_key_option(state_key), do: {state_key, true}

  @spec handle(term(), t()) :: map() | [map()] | nil
  def handle(payload, %__MODULE__{} = server) do
    payload
    |> handle_response_state(server)
    |> elem(0)
  end

  @doc false
  @spec mcp_contract_identity() :: map()
  defdelegate mcp_contract_identity, to: Health

  @doc false
  @spec handle_response_state(term(), t()) :: {map() | [map()] | nil, t()}
  def handle_response_state(payload, %__MODULE__{} = server) do
    if OfflineSandbox.enabled?() do
      id = if is_map(payload), do: Map.get(payload, "id")
      {Response.error(id, -32_003, "MCP is disabled in the offline beta sandbox", %{"reason" => "offline_sandbox"}), server}
    else
      HandleStateStore.cleanup_default_handle_states()
      server = HandleStateStore.restore(payload, server)
      {response, updated_server} = handle_state(payload, server)
      {response, HandleStateStore.persist(payload, response, server, updated_server)}
    end
  end

  @spec handle_state(term(), t()) :: {map() | [map()] | nil, t()}
  def handle_state(%{"jsonrpc" => "2.0", "method" => "initialize"} = payload, %__MODULE__{} = server) do
    response = do_handle(payload, server)

    case response do
      %{"result" => _result} -> {response, %{server | initialized: true}}
      _response -> {response, server}
    end
  end

  def handle_state(payloads, %__MODULE__{} = server) when is_list(payloads) do
    cond do
      payloads == [] ->
        {Response.error(nil, -32_600, "Invalid Request", %{"reason" => "empty_batch"}), server}

      Enum.any?(payloads, &initialize_request?/1) ->
        {Response.error(nil, -32_600, "Invalid Request", %{"reason" => "initialize_must_be_standalone"}), server}

      true ->
        responses =
          payloads
          |> Enum.map(&handle_batch_item(&1, server))
          |> Enum.reject(&is_nil/1)

        {if(responses == [], do: nil, else: responses), server}
    end
  end

  def handle_state(%{"jsonrpc" => "2.0", "method" => "tools/call"} = payload, %__MODULE__{initialized: true} = server) do
    id = Map.get(payload, "id")

    response =
      observe_tool_call(payload, server, fn ->
        if Map.has_key?(payload, "id") and invalid_request_id(id),
          do: Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"}),
          else: dispatch_request(request_params(payload), "tools/call", id, server)
      end)

    if Map.has_key?(payload, "id"), do: {response, server}, else: {nil, server}
  end

  def handle_state(%{"jsonrpc" => "2.0", "method" => "tools/call"} = payload, %__MODULE__{} = server),
    do: {observe_tool_call(payload, server, fn -> do_handle(payload, server) end), server}

  def handle_state(payload, %__MODULE__{} = server), do: {do_handle(payload, server), server}

  defp handle_batch_item(payload, %__MODULE__{} = server) when is_map(payload), do: payload |> handle_state(server) |> elem(0)
  defp handle_batch_item(_payload, _server), do: Response.error(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"})

  defp observe_tool_call(payload, %__MODULE__{} = server, fun) when is_function(fun, 0) do
    started_at = FailedCall.monotonic_now()

    FailedCall.protect(server, payload, :tool, started_at, fn ->
      response = fun.()
      {FailedCall.observe_response(server, payload, response, :tool, started_at), server}
    end)
    |> elem(0)
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, %__MODULE__{initialized: false})
       when is_binary(method) and method != "initialize" and valid_request_id(id) do
    Response.error(id, -32_000, "Server error", %{"reason" => "server_not_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize"}, %__MODULE__{initialized: true})
       when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "already_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = request, %__MODULE__{} = server)
       when is_binary(method) and valid_request_id(id) do
    request
    |> request_params()
    |> dispatch_request(method, id, server)
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => "initialize"}, %__MODULE__{}) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "initialize_requires_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => method} = notification, %__MODULE__{}) when is_binary(method) do
    if Map.has_key?(notification, "id") do
      Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
    end
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(%{"jsonrpc" => version, "id" => id}, %__MODULE__{}) when version != "2.0" and valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"jsonrpc" => version}, %__MODULE__{}) when version != "2.0" do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(_payload, %__MODULE__{}) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"})
  end

  defp dispatch_request({:ok, params}, method, id, %__MODULE__{} = server) do
    case ToolResult.with_text_profile(response_text_profile(server), fn -> dispatch(method, params, server) end) do
      {:ok, result} -> Response.response(id, result)
      {:error, code, message, data} -> Response.error(id, code, message, data)
    end
  end

  defp dispatch_request({:error, code, message, data}, _method, id, %__MODULE__{}), do: Response.error(id, code, message, data)

  defp dispatch(
         "initialize",
         %{"protocolVersion" => protocol_version, "clientInfo" => client_info, "capabilities" => capabilities},
         %__MODULE__{config: config}
       )
       when is_binary(protocol_version) and is_map(client_info) and is_map(capabilities) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{}, "resources" => %{}},
       "serverInfo" => %{"name" => "sympp", "version" => config.version}
     }}
  end

  defp dispatch("initialize", %{"protocolVersion" => protocol_version}, _server) when is_binary(protocol_version) do
    {:error, -32_602, "Invalid params", %{"reason" => "invalid_initialize_params"}}
  end

  defp dispatch("initialize", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_protocol_version", "supported" => @protocol_version}}
  end

  defp dispatch("tools/list", params, %__MODULE__{} = server) when is_map(params) do
    {:ok, %{"tools" => Surface.tool_specs(server.config)}}
  end

  defp dispatch("tools/list", _params, _server), do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    cond do
      not is_map(arguments) -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
      name not in Surface.tool_names(server.config) -> {:error, -32_601, "Method not found", %{"tool" => name}}
      name == @health_tool and arguments != %{} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
      name == @health_tool -> {:ok, ToolResult.tool_result(Health.health(server, Terminal.from_params(params)))}
      true -> call_tool(name, params, arguments, Terminal.from_params(params), server)
    end
  end

  defp dispatch("tools/call", params, _server) when is_map(params), do: {:error, -32_602, "Invalid params", %{"reason" => "missing_tool_name"}}
  defp dispatch("tools/call", _params, _server), do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}

  defp dispatch("resources/list", params, _server) when is_map(params), do: {:ok, %{"resources" => Surface.resource_specs()}}
  defp dispatch("resources/list", _params, _server), do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}

  defp dispatch("resources/read", %{"uri" => @version_resource}, %__MODULE__{config: %Config{} = config}) do
    payload = %{"version" => config.version, "source" => Health.source_identity(config), "mode" => Atom.to_string(config.mode)}
    {:ok, Response.json_resource(@version_resource, payload)}
  end

  defp dispatch("resources/read", %{"uri" => "sympp://work-packages/" <> rest = uri}, %__MODULE__{config: config} = server) do
    with :ok <- LocalTrustedTools.authorize(server, uri),
         :ok <- prepare_repository(config.repo, uri) do
      case Surface.work_package_resource_id(rest) do
        {:ok, work_package_id, file_name} -> Surface.read_work_package_virtual_resource(config.repo, work_package_id, file_name, uri)
        :error -> {:error, -32_602, "Invalid params", %{"resource" => uri, "reason" => "invalid_work_package_resource_uri"}}
      end
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, _server) when is_binary(uri), do: {:error, -32_601, "Method not found", %{"resource" => uri}}
  defp dispatch("resources/read", _params, _server), do: {:error, -32_602, "Invalid params", %{"reason" => "missing_resource_uri"}}
  defp dispatch(_method, _params, _server), do: {:error, -32_601, "Method not found", %{}}

  # Solo tools keep their own transport rules until cards replace them.
  defp call_tool(name, params, arguments, terminal, server) when name in @solo_tools do
    with :ok <- require_write_identity(name, arguments, terminal),
         {:ok, arguments} <- solo_tool_arguments(params, name) do
      SoloTools.call(name, arguments, server.config, &tool_error/2)
    end
  end

  defp call_tool(name, params, arguments, terminal, %__MODULE__{config: config} = server) do
    with :ok <- LocalTrustedTools.authorize(server, name),
         :ok <- require_write_identity(name, arguments, terminal),
         :ok <- prepare_repository(config.repo, name),
         {:ok, arguments} <- tool_arguments(name, params) do
      if ToolCatalog.owner_gated_call?(name, arguments),
        do: owner_gated(name, arguments, terminal, server),
        else: run(name, arguments, terminal, server)
    end
  end

  defp owner_gated(name, arguments, %Terminal{} = terminal, %__MODULE__{config: config} = server) do
    case target_work_request_id(config.repo, arguments) do
      {:ok, work_request_id} ->
        arguments = Map.put(arguments, "work_request_id", work_request_id)

        config.repo
        |> Ownership.gated(work_request_id, terminal, fn -> run(name, arguments, terminal, server) end)
        |> ownership_result(name)

      {:error, :missing_target} ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "missing_work_request_id"}}

      {:error, :not_found} ->
        not_found_error(name)
    end
  end

  defp target_work_request_id(repo, %{"work_request_id" => id}) when is_binary(id) and id != "" do
    case WorkRequestService.get(repo, id) do
      {:ok, %WorkRequest{id: id}} -> {:ok, id}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp target_work_request_id(repo, %{"work_package_id" => id}) when is_binary(id) and id != "" do
    case WorkPackageRepository.get(repo, id) do
      {:ok, %{work_request_id: work_request_id}} when is_binary(work_request_id) -> {:ok, work_request_id}
      _missing -> {:error, :not_found}
    end
  end

  defp target_work_request_id(_repo, _arguments), do: {:error, :missing_target}

  defp ownership_result({:error, {:owned_by_other_terminal, owner}}, name) do
    {:error, -32_003, "Forbidden",
     %{
       "tool" => name,
       "reason" => "owned_by_other_terminal",
       "state" => "owned",
       "owner" => Map.delete(owner, "next_action"),
       "next_action" => owner["next_action"]
     }}
  end

  defp ownership_result({:error, :not_found}, name), do: not_found_error(name)

  defp ownership_result({:error, :work_request_archived}, name),
    do: {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "work_request_archived", "state" => "archived", "next_action" => "restore"}}

  defp ownership_result({:error, :database_busy}, name),
    do: {:error, -32_000, "Ledger busy", %{"tool" => name, "reason" => "database_busy", "remediation" => "Another ledger writer held the lock. Retry the call."}}

  defp ownership_result({:error, reason}, name) when is_atom(reason) or is_tuple(reason), do: service_error(name)
  defp ownership_result(result, _name), do: result

  defp run(name, arguments, terminal, %__MODULE__{config: config}) when name in @work_request_tools,
    do: ArchitectWorkRequestTools.call(name, config, terminal, arguments)

  defp run(name, arguments, terminal, %__MODULE__{config: config}) when name in @product_tree_tools,
    do: ArchitectProductTreeTools.call(name, config, terminal, arguments)

  defp run(name, arguments, terminal, %__MODULE__{config: config}) when name in @delivery_tools,
    do: ArchitectDeliveryTools.call(name, config, terminal, arguments)

  defp run(name, arguments, terminal, %__MODULE__{config: config}) when name in @package_tools,
    do: PackageTools.call(name, config, terminal, arguments)

  defp run("resolve_blocker", arguments, terminal, %__MODULE__{config: config}),
    do: BlockerTools.call("resolve_blocker", config, terminal, arguments)

  defp run("set_report", arguments, _terminal, %__MODULE__{config: config}) do
    case OperatorReport.set(config.repo, Map.fetch!(arguments, "work_request_id"), arguments) do
      {:ok, %WorkRequest{} = work_request} ->
        {:ok, ToolResult.tool_result(%{"work_request_id" => work_request.id, "report" => OperatorReport.public(work_request.report)})}

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "set_report", "reason" => reason}}

      {:error, :not_found} ->
        not_found_error("set_report")

      {:error, _reason} ->
        service_error("set_report")
    end
  end

  defp run("create_work_request", arguments, terminal, %__MODULE__{config: config}) do
    with {:ok, attrs} <- create_work_request_attrs(arguments, terminal),
         {:ok, own?} <- own_argument(arguments),
         {:ok, work_request} <- WorkRequestService.create(config.repo, attrs) do
      {:ok, ToolResult.tool_result(create_work_request_payload(config.repo, work_request, terminal, own?))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason}}
      {:error, reason} -> create_work_request_error(reason)
    end
  end

  defp run("summarize_failed_mcp_calls", _arguments, _terminal, %__MODULE__{config: config}),
    do: {:ok, ToolResult.tool_result(LocalTrustedTools.failed_call_summary(config))}

  defp run("record_work_request_operator_decision", arguments, terminal, %__MODULE__{config: config}) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", terminal.display_address),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id"),
         {:ok, work_request} <- WorkRequestService.get(config.repo, work_request_id),
         {:ok, decision_record} <-
           WorkRequestService.record_decision(config.repo, work_request.id, operator_decision_attrs(decision, rationale, scope_impact, created_by, source_id)) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
         "provenance" => operator_note_provenance(created_by, source_id),
         "status" => %{"work_request_status" => work_request.status}
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "record_work_request_operator_decision", "reason" => reason}}
      {:error, :not_found} -> not_found_error("record_work_request_operator_decision")
      {:error, _reason} -> service_error("record_work_request_operator_decision")
    end
  end

  defp tool_arguments(name, params) when name in @bootstrap_tools, do: bootstrap_tool_arguments(params, name)
  defp tool_arguments(name, params) when name in @local_operator_tools, do: local_operator_tool_arguments(params, name)
  defp tool_arguments(name, params), do: architect_tool_arguments(params, name)

  # Reads are open to every trusted caller. Writes need a bridge-asserted Herdr
  # terminal; when the factory's own herdr-core can see that terminal, it must
  # not have finished.
  defp require_write_identity(name, arguments, terminal) do
    cond do
      ToolCatalog.read_call?(name, arguments) ->
        :ok

      is_nil(terminal) ->
        {:error, -32_001, "Unauthorized",
         %{
           "tool" => name,
           "reason" => "read_only_outside_herdr",
           "message" => "Writes need a Herdr terminal identity from the sympp bridge. Run this agent in a Herdr terminal; reads still work here."
         }}

      HerdrCore.view(terminal.core_id, terminal.address) == :finished ->
        {:error, -32_001, "Unauthorized", %{"tool" => name, "reason" => "terminal_not_live"}}

      true ->
        :ok
    end
  end

  defp create_work_request_attrs(arguments, terminal) do
    with {:ok, repo} <- required_argument(arguments, "repo"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, request_kind} <- required_argument(arguments, "request_kind"),
         {:ok, description} <- required_argument(arguments, "description"),
         {:ok, workflow_mode} <- optional_string_argument(arguments, "workflow_mode", "architect_led_feature_branch"),
         {:ok, repo_scopes} <- optional_list_argument(arguments, "repo_scopes"),
         {:ok, constraints} <- optional_object_argument(arguments, "constraints"),
         {:ok, status} <- optional_string_argument(arguments, "status", "ready_for_clarification"),
         {:ok, creator_kind} <- optional_string_argument(arguments, "creator_kind", "agent"),
         {:ok, creator_name} <- optional_string_argument(arguments, "creator_name", terminal.display_address),
         {:ok, created_via} <- optional_string_argument(arguments, "created_via", "mcp") do
      {:ok,
       %{
         "repo" => repo,
         "base_branch" => base_branch,
         "title" => title,
         "work_type" => request_kind,
         "human_description" => description,
         "desired_dispatch_shape" => workflow_mode,
         "repo_scopes" => repo_scopes || [],
         "constraints" => constraints || %{},
         "status" => status,
         "creator_kind" => creator_kind,
         "creator_name" => creator_name,
         "created_via" => created_via,
         "dispatched_by" => Terminal.attribution(terminal)
       }}
    end
  end

  defp own_argument(arguments) do
    case Map.get(arguments, "own", true) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:tool_error, "invalid_own"}
    end
  end

  defp create_work_request_payload(repo, %WorkRequest{} = work_request, terminal, true) do
    case Ownership.acquire(repo, work_request.id, terminal) do
      {:ok, row, _how} ->
        %{"status" => "created", "work_request" => WorkRequestPayloads.work_request(work_request), "worked_on" => Ownership.public(row)}

      {:error, _reason} ->
        %{"status" => "created", "work_request" => WorkRequestPayloads.work_request(work_request)}
    end
  end

  defp create_work_request_payload(_repo, %WorkRequest{} = work_request, _terminal, false) do
    %{
      "status" => "created",
      "work_request" => WorkRequestPayloads.work_request(work_request),
      "next_action" => "hand #{work_request.id} to an architect; its first plan write makes it the owner"
    }
  end

  defp create_work_request_error(%Ecto.Changeset{} = changeset),
    do: ErrorDetails.changeset_invalid_params_error("create_work_request", "invalid_work_request", changeset)

  defp create_work_request_error(:id_already_exists),
    do: {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => "id_already_exists"}}

  defp create_work_request_error(reason) when reason == :database_busy or (is_tuple(reason) and elem(reason, 0) == :storage_failed),
    do: service_error("create_work_request")

  defp create_work_request_error(reason),
    do: {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason_text(reason)}}

  defp operator_decision_attrs(decision, rationale, scope_impact, created_by, source_id) do
    %{
      "source_type" => "operator",
      "decision" => Redactor.redact_text(decision),
      "rationale" => Redactor.redact_text(rationale),
      "scope_impact" => Redactor.redact_text(scope_impact),
      "created_by" => Redactor.redact_text(created_by)
    }
    |> optional_put("source_id", Redactor.redact_text(source_id))
  end

  defp operator_note_provenance(created_by, source_id) do
    %{"source_type" => "operator", "created_by" => Redactor.redact_text(created_by)}
    |> optional_put("source_id", Redactor.redact_text(source_id))
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp prepare_repository(repo, resource) do
    case Repository.ensure_migrated(repo) do
      :ok -> :ok
      {:error, _reason} -> service_error(resource)
    end
  end

  defp tool_error(:database_busy, tool), do: service_error(tool)
  defp tool_error({:storage_failed, _reason}, tool), do: service_error(tool)
  defp tool_error({:migration_failed, _reason}, tool), do: service_error(tool)
  defp tool_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp not_found_error(tool), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  defp service_error(resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp request_params(%{"params" => params}) when is_map(params), do: {:ok, params}
  defp request_params(%{"params" => params}) when is_list(params), do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  defp request_params(%{"params" => _params}), do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object_or_array"}}
  defp request_params(_request), do: {:ok, %{}}

  defp response_text_profile(%__MODULE__{config: %Config{mode: :stdio, surface_profile: :full}}), do: :full
  defp response_text_profile(%__MODULE__{}), do: :canonical

  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false
end
