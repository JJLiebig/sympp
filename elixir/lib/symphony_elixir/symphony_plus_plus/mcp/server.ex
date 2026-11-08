defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      architect_tool_arguments: 2,
      assignment_release_tool_arguments: 1,
      bootstrap_tool_arguments: 2,
      local_operator_tool_arguments: 2,
      optional_list_argument: 2,
      optional_object_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2,
      solo_tool_arguments: 2,
      worker_tool_arguments: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads, only: [json_safe_payload: 1]

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Chiefs

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectDeliveryTools,
    ArchitectProductTreeTools,
    ArchitectWorkRequestTools,
    Auth,
    BlockerTools,
    Config,
    ErrorDetails,
    FailedCall,
    HandleStateStore,
    HandoffDatabase,
    Health,
    LocalAssignmentClaims,
    LocalTrustedTools,
    Payloads,
    Repository,
    Response,
    Session,
    SessionBindingTools,
    SoloTools,
    Surface,
    TaskPlanTools,
    ToolCatalog,
    ToolResult,
    WorkerTools,
    WorkRequestPayloads
  }

  alias SymphonyElixir.SymphonyPlusPlus.OfflineSandbox
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.SessionLocations
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @protocol_version "2025-03-26"
  @health_tool ToolCatalog.health_tool()
  @solo_tools ToolCatalog.solo_tools()
  @assignment_release_tool ToolCatalog.assignment_release_tool()
  @local_operator_tools ToolCatalog.local_operator_tools()
  # Reads whose handlers can serve a trusted session without its binding.
  @session_free_read_tools ["list_work_requests", "read_work_request", "read_plan", "read_delivery_board"]
  @trusted_target_read_tools ["read_task_plan", "reconcile_work_request"]
  @explicit_read_target_keys ["work_request_id", "work_package_id"]
  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()
  @local_architect_assignment_claim_tool ToolCatalog.local_architect_assignment_claim_tool()
  @session_claim_tools ToolCatalog.session_claim_tools()
  @worker_tools ToolCatalog.worker_tools()
  @worker_tool_module_tools WorkerTools.tools()
  @architect_tools ToolCatalog.architect_tools()
  @architect_planning_tools ToolCatalog.architect_planning_tools()
  @architect_work_request_tools ArchitectWorkRequestTools.tools()
  @architect_product_tree_tools ArchitectProductTreeTools.tools()
  @delivery_policy_tools ToolCatalog.delivery_policy_tools()
  @version_resource "sympp://health/version"
  @assignment_resource "sympp://assignment/current"
  @enforce_keys [:config]
  defstruct [
    :config,
    :session,
    :state_key,
    :state_key_version,
    :stale_architect_claim,
    :client_location,
    batch_claim_pending: false,
    local_daemon_trusted: false,
    state_key_explicit: false,
    session_refresh_required: false,
    stale_assignment_role: nil,
    initialized: false
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          session: Session.t() | nil,
          state_key: term(),
          state_key_version: integer() | nil,
          stale_architect_claim: map() | nil,
          client_location: map() | nil,
          batch_claim_pending: boolean(),
          local_daemon_trusted: boolean(),
          state_key_explicit: boolean(),
          session_refresh_required: boolean(),
          stale_assignment_role: String.t() | nil,
          initialized: boolean()
        }

  defguardp valid_request_id(id) when is_binary(id) or is_number(id) or is_nil(id)
  defguardp invalid_request_id(id) when not is_binary(id) and not is_number(id) and not is_nil(id)

  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    {state_key, state_key_explicit?} = state_key_option(opts)

    %__MODULE__{
      config: config,
      session: Keyword.get(opts, :session),
      state_key: state_key,
      state_key_version: nil,
      stale_architect_claim: Keyword.get(opts, :stale_architect_claim),
      local_daemon_trusted: Keyword.get(opts, :local_daemon_trusted, config.local_daemon_trusted),
      state_key_explicit: state_key_explicit?,
      session_refresh_required: false,
      stale_assignment_role: Keyword.get(opts, :stale_assignment_role),
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
  @spec mcp_timestamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  defdelegate mcp_timestamp(timestamp), to: Payloads

  @doc false
  @spec handle_response_state(term(), t()) :: {map() | [map()] | nil, t()}
  def handle_response_state(payload, %__MODULE__{} = server) do
    if OfflineSandbox.enabled?() do
      id = if is_map(payload), do: Map.get(payload, "id")
      {Response.error(id, -32_003, "MCP is disabled in the offline beta sandbox", %{"reason" => "offline_sandbox"}), server}
    else
      handle_online_response_state(payload, server)
    end
  end

  defp handle_online_response_state(payload, server) do
    HandleStateStore.cleanup_default_handle_states()
    server = HandleStateStore.restore(payload, server)
    {response, updated_server} = handle_state(payload, server)
    updated_server = SessionLocations.observe(payload, response, updated_server)
    updated_server = HandleStateStore.persist(payload, response, server, updated_server)
    {response, updated_server}
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
        handle_batch(payloads, server)
    end
  end

  def handle_state(
        %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"} = payload,
        %__MODULE__{initialized: true} = server
      )
      when valid_request_id(id) do
    observe_tool_call(payload, server, fn ->
      payload
      |> request_params()
      |> handle_tool_call_request(id, server)
    end)
  end

  def handle_state(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"} = payload, %__MODULE__{initialized: true} = server)
      when invalid_request_id(id) do
    observe_tool_call(payload, server, fn -> {do_handle(payload, server), server} end)
  end

  def handle_state(%{"jsonrpc" => "2.0", "method" => "tools/call"} = payload, %__MODULE__{initialized: true} = server) do
    {_response, updated_server} =
      observe_tool_call(payload, server, fn ->
        payload
        |> request_params()
        |> handle_tool_call_request(nil, server)
      end)

    {nil, updated_server}
  end

  def handle_state(%{"jsonrpc" => "2.0", "method" => "tools/call"} = payload, %__MODULE__{} = server),
    do: observe_tool_call(payload, server, fn -> {do_handle(payload, server), server} end)

  def handle_state(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload, %__MODULE__{initialized: true} = server)
      when is_binary(method) and valid_request_id(id) do
    payload
    |> request_params()
    |> dispatch_request_state(method, id, server)
  end

  def handle_state(payload, %__MODULE__{} = server), do: {do_handle(payload, server), server}

  defp handle_tool_call_request({:ok, %{"name" => name} = params}, id, %__MODULE__{} = server)
       when name in @session_claim_tools do
    {:ok, specs} = Surface.tool_specs_for_server(server)

    if Enum.any?(specs, &(&1["name"] == name)) and session_claim_tool_allowed?(name, server) do
      handle_session_claim_tool(name, params, id, server)
    else
      error = {:error, -32_601, "Method not found", %{"tool" => name, "reason" => "tool_not_callable"}}
      dispatch_request_state(error, "tools/call", id, server)
    end
  end

  defp handle_tool_call_request({:ok, %{"name" => @assignment_release_tool} = params}, id, %__MODULE__{} = server),
    do: handle_assignment_release_tool(params, id, server)

  defp handle_tool_call_request(params_result, id, %__MODULE__{} = server),
    do: dispatch_request_state(params_result, "tools/call", id, server)

  defp session_claim_tool_allowed?(_name, %__MODULE__{session: nil, stale_assignment_role: nil}), do: true

  defp session_claim_tool_allowed?(@local_assignment_claim_tool, %__MODULE__{
         session: %Session{assignment: %{grant_role: "worker"}}
       }),
       do: true

  defp session_claim_tool_allowed?(@local_assignment_claim_tool, %__MODULE__{session: nil, stale_assignment_role: "worker"}), do: true

  defp session_claim_tool_allowed?(@local_architect_assignment_claim_tool, %__MODULE__{
         session: %Session{assignment: %{grant_role: "architect"}}
       }),
       do: true

  defp session_claim_tool_allowed?(@local_architect_assignment_claim_tool, %__MODULE__{session: nil, stale_assignment_role: "architect"}), do: true
  defp session_claim_tool_allowed?(_name, %__MODULE__{}), do: false

  defp observe_tool_call(payload, %__MODULE__{} = server, fun) when is_function(fun, 0) do
    started_at = FailedCall.monotonic_now()

    FailedCall.protect(server, payload, :tool, started_at, fn ->
      {response, updated_server} = fun.()
      {FailedCall.observe_response(server, payload, response, :tool, started_at), updated_server}
    end)
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when invalid_request_id(id) do
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

  defp do_handle(%{"jsonrpc" => "2.0", "id" => _id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
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

  defp handle_batch(payloads, %__MODULE__{} = server) do
    {items, {_claimed?, updated_server, claimed_server}} =
      Enum.map_reduce(payloads, {false, server, nil}, &handle_batch_claim_state/2)

    responses =
      items
      |> Enum.map(fn {_payload, {response, _server}} -> response end)
      |> Enum.reject(&is_nil/1)

    {if(responses == [], do: nil, else: responses), claimed_server || updated_server}
  end

  defp handle_batch_claim_state(payload, {true, %__MODULE__{} = current_server, claimed_server} = claim_state) do
    if batch_session_claim_request?(payload, current_server) do
      item = handle_batch_item(payload, claimed_server || current_server)
      {_response, %__MODULE__{} = item_server} = item

      claimed_server =
        if batch_session_claim_success?(item, claimed_server || current_server),
          do: item_server,
          else: claimed_server

      {{payload, item}, {true, current_server, claimed_server}}
    else
      handle_unblocked_batch_item(payload, claim_state)
    end
  end

  defp handle_batch_claim_state(payload, claim_state) do
    handle_unblocked_batch_item(payload, claim_state)
  end

  defp handle_unblocked_batch_item(payload, {claimed?, %__MODULE__{} = current_server, claimed_server}) do
    item = handle_batch_item(payload, %{current_server | batch_claim_pending: claimed?})
    {response, %__MODULE__{} = item_server} = item
    item_server = %{item_server | batch_claim_pending: current_server.batch_claim_pending}
    item = {response, item_server}

    claim_succeeded? =
      (batch_session_claim_request?(payload, current_server) and batch_session_claim_success?(item, current_server)) or
        (is_nil(current_server.session) and match?(%Session{}, item_server.session))

    updated_server =
      if claim_succeeded? do
        current_server
      else
        if batch_server_state_changed?(current_server, item_server), do: item_server, else: current_server
      end

    claimed_server = if claim_succeeded?, do: item_server, else: claimed_server

    {{payload, item}, {claimed? or claim_succeeded?, updated_server, claimed_server}}
  end

  defp batch_server_state_changed?(%__MODULE__{} = server, %__MODULE__{} = updated_server) do
    server.initialized != updated_server.initialized or
      server.client_location != updated_server.client_location or
      server.session != updated_server.session or
      server.session_refresh_required != updated_server.session_refresh_required or
      server.stale_assignment_role != updated_server.stale_assignment_role
  end

  defp batch_session_claim_success?(
         {%{"result" => %{"structuredContent" => %{"assignment" => _assignment}}}, %__MODULE__{}},
         %__MODULE__{}
       ),
       do: true

  defp batch_session_claim_success?({nil, %__MODULE__{session: %Session{} = updated_session}}, %__MODULE__{session: original_session}) do
    original_session == nil or updated_session != original_session
  end

  defp batch_session_claim_success?(_item, %__MODULE__{}), do: false

  defp batch_session_claim_request?(
         %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name}},
         %__MODULE__{initialized: true}
       )
       when name in @session_claim_tools and valid_request_id(id),
       do: true

  defp batch_session_claim_request?(%{"jsonrpc" => "2.0", "id" => _id, "method" => "tools/call"}, %__MODULE__{initialized: true}),
    do: false

  defp batch_session_claim_request?(
         %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"name" => name}},
         %__MODULE__{initialized: true}
       )
       when name in @session_claim_tools,
       do: true

  defp batch_session_claim_request?(_payload, %__MODULE__{}), do: false

  defp dispatch(
         "initialize",
         %{"protocolVersion" => protocol_version, "clientInfo" => client_info, "capabilities" => capabilities},
         %__MODULE__{config: config}
       )
       when is_binary(protocol_version) and is_map(client_info) and is_map(capabilities) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{
         "tools" => %{},
         "resources" => %{}
       },
       "serverInfo" => %{
         "name" => "sympp",
         "version" => config.version
       }
     }}
  end

  defp dispatch(
         "initialize",
         %{"protocolVersion" => protocol_version, "clientInfo" => client_info, "capabilities" => capabilities},
         _server
       )
       when is_binary(protocol_version) and (not is_map(client_info) or not is_map(capabilities)) do
    {:error, -32_602, "Invalid params", %{"reason" => "invalid_initialize_params"}}
  end

  defp dispatch("initialize", %{"protocolVersion" => protocol_version}, _server) when is_binary(protocol_version) do
    {:error, -32_602, "Invalid params", %{"reason" => "invalid_initialize_params"}}
  end

  defp dispatch("initialize", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_protocol_version", "supported" => @protocol_version}}
  end

  defp dispatch("tools/list", params, %__MODULE__{} = server) when is_map(params) do
    {:ok, tools} = Surface.tool_specs_for_server(server)
    {:ok, %{"tools" => tools}}
  end

  defp dispatch("tools/list", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("tools/call", %{"name" => @health_tool} = params, %__MODULE__{} = server) do
    case Map.get(params, "arguments", %{}) do
      arguments when arguments == %{} ->
        result = Health.health(server)

        {:ok, ToolResult.tool_result(result)}

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => @health_tool, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @solo_tools do
    with :ok <- authorize_solo_tool_call(server, name),
         {:ok, arguments} <- solo_tool_arguments(params, name) do
      solo_tool(name, arguments, server)
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @local_assignment_claim_tool} = params, %__MODULE__{} = server) do
    case claim_local_assignment(params, server) do
      {:ok, result, session} ->
        updated_server = bind_session(server, session)
        {:ok, ToolResult.claim_tool_result(result), updated_server}

      {:error, code, message, data} ->
        {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @local_architect_assignment_claim_tool} = params, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, result, session} ->
        updated_server = bind_session(server, session)
        {:ok, ToolResult.claim_tool_result(result), updated_server}

      {:error, code, message, data} ->
        {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @assignment_release_tool} = params, %__MODULE__{} = server) do
    with {:ok, arguments} <- prepare_assignment_release_tool_call(server, params),
         {:ok, result, updated_server} <- release_current_assignment(arguments, server) do
      {:ok, ToolResult.release_tool_result(result), updated_server}
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> invalid_params_error(@assignment_release_tool, reason)
    end
  end

  defp dispatch("tools/call", %{"name" => "get_current_assignment"} = params, %__MODULE__{} = server) do
    with {:ok, _arguments} <- worker_tool_arguments(params, "get_current_assignment"),
         {:ok, result, updated_server} <- SessionBindingTools.get_current_assignment(server) do
      {:ok, ToolResult.agent_tool_result(result), updated_server}
    else
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "get_current_assignment")
    end
  end

  defp dispatch("tools/call", %{"name" => "register_chief"}, %__MODULE__{session: %Session{assignment: %{grant_role: "worker"}}}) do
    auth_error({:unauthorized, :architect_grant_required}, "register_chief")
  end

  defp dispatch("tools/call", %{"name" => "register_chief"}, %__MODULE__{config: %{surface_profile: profile}}) when profile in [:worker, :solo] do
    auth_error({:unauthorized, :architect_grant_required}, "register_chief")
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in ["create_work_request", "register_chief"] do
    case prepare_bootstrap_tool_call(server, params, name) do
      {:ok, arguments} -> bootstrap_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @local_operator_tools do
    case prepare_local_operator_tool_call(server, params, name) do
      {:ok, arguments} -> local_operator_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch(
         "tools/call",
         %{"name" => name} = params,
         %__MODULE__{session: %Session{assignment: %{grant_role: "architect"}}} = server
       )
       when name in ["resolve_blocker", "attach_branch", "sync_pr"] or
              name in @architect_planning_tools do
    case prepare_architect_tool_call(server, params, name) do
      {:ok, arguments} -> architect_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @worker_tools do
    case prepare_worker_tool_call(server, params, name) do
      {:ok, arguments} -> worker_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @architect_tools do
    case prepare_architect_tool_call(server, params, name) do
      {:ok, arguments} -> architect_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name}, _server) when is_binary(name) do
    {:error, -32_601, "Method not found", %{"tool" => name}}
  end

  defp dispatch("tools/call", params, _server) when is_map(params) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_tool_name"}}
  end

  defp dispatch("tools/call", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/list", params, %__MODULE__{config: config, session: session}) when is_map(params) do
    case Surface.resource_specs_for_session(session, config.repo) do
      {:ok, resources} -> {:ok, %{"resources" => resources}}
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("resources/list", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/read", %{"uri" => @version_resource}, %__MODULE__{config: %Config{} = config}) do
    payload = %{
      "version" => config.version,
      "source" => Health.source_identity(config),
      "mode" => Atom.to_string(config.mode)
    }

    {:ok, Response.json_resource(@version_resource, payload)}
  end

  defp dispatch("resources/read", %{"uri" => @assignment_resource}, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_assignment_introspection(session.assignment) do
      {:ok, Response.json_resource(@assignment_resource, Session.public_assignment(session))}
    else
      {:error, :unsupported_grant_role} -> auth_error({:unauthorized, :unsupported_grant_role}, @assignment_resource)
      {:error, reason} -> auth_error(reason, @assignment_resource)
    end
  end

  defp dispatch("resources/read", %{"uri" => "sympp://work-packages/" <> rest = uri}, %__MODULE__{
         config: config,
         session: session
       }) do
    case Surface.work_package_resource_id(rest) do
      {:ok, work_package_id, file_name} ->
        Surface.read_work_package_virtual_resource(config.repo, session, work_package_id, file_name, uri)

      :error ->
        {:error, -32_602, "Invalid params", %{"resource" => uri, "reason" => "invalid_work_package_resource_uri"}}
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, _server) when is_binary(uri) do
    {:error, -32_601, "Method not found", %{"resource" => uri}}
  end

  defp dispatch("resources/read", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_resource_uri"}}
  end

  defp dispatch(_method, _params, _server) do
    {:error, -32_601, "Method not found", %{}}
  end

  defp handle_assignment_release_tool(params, id, %__MODULE__{} = server) do
    case prepare_assignment_release_tool_call(server, params) do
      {:ok, arguments} ->
        case release_current_assignment(arguments, server) do
          {:ok, result, updated_server} ->
            tool_result = build_release_tool_result(server, result)
            {Response.response(id, tool_result), updated_server}

          {:tool_error, reason} ->
            {:error, code, message, data} = invalid_params_error(@assignment_release_tool, reason)
            {Response.error(id, code, message, data), server}
        end

      {:error, code, message, data} ->
        {Response.error(id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_assignment(params, server) do
      {:ok, result, session} ->
        updated_server = bind_session(server, session)

        tool_result =
          build_tool_result(server, fn ->
            ToolResult.claim_tool_result(result)
          end)

        {
          Response.response(id, tool_result),
          updated_server
        }

      {:error, code, message, data} ->
        {Response.error(id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_architect_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, result, session} ->
        updated_server = bind_session(server, session)

        tool_result =
          build_tool_result(server, fn ->
            ToolResult.claim_tool_result(result)
          end)

        {
          Response.response(id, tool_result),
          updated_server
        }

      {:error, code, message, data} ->
        {Response.error(id, code, message, data), server}
    end
  end

  defp claim_local_assignment(params, %__MODULE__{} = server) do
    LocalAssignmentClaims.claim_local_assignment(params, server, local_assignment_claim_callbacks())
  end

  defp claim_local_architect_assignment(params, %__MODULE__{} = server) do
    LocalAssignmentClaims.claim_local_architect_assignment(params, server, local_assignment_claim_callbacks())
  end

  defp local_assignment_claim_callbacks do
    %{
      current_assignment_summary: &current_assignment_summary/2,
      release_current_assignment: &release_current_assignment/2,
      create_work_request_handoff_opts: &create_work_request_handoff_opts/2
    }
  end

  defp require_local_assignment_claim_mode(%__MODULE__{initialized: false}), do: {:error, :local_mcp_session_required}

  defp require_local_assignment_claim_mode(%__MODULE__{
         config: %Config{mode: :http, local_daemon_trusted: true} = config,
         local_daemon_trusted: true,
         state_key_explicit: true
       }) do
    LocalTrustedTools.require_database(config)
  end

  defp require_local_assignment_claim_mode(%__MODULE__{config: %Config{mode: :http}, state_key_explicit: false}),
    do: {:error, :local_mcp_session_required}

  defp require_local_assignment_claim_mode(%__MODULE__{config: %Config{mode: :http}}), do: {:error, :local_daemon_trust_required}

  defp require_local_assignment_claim_mode(%__MODULE__{}), do: :ok

  defp require_local_architect_assignment_claim_mode(%__MODULE__{config: config} = server) do
    with :ok <- require_local_assignment_claim_mode(server) do
      LocalTrustedTools.require_database(config)
    end
  end

  defp require_assignment_introspection(%{grant_role: role}) when role in ["worker", "architect"], do: :ok
  defp require_assignment_introspection(_assignment), do: {:error, :unsupported_grant_role}

  defp prepare_worker_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- require_worker_tool_binding(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name) do
      worker_tool_arguments(params, name)
    end
  end

  defp prepare_architect_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- require_architect_tool_binding(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name) do
      if name in @delivery_policy_tools do
        {:ok, Map.get(params, "arguments", %{})}
      else
        architect_tool_arguments_for_binding(server, params, name)
      end
    end
  end

  defp architect_tool_arguments_for_binding(%__MODULE__{} = server, params, name) do
    case architect_tool_arguments(params, name) do
      {:error, _code, _message, _data} = error -> mask_non_architect_argument_error(server, name, error)
      {:ok, _arguments} = result -> result
    end
  end

  defp mask_non_architect_argument_error(
         %__MODULE__{session: %Session{assignment: %{grant_role: "architect"}}},
         _name,
         error
       ),
       do: error

  defp mask_non_architect_argument_error(%__MODULE__{session: nil}, _name, error), do: error

  defp mask_non_architect_argument_error(%__MODULE__{session: %Session{}}, name, _error) do
    architect_error(:architect_grant_required, name)
  end

  defp require_worker_tool_binding(%__MODULE__{session: nil}, name) do
    {:error, -32_001, "Unauthorized", %{"resource" => name, "reason" => "claim_required", "action" => @local_assignment_claim_tool}}
  end

  defp require_worker_tool_binding(%__MODULE__{session: %Session{assignment: %{grant_role: "worker"}}}, _name), do: :ok

  defp require_worker_tool_binding(%__MODULE__{session: %Session{}}, name) do
    worker_error(:worker_grant_required, name)
  end

  defp require_architect_tool_binding(%__MODULE__{session: nil}, name) do
    {:error, -32_001, "Unauthorized",
     %{
       "resource" => name,
       "reason" => "claim_required",
       "action" => @local_architect_assignment_claim_tool,
       "message" => "#{name} needs this session to hold the WorkRequest's architect claim. Claim it with #{@local_architect_assignment_claim_tool} and its work_request_id, then retry.",
       "recovery" => %{"next_action" => "claim_then_retry", "tool" => @local_architect_assignment_claim_tool}
     }}
  end

  defp require_architect_tool_binding(%__MODULE__{session: %Session{assignment: %{grant_role: "architect"}}}, _name), do: :ok

  defp require_architect_tool_binding(%__MODULE__{session: %Session{}}, name)
       when name in @delivery_policy_tools or name == "update_work_package" do
    architect_error(:architect_grant_required, name)
  end

  defp require_architect_tool_binding(%__MODULE__{session: %Session{}}, _name), do: :ok

  defp prepare_bootstrap_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- authorize_bootstrap_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name) do
      bootstrap_tool_arguments(params, name)
    end
  end

  defp prepare_assignment_release_tool_call(%__MODULE__{} = server, params) do
    with :ok <- require_tool_arguments_object(params, @assignment_release_tool),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, @assignment_release_tool) do
      assignment_release_tool_arguments(params)
    end
  end

  defp prepare_local_operator_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- authorize_local_operator_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name) do
      local_operator_tool_arguments(params, name)
    end
  end

  defp require_tool_arguments_object(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> :ok
      _arguments -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp authorize_bootstrap_tool_call(%__MODULE__{} = server, tool), do: authorize_trusted_local_tool_call(server, tool)

  defp authorize_local_operator_tool_call(%__MODULE__{} = server, tool), do: authorize_trusted_local_tool_call(server, tool)

  defp authorize_trusted_local_tool_call(%__MODULE__{} = server, tool), do: LocalTrustedTools.authorize(server, tool)

  defp prepare_mcp_repository(repo), do: Repository.ensure_migrated(repo)

  defp prepare_mcp_repository_for_tool(repo, tool) do
    case prepare_mcp_repository(repo) do
      :ok -> :ok
      {:error, reason} -> service_error(reason, tool)
    end
  end

  defp bootstrap_tool("create_work_request", arguments, %__MODULE__{config: config} = server) do
    with {:ok, requested_claimed_by} <- create_work_request_requested_claimed_by(arguments),
         {:ok, attrs} <- create_work_request_attrs(arguments, requested_claimed_by),
         {:ok, work_request} <- WorkRequestService.create(config.repo, Map.put(attrs, "dispatched_by", Chiefs.attribution(server))) do
      effective_claimed_by = requested_claimed_by || ArchitectHandoff.claimed_by()
      payload = create_work_request_handoff_payload(server, work_request, effective_claimed_by)

      {:ok, ToolResult.architect_agent_tool_result(payload, :create_work_request_handoff)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason}}
      {:error, reason} -> create_work_request_error(reason)
    end
  end

  defp bootstrap_tool("register_chief", arguments, %__MODULE__{config: config} = server) do
    case Chiefs.register(config.repo, server.state_key, arguments) do
      {:ok, chief} ->
        {:ok, ToolResult.tool_result(%{"chief" => %{"id" => chief.id, "domain" => chief.domain, "repos" => chief.repos, "registered_at" => DateTime.to_iso8601(chief.registered_at)}})}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_invalid_params_error("register_chief", "invalid_chief", changeset)

      {:error, reason} ->
        service_error(reason, "register_chief")
    end
  end

  defp create_work_request_attrs(arguments, claimed_by) do
    with {:ok, repo} <- required_argument(arguments, "repo"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, request_kind} <- required_argument(arguments, "request_kind"),
         {:ok, description} <- required_argument(arguments, "description"),
         {:ok, workflow_mode} <- optional_string_argument(arguments, "workflow_mode", "architect_led_feature_branch"),
         {:ok, repo_scopes} <- optional_list_argument(arguments, "repo_scopes"),
         {:ok, constraints} <- optional_object_argument(arguments, "constraints"),
         {:ok, creator_kind} <- optional_string_argument(arguments, "creator_kind", "agent"),
         {:ok, creator_name} <- optional_string_argument(arguments, "creator_name", claimed_by || "mcp-agent"),
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
         "creator_kind" => creator_kind,
         "creator_name" => creator_name,
         "created_via" => created_via
       }}
    end
  end

  defp create_work_request_requested_claimed_by(arguments) do
    optional_string_argument(arguments, "claimed_by")
  end

  defp create_work_request_handoff_payload(%__MODULE__{} = server, %WorkRequest{} = work_request, claimed_by) do
    case create_work_request_architect_handoff(server, work_request, claimed_by) do
      {:ok, handoff} ->
        %{
          "status" => "created",
          "work_request" => WorkRequestPayloads.work_request(work_request),
          "architect_handoff" => json_safe_payload(handoff),
          "launch_prompt" => Map.get(handoff, :prompt)
        }
        |> drop_nil_values()

      {:error, reason} ->
        create_work_request_partial_handoff_payload(work_request, reason)
    end
  end

  defp create_work_request_partial_handoff_payload(%WorkRequest{} = work_request, reason) do
    %{
      "status" => "partial_success",
      "work_request" => WorkRequestPayloads.work_request(work_request),
      "architect_handoff" => nil,
      "handoff_error" => %{
        "reason" => reason_text(reason),
        "message" => ArchitectHandoff.error_message(reason)
      },
      "retry" => %{
        "type" => "local_architect_assignment_claim",
        "work_request_id" => work_request.id,
        "operator_action" => "claim_local_architect_assignment"
      }
    }
  end

  defp create_work_request_architect_handoff(%__MODULE__{config: config} = server, %WorkRequest{} = work_request, claimed_by) do
    with {:ok, handoff_opts} <- create_work_request_handoff_opts(config, claimed_by) do
      ArchitectHandoff.create_or_replay(config.repo, work_request.id,
        local_operator?: true,
        local_architect_claim?: local_architect_claim_handoff_enabled?(server),
        handoff_opts: handoff_opts
      )
    end
  end

  defp local_architect_claim_handoff_enabled?(%__MODULE__{} = server) do
    require_local_architect_assignment_claim_mode(server) == :ok
  end

  defp create_work_request_handoff_opts(%Config{} = config, claimed_by) do
    {:ok,
     [claimed_by: claimed_by]
     |> put_optional_handoff_opt(:database, create_work_request_handoff_database(config))}
  end

  defp create_work_request_handoff_database(%Config{} = config) do
    case HandoffDatabase.resolve(config.database, config.repo) do
      {:ok, database} -> database
      _result -> nil
    end
  end

  defp local_operator_tool("summarize_failed_mcp_calls", _arguments, %__MODULE__{config: config}) do
    {:ok, ToolResult.tool_result(LocalTrustedTools.failed_call_summary(config))}
  end

  defp local_operator_tool("record_work_request_operator_decision", arguments, %__MODULE__{config: config} = server) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- local_operator_created_by(arguments, server),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id"),
         {:ok, work_request} <- WorkRequestService.get(config.repo, work_request_id),
         {:ok, decision_record} <-
           WorkRequestService.record_decision(
             config.repo,
             work_request.id,
             local_operator_decision_attrs(decision, rationale, scope_impact, created_by, source_id)
           ) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
         "provenance" => local_operator_note_provenance(created_by, source_id)
       })}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "record_work_request_operator_decision", "reason" => reason}}

      {:error, :not_found} ->
        not_found_error("record_work_request_operator_decision")

      {:error, reason} ->
        local_operator_error(reason, "record_work_request_operator_decision")
    end
  end

  defp local_operator_decision_attrs(decision, rationale, scope_impact, created_by, source_id) do
    %{
      "source_type" => "operator",
      "decision" => Redactor.redact_text(decision),
      "rationale" => Redactor.redact_text(rationale),
      "scope_impact" => Redactor.redact_text(scope_impact),
      "created_by" => Redactor.redact_text(created_by)
    }
    |> optional_put("source_id", Redactor.redact_text(source_id))
  end

  defp local_operator_note_provenance(created_by, source_id) do
    %{"source_type" => "operator", "created_by" => Redactor.redact_text(created_by)}
    |> optional_put("source_id", Redactor.redact_text(source_id))
  end

  defp local_operator_created_by(arguments, %__MODULE__{} = server) do
    with {:ok, live_session} <- SessionBindingTools.tool_surface_session(server) do
      case live_session do
        %Session{} -> optional_string_argument(arguments, "created_by", session_claimed_by(live_session))
        nil -> required_argument(arguments, "created_by")
      end
    end
  end

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session} = server) when name in @architect_work_request_tools do
    ArchitectWorkRequestTools.call(name, config, session, arguments, server: server)
  end

  defp architect_tool("resolve_blocker", arguments, %__MODULE__{config: config, session: session}),
    do: BlockerTools.call("resolve_blocker", config, session, arguments)

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session})
       when name in @architect_planning_tools,
       do: WorkerTools.call(name, config, session, arguments)

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session})
       when name in [
              "reconcile_work_request",
              "attach_branch",
              "sync_pr",
              "record_work_package_delivery",
              "cleanup_work_request_work_package_runtime",
              "revoke_work_package_worker_key",
              "force_release_work_package_claim"
            ],
       do: ArchitectDeliveryTools.call(name, config, session, arguments)

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session}) when name in @architect_product_tree_tools do
    ArchitectProductTreeTools.call(name, config, session, arguments)
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, _key, value) when is_binary(value) and value == "", do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp release_current_assignment(arguments, %__MODULE__{} = server),
    do: SessionBindingTools.release_current_assignment(arguments, server)

  defp current_assignment_context(%__MODULE__{} = server), do: SessionBindingTools.current_assignment_context(server)

  defp current_assignment_summary(repo, %Session{} = session), do: SessionBindingTools.current_assignment_summary(repo, session)

  defp solo_tool(name, arguments, %__MODULE__{config: config}) do
    SoloTools.call(name, arguments, config, &worker_error/2)
  end

  defp worker_tool(name, arguments, %__MODULE__{config: config, session: session}) when name in @worker_tool_module_tools,
    do: WorkerTools.call(name, config, session, arguments)

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp create_work_request_error(%Ecto.Changeset{} = changeset) do
    changeset_invalid_params_error("create_work_request", "invalid_work_request", changeset)
  end

  defp create_work_request_error(:id_already_exists) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => "id_already_exists"}}
  end

  defp create_work_request_error(:database_busy), do: service_error(:database_busy, "create_work_request")
  defp create_work_request_error({:storage_failed, _reason} = reason), do: service_error(reason, "create_work_request")

  defp create_work_request_error(reason) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason_text(reason)}}
  end

  defp worker_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp worker_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp worker_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp worker_error(:assignment_mismatch, resource), do: auth_error({:unauthorized, :assignment_mismatch}, resource)
  defp worker_error(:worker_grant_required, resource), do: auth_error({:unauthorized, :worker_grant_required}, resource)
  defp worker_error({:authorization_policy_denied, %Decision{} = decision}, resource), do: MCPError.from_decision(decision, resource)
  defp worker_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp worker_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp worker_error({:scope_lookup_failed, reason}, tool), do: service_error(reason, tool)
  defp worker_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp worker_error(:work_request_archived, tool),
    do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"phase" => "archived"})

  defp worker_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp local_operator_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp local_operator_error({:service_unavailable, _reason} = reason, tool), do: service_error(reason, tool)
  defp local_operator_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp local_operator_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp local_operator_error(:work_request_archived, tool),
    do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"phase" => "archived"})

  defp local_operator_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp architect_error(:architect_grant_required, resource) do
    {:error, code, message, data} = auth_error({:unauthorized, :architect_grant_required}, resource)
    {:error, code, message, Map.put(data, "recovery", %{"next_action" => "return_to_architect", "next_owner" => "architect"})}
  end

  defp invalid_params_error(tool, reason) when reason in [:missing_repo_root, "missing_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "missing_repo_root",
       "message" => "No sympp helper root was provided or discoverable; pass symphony_repo_root or configure --repo-root to the sympp repo containing the worker secret helper script."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:invalid_repo_root, "invalid_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_repo_root",
       "message" => "symphony_repo_root must point to the sympp helper/namespace repo root containing the worker secret helper script under scripts/; it is not the target product repository root."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:missing_target_repo_root, "missing_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "missing_target_repo_root",
       "message" => "target_repo_root must point to the target product repository root used for git worktree operations."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:invalid_target_repo_root, "invalid_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_target_repo_root",
       "message" => "target_repo_root must point to an existing target product repository root."
     }}
  end

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    ErrorDetails.changeset_invalid_params_error(tool, reason, changeset)
  end

  defp authorize_solo_tool_call(%__MODULE__{session_refresh_required: true}, tool) do
    {:error, -32_001, "Unauthorized",
     %{
       "tool" => tool,
       "reason" => "claim_required",
       "action" => @local_assignment_claim_tool,
       "hint" => "This MCP state no longer has a live current assignment. Reclaim the assignment or start a fresh MCP session before using Solo tools."
     }}
  end

  defp authorize_solo_tool_call(%__MODULE__{session: nil}, _tool), do: :ok

  defp authorize_solo_tool_call(%__MODULE__{} = server, tool) do
    {:error, -32_001, "Unauthorized", bound_solo_tool_denial(tool, server)}
  end

  defp bound_solo_tool_denial(tool, %__MODULE__{} = server) do
    %{
      "tool" => tool,
      "reason" => "solo_tools_require_unbound_session",
      "action" => @assignment_release_tool,
      "current_assignment" => current_assignment_context(server),
      "recovery" => %{
        "tool" => @assignment_release_tool,
        "next_action" => "call_release_current_assignment_then_retry_solo_tool",
        "fresh_mcp_session_required" => false,
        "fallback" => "If release_current_assignment is unavailable or returns fresh_mcp_session_required=true, start a fresh MCP session before using Solo tools."
      }
    }
  end

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

  # Reads only keep a live claim fresh; claim state never blocks or reclaims them.
  defp require_current_session_claim_for_bound_call(%__MODULE__{} = server, "tools/call" = method, %{"name" => name} = params)
       when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    if is_map(arguments) and ToolCatalog.read_call?(name, arguments),
      do: SessionBindingTools.refresh_current_session_claim_for_read(server, method, params),
      else: SessionBindingTools.require_current_session_claim_for_bound_call(server, method, params)
  end

  defp require_current_session_claim_for_bound_call(%__MODULE__{} = server, "resources/read" = method, params),
    do: SessionBindingTools.refresh_current_session_claim_for_read(server, method, params)

  defp require_current_session_claim_for_bound_call(%__MODULE__{} = server, method, params),
    do: SessionBindingTools.require_current_session_claim_for_bound_call(server, method, params)

  defp auth_error(:unauthorized, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  end

  defp auth_error({:unauthorized, reason}, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  end

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource) do
    {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  end

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp request_params(%{"params" => params}) when is_map(params), do: {:ok, params}

  defp request_params(%{"params" => params}) when is_list(params),
    do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}

  defp request_params(%{"params" => _params}),
    do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object_or_array"}}

  defp request_params(_request), do: {:ok, %{}}

  defp dispatch_request({:ok, params}, method, id, %__MODULE__{} = server) do
    dispatch_request_state({:ok, params}, method, id, server)
    |> elem(0)
  end

  defp dispatch_request({:error, code, message, data}, _method, id, %__MODULE__{}) do
    Response.error(id, code, message, data)
  end

  defp dispatch_request_state({:ok, params}, method, id, %__MODULE__{} = server) do
    with {:ok, server} <- auto_claim_architect(server, method, params),
         {:ok, server} <- require_current_session_claim_for_bound_call(server, method, params) do
      case dispatch_with_text_profile(method, params, server) do
        {:ok, result} ->
          {Response.response(id, result), server}

        {:ok, result, %__MODULE__{} = updated_server} ->
          {Response.response(id, result), updated_server}

        {:error, code, message, data} ->
          {Response.error(id, code, message, data), server}
      end
    else
      {:error, code, message, data} ->
        {Response.error(id, code, message, data), server}

      {:error, code, message, data, %__MODULE__{} = updated_server} ->
        {Response.error(id, code, message, data), updated_server}
    end
  end

  defp dispatch_request_state({:error, code, message, data}, _method, id, %__MODULE__{} = server) do
    {Response.error(id, code, message, data), server}
  end

  defp auto_claim_architect(
         %__MODULE__{
           session: nil,
           batch_claim_pending: false,
           config: %Config{surface_profile: profile},
           stale_assignment_role: role
         } = server,
         "tools/call",
         %{"name" => name} = params
       )
       when profile in [:full, :architect] and role != "worker" and name in @architect_tools do
    if architect_claim_call?(profile, role, name, params) and Surface.local_trusted_tools_enabled?(server) do
      with {:ok, arguments} <- architect_tool_arguments(params, name) do
        auto_claim_architect_scope(server, arguments)
      end
    else
      {:ok, server}
    end
  end

  defp auto_claim_architect(%__MODULE__{} = server, _method, _params), do: {:ok, server}

  defp architect_claim_call?(profile, role, name, params) do
    arguments = Map.get(params, "arguments", %{})

    is_map(arguments) and not ToolCatalog.read_call?(name, arguments) and
      (name not in @worker_tools or profile == :architect or role == "architect")
  end

  defp auto_claim_architect_scope(server, arguments) do
    claim_arguments = server.stale_architect_claim || Map.take(arguments, ["work_request_id"])

    if is_binary(claim_arguments["work_request_id"]) do
      with {:ok, _result, session} <- claim_local_architect_assignment(%{"arguments" => claim_arguments}, server) do
        {:ok, bind_session(server, session)}
      end
    else
      {:ok, server}
    end
  end

  defp bind_session(server, session) do
    %{
      server
      | session: session,
        session_refresh_required: false,
        stale_assignment_role: nil,
        stale_architect_claim: nil
    }
  end

  defp dispatch_with_text_profile(method, params, %__MODULE__{} = server) do
    build_tool_result(server, fn -> dispatch_call(method, params, server) end)
  end

  defp dispatch_call("tools/call", %{"name" => name} = params, %__MODULE__{} = server) do
    if local_trusted_read?(server, params),
      do: local_trusted_read(name, params, %{server | session: nil}),
      else: dispatch("tools/call", params, server)
  end

  defp dispatch_call(method, params, %__MODULE__{} = server), do: dispatch(method, params, server)

  # A trusted local session reads any object it names, whatever it holds, and
  # such a read neither renews nor reclaims the session's claim. Unbound
  # sessions route the WorkRequest reads here even without trust, so the
  # handler can say which connection they need.
  defp local_trusted_read?(%__MODULE__{} = server, %{"name" => name} = params) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})
    is_map(arguments) and ToolCatalog.read_call?(name, arguments) and local_trusted_read_route?(server, name, arguments)
  end

  defp local_trusted_read?(%__MODULE__{}, _params), do: false

  # A session that last held a worker claim gains no session-free reads beyond the unbound ones it already had.
  defp local_trusted_read_route?(%__MODULE__{session: nil, stale_assignment_role: "worker"}, name, _arguments)
       when name in ["read_task_plan", "reconcile_work_request"],
       do: false

  defp local_trusted_read_route?(%__MODULE__{session: nil}, name, _arguments) when name in @session_free_read_tools, do: true

  defp local_trusted_read_route?(%__MODULE__{session: session} = server, name, arguments)
       when name in @session_free_read_tools or name in @trusted_target_read_tools do
    (is_nil(session) or match?(%Session{assignment: %{grant_role: "architect"}}, session)) and
      explicit_read_target?(arguments) and Surface.local_trusted_tools_enabled?(server)
  end

  defp local_trusted_read_route?(%__MODULE__{}, _name, _arguments), do: false

  defp explicit_read_target?(arguments),
    do: Enum.any?(@explicit_read_target_keys, &(is_binary(arguments[&1]) and String.trim(arguments[&1]) != ""))

  defp local_trusted_read(name, params, server) when name in @session_free_read_tools do
    with :ok <- prepare_local_trusted_read(server, params, name),
         {:ok, arguments} <- architect_tool_arguments(params, name) do
      ArchitectWorkRequestTools.call(name, server.config, nil, arguments, server: server)
    end
  end

  defp local_trusted_read(name, params, server), do: trusted_only_read(name, params, Map.get(params, "arguments", %{}), server)

  defp trusted_only_read("read_task_plan", params, _arguments, server) do
    with :ok <- prepare_local_trusted_read(server, params, "read_task_plan"),
         {:ok, arguments} <- architect_tool_arguments(params, "read_task_plan"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, result} <- TaskPlanTools.local_trusted_read_task_plan(server.config.repo, work_package_id) do
      {:ok, result}
    else
      {:error, _code, _message, _data} = error -> error
      {:tool_error, reason} -> invalid_params_error("read_task_plan", reason)
      {:error, :not_found} -> not_found_error("read_task_plan")
      {:error, reason} -> local_operator_error(reason, "read_task_plan")
    end
  end

  defp trusted_only_read("reconcile_work_request", params, arguments, server) do
    with :ok <- prepare_local_trusted_read(server, params, "reconcile_work_request") do
      ArchitectDeliveryTools.local_trusted_reconcile_dry_run(server.config, arguments)
    end
  end

  defp prepare_local_trusted_read(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- authorize_trusted_local_tool_call(server, name) do
      prepare_mcp_repository_for_tool(server.config.repo, name)
    end
  end

  defp build_tool_result(%__MODULE__{} = server, fun) when is_function(fun, 0) do
    ToolResult.with_text_profile(response_text_profile(server), fun)
  end

  defp build_release_tool_result(%__MODULE__{} = server, result) do
    build_tool_result(server, fn -> ToolResult.release_tool_result(result) end)
  end

  defp response_text_profile(%__MODULE__{config: %Config{mode: :stdio, surface_profile: :full}}), do: :full
  defp response_text_profile(%__MODULE__{}), do: :canonical

  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false

  defp handle_batch_item(payload, %__MODULE__{} = server) when is_map(payload) do
    {response, updated_server} = handle_state(payload, server)
    {response, SessionLocations.observe(payload, response, updated_server)}
  end

  defp handle_batch_item(_payload, %__MODULE__{} = server) do
    {Response.error(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"}), server}
  end
end
